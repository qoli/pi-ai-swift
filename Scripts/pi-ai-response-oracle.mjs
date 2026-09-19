#!/usr/bin/env node

import { registerHooks } from "node:module";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import http from "node:http";
import path from "node:path";

const GOOGLE_MOCK_URL = "oracle:google-genai";
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
        export const FinishReason = Object.freeze({ STOP: "STOP", MAX_TOKENS: "MAX_TOKENS" });
        export const FunctionCallingConfigMode = Object.freeze({ AUTO: "AUTO", NONE: "NONE", ANY: "ANY", VALIDATED: "VALIDATED" });
        export const ResourceScope = Object.freeze({ COLLECTION: "COLLECTION" });
        export const ThinkingLevel = Object.freeze({ MINIMAL: "MINIMAL", LOW: "LOW", MEDIUM: "MEDIUM", HIGH: "HIGH" });
        export class GoogleGenAI {
          models = {
            generateContentStream: async function* () {
              for (const event of globalThis.__PI_RESPONSE_ORACLE_GOOGLE_EVENTS__ ?? []) yield event;
            }
          };
        }
      `,
    };
  },
});

const [upstreamRoot, casePath, outputPath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) {
  throw new Error("usage: pi-ai-response-oracle.mjs UPSTREAM_ROOT CASE_JSON");
}

const fixture = JSON.parse(await readFile(casePath, "utf8"));
if (fixture.schemaVersion !== 1) throw new Error(`unsupported response case schema: ${fixture.schemaVersion}`);
const upstreamRevision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (upstreamRevision !== fixture.upstreamRevision) {
  throw new Error(`response oracle revision mismatch: expected ${fixture.upstreamRevision}, found ${upstreamRevision}`);
}
const apiRoot = path.join(upstreamRoot, "packages/ai/src/api");
const protocols = {};

for (const protocol of fixture.protocols) {
  const observation = await runProtocol(protocol, fixtureCost());
  if (!["pi-messages", "openrouter-images"].includes(protocol.protocolID)) {
    const tiered = await runProtocol(protocol, tieredFixtureCost());
    observation.costVariants = {
      base: observation.terminalReplay.usage?.cost,
      tier: tiered.terminalReplay.usage?.cost,
    };
  } else {
    observation.costVariants = {
      [protocol.protocolID === "pi-messages" ? "direct" : "base"]:
        observation.terminalReplay.usage?.cost,
    };
  }
  protocols[protocol.protocolID] = observation;
}

const rendered = `${JSON.stringify({
  schemaVersion: 1,
  caseID: fixture.caseID,
  upstreamRevision,
  protocolSet: fixture.protocols.map((item) => item.protocolID).sort(),
  excludedProtocols: fixture.excludedProtocols,
  protocols,
}, null, 2)}\n`;
if (outputPath) await writeFile(outputPath, rendered, "utf8");
else process.stdout.write(rendered);

async function runProtocol(protocol, modelCost) {
  if (protocol.protocolID === "openrouter-images") return runImages(protocol, modelCost);
  if (protocol.protocolID === "bedrock-converse-stream") return runBedrock(protocol, modelCost);
  const implementation = await import(pathToFileURL(path.join(apiRoot, `${protocol.protocolID}.ts`)).href);
  if (typeof implementation.stream !== "function") throw new Error(`${protocol.protocolID} has no public stream entrypoint`);

  const decoderInput = decoderInputFor(protocol.protocolID);
  if (protocol.driver === "decoded-sdk-events") {
    globalThis.__PI_RESPONSE_ORACLE_GOOGLE_EVENTS__ = decoderInput.events;
  }
  const options = {
    apiKey: credential(protocol.protocolID),
    maxRetries: 0,
    cacheRetention: "none",
    transport: "sse",
    azureDeploymentName: protocol.modelID,
    azureApiVersion: "v1",
    env: { GOOGLE_CLOUD_PROJECT: "fixture-project", GOOGLE_CLOUD_LOCATION: "us-central1" },
  };
  if (protocol.driver.startsWith("http-")) options.fetch = fakeFetch(decoderInput);

  const sourceStream = implementation.stream(textModel(protocol, modelCost), baseContext(), options);
  const projected = await projectAssistantStream(sourceStream, protocol);
  return {
    driver: protocol.driver,
    decoderInput: canonicalize(decoderInput),
    normalizedEvents: projected.events,
    terminalReplay: projected.terminalReplay,
    source: { module: `packages/ai/src/api/${protocol.protocolID}.ts`, entrypoint: "stream" },
  };
}

async function runBedrock(protocol, modelCost) {
  const decoderInput = decoderInputFor(protocol.protocolID);
  const chunks = decoderInput.chunksBase64.map((value) => Buffer.from(value, "base64"));
  const server = http.createServer((request, response) => {
    request.resume();
    request.on("end", () => {
      response.writeHead(200, decoderInput.headers);
      chunks.forEach((chunk) => response.write(chunk));
      response.end();
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  try {
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("invalid Bedrock loopback address");
    const implementation = await import(pathToFileURL(path.join(apiRoot, "bedrock-converse-stream.ts")).href);
    const sourceStream = implementation.stream(
      { ...textModel(protocol, modelCost), baseUrl: `http://127.0.0.1:${address.port}` },
      baseContext(),
      {
        maxRetries: 0,
        env: {
          AWS_BEDROCK_FORCE_HTTP1: "1",
          AWS_BEDROCK_SKIP_AUTH: "1",
          AWS_REGION: "us-east-1",
        },
      },
    );
    const projected = await projectAssistantStream(sourceStream, protocol);
    return {
      driver: protocol.driver,
      decoderInput: canonicalize(decoderInput),
      normalizedEvents: projected.events,
      terminalReplay: projected.terminalReplay,
      source: { module: "packages/ai/src/api/bedrock-converse-stream.ts", entrypoint: "stream" },
    };
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function runImages(protocol, modelCost) {
  const implementation = await import(pathToFileURL(path.join(apiRoot, "openrouter-images.ts")).href);
  const decoderInput = decoderInputFor(protocol.protocolID);
  const output = await implementation.generateImages(
    imageModel(protocol, modelCost),
    { input: [{ type: "text", text: "create an image" }] },
    { apiKey: "fixture-key", maxRetries: 0, fetch: fakeFetch(decoderInput) },
  );
  const events = [{ type: "responseStarted", responseID: output.responseId, providerID: output.provider, modelID: output.model }];
  for (let index = 0; index < output.output.length; index++) {
    const item = output.output[index];
    if (item.type === "text") events.push({ type: "textDelta", delta: item.text });
    if (item.type === "image") events.push({
      type: "asset", id: `${output.responseId}-image-${index - output.output.filter((value, itemIndex) => itemIndex < index && value.type === "text").length}`,
      kind: "image", mimeType: item.mimeType, dataBase64: item.data,
    });
  }
  if (output.usage) events.push(usageEvent(output.usage));
  events.push({ type: "completed", reason: output.stopReason });
  return {
    driver: protocol.driver,
    decoderInput: canonicalize(decoderInput),
    normalizedEvents: canonicalize(events),
    terminalReplay: canonicalTerminalImages(output),
    source: { module: "packages/ai/src/api/openrouter-images.ts", entrypoint: "generateImages" },
  };
}

async function projectAssistantStream(sourceStream, protocol) {
  const events = [];
  const signatures = new Map();
  let terminal;
  let startSeen = false;
  let startResponseID = null;
  for await (const event of sourceStream) {
    const snapshot = structuredClone(event);
    const partial = snapshot.partial ?? snapshot.message ?? snapshot.error;
    if (snapshot.type === "start") {
      startSeen = true;
      startResponseID = partial?.responseId ?? null;
    }
    if (snapshot.type === "text_delta") events.push({ type: "textDelta", delta: snapshot.delta });
    if (snapshot.type === "thinking_delta") events.push({ type: "reasoningDelta", delta: snapshot.delta });
    if (snapshot.type === "toolcall_start") {
      const block = partial?.content?.[snapshot.contentIndex];
      appendBlockSignature(events, signatures, snapshot.contentIndex, block);
      events.push({ type: "toolCallStarted", id: block?.id ?? "", name: block?.name ?? "" });
    }
    if (snapshot.type === "toolcall_delta") {
      const block = partial?.content?.[snapshot.contentIndex];
      events.push({ type: "toolInputDelta", id: block?.id ?? "", delta: snapshot.delta });
    }
    if (snapshot.type === "toolcall_end") events.push({
      type: "toolCallCompleted", toolCall: canonicalToolCall(snapshot.toolCall),
    });
    if (snapshot.type === "thinking_end") {
      appendBlockSignature(
        events,
        signatures,
        snapshot.contentIndex,
        partial?.content?.[snapshot.contentIndex],
      );
    }
    if (snapshot.type === "done" || snapshot.type === "error") terminal = snapshot.message ?? snapshot.error;
  }
  if (!terminal) throw new Error(`${protocol.protocolID} ended without a terminal message`);
  if (terminal.stopReason === "error" || terminal.stopReason === "aborted") {
    throw new Error(`${protocol.protocolID} oracle failed: ${terminal.errorMessage ?? terminal.stopReason}`);
  }
  appendSignatureDeltas(events, signatures, terminal.content ?? []);
  if (terminal.usage) events.push(usageEvent(terminal.usage));
  events.push({ type: "completed", reason: mapReason(terminal.stopReason) });
  if (startSeen) events.unshift({
    type: "responseStarted",
    responseID: protocol.protocolID === "bedrock-converse-stream"
        ? "bedrock-response"
        : startResponseID,
    providerID: terminal.provider,
    modelID: terminal.model,
  });
  return { events: canonicalize(events), terminalReplay: canonicalTerminalMessage(terminal) };
}

function appendSignatureDeltas(events, signatures, content) {
  content.forEach((block, index) => appendBlockSignature(events, signatures, index, block));
}

function appendBlockSignature(events, signatures, index, block) {
  if (!block) return;
  const value = block.type === "thinking" ? block.thinkingSignature : block.type === "toolCall" ? block.thoughtSignature : undefined;
  if (typeof value !== "string" || value.length === 0) return;
  const normalizedValue = canonicalSignature(value);
  const previous = signatures.get(index) ?? "";
  if (normalizedValue !== previous) {
    events.push({ type: "reasoningSignatureDelta", delta: normalizedValue.startsWith(previous) ? normalizedValue.slice(previous.length) : normalizedValue });
    signatures.set(index, normalizedValue);
  }
}

function canonicalSignature(value) {
  try {
    return JSON.stringify(canonicalize(JSON.parse(value)));
  } catch {
    return value;
  }
}

function decoderInputFor(protocolID) {
  if (protocolID === "anthropic-messages") {
    const items = [
      ["message_start", { type: "message_start", message: { id: "message-1", model: "k3-256k", usage: { input_tokens: 12, output_tokens: 0, cache_read_input_tokens: 2, cache_creation_input_tokens: 4, cache_creation: { ephemeral_1h_input_tokens: 2, ephemeral_5m_input_tokens: 2 } } } }],
      ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
      ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Checking" } }],
      ["content_block_stop", { type: "content_block_stop", index: 0 }],
      ["content_block_start", { type: "content_block_start", index: 1, content_block: { type: "thinking", thinking: "" } }],
      ["content_block_delta", { type: "content_block_delta", index: 1, delta: { type: "thinking_delta", thinking: "inspect" } }],
      ["content_block_delta", { type: "content_block_delta", index: 1, delta: { type: "signature_delta", signature: "opaque-signature" } }],
      ["content_block_stop", { type: "content_block_stop", index: 1 }],
      ["content_block_start", { type: "content_block_start", index: 2, content_block: { type: "tool_use", id: "tool-1", name: "weather", input: {} } }],
      ["content_block_delta", { type: "content_block_delta", index: 2, delta: { type: "input_json_delta", partial_json: "{\"city\":\"Tai" } }],
      ["content_block_delta", { type: "content_block_delta", index: 2, delta: { type: "input_json_delta", partial_json: "pei\"}" } }],
      ["content_block_stop", { type: "content_block_stop", index: 2 }],
      ["message_delta", { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 8, output_tokens_details: { thinking_tokens: 2 } } }],
      ["message_stop", { type: "message_stop" }],
    ];
    return sseInput(items.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}`));
  }
  if (protocolID === "openai-completions") return sseInput([
    `data: ${JSON.stringify({ id: "chat-1", model: "fixture-chat", choices: [{ delta: { content: "hello", reasoning_content: "think", tool_calls: [{ index: 0, id: "call-1", function: { name: "weather", arguments: "{\"city\":" } }] }, finish_reason: null }] })}`,
    `data: ${JSON.stringify({ id: "chat-1", model: "fixture-chat", choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: "\"Taipei\"}" } }] }, finish_reason: "tool_calls" }] })}`,
    `data: ${JSON.stringify({ id: "chat-1", model: "fixture-chat", choices: [], usage: { prompt_tokens: 5, completion_tokens: 3, prompt_tokens_details: { cached_tokens: 1 }, completion_tokens_details: { reasoning_tokens: 1 } } })}`,
    "data: [DONE]",
  ]);
  if (["openai-responses", "azure-openai-responses", "openai-codex-responses"].includes(protocolID)) {
    const terminalType = protocolID === "openai-codex-responses" ? "response.done" : "response.completed";
    const response = { id: "response-1", status: "completed", output: [], usage: { input_tokens: 6, output_tokens: 4, total_tokens: 10, input_tokens_details: { cached_tokens: 1 }, output_tokens_details: { reasoning_tokens: 1 } } };
    return sseInput([
      `data: ${JSON.stringify({ type: "response.created", response: { id: "response-1", model: "fixture-responses" } })}`,
      `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 0, item: { type: "reasoning", id: "rs_1", summary: [] } })}`,
      `data: ${JSON.stringify({ type: "response.reasoning_text.delta", output_index: 0, delta: "inspect" })}`,
      `data: ${JSON.stringify({ type: "response.output_item.done", output_index: 0, item: { type: "reasoning", id: "rs_1", summary: [{ type: "summary_text", text: "inspect" }], encrypted_content: "encrypted-reasoning" } })}`,
      `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 1, item: { type: "message", id: "msg_1", role: "assistant", status: "in_progress", content: [] } })}`,
      `data: ${JSON.stringify({ type: "response.output_text.delta", output_index: 1, delta: "hello" })}`,
      `data: ${JSON.stringify({ type: "response.output_item.done", output_index: 1, item: { type: "message", id: "msg_1", role: "assistant", status: "completed", phase: "final_answer", content: [{ type: "output_text", text: "hello", annotations: [] }] } })}`,
      `data: ${JSON.stringify({ type: "response.output_item.added", output_index: 2, item: { type: "function_call", id: "fc_1", call_id: "call_1", name: "weather", arguments: "" } })}`,
      `data: ${JSON.stringify({ type: "response.function_call_arguments.delta", output_index: 2, item_id: "fc_1", delta: "{\"city\":\"Taipei\"}" })}`,
      `data: ${JSON.stringify({ type: "response.output_item.done", output_index: 2, item: { type: "function_call", id: "fc_1", call_id: "call_1", name: "weather", arguments: "{\"city\":\"Taipei\"}", status: "completed" } })}`,
      `data: ${JSON.stringify({ type: terminalType, response })}`,
      "data: [DONE]",
    ]);
  }
  if (["google-generative-ai", "google-vertex"].includes(protocolID)) return {
    kind: "decoded-sdk-events",
    events: [{
      responseId: "google-response-1",
      candidates: [{ content: { role: "model", parts: [
        { text: "inspect", thought: true, thoughtSignature: "YWJjZA==" },
        { text: "ready" },
        { functionCall: { id: "call-1", name: "weather", args: { city: "Taipei" } }, thoughtSignature: "ZWZnaA==" },
      ] }, finishReason: "STOP" }],
      usageMetadata: { promptTokenCount: 12, candidatesTokenCount: 5, thoughtsTokenCount: 2, cachedContentTokenCount: 3, totalTokenCount: 19 },
    }],
  };
  if (protocolID === "mistral-conversations") return sseInput([
    `data: ${JSON.stringify({ id: "mistral-response", choices: [{ delta: { content: "Checking" } }] })}`,
    `data: ${JSON.stringify({ id: "mistral-response", choices: [{ delta: { content: [{ type: "thinking", thinking: [{ type: "text", text: "Need a lookup" }] }] } }] })}`,
    `data: ${JSON.stringify({ id: "mistral-response", choices: [{ delta: { tool_calls: [{ index: 0, id: "call-1", function: { name: "weather", arguments: "{\"city\":\"Tai" } }] } }] })}`,
    `data: ${JSON.stringify({ id: "mistral-response", choices: [{ delta: { tool_calls: [{ index: 0, function: { name: "", arguments: "pei\"}" } }] } }] })}`,
    `data: ${JSON.stringify({ id: "mistral-response", usage: { prompt_tokens: 12, completion_tokens: 7, total_tokens: 19, prompt_tokens_details: { cached_tokens: 3 } }, choices: [{ finish_reason: "tool_calls", delta: {} }] })}`,
    "data: [DONE]",
  ]);
  if (protocolID === "pi-messages") return sseInput([
    { type: "start" }, { type: "text_start", contentIndex: 0 }, { type: "text_delta", contentIndex: 0, delta: "hello" }, { type: "text_end", contentIndex: 0, content: "hello" },
    { type: "thinking_start", contentIndex: 1 }, { type: "thinking_delta", contentIndex: 1, delta: "thinking" }, { type: "thinking_end", contentIndex: 1, content: "thinking", contentSignature: "opaque" },
    { type: "toolcall_start", contentIndex: 2, id: "call-1", toolName: "lookup" }, { type: "toolcall_delta", contentIndex: 2, delta: "{\"query\":\"Swift\"}" },
    { type: "toolcall_end", contentIndex: 2, toolCall: { type: "toolCall", id: "call-1", name: "lookup", arguments: { query: "Swift" } } },
    { type: "done", reason: "toolUse", usage: { input: 8, output: 5, reasoning: 2, cacheRead: 3, cacheWrite: 0, totalTokens: 16, cost: { input: 8, output: 10, cacheRead: 9, cacheWrite: 0, total: 27 } }, responseId: "response-1" },
  ].map((event) => `data: ${JSON.stringify(event)}`));
  if (protocolID === "bedrock-converse-stream") {
    const events = [
      ["messageStart", { role: "assistant" }],
      ["contentBlockDelta", { contentBlockIndex: 0, delta: { reasoningContent: { text: "inspect" } } }],
      ["contentBlockDelta", { contentBlockIndex: 0, delta: { reasoningContent: { signature: "opaque-bedrock" } } }],
      ["contentBlockStop", { contentBlockIndex: 0 }],
      ["contentBlockDelta", { contentBlockIndex: 1, delta: { text: "Checking" } }],
      ["contentBlockStop", { contentBlockIndex: 1 }],
      ["contentBlockStart", { contentBlockIndex: 2, start: { toolUse: { toolUseId: "tool-1", name: "weather" } } }],
      ["contentBlockDelta", { contentBlockIndex: 2, delta: { toolUse: { input: "{\"city\":\"Tai" } } }],
      ["contentBlockDelta", { contentBlockIndex: 2, delta: { toolUse: { input: "pei\"}" } } }],
      ["contentBlockStop", { contentBlockIndex: 2 }],
      ["messageStop", { stopReason: "tool_use" }],
      ["metadata", { usage: { inputTokens: 12, outputTokens: 8, cacheReadInputTokens: 2, totalTokens: 20 } }],
    ];
    return {
      kind: "aws-eventstream",
      status: 200,
      headers: {
        "content-type": "application/vnd.amazon.eventstream",
        "x-amzn-requestid": "bedrock-response",
      },
      chunksBase64: events.map(([eventType, payload]) => encodeAWSEvent(eventType, payload).toString("base64")),
    };
  }
  if (protocolID === "openrouter-images") return {
    kind: "http-json", status: 200, headers: { "content-type": "application/json" },
    body: { id: "image-response-1", model: "fixture-image", choices: [{ message: { role: "assistant", content: "created", images: [{ image_url: "data:image/png;base64,iVA=" }, { image_url: { url: "data:image/jpeg;base64,/9g=" } }, { image_url: "https://example.invalid/ignored" }] } }], usage: { prompt_tokens: 10, completion_tokens: 4, prompt_tokens_details: { cached_tokens: 3, cache_write_tokens: 1 } } },
  };
  throw new Error(`no response stimulus for ${protocolID}`);
}

function sseInput(events) {
  const value = `${events.join("\n\n")}\n\n`;
  const bytes = new TextEncoder().encode(value);
  const first = Math.min(37, bytes.length);
  const second = Math.min(173, bytes.length);
  return { kind: "http-sse", status: 200, headers: { "content-type": "text/event-stream" }, chunksBase64: [bytes.slice(0, first), bytes.slice(first, second), bytes.slice(second)].filter((part) => part.length > 0).map((part) => Buffer.from(part).toString("base64")) };
}

function fakeFetch(input) {
  return async () => {
    if (input.kind === "http-json") return new Response(JSON.stringify(input.body), { status: input.status, headers: input.headers });
    const chunks = input.chunksBase64.map((value) => Uint8Array.from(Buffer.from(value, "base64")));
    return new Response(new ReadableStream({ start(controller) { chunks.forEach((chunk) => controller.enqueue(chunk)); controller.close(); } }), { status: input.status, headers: input.headers });
  };
}

function encodeAWSEvent(eventType, payload) {
  const require = createRequire(path.resolve(upstreamRoot, "package.json"));
  const { EventStreamCodec } = require("@smithy/core/event-streams");
  const codec = new EventStreamCodec(
    (bytes) => new TextDecoder().decode(bytes),
    (value) => new TextEncoder().encode(value),
  );
  return Buffer.from(codec.encode({
    headers: {
      ":message-type": { type: "string", value: "event" },
      ":event-type": { type: "string", value: eventType },
      ":content-type": { type: "string", value: "application/json" },
    },
    body: new TextEncoder().encode(JSON.stringify(payload)),
  }));
}

function baseContext() { return { systemPrompt: "Be concise", messages: [{ role: "user", content: "Use the weather tool", timestamp: 0 }], tools: [{ name: "weather", description: "Read weather", parameters: { type: "object", properties: { city: { type: "string" } }, required: ["city"] } }] }; }
function textModel(protocol, cost) { return { id: protocol.modelID, name: protocol.modelID, api: protocol.protocolID, provider: protocol.providerID, baseUrl: protocol.baseURL, reasoning: true, input: ["text", "image"], cost, contextWindow: 262144, maxTokens: 4096 }; }
function imageModel(protocol, cost) { return { id: protocol.modelID, name: protocol.modelID, api: protocol.protocolID, provider: protocol.providerID, baseUrl: protocol.baseURL, input: ["text", "image"], output: ["text", "image"], cost }; }
function credential(protocolID) { if (protocolID !== "openai-codex-responses") return "fixture-key"; const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "fixture-account" } })).toString("base64url"); return `aaa.${payload}.bbb`; }
function fixtureCost() { return { input: 1_000_000, output: 2_000_000, cacheRead: 3_000_000, cacheWrite: 4_000_000 }; }
function tieredFixtureCost() { return { ...fixtureCost(), tiers: [{ inputTokensAbove: 0, input: 5_000_000, output: 6_000_000, cacheRead: 7_000_000, cacheWrite: 8_000_000 }] }; }
function mapReason(reason) { return reason === "toolUse" ? "toolCalls" : reason; }
function canonicalToolCall(call) { return { id: call?.id ?? "", name: call?.name ?? "", arguments: canonicalize(call?.arguments ?? {}) }; }
function usageEvent(usage) { return { type: "usage", inputTokens: usage.input ?? null, outputTokens: usage.output ?? null, reasoningTokens: usage.reasoning ?? null, cachedInputTokens: usage.cacheRead ?? null, cost: usage.cost }; }
function canonicalTerminalMessage(message) { return canonicalize({ responseID: message.responseId ?? null, responseModel: message.responseModel ?? null, providerID: message.provider, modelID: message.model, stopReason: mapReason(message.stopReason), rawStopReason: message.rawStopReason ?? null, content: (message.content ?? []).map((block) => ({ ...block, ...(typeof block.thinkingSignature === "string" ? { thinkingSignature: canonicalSignature(block.thinkingSignature) } : {}), ...(typeof block.thoughtSignature === "string" ? { thoughtSignature: canonicalSignature(block.thoughtSignature) } : {}) })), usage: message.usage ? { input: message.usage.input, output: message.usage.output, reasoning: message.usage.reasoning ?? null, cacheRead: message.usage.cacheRead, cacheWrite: message.usage.cacheWrite, totalTokens: message.usage.totalTokens, cost: message.usage.cost } : null }); }
function canonicalTerminalImages(output) { return canonicalize({ responseID: output.responseId ?? null, providerID: output.provider, modelID: output.model, stopReason: output.stopReason, output: output.output, usage: output.usage ? { input: output.usage.input, output: output.usage.output, cacheRead: output.usage.cacheRead, cacheWrite: output.usage.cacheWrite, totalTokens: output.usage.totalTokens, cost: output.usage.cost } : null }); }
function canonicalize(value) { if (Array.isArray(value)) return value.map(canonicalize); if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => [key, canonicalize(item)])); return value; }
