import { fixtureInput, invokeNative, projectNativeRequest, recordNative } from "./bridge.mjs";
import { clampThinkingLevel as upstreamClampThinkingLevel } from "pi-conformance:upstream-models";
import path from "node:path";
import { pathToFileURL } from "node:url";
const { normalizeContext } = await import(pathToFileURL(path.join(process.env.PI_CONFORMANCE_UPSTREAM, "packages/ai/src/utils/transcript.ts")));

export function clampThinkingLevel(...args) {
  recordNative("caller.thinking-clamp", args[0].api, undefined, ["caller-thinking-clamp"]);
  return upstreamClampThinkingLevel(...args);
}

export function getSupportedThinkingLevels(model) {
  const result = invokeNative({
    ...fixtureInput(model, { messages: [] }, {}, [], { key: "fixture", metadata: {} }),
    operation: "reasoning-levels",
  });
  recordNative("catalog.reasoning", model.api, result?.failure);
  if (!Array.isArray(result)) throw new Error(result?.failure?.message ?? "Native reasoning lookup failed");
  return result;
}

export function calculateCost(model, usage) {
  const cost = invokeNative({ operation: "usage.calculate", model, usage });
  recordNative("usage.calculate", "*", cost?.failure);
  if (cost?.failure) throw new Error(cost.failure.message);
  Object.assign(usage.cost, cost);
  return usage.cost;
}

function googleModel(id = "gemini-3-flash-preview") {
  return {
    id, name: id, api: "google-generative-ai", provider: "google",
    baseUrl: "https://fixture.invalid", reasoning: false, input: ["text"],
    contextWindow: 128000, maxTokens: 1024,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  };
}

function googleRequest(model, context, operation, options = {}) {
  const result = projectNativeRequest(model, normalizeContext(context), { apiKey: "fixture", ...options });
  recordNative(operation, model.api, result.failure);
  if (!result.request) throw new Error(result.failure?.message ?? "Native Google request projection failed");
  return result.request.body;
}

export function requiresToolCallId(modelId) {
  const model = googleModel(modelId);
  const body = googleRequest(model, { messages: [{ role: "assistant", api: model.api,
    provider: model.provider, model: model.id, stopReason: "toolUse", timestamp: 0,
    content: [{ type: "toolCall", id: "native-call", name: "probe", arguments: {} }],
  }] }, "google.tool-call-id");
  return body.contents.some(content => content.parts?.some(part => part.functionCall?.id === "native-call"));
}

export function convertTools(tools, useParameters = false, supportsStrictMode = true) {
  if (useParameters && tools.length) {
    recordNative("google.tools", "google-generative-ai", undefined, ["legacy-sdk-openapi-parameters"]);
    throw new Error("Legacy SDK parameters are not used by either pinned Google provider");
  }
  const result = invokeNative({ operation: "google-tools", tools, supportsStrictMode });
  recordNative("google.tools", "google-generative-ai", result?.failure);
  if (result?.failure) throw new Error(result.failure.message);
  return result ?? undefined;
}

export function supportsGoogleStrictToolSampling(modelId) {
  const body = googleRequest(googleModel(modelId), { messages: [], tools: [{ name: "probe",
    description: "", parameters: { type: "object", properties: {} },
    constrainedSampling: { type: "json_schema", strict: "prefer" },
  }] }, "google.strict-tools");
  return body.toolConfig?.functionCallingConfig?.mode === "VALIDATED";
}

export function resolveGoogleFunctionCallingMode(tools, toolChoice, supportsStrictMode) {
  const body = googleRequest(googleModel(supportsStrictMode ? "gemini-3-flash-preview" : "gemini-2.5-flash"),
    { messages: [], tools }, "google.tool-choice", { toolChoice });
  return body.toolConfig?.functionCallingConfig?.mode;
}

function googleParts(parts, operation) {
  const model = googleModel();
  const chunks = parts.map((part, index) => Buffer.from(`data: ${JSON.stringify({
    candidates: [{ content: { parts: [part] }, ...(index === parts.length - 1 ? { finishReason: "STOP" } : {}) }],
  })}\n\n`).toString("base64"));
  const result = projectNativeRequest(model, { messages: [] }, { apiKey: "fixture" },
    [{ status: 200, headers: {}, chunks }]);
  recordNative(operation, model.api, result.failure);
  if (result.failure) throw new Error(result.failure.message);
  return result.events;
}

export function isThinkingPart(part) {
  return googleParts([{ ...part, text: "probe" }], "google.thinking-part")
    .some(event => event.reasoningDelta !== undefined);
}

export function retainThoughtSignature(existing, incoming) {
  const events = googleParts([
    { text: "a", thoughtSignature: existing }, { text: "b", thoughtSignature: incoming },
  ], "google.thought-signature");
  return events.find(event => event.responseSnapshot)?.responseSnapshot._0.content[0]?.text?._0.signature;
}
