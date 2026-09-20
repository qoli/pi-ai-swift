#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [upstreamRoot, casePath, outputPath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) throw new Error("usage: oracle UPSTREAM_ROOT CASE_JSON");
const fixture = JSON.parse(await readFile(casePath, "utf8"));
if (fixture.schemaVersion !== 1) throw new Error("unsupported fixture schema");
const revision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) {
  throw new Error(`Anthropic/Bedrock oracle revision mismatch: expected ${fixture.upstreamRevision}, found ${revision}`);
}
const apiRoot = path.join(upstreamRoot, "packages/ai/src/api");
const anthropic = await providerStreams(
  upstreamRoot,
  await import(pathToFileURL(path.join(apiRoot, "anthropic-messages.ts")).href),
);
const bedrock = await providerStreams(
  upstreamRoot,
  await import(pathToFileURL(path.join(apiRoot, "bedrock-converse-stream.ts")).href),
);

const tool = { name: "read", description: "Read data", parameters: objectSchema() };
const user = { role: "user", content: "hello", timestamp: 0 };
const signedAssistant = {
  role: "assistant", api: "bedrock-converse-stream", provider: "amazon-bedrock",
  model: "anthropic.claude-sonnet-4-5", stopReason: "stop", timestamp: 1,
  usage: zeroUsage(),
  content: [{ type: "thinking", thinking: "inspect", thinkingSignature: "opaque-signature" }],
};

const results = {};
for (const scenario of fixture.scenarios) {
  results[scenario.caseID] = scenario.protocolID === "anthropic-messages"
    ? await captureAnthropic(scenario.caseID)
    : await captureBedrock(scenario.caseID);
}
const output = `${JSON.stringify({
  schemaVersion: 1,
  caseID: fixture.caseID,
  upstreamRevision: fixture.upstreamRevision,
  scenarios: results,
}, null, 2)}\n`;
if (outputPath) await writeFile(outputPath, output, "utf8");
else process.stdout.write(output);

async function captureAnthropic(caseID) {
  const spec = anthropicSpec(caseID);
  let payload;
  let headers = {};
  const fetch = async (input, init) => {
    const request = input instanceof Request ? input : new Request(input, init);
    headers = selectedHeaders(Object.fromEntries(request.headers.entries()));
    return new Response([
      'data: {"type":"message_start","message":{"id":"fixture","model":"fixture","usage":{"input_tokens":0,"output_tokens":0}}}',
      'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}',
      'data: {"type":"message_stop"}', '',
    ].join("\n"), { status: 200, headers: { "content-type": "text/event-stream" } });
  };
  const options = {
    thinkingEnabled: false,
    ...spec.options,
    fetch,
    maxRetries: 0,
    onPayload(value) { payload = value; },
  };
  const result = await anthropic[spec.entrypoint](spec.model, spec.context, options).result();
  if (spec.expectedFailure) {
    if (payload !== undefined || result.stopReason !== "error") {
      throw new Error(`${caseID}: expected source authentication failure`);
    }
    return {
      requestBody: null,
      headers,
      sourceFailure: { stopReason: result.stopReason, errorMessage: result.errorMessage ?? null },
    };
  }
  if (payload === undefined) throw new Error(`${caseID}: ${result.errorMessage ?? "no payload"}`);
  return { requestBody: canonicalize(payload), headers };
}

function anthropicSpec(caseID) {
  const baseModel = model("anthropic-messages", "anthropic", "claude-sonnet-4-5", true);
  const context = { systemPrompt: "Be concise", messages: [user], tools: [tool] };
  switch (caseID) {
    case "anthropic-api-key-system-cache-short":
      return { entrypoint: "stream", model: baseModel, context, options: { apiKey: "fixture-key", maxTokens: 4096, temperature: 0.25, cacheRetention: "short", toolChoice: "auto" } };
    case "anthropic-oauth-named-tool":
      return { entrypoint: "stream", model: baseModel, context, options: { apiKey: "sk-ant-oat-fixture", maxTokens: 4096, cacheRetention: "none", toolChoice: { type: "tool", name: "read" } } };
    case "anthropic-header-owned":
      return { entrypoint: "stream", model: baseModel, context, options: { headers: { "x-api-key": "header-fixture" }, maxTokens: 4096, cacheRetention: "none" } };
    case "anthropic-missing-auth":
      return { entrypoint: "stream", model: baseModel, context, expectedFailure: true, options: { maxTokens: 4096, cacheRetention: "none" } };
    case "anthropic-copilot":
      return { entrypoint: "stream", model: { ...baseModel, provider: "github-copilot" }, context, options: { apiKey: "copilot-fixture", maxTokens: 4096, cacheRetention: "none" } };
    case "anthropic-compat-suppression":
      return { entrypoint: "stream", model: { ...baseModel, compat: { supportsEagerToolInputStreaming: false, supportsCacheControlOnTools: false, supportsTemperature: false, supportsLongCacheRetention: false } }, context, options: { apiKey: "fixture-key", maxTokens: 4096, temperature: 0.4, cacheRetention: "long" } };
    case "anthropic-budget-custom-omitted":
      return { entrypoint: "streamSimple", model: baseModel, context, options: { apiKey: "fixture-key", maxTokens: 2048, temperature: 0.4, reasoning: "high", thinkingBudgets: { high: 1536 }, cacheRetention: "none", onPayload: undefined } };
    case "anthropic-budget-default-answer-room-clamp":
      return { entrypoint: "streamSimple", model: { ...baseModel, maxTokens: 2048 }, context, options: { apiKey: "fixture-key", reasoning: "high", cacheRetention: "none" } };
    case "anthropic-adaptive-xhigh":
      return { entrypoint: "stream", model: { ...baseModel, id: "claude-opus-4-7", name: "Claude Opus 4.7", compat: { forceAdaptiveThinking: true } }, context, options: { apiKey: "fixture-key", maxTokens: 4096, thinkingEnabled: true, effort: "xhigh", thinkingDisplay: "omitted", cacheRetention: "none" } };
    case "anthropic-mid-convo-effort-history": {
      const model = { ...baseModel, id: "claude-fable-5-1", name: "Claude Fable 5.1", compat: { forceAdaptiveThinking: true, supportsMidConvoEffort: true } };
      const assistant = {
        role: "assistant", api: "anthropic-messages", provider: "anthropic", model: model.id,
        content: [{ type: "thinking", thinking: "inspect", thinkingSignature: "opaque-signature" }, { type: "text", text: "answer" }],
        providerThinkingLevel: "low", usage: zeroUsage(), stopReason: "stop", timestamp: 1,
      };
      return { entrypoint: "stream", model, context: { ...context, messages: [user, assistant, { role: "user", content: "again", timestamp: 2 }] }, options: { apiKey: "fixture-key", maxTokens: 4096, thinkingEnabled: true, effort: "high", cacheRetention: "none" } };
    }
    case "anthropic-mid-convo-effort-default":
      return { entrypoint: "stream", model: { ...baseModel, id: "claude-fable-5-1", name: "Claude Fable 5.1", compat: { forceAdaptiveThinking: true, supportsMidConvoEffort: true } }, context, options: { apiKey: "fixture-key", maxTokens: 4096, thinkingEnabled: true, cacheRetention: "none" } };
    case "anthropic-tool-any":
      return { entrypoint: "stream", model: baseModel, context, options: { apiKey: "fixture-key", maxTokens: 4096, cacheRetention: "none", toolChoice: "any" } };
    case "anthropic-disabled":
      return { entrypoint: "stream", model: baseModel, context, options: { apiKey: "fixture-key", maxTokens: 4096, thinkingEnabled: false, cacheRetention: "none" } };
    case "anthropic-server-fallback-source":
      return { entrypoint: "stream", model: { ...baseModel, compat: { allowedFallbackModels: [{ provider: "anthropic", model: "claude-haiku-4-5", cost: zeroCost() }] } }, context, options: { apiKey: "fixture-key", maxTokens: 4096, cacheRetention: "none" } };
    default: throw new Error(`unknown Anthropic case: ${caseID}`);
  }
}

async function captureBedrock(caseID) {
  const spec = bedrockSpec(caseID);
  let payload;
  const options = {
    ...spec.options,
    apiKey: "fixture-bearer",
    maxRetries: 0,
    env: { AWS_REGION: spec.region ?? "us-east-1", AWS_BEDROCK_SKIP_AUTH: "1", ...(spec.env ?? {}) },
    onPayload(value) { payload = value; throw new CaptureComplete(); },
  };
  const result = await bedrock[spec.entrypoint](spec.model, spec.context, options).result();
  if (payload === undefined) throw new Error(`${caseID}: ${result.errorMessage ?? "no payload"}`);
  const body = { ...payload }; delete body.modelId;
  return { requestBody: canonicalize(body), headers: {} };
}

function bedrockSpec(caseID) {
  const claude = model("bedrock-converse-stream", "amazon-bedrock", "anthropic.claude-sonnet-4-5", true);
  const nova = model("bedrock-converse-stream", "amazon-bedrock", "amazon.nova-lite-v1:0", true);
  const context = { systemPrompt: "Be concise", messages: [user], tools: [tool] };
  switch (caseID) {
    case "bedrock-cache-short-signed":
      return { entrypoint: "stream", model: claude, context: { ...context, messages: [user, signedAssistant] }, options: { maxTokens: 4096, cacheRetention: "short" } };
    case "bedrock-cache-long-forced-nonclaude":
      return { entrypoint: "stream", model: nova, context: { ...context, messages: [user, { ...signedAssistant, model: nova.id }] }, env: { AWS_BEDROCK_FORCE_CACHE: "1" }, options: { maxTokens: 4096, cacheRetention: "long" } };
    case "bedrock-cache-unsupported-invalid-redacted":
      return { entrypoint: "stream", model: nova, context: { ...context, messages: [user, { ...signedAssistant, model: nova.id, content: [{ type: "thinking", thinking: "[Reasoning redacted]", thinkingSignature: "%%%", redacted: true }] }] }, options: { maxTokens: 4096, cacheRetention: "short" } };
    case "bedrock-budget-custom-interleaved":
      return { entrypoint: "streamSimple", model: claude, context, options: { maxTokens: 4096, reasoning: "high", thinkingBudgets: { high: 1536 }, cacheRetention: "none" } };
    case "bedrock-budget-default-answer-room-clamp":
      return { entrypoint: "streamSimple", model: { ...claude, maxTokens: 2048 }, context, options: { reasoning: "high", cacheRetention: "none" } };
    case "bedrock-adaptive-govcloud":
      return { entrypoint: "stream", model: { ...claude, id: "us-gov.anthropic.claude-sonnet-4-6", name: "Claude Sonnet 4.6" }, context, region: "us-gov-west-1", options: { maxTokens: 4096, reasoning: "high", thinkingDisplay: "omitted", cacheRetention: "none" } };
    case "bedrock-nonclaude-reasoning":
      return { entrypoint: "stream", model: nova, context, options: { maxTokens: 4096, reasoning: "high", cacheRetention: "none" } };
    case "bedrock-tool-any":
      return { entrypoint: "stream", model: nova, context, options: { maxTokens: 4096, toolChoice: "any", cacheRetention: "none" } };
    case "bedrock-tool-named":
      return { entrypoint: "stream", model: nova, context, options: { maxTokens: 4096, toolChoice: { type: "tool", name: "read" }, cacheRetention: "none" } };
    default: throw new Error(`unknown Bedrock case: ${caseID}`);
  }
}

function model(api, provider, id, reasoning) {
  return { id, name: id, api, provider, baseUrl: "https://fixture.invalid", reasoning,
    input: ["text", "image"], cost: zeroCost(), contextWindow: 262144, maxTokens: 64000 };
}
function objectSchema() { return { type: "object", properties: { path: { type: "string" } }, required: ["path"] }; }
function zeroCost() { return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }; }
function zeroUsage() { return { ...zeroCost(), totalTokens: 0, cost: { ...zeroCost(), total: 0 } }; }
function selectedHeaders(headers) {
  const selected = ["accept", "anthropic-beta", "anthropic-dangerous-direct-browser-access", "authorization", "x-api-key", "x-app", "x-session-affinity"];
  return Object.fromEntries(selected.flatMap((name) => headers[name] === undefined ? [] : [[name, headers[name]]]));
}
function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object" && !(value instanceof Uint8Array)) {
    return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined)
      .sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => [key, canonicalize(item)]));
  }
  if (value instanceof Uint8Array) return Buffer.from(value).toString("base64");
  return value;
}
class CaptureComplete extends Error {}
