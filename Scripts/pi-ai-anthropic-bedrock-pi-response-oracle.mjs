#!/usr/bin/env node

import { createRequire, registerHooks } from "node:module";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import http from "node:http";
import path from "node:path";
import { installEmissionSnapshots, emissionSnapshot } from "./pi-ai-emission-snapshots.mjs";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [upstreamRoot, casePath, outputPath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) throw new Error("usage: oracle UPSTREAM_ROOT CASE_JSON [OUTPUT]");
await installEmissionSnapshots(upstreamRoot);
const fixture = JSON.parse(await readFile(casePath, "utf8"));
if (fixture.schemaVersion !== 1) throw new Error("unsupported response fixture schema");
const revision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error(`revision mismatch: ${revision}`);
const apiRoot = path.join(upstreamRoot, "packages/ai/src/api");
const bedrockMockURL = "oracle:bedrock-decoded-event-fixture";
registerHooks({
  resolve(specifier, context, next) {
    return specifier === "@aws-sdk/client-bedrock-runtime" && context.parentURL?.endsWith("?decoded-fixture")
      ? { url: bedrockMockURL, shortCircuit: true } : next(specifier, context);
  },
  load(url, context, next) {
    if (url !== bedrockMockURL) return next(url, context);
    return { format: "module", shortCircuit: true, source: `
      export class BedrockRuntimeServiceException extends Error {}
      export class ConverseStreamCommand { constructor(input) { this.input = input; } }
      export class BedrockRuntimeClient {
        middlewareStack = { add() {} };
        async send(command) {
          globalThis.__PI_BEDROCK_OBSERVER_PARAMS__ = command.input;
          return { $metadata: { httpStatusCode: 200, requestId: "bedrock-branch" }, stream: (async function* () {
            yield { messageStart: { role: "assistant" } };
            yield { internalServerException: new Error("bedrock stream failed") };
          })() };
        }
      }
      export const StopReason = { END_TURN: "end_turn" };
      export const CachePointType = { DEFAULT: "default" };
      export const CacheTTL = { ONE_HOUR: "ONE_HOUR" };
      export const ConversationRole = { ASSISTANT: "assistant", USER: "user" };
      export const ImageFormat = { JPEG: "jpeg", PNG: "png", GIF: "gif", WEBP: "webp" };
      export const ToolResultStatus = { ERROR: "error", SUCCESS: "success" };
    ` };
  },
});
const results = {};
for (const scenario of fixture.scenarios) {
  const input = scenario.decoderInput ?? stimulus(scenario.caseID);
  const projected = scenario.protocolID === "bedrock-converse-stream"
    ? await runBedrock(scenario, input)
    : await runSSE(scenario, input);
  results[scenario.caseID] = { ...projected, decoderInput: input };
}
const rendered = `${JSON.stringify({
  schemaVersion: 1, caseID: fixture.caseID, upstreamRevision: revision, scenarios: results,
}, null, 2)}\n`;
if (outputPath) await writeFile(outputPath, rendered, "utf8");
else process.stdout.write(rendered);

async function runSSE(scenario, input) {
  const implementation = await providerStreams(
    upstreamRoot,
    await import(pathToFileURL(path.join(apiRoot, `${scenario.protocolID}.ts`)).href),
  );
  const wire = { stages: [], events: [], models: [], responses: [] };
  const stream = implementation.stream(model(scenario.protocolID), context(), {
    apiKey: "fixture-key", maxRetries: 0, cacheRetention: "none",
    fetch: async (url, init) => {
      if (scenario.observeWire) wire.stream = JSON.parse(init.body).stream;
      return fakeFetch(input)(url, init);
    },
    ...(scenario.observeWire ? {
      onPayload: async payload => {
        await Promise.resolve();
        wire.stages.push("payload");
        if (scenario.payloadMode === "replacement") return { ...payload, stream: false };
        if (scenario.payloadMode === "mutation") payload.stream = false;
      },
      onResponse: async response => {
        await Promise.resolve();
        wire.stages.push("response");
        wire.responses.push(response);
      },
      onProviderStreamEvent: async (event, eventModel) => {
        await Promise.resolve();
        wire.stages.push("event");
        wire.events.push(structuredClone(event));
        wire.models.push({ id: eventModel.id, provider: eventModel.provider, api: eventModel.api });
      },
    } : {}),
  });
  const result = await project(stream);
  return { ...result, ...(scenario.observeWire ? { wire } : {}) };
}

async function runBedrock(scenario, input) {
  const wire = { stages: [], events: [], models: [], responses: [] };
  const chunks = input.chunksBase64.map((value) => Buffer.from(value, "base64"));
  const server = http.createServer((request, response) => {
    const body = [];
    request.on("data", bytes => body.push(bytes));
    request.on("end", () => {
      if (scenario.observeWire) wire.temperature = JSON.parse(Buffer.concat(body)).inferenceConfig.temperature;
      response.writeHead(input.status, input.headers);
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
    if (!address || typeof address === "string") throw new Error("invalid loopback address");
    const implementation = await providerStreams(
      upstreamRoot,
      await import(pathToFileURL(path.join(apiRoot, "bedrock-converse-stream.ts")).href + (scenario.driver === "decoded-sdk-events" ? "?decoded-fixture" : "")),
    );
    const stream = implementation.stream(
      { ...model(scenario.protocolID), ...(scenario.cost ? { cost: scenario.cost } : {}), baseUrl: `http://127.0.0.1:${address.port}` },
      context(),
      { maxRetries: 0, env: { AWS_BEDROCK_FORCE_HTTP1: "1", AWS_BEDROCK_SKIP_AUTH: "1", AWS_REGION: "us-east-1" },
        ...(scenario.observeWire ? {
          onPayload: async payload => {
            await Promise.resolve();
            wire.stages.push("payload");
            payload.inferenceConfig.temperature = 0.25;
          },
          onResponse: async response => {
            await Promise.resolve();
            wire.stages.push("response");
            wire.responses.push({ status: response.status, headers: { "content-type": response.headers["content-type"], "x-amzn-requestid": response.headers["x-amzn-requestid"] } });
          },
          onProviderStreamEvent: async (event, model) => {
            await Promise.resolve();
            wire.stages.push("event");
            wire.events.push(JSON.parse(JSON.stringify(event, (_key, value) => value instanceof Error ? { ...value, message: value.message } : value instanceof Uint8Array ? Buffer.from(value).toString("base64") : value)));
            wire.models.push({ id: model.id, provider: model.provider, api: model.api });
          },
        } : {}),
      },
    );
    const result = await project(stream);
    if (scenario.driver === "decoded-sdk-events") wire.temperature = globalThis.__PI_BEDROCK_OBSERVER_PARAMS__.inferenceConfig.temperature;
    return { ...result, ...(scenario.observeWire ? { wire } : {}) };
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function project(stream) {
  const events = [];
  let terminal;
  const streamedText = new Map();
  const streamedReasoning = new Map();
  for await (const sourceEvent of stream) {
    const event = emissionSnapshot(sourceEvent);
    if (event.type === "text_delta") {
      streamedText.set(event.contentIndex, `${streamedText.get(event.contentIndex) ?? ""}${event.delta}`);
      events.push(canonicalEvent(event));
    } else if (event.type === "text_end") {
      const prior = streamedText.get(event.contentIndex) ?? "";
      if (event.content.startsWith(prior) && event.content.length > prior.length) {
        events.push({ type: "textDelta", delta: event.content.slice(prior.length) });
      }
    } else if (event.type === "thinking_delta") {
      streamedReasoning.set(event.contentIndex, `${streamedReasoning.get(event.contentIndex) ?? ""}${event.delta}`);
      events.push(canonicalEvent(event));
    } else if (event.type === "thinking_end") {
      const prior = streamedReasoning.get(event.contentIndex) ?? "";
      if (event.content.startsWith(prior) && event.content.length > prior.length) {
        events.push({ type: "reasoningDelta", delta: event.content.slice(prior.length) });
      }
      const signature = canonicalEvent(event);
      if (signature.type !== "reasoningEnded") events.push(signature);
    } else if (["toolcall_start", "toolcall_delta", "toolcall_end"].includes(event.type)) {
      events.push(canonicalEvent(event));
    }
    if (event.type === "done" || event.type === "error") terminal = event.message ?? event.error;
  }
  if (!terminal) throw new Error("source stream ended without terminal projection");
  return {
    outcome: terminal.stopReason === "error" || terminal.stopReason === "aborted" ? "failure" : "success",
    events: canonicalize(events),
    terminal: canonicalTerminal(terminal),
  };
}

function canonicalEvent(event) {
  if (event.type === "text_delta") return { type: "textDelta", delta: event.delta };
  if (event.type === "thinking_delta") return { type: "reasoningDelta", delta: event.delta };
  if (event.type === "thinking_end") {
    const block = event.partial.content[event.contentIndex];
    return typeof block?.thinkingSignature === "string" && block.thinkingSignature.length > 0
      ? { type: "reasoningSignatureDelta", delta: block.thinkingSignature }
      : { type: "reasoningEnded" };
  }
  if (event.type === "toolcall_start") {
    const block = event.partial.content[event.contentIndex];
    return { type: "toolCallStarted", id: block.id, name: block.name };
  }
  if (event.type === "toolcall_delta") {
    const block = event.partial.content[event.contentIndex];
    return { type: "toolInputDelta", id: block.id, delta: event.delta };
  }
  return { type: "toolCallCompleted", toolCall: event.toolCall };
}

function canonicalTerminal(message) {
  return canonicalize({
    responseID: message.responseId ?? null,
    responseModel: message.responseModel ?? null,
    providerID: message.provider,
    modelID: message.model,
    stopReason: message.stopReason,
    rawStopReason: message.rawStopReason ?? null,
    errorMessage: message.errorMessage ?? null,
    content: message.content ?? [],
    ...(message.api === "pi-messages" && message.providerThinkingLevel !== undefined ? { providerThinkingLevel: message.providerThinkingLevel } : {}),
    ...(message.diagnostics ? { diagnostics: message.diagnostics.map(({ timestamp, ...data }) => data) } : {}),
    usage: message.usage ? {
      input: message.usage.input ?? null,
      output: message.usage.output ?? null,
      reasoning: message.usage.reasoning ?? null,
      cacheRead: message.usage.cacheRead ?? null,
      cacheWrite: message.usage.cacheWrite ?? null,
      cacheWrite1h: message.usage.cacheWrite1h ?? null,
      cacheWriteCost: message.usage.cost?.cacheWrite ?? null,
      totalTokens: message.usage.totalTokens ?? null,
    } : null,
  });
}

function stimulus(caseID) {
  switch (caseID) {
    case "bedrock-native-sdk-error-event": {
      const input = aws([
        ["messageStart", { role: "assistant" }],
        ["internalServerException", { message: "bedrock stream failed" }],
      ]);
      input.headers = { "x-amzn-requestid": "bedrock-branch" };
      return input;
    }
    case "anthropic-observer-payload-replacement":
    case "anthropic-observer-payload-mutation": return sse([
      anth("message_start", { type: "message_start", message: { id: "msg_test", usage: { input_tokens: 12, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } }),
      anth("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }),
      anth("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hello" } }),
      anth("content_block_stop", { type: "content_block_stop", index: 0 }),
      anth("message_delta", { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { input_tokens: 12, output_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } }),
      anth("message_stop", { type: "message_stop" }),
    ]);
    case "anthropic-transformations-start":
    case "anthropic-transformations-delta":
    case "anthropic-transformations-cleared":
    case "anthropic-transformations-nonarray":
    case "anthropic-transformations-null":
    case "anthropic-transformations-after-stop": {
      const first = [{ type: "thinking_dropped", path: "messages.1.content.0", reason: "prefix_binding_mismatch", ignored: "source omits this" }];
      const last = [{ type: "thinking_dropped", path: "messages.3.content.0", reason: "model_binding_mismatch" }];
      const ending = caseID.endsWith("delta") ? last : caseID.endsWith("cleared") ? []
        : caseID.endsWith("nonarray") ? { invalid: true } : caseID.endsWith("null") ? null : undefined;
      const events = [
        anth("message_start", { type: "message_start", message: { id: caseID, model: "fixture-model", usage: { input_tokens: 1, output_tokens: 0 }, input_transformations: first } }),
        anth("message_delta", { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 2 }, ...(ending !== undefined ? { input_transformations: ending } : {}) }),
        anth("message_stop", { type: "message_stop" }),
      ];
      if (caseID.endsWith("after-stop")) events.push(anth("message_delta", { type: "message_delta", delta: {}, input_transformations: last }));
      return sse(events);
    }
    case "anthropic-raw-error": return sse(["event: error\ndata: fixture raw failure"]);
    case "anthropic-repaired-sse-tool": return sse([
      anth("message_start", {type: "message_start", message: {id: "anth-repaired", model: "fixture-model", usage: {input_tokens: 1, output_tokens: 0}}}),
      anth("content_block_start", {type: "content_block_start", index: 0, content_block: {type: "tool_use", id: "toolu_test", name: "edit", input: {}}}),
      "event: content_block_delta\ndata: " + String.raw`{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"A\H\",\"text\":\"col1	col2\"}"}}`,
      anth("content_block_stop", {type: "content_block_stop", index: 0}),
      anth("message_delta", {type: "message_delta", delta: {stop_reason: "tool_use"}, usage: {output_tokens: 1}}),
      anth("message_stop", {type: "message_stop"}),
    ]);
    case "anthropic-ignored-sse-envelopes": return sse([
      "event: proxy.stats\ndata: not json",
      "event: ping\ndata: not json",
      `data: ${JSON.stringify({type: "message_start", message: {id: "ignored"}})}`,
      anth("message_start", {}),
      anth("message_start", { type: "message_start", message: { id: "anth-filtered", model: "fixture-model", usage: { input_tokens: 1, output_tokens: 0 } } }),
      anth("content_block_start", { type: "future_event" }),
      anth("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }),
      anth("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hello" } }),
      anth("content_block_stop", { type: "content_block_stop", index: 0 }),
      anth("message_delta", { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 1 } }),
      anth("message_stop", { type: "message_stop" }),
      anth("proxy.stats", { type: "message_delta", delta: { stop_reason: "refusal" } }),
      "event: done\ndata: [DONE]",
      "event: proxy.stats\ndata: not json",
    ]);
    case "anthropic-mid-output-fallback": return sse([
      anth("message_start", { type: "message_start", message: { id: "fallback", model: "fixture-model", usage: {input_tokens: 0, output_tokens: 0} } }),
      anth("content_block_start", { type: "content_block_start", index: 0, content_block: {type: "text", text: ""} }),
      anth("content_block_start", { type: "content_block_start", index: 1, content_block: {type: "fallback"} }),
    ]);
    case "pi-future-content-index": return sse(piEvents([{type: "start"}, {type: "text_start", contentIndex: 1}]));
    case "pi-negative-content-index": return sse(piEvents([{type: "start"}, {type: "text_start", contentIndex: -1}]));
    case "pi-string-content-index": return sse(piEvents([{type: "start"}, {type: "text_start", contentIndex: "__proto__"}]));
    case "anthropic-redacted-pause-usage": return sse([
      anth("message_start", { type: "message_start", message: { id: "anth-redacted", model: "fixture-model", usage: { input_tokens: 10, output_tokens: 0, cache_read_input_tokens: 2, cache_creation_input_tokens: 3 } } }),
      anth("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "redacted_thinking", data: "opaque-redacted" } }),
      anth("content_block_stop", { type: "content_block_stop", index: 0 }),
      anth("message_delta", { type: "message_delta", delta: { stop_reason: "pause_turn" }, usage: { output_tokens: 5, cache_creation_input_tokens: 4, output_tokens_details: { thinking_tokens: 1 } } }),
      anth("message_stop", { type: "message_stop" }),
    ]);
    case "anthropic-signed-length": return sse([
      anth("message_start", { type: "message_start", message: { id: "anth-length", model: "fixture-model", usage: { input_tokens: 4, output_tokens: 0 } } }),
      anth("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "" } }),
      anth("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "inspect" } }),
      anth("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "opaque-signature" } }),
      anth("content_block_stop", { type: "content_block_stop", index: 0 }),
      anth("message_delta", { type: "message_delta", delta: { stop_reason: "max_tokens" }, usage: { output_tokens: 7 } }),
      anth("message_stop", { type: "message_stop" }),
    ]);
    case "anthropic-tool-use": return sse([
      anth("message_start", { type: "message_start", message: { id: "anth-tool", model: "fixture-model", usage: { input_tokens: 3, output_tokens: 0 } } }),
      anth("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "call-1", name: "lookup", input: {} } }),
      anth("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: "{\"query\":\"Swift\"}" } }),
      anth("content_block_stop", { type: "content_block_stop", index: 0 }),
      anth("message_delta", { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 2 } }),
      anth("message_stop", { type: "message_stop" }),
    ]);
    case "anthropic-refusal": return sse([
      anth("message_start", { type: "message_start", message: { id: "anth-refusal", model: "fixture-model", usage: { input_tokens: 1, output_tokens: 0 } } }),
      anth("message_delta", { type: "message_delta", delta: { stop_reason: "refusal", stop_details: { explanation: "fixture refusal" } }, usage: { output_tokens: 0 } }),
      anth("message_stop", { type: "message_stop" }),
    ]);
    case "anthropic-refusal-no-details":
    case "anthropic-refusal-empty-explanation":
    case "anthropic-sensitive-explanation":
    case "anthropic-unknown-stop": {
      const reason = caseID === "anthropic-sensitive-explanation" ? "sensitive"
        : caseID === "anthropic-unknown-stop" ? "future_stop" : "refusal";
      const delta = { stop_reason: reason,
        ...(caseID === "anthropic-refusal-empty-explanation" ? { stop_details: { explanation: "" } } : {}),
        ...(caseID === "anthropic-sensitive-explanation" ? { stop_details: { explanation: "ignored sensitive detail" } } : {}),
      };
      return sse([
        anth("message_start", { type: "message_start", message: { id: caseID, model: "fixture-model", usage: { input_tokens: 1, output_tokens: 0 } } }),
        anth("message_delta", { type: "message_delta", delta, usage: { output_tokens: 0 } }),
        anth("message_stop", { type: "message_stop" }),
      ]);
    }
    case "anthropic-error-event": return sse([
      anth("error", { type: "error", error: { type: "overloaded_error", message: "fixture overloaded" } }),
    ]);
    case "anthropic-missing-terminal": return sse([
      anth("message_start", { type: "message_start", message: { id: "anth-partial", model: "fixture-model", usage: { input_tokens: 1, output_tokens: 0 } } }),
    ]);
    case "bedrock-cache-write-1h-before-stop":
    case "bedrock-cache-write-1h-after-stop":
    case "bedrock-cache-write-1h-repeated": {
      const metadata = ["metadata", { usage: {
        inputTokens: 100, outputTokens: 5, totalTokens: 1_000_105,
        cacheWriteInputTokens: 1_000_000,
        cacheDetails: [
          { ttl: "1h", inputTokens: 150_000 },
          { ttl: "5m", inputTokens: 600_000 },
          { ttl: "1h", inputTokens: 250_000 },
        ],
      } }];
      const stop = ["messageStop", { stopReason: "end_turn" }];
      const initial = ["messageStart", { role: "assistant" }];
      if (caseID.endsWith("before-stop")) return aws([initial, metadata, stop]);
      if (caseID.endsWith("repeated")) return aws([
        initial, ["metadata", { usage: { inputTokens: 1, outputTokens: 1, totalTokens: 2 } }],
        stop, metadata,
      ]);
      return aws([initial, stop, metadata]);
    }
    case "bedrock-redacted-length-usage": return aws([
      ["messageStart", { role: "assistant" }],
      ["contentBlockDelta", { contentBlockIndex: 0, delta: { reasoningContent: { redactedContent: Buffer.from([1, 2]).toString("base64") } } }],
      ["contentBlockDelta", { contentBlockIndex: 0, delta: { reasoningContent: { redactedContent: Buffer.from([3, 4]).toString("base64") } } }],
      ["contentBlockStop", { contentBlockIndex: 0 }],
      ["messageStop", { stopReason: "max_tokens" }],
      ["metadata", { usage: { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 2, cacheWriteInputTokens: 4, totalTokens: 99 } }],
    ]);
    case "bedrock-stop": return aws([
      ["messageStart", { role: "assistant" }],
      ["contentBlockDelta", { contentBlockIndex: 0, delta: { text: "done" } }],
      ["contentBlockStop", { contentBlockIndex: 0 }],
      ["messageStop", { stopReason: "end_turn" }],
      ["metadata", { usage: { inputTokens: 2, outputTokens: 1, totalTokens: 3 } }],
    ]);
    case "bedrock-tool-use": return aws([
      ["messageStart", { role: "assistant" }],
      ["contentBlockStart", { contentBlockIndex: 0, start: { toolUse: { toolUseId: "call-1", name: "lookup" } } }],
      ["contentBlockDelta", { contentBlockIndex: 0, delta: { toolUse: { input: "{\"query\":\"Swift\"}" } } }],
      ["contentBlockStop", { contentBlockIndex: 0 }],
      ["messageStop", { stopReason: "tool_use" }],
      ["metadata", { usage: { inputTokens: 2, outputTokens: 1, totalTokens: 3 } }],
    ]);
    case "bedrock-provider-stop-error": return aws([
      ["messageStart", { role: "assistant" }],
      ["messageStop", { stopReason: "guardrail_intervened" }],
    ]);
    case "bedrock-exception": return aws([
      ["throttlingException", { message: "fixture throttled" }, "exception"],
    ]);
    case "bedrock-midstream-exception-diagnostic": return aws([
      ["messageStart", { role: "assistant" }],
      ["throttlingException", { message: "fixture throttled" }, "exception"],
    ]);
    case "bedrock-missing-terminal": return aws([
      ["messageStart", { role: "assistant" }],
      ["contentBlockDelta", { contentBlockIndex: 0, delta: { text: "partial" } }],
    ]);
    case "pi-terminal-no-start-stop":
    case "pi-terminal-no-start-length":
    case "pi-terminal-no-start-tool-use": return sse(piEvents([
      { type: "done", reason: caseID.endsWith("tool-use") ? "toolUse" : caseID.endsWith("length") ? "length" : "stop",
        usage: usage3(), responseId: "pi-terminal", responseModel: "routed-model", providerThinkingLevel: "high" },
    ]));
    case "pi-terminal-no-start-error": return sse(piEvents([
      { type: "error", reason: "error", usage: usage3(), errorMessage: "fixture pi failure", responseId: "pi-error" },
    ]));
    case "pi-signatures-namespace-length": return sse(piEvents([
      { type: "start" },
      { type: "text_start", contentIndex: 0 },
      { type: "text_delta", contentIndex: 0, delta: "answer" },
      { type: "text_end", contentIndex: 0, content: "answer", contentSignature: "text-signature" },
      { type: "thinking_start", contentIndex: 1 },
      { type: "thinking_end", contentIndex: 1, content: "[Reasoning redacted]", contentSignature: "reasoning-signature", redacted: true },
      { type: "toolcall_start", contentIndex: 2, id: "call-1", toolName: "lookup" },
      { type: "toolcall_delta", contentIndex: 2, delta: "{\"query\":\"Swift\"}" },
      { type: "toolcall_end", contentIndex: 2, toolCall: { type: "toolCall", id: "call-1", name: "lookup", arguments: { query: "Swift" }, thoughtSignature: "tool-signature", namespace: "fixture.namespace" } },
      { type: "done", reason: "length", usage: usage99(), responseId: "pi-response" },
    ]));
    case "pi-stop": return sse(piEvents([
      { type: "start" },
      { type: "text_start", contentIndex: 0 },
      { type: "text_delta", contentIndex: 0, delta: "done" },
      { type: "text_end", contentIndex: 0, content: "done" },
      { type: "done", reason: "stop", usage: usage3(), responseId: "pi-stop" },
    ]));
    case "pi-tool-use": return sse(piEvents([
      { type: "start" },
      { type: "toolcall_start", contentIndex: 0, id: "call-1", toolName: "lookup" },
      { type: "toolcall_delta", contentIndex: 0, delta: "{\"query\":\"Swift\"}" },
      { type: "toolcall_end", contentIndex: 0, toolCall: { type: "toolCall", id: "call-1", name: "lookup", arguments: { query: "Swift" } } },
      { type: "done", reason: "toolUse", usage: usage3(), responseId: "pi-tool" },
    ]));
    case "pi-error-event": return sse(piEvents([
      { type: "start" },
      { type: "error", reason: "error", usage: usage99(), errorMessage: "fixture pi error", responseId: "pi-error" },
    ]));
    case "pi-invalid-tool-end": return sse(piEvents([
      { type: "start" },
      { type: "toolcall_start", contentIndex: 0, id: "call-1", toolName: "lookup" },
      { type: "toolcall_end", contentIndex: 0, toolCall: { type: "toolCall", id: "different", name: "lookup", arguments: {} } },
    ]));
    case "pi-missing-terminal": return sse(piEvents([{ type: "start" }]));
    default: throw new Error(`unknown scenario: ${caseID}`);
  }
}

function anth(event, value) { return `event: ${event}\ndata: ${JSON.stringify(value)}`; }
function piEvents(events) { return events.map((value) => `data: ${JSON.stringify(value)}`); }
function usage99() { return { input: 10, output: 5, reasoning: 1, cacheRead: 2, cacheWrite: 4, totalTokens: 99, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }; }
function usage3() { return { input: 2, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 3, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }; }
function sse(events) {
  const bytes = Buffer.from(`${events.join("\n\n")}\n\n`);
  return { kind: "http-sse", status: 200, headers: { "content-type": "text/event-stream" }, chunksBase64: [bytes.toString("base64")] };
}
function aws(events) {
  return {
    kind: "aws-eventstream", status: 200,
    headers: { "content-type": "application/vnd.amazon.eventstream", "x-amzn-requestid": "bedrock-branch" },
    chunksBase64: events.map(([type, body, messageType]) => encodeAWS(type, body, messageType).toString("base64")),
  };
}
function encodeAWS(eventType, payload, messageType = "event") {
  const require = createRequire(path.resolve(upstreamRoot, "package.json"));
  const { EventStreamCodec } = require("@smithy/core/event-streams");
  const codec = new EventStreamCodec(
    (bytes) => new TextDecoder().decode(bytes),
    (value) => new TextEncoder().encode(value),
  );
  return Buffer.from(codec.encode({
    headers: {
      ":message-type": { type: "string", value: messageType },
      [messageType === "exception" ? ":exception-type" : ":event-type"]: { type: "string", value: eventType },
      ":content-type": { type: "string", value: "application/json" },
    },
    body: new TextEncoder().encode(JSON.stringify(payload)),
  }));
}
function fakeFetch(input) {
  return async () => new Response(
    new ReadableStream({
      start(controller) {
        input.chunksBase64.forEach((chunk) => controller.enqueue(Uint8Array.from(Buffer.from(chunk, "base64"))));
        controller.close();
      },
    }),
    { status: input.status, headers: input.headers },
  );
}
function context() { return { messages: [{ role: "user", content: "fixture", timestamp: 0 }] }; }
function model(api) {
  const provider = api === "bedrock-converse-stream" ? "amazon-bedrock" : api === "pi-messages" ? "fixture-pi" : "anthropic";
  return { id: "fixture-model", name: "fixture-model", api, provider, baseUrl: "https://fixture.invalid", reasoning: true, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 262144, maxTokens: 4096 };
}
function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") return Object.fromEntries(
    Object.entries(value).filter(([, item]) => item !== undefined)
      .sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => [key, canonicalize(item)]),
  );
  return value;
}
