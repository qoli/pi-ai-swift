#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [upstreamRoot, casePath, protocolPath] = process.argv.slice(2);
if (!upstreamRoot || !casePath || !protocolPath) {
  throw new Error("usage: pi-ai-replay-oracle.mjs UPSTREAM_ROOT CASE_JSON PROTOCOL_JSON");
}

const fixture = JSON.parse(await readFile(casePath, "utf8"));
const protocolFixture = JSON.parse(await readFile(protocolPath, "utf8"));
if (fixture.schemaVersion !== 1) throw new Error(`unsupported replay case schema: ${fixture.schemaVersion}`);
const revision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) {
  throw new Error(`replay oracle revision mismatch: expected ${fixture.upstreamRevision}, found ${revision}`);
}

const protocols = protocolFixture.protocols.filter((value) => value.protocolID !== "openrouter-images");
const results = {};
for (const scenario of fixture.scenarios) {
  results[scenario.caseID] = {};
  for (const protocol of protocols) {
    if (scenario.protocolIDs && !scenario.protocolIDs.includes(protocol.protocolID)) continue;
    results[scenario.caseID][protocol.protocolID] = await capture(protocol, scenario);
  }
}

process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  caseIDs: fixture.scenarios.map((value) => value.caseID),
  protocolSet: protocols.map((value) => value.protocolID).sort(),
  scenarios: results,
}, null, 2)}\n`);

async function capture(protocol, scenario) {
  const implementation = await providerStreams(
    upstreamRoot,
    await import(
      pathToFileURL(path.join(upstreamRoot, "packages/ai/src/api", `${protocol.protocolID}.ts`)).href
    ),
  );
  let payload;
  const model = textModel(protocol, scenario);
  const primarySchema = scenario.toolSchema === "root-ref"
    ? { $ref: "#/$defs/input", $defs: { input: { type: "object", properties: { city: { type: "string" } }, required: ["city"] } } }
    : { type: "object", properties: { city: { type: "string" } }, required: ["city"] };
  const tools = [{
    name: "weather",
    description: "Read weather",
    parameters: primarySchema,
    ...(scenario.constrainedSampling === "strict-prefer"
      ? { constrainedSampling: { type: "json_schema", strict: "prefer" } }
      : scenario.constrainedSampling === "strict-require"
        ? { constrainedSampling: { type: "json_schema", strict: "require" } }
        : scenario.constrainedSampling === "grammar"
          ? { constrainedSampling: { type: "grammar", variants: { openai_lark: "start: /[a-z]+/" } } }
          : scenario.constrainedSampling === "grammar-regex"
            ? { constrainedSampling: { type: "grammar", variants: { openai_regex: "[a-z]+" } } }
            : {}),
  }];
  if (scenario.consecutiveToolResults) {
    tools.push({
      name: "weather2",
      description: "Read another weather report",
      parameters: { type: "object", properties: { city: { type: "string" } }, required: ["city"] },
    });
  }
  if (scenario.addedToolNames?.includes("lookup")) {
    tools.push({
      name: "lookup",
      description: "Look up a place",
      parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
    });
  }
  const context = {
    systemPrompt: "Replay exactly",
    messages: replayMessages(protocol, scenario),
    tools,
  };
  const options = {
    apiKey: credential(protocol.protocolID),
    ...(!scenario.omitMaximumOutputTokens ? { maxTokens: 64 } : {}),
    ...(scenario.temperature !== undefined ? { temperature: scenario.temperature } : {}),
    maxRetries: 0,
    cacheRetention: scenario.cacheRetention ?? "none",
    ...(scenario.sessionID ? { sessionId: scenario.sessionID } : {}),
    ...(scenario.toolChoice ? { toolChoice: scenario.toolChoice } : {}),
    ...(scenario.reasoningEffort && scenario.reasoningEffort !== "off"
      ? { reasoning: scenario.reasoningEffort }
      : {}),
    env: {
      AWS_REGION: "us-east-1",
      AWS_BEDROCK_SKIP_AUTH: "1",
      GOOGLE_CLOUD_PROJECT: "fixture-project",
      GOOGLE_CLOUD_LOCATION: "us-central1",
    },
    onPayload(value) {
      payload = value;
      throw new OracleCaptureComplete();
    },
  };
  if (!["google-generative-ai", "google-vertex", "bedrock-converse-stream"].includes(protocol.protocolID)) {
    options.fetch = () => { throw new Error(`unexpected network request: ${protocol.protocolID}`); };
  }
  const result = await implementation.streamSimple(model, context, options).result();
  if (payload === undefined) {
    throw new Error(`${protocol.protocolID}/${scenario.caseID} did not expose a payload: ${result.errorMessage ?? "unknown"}`);
  }
  return { requestBody: canonicalize(canonicalRequestBody(protocol.protocolID, payload)) };
}

function replayMessages(protocol, scenario) {
  const sameSource = scenario.sameSource;
  const signatures = protocolSignatures(protocol.protocolID);
  const messages = [
    {
      role: "user",
      content: scenario.imageInput
        ? [{ type: "text", text: "First turn" }, { type: "image", data: "AQI=", mimeType: "image/png" }]
        : "First turn",
      timestamp: 0,
    },
    {
      role: "assistant",
      api: sameSource ? protocol.protocolID : "different-api",
      provider: sameSource ? protocol.providerID : "different-provider",
      model: sameSource ? protocol.modelID : "different-model",
      responseId: "prior-response",
      responseModel: "concrete-prior-model",
      content: [
        { type: "text", text: "answer", ...(signatures.text ? { textSignature: signatures.text } : {}) },
        {
          type: "thinking",
          thinking: "private analysis",
          ...(scenario.redactedReasoning ? { redacted: true } : {}),
          ...(signatures.thinking ? { thinkingSignature: signatures.thinking } : {}),
        },
        ...(scenario.consecutiveToolResults ? [{
          type: "toolCall",
          id: "call-second",
          name: "weather2",
          arguments: { city: "Tokyo" },
        }] : []),
        {
          type: "toolCall",
          id: signatures.toolID,
          name: "weather",
          arguments: { city: "Taipei" },
          ...(signatures.tool ? { thoughtSignature: signatures.tool } : {}),
          namespace: "fixture.namespace",
        },
      ],
      usage: { input: 1, output: 2, reasoning: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 3, cost: zeroCost() },
      stopReason: scenario.assistantStopReason ?? "toolUse",
      rawStopReason: "tool_use",
      timestamp: 1,
    },
  ];
  if (!scenario.omitToolResult) {
    messages.push({
      role: "toolResult",
      toolCallId: signatures.toolID,
      toolName: "weather",
      content: [
        { type: "text", text: "sunny" },
        ...(scenario.toolResultImage ? [{ type: "image", data: "AQI=", mimeType: "image/png" }] : []),
      ],
      isError: scenario.toolResultError === true,
      timestamp: 2,
    });
    if (scenario.consecutiveToolResults) {
      messages.push({
        role: "toolResult",
        toolCallId: "call-second",
        toolName: "weather2",
        content: [{ type: "text", text: "rain" }],
        isError: false,
        timestamp: 3,
      });
    }
  }
  if (scenario.appendUserAfterAssistant) {
    messages.push({ role: "user", content: "Continue", timestamp: 3 });
  }
  return messages;
}

function protocolSignatures(protocolID) {
  if (["openai-responses", "azure-openai-responses", "openai-codex-responses"].includes(protocolID)) {
    return {
      text: JSON.stringify({ v: 1, id: "msg_prior", phase: "final_answer" }),
      thinking: JSON.stringify({ type: "reasoning", id: "rs_prior", summary: [{ type: "summary_text", text: "private analysis" }], encrypted_content: "encrypted" }),
      tool: undefined,
      toolID: "call_prior|fc_prior",
    };
  }
  if (["google-generative-ai", "google-vertex"].includes(protocolID)) {
    return { text: "dGV4dA==", thinking: "dGhpbms=", tool: "dG9vbA==", toolID: "call-prior" };
  }
  if (protocolID === "openai-completions") {
    return { text: undefined, thinking: "reasoning_content", tool: undefined, toolID: "call-prior" };
  }
  return { text: "opaque-text", thinking: "opaque-thinking", tool: "opaque-tool", toolID: "call-prior" };
}

function textModel(protocol, scenario) {
  return {
    id: protocol.modelID,
    name: protocol.modelID,
    api: protocol.protocolID,
    provider: protocol.providerID,
    baseUrl: protocol.baseURL,
    reasoning: scenario.reasoningEffort ? true : protocol.reasoning,
    input: ["text", "image"],
    cost: zeroCost(),
    contextWindow: 262144,
    maxTokens: protocol.maximumOutputTokens,
    ...((protocol.compat || scenario.forceStrictSupport || scenario.forceGrammarSupport)
      ? { compat: {
          ...(protocol.compat ?? {}),
          ...(scenario.forceStrictSupport ? { supportsStrictMode: true } : {}),
          ...(scenario.forceGrammarSupport ? { supportsOpenAIGrammarTools: true } : {}),
        } }
      : {}),
  };
}

function credential(protocolID) {
  if (protocolID !== "openai-codex-responses") return "fixture-key";
  const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url");
  const body = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "fixture-account" } })).toString("base64url");
  return `${header}.${body}.fixture`;
}

function zeroCost() { return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }; }

function canonicalRequestBody(protocolID, payload) {
  if (protocolID === "mistral-conversations") {
    const body = { ...payload };
    for (const [source, target] of [["maxTokens", "max_tokens"], ["toolChoice", "tool_choice"], ["promptMode", "prompt_mode"], ["reasoningEffort", "reasoning_effort"], ["promptCacheKey", "prompt_cache_key"]]) {
      if (body[source] !== undefined) { body[target] = body[source]; delete body[source]; }
    }
    body.messages = body.messages.map((message) => {
      const wire = { ...message };
      if (wire.toolCalls !== undefined) { wire.tool_calls = wire.toolCalls; delete wire.toolCalls; }
      if (wire.toolCallId !== undefined) { wire.tool_call_id = wire.toolCallId; delete wire.toolCallId; }
      if (Array.isArray(wire.content)) {
        wire.content = wire.content.map((chunk) => {
          const wireChunk = { ...chunk };
          for (const [source, target] of [["imageUrl", "image_url"], ["documentUrl", "document_url"], ["documentName", "document_name"], ["fileId", "file_id"], ["referenceIds", "reference_ids"], ["inputAudio", "input_audio"]]) {
            if (wireChunk[source] !== undefined) { wireChunk[target] = wireChunk[source]; delete wireChunk[source]; }
          }
          return wireChunk;
        });
      }
      return wire;
    });
    return body;
  }
  if (protocolID === "bedrock-converse-stream") {
    const normalizeBinary = (value) => {
      if (ArrayBuffer.isView(value)) {
        return Buffer.from(value.buffer, value.byteOffset, value.byteLength).toString("base64");
      }
      if (Array.isArray(value)) return value.map(normalizeBinary);
      if (value && typeof value === "object") {
        return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalizeBinary(item)]));
      }
      return value;
    };
    const body = normalizeBinary(payload);
    delete body.modelId;
    return body;
  }
  if (!["google-generative-ai", "google-vertex"].includes(protocolID)) return payload;
  const config = payload.config ?? {};
  const body = { contents: payload.contents };
  if (config.systemInstruction !== undefined) body.systemInstruction = { parts: [{ text: config.systemInstruction }] };
  const generationConfig = {};
  for (const key of ["maxOutputTokens", "temperature", "responseMimeType", "responseJsonSchema", "thinkingConfig"]) {
    if (config[key] !== undefined) generationConfig[key] = config[key];
  }
  if (Object.keys(generationConfig).length > 0) body.generationConfig = generationConfig;
  if (config.tools !== undefined) body.tools = config.tools;
  if (config.toolConfig !== undefined) body.toolConfig = config.toolConfig;
  return body;
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => [key, canonicalize(item)]));
  }
  return value;
}

class OracleCaptureComplete extends Error {}
