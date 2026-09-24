#!/usr/bin/env node

import { registerHooks } from "node:module";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { installEmissionSnapshots, emissionSnapshot } from "./pi-ai-emission-snapshots.mjs";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const GOOGLE_MOCK_URL = "oracle:google-genai-response-branches";
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "@google/genai") return { url: GOOGLE_MOCK_URL, shortCircuit: true };
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url !== GOOGLE_MOCK_URL) return nextLoad(url, context);
    return {
      format: "module",
      shortCircuit: true,
      source: `
        export const FinishReason = Object.freeze({
          STOP: "STOP", MAX_TOKENS: "MAX_TOKENS", SAFETY: "SAFETY", BLOCKLIST: "BLOCKLIST",
          PROHIBITED_CONTENT: "PROHIBITED_CONTENT", SPII: "SPII", IMAGE_SAFETY: "IMAGE_SAFETY",
          IMAGE_PROHIBITED_CONTENT: "IMAGE_PROHIBITED_CONTENT", IMAGE_RECITATION: "IMAGE_RECITATION",
          IMAGE_OTHER: "IMAGE_OTHER", RECITATION: "RECITATION", FINISH_REASON_UNSPECIFIED: "FINISH_REASON_UNSPECIFIED",
          OTHER: "OTHER", LANGUAGE: "LANGUAGE", MALFORMED_FUNCTION_CALL: "MALFORMED_FUNCTION_CALL",
          UNEXPECTED_TOOL_CALL: "UNEXPECTED_TOOL_CALL", NO_IMAGE: "NO_IMAGE"
        });
        export const FunctionCallingConfigMode = Object.freeze({ AUTO: "AUTO", NONE: "NONE", ANY: "ANY", VALIDATED: "VALIDATED" });
        export const ResourceScope = Object.freeze({ COLLECTION: "COLLECTION" });
        export const ThinkingLevel = Object.freeze({ MINIMAL: "MINIMAL", LOW: "LOW", MEDIUM: "MEDIUM", HIGH: "HIGH" });
        export class GoogleGenAI {
          models = {
            generateContentStream: async function* () {
              if (globalThis.__PI_GOOGLE_RESPONSE_ERROR__) throw new Error(globalThis.__PI_GOOGLE_RESPONSE_ERROR__);
              for (const event of globalThis.__PI_GOOGLE_RESPONSE_EVENTS__ ?? []) yield event;
            }
          };
        }
      `,
    };
  },
});

const [upstreamRoot, casePath, outputPath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) {
  throw new Error("usage: pi-ai-provider-response-branches-oracle.mjs UPSTREAM_ROOT CASE_JSON [OUTPUT_JSON]");
}
await installEmissionSnapshots(upstreamRoot);
const fixture = JSON.parse(await readFile(casePath, "utf8"));
if (fixture.schemaVersion !== 1) throw new Error(`unsupported fixture schema: ${fixture.schemaVersion}`);
const upstreamRevision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (upstreamRevision !== fixture.upstreamRevision) {
  throw new Error(`response branch revision mismatch: expected ${fixture.upstreamRevision}, found ${upstreamRevision}`);
}

const cases = {};
for (const scenario of fixture.scenarios) {
  cases[scenario.caseID] = {};
  for (const protocolID of scenario.protocolIDs) {
    cases[scenario.caseID][protocolID] = await execute(protocolID, scenario);
  }
}
const rendered = `${JSON.stringify({ schemaVersion: 1, upstreamRevision, cases }, null, 2)}\n`;
if (outputPath) await writeFile(outputPath, rendered);
else process.stdout.write(rendered);

async function execute(protocolID, scenario) {
  const implementation = await providerStreams(
    upstreamRoot,
    await import(
      pathToFileURL(path.join(upstreamRoot, "packages/ai/src/api", `${protocolID}.ts`)).href
    ),
  );
  if (protocolID === "openrouter-images") {
    const output = await implementation.generateImages(
      imageModel(),
      { input: [{ type: "text", text: "create an image" }] },
      { apiKey: "fixture-key", maxRetries: 0, fetch: fakeFetch(scenario) },
    );
    return {
      decoderInput: decoderInput(scenario),
      sourceOutcome: output.stopReason === "error" || output.stopReason === "aborted"
        ? { kind: "failure", stopReason: output.stopReason, errorMessage: output.errorMessage ?? null }
        : { kind: "success", events: imageEvents(output), terminalReplay: canonicalTerminalImages(output) },
      swiftExplicitFailure: scenario.swiftExplicitFailure === true,
    };
  }

  const model = textModel(protocolID);
  const options = { apiKey: "fixture-key", maxRetries: 0, cacheRetention: "none" };
  if (protocolID === "google-generative-ai" || protocolID === "google-vertex") {
    globalThis.__PI_GOOGLE_RESPONSE_EVENTS__ = scenario.events ?? [];
    globalThis.__PI_GOOGLE_RESPONSE_ERROR__ = scenario.errorMessage;
    options.env = { GOOGLE_CLOUD_PROJECT: "fixture-project", GOOGLE_CLOUD_LOCATION: "us-central1" };
  } else {
    options.fetch = fakeFetch(scenario);
  }
  const projected = await projectAssistantStream(
    implementation.stream(model, baseContext(), options),
    protocolID,
  );
  globalThis.__PI_GOOGLE_RESPONSE_ERROR__ = undefined;
  return { decoderInput: decoderInput(scenario), sourceOutcome: projected };
}

async function projectAssistantStream(sourceStream, protocolID) {
  const events = [];
  const signatures = new Map();
  let terminal;
  for await (const sourceEvent of sourceStream) {
    const event = emissionSnapshot(sourceEvent);
    const partial = event.partial ?? event.message ?? event.error;
    if (event.type === "start") {
      events.push({
        type: "responseStarted",
        responseID: partial?.responseId ?? null,
        providerID: partial?.provider,
        modelID: partial?.model,
      });
    }
    if (event.type === "text_delta") {
      events.push({ type: "textDelta", delta: event.delta });
      appendSignature(events, signatures, event.contentIndex, partial?.content?.[event.contentIndex]);
    }
    if (event.type === "thinking_delta") {
      events.push({ type: "reasoningDelta", delta: event.delta });
      appendSignature(events, signatures, event.contentIndex, partial?.content?.[event.contentIndex]);
    }
    if (event.type === "toolcall_start") {
      const block = partial?.content?.[event.contentIndex];
      appendSignature(events, signatures, event.contentIndex, block);
      events.push({ type: "toolCallStarted", id: block?.id ?? "", name: block?.name ?? "" });
    }
    if (event.type === "toolcall_delta") {
      const block = partial?.content?.[event.contentIndex];
      events.push({ type: "toolInputDelta", id: block?.id ?? "", delta: event.delta });
    }
    if (event.type === "toolcall_end") {
      events.push({ type: "toolCallCompleted", toolCall: canonicalToolCall(event.toolCall) });
    }
    if (event.type === "done" || event.type === "error") terminal = event.message ?? event.error;
  }
  if (!terminal) throw new Error(`${protocolID} source stream had no terminal event`);
  if (terminal.stopReason === "error" || terminal.stopReason === "aborted") {
    return {
      kind: "failure",
      stopReason: terminal.stopReason,
      errorMessage: terminal.errorMessage ?? null,
      rawStopReason: terminal.rawStopReason ?? null,
    };
  }
  if (terminal.usage) events.push(usageEvent(terminal.usage));
  events.push({ type: "completed", reason: mapReason(terminal.stopReason) });
  return { kind: "success", events: canonicalize(events), terminalReplay: canonicalTerminalMessage(terminal) };
}

function appendSignature(events, signatures, index, block) {
  if (!block) return;
  const value = block.type === "text"
    ? block.textSignature
    : block.type === "thinking"
      ? block.thinkingSignature
      : block.type === "toolCall" ? block.thoughtSignature : undefined;
  if (typeof value !== "string" || value.length === 0) return;
  const previous = signatures.get(index);
  if (previous === value) return;
  events.push({ type: "reasoningSignatureDelta", delta: value });
  signatures.set(index, value);
}

function decoderInput(scenario) {
  return canonicalize({
    kind: scenario.driver,
    status: scenario.status ?? 200,
    events: scenario.events,
    body: scenario.body,
    rawEvents: scenario.rawEvents,
    rawBody: scenario.rawBody,
    errorMessage: scenario.errorMessage,
  });
}

function fakeFetch(scenario) {
  return async () => {
    const status = scenario.status ?? 200;
    if (scenario.driver === "http-json") {
      return new Response(JSON.stringify(scenario.body), {
        status,
        headers: { "content-type": "application/json" },
      });
    }
    if (scenario.driver === "http-raw") {
      return new Response(scenario.rawBody, {
        status,
        headers: { "content-type": "application/json" },
      });
    }
    const records = scenario.driver === "http-sse-raw"
      ? scenario.rawEvents.map((value) => `data: ${value}`)
      : scenario.events.map((value) => `data: ${JSON.stringify(value)}`);
    const body = `${records.join("\n\n")}\n\ndata: [DONE]\n\n`;
    return new Response(body, { status, headers: { "content-type": "text/event-stream" } });
  };
}

function baseContext() {
  return {
    systemPrompt: "Be concise",
    messages: [{ role: "user", content: "Use the weather tool", timestamp: 0 }],
    tools: [{ name: "weather", description: "Read weather", parameters: { type: "object", properties: { city: { type: "string" } }, required: ["city"] } }],
  };
}
function textModel(protocolID) {
  const vertex = protocolID === "google-vertex";
  return {
    id: protocolID.startsWith("google") ? "gemini-3-flash-preview" : "mistral-fixture",
    name: "fixture-model",
    api: protocolID,
    provider: vertex ? "fixture-vertex" : protocolID === "google-generative-ai" ? "fixture-google" : "fixture-mistral",
    baseUrl: vertex ? "https://us-central1-aiplatform.googleapis.com" : protocolID === "google-generative-ai" ? "https://generativelanguage.googleapis.com/v1beta" : "https://api.mistral.ai/v1",
    reasoning: true,
    input: ["text", "image"],
    cost: zeroCost(), contextWindow: 262144, maxTokens: 4096,
  };
}
function imageModel() {
  return {
    id: "fixture-image", name: "fixture-image", api: "openrouter-images", provider: "fixture-openrouter",
    baseUrl: "https://openrouter.ai/api/v1", input: ["text", "image"], output: ["text", "image"], cost: zeroCost(),
  };
}
function imageEvents(output) {
  const events = [{ type: "responseStarted", responseID: output.responseId ?? null, providerID: output.provider, modelID: output.model }];
  let imageIndex = 0;
  for (const item of output.output) {
    if (item.type === "text") events.push({ type: "textDelta", delta: item.text });
    if (item.type === "image") {
      events.push({ type: "asset", id: `${output.responseId}-image-${imageIndex++}`, kind: "image", mimeType: item.mimeType, dataBase64: item.data });
    }
  }
  if (output.usage) events.push(usageEvent(output.usage));
  events.push({ type: "completed", reason: output.stopReason });
  return canonicalize(events);
}
function mapReason(reason) { return reason === "toolUse" ? "toolCalls" : reason; }
function usageEvent(usage) {
  return { type: "usage", inputTokens: usage.input ?? null, outputTokens: usage.output ?? null, reasoningTokens: usage.reasoning ?? null, cachedInputTokens: usage.cacheRead ?? null };
}
function canonicalToolCall(call) { return { id: call?.id ?? "", name: call?.name ?? "", arguments: canonicalize(call?.arguments ?? {}) }; }
function canonicalTerminalMessage(message) {
  return canonicalize({
    responseID: message.responseId ?? null, responseModel: message.responseModel ?? null,
    providerID: message.provider, modelID: message.model, stopReason: mapReason(message.stopReason),
    rawStopReason: message.rawStopReason ?? null, content: message.content ?? [],
    usage: message.usage ? { input: message.usage.input, output: message.usage.output, reasoning: message.usage.reasoning ?? null, cacheRead: message.usage.cacheRead, cacheWrite: message.usage.cacheWrite, totalTokens: message.usage.totalTokens } : null,
  });
}
function canonicalTerminalImages(output) {
  return canonicalize({
    responseID: output.responseId ?? null, providerID: output.provider, modelID: output.model,
    stopReason: output.stopReason, output: output.output,
    usage: output.usage ? { input: output.usage.input, output: output.usage.output, cacheRead: output.usage.cacheRead, cacheWrite: output.usage.cacheWrite, totalTokens: output.usage.totalTokens } : null,
  });
}
function zeroCost() { return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }; }
function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => [key, canonicalize(item)]));
  }
  return value;
}
