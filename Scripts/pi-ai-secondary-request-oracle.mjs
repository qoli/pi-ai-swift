#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [upstreamRoot, casePath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) {
  throw new Error("usage: pi-ai-secondary-request-oracle.mjs UPSTREAM_ROOT CASE_JSON");
}
const fixture = JSON.parse(await readFile(casePath, "utf8"));
if (fixture.schemaVersion !== 1) throw new Error(`unsupported case schema: ${fixture.schemaVersion}`);
const revision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) {
  throw new Error(`secondary request oracle revision mismatch: expected ${fixture.upstreamRevision}, found ${revision}`);
}

const cases = {};
for (const item of fixture.cases) cases[item.caseID] = await capture(item);
process.stdout.write(`${JSON.stringify({ schemaVersion: 1, cases }, null, 2)}\n`);

async function capture(item) {
  switch (item.protocolID) {
    case "pi-messages": return capturePi(item.caseID);
    case "mistral-conversations": return captureMistral(item.caseID);
    case "openrouter-images": return captureOpenRouter(item.caseID);
    default: throw new Error(`unsupported protocol: ${item.protocolID}`);
  }
}

async function capturePi(caseID) {
  const api = await providerStreams(
    upstreamRoot,
    await import(pathToFileURL(path.join(upstreamRoot, "packages/ai/src/api/pi-messages.ts")).href),
  );
  let payload;
  let requestUrl;
  const context = piContext(caseID);
  const options = {
    apiKey: "fixture-key",
    ...(caseID === "pi-debug-query" ? { debug: true } : {}),
    temperature: 0.25,
    maxTokens: 96,
    reasoning: "high",
    cacheRetention: "short",
    sessionId: "pi-session",
    toolChoice: "auto",
    onPayload(value) { payload = value; },
    fetch(url) {
      requestUrl = String(url);
      throw new CaptureComplete();
    },
  };
  await api.stream(piModel(), context, options).result();
  if (!payload || !requestUrl) throw new Error(`${caseID} did not capture Pi request`);
  return { protocolID: "pi-messages", url: requestUrl, requestBody: canonicalize(payload) };
}

function piContext(caseID) {
  const full = caseID === "pi-full-context";
  return {
    systemPrompt: "Keep metadata",
    messages: full ? [
      { role: "user", content: "First", timestamp: 11 },
      {
        role: "assistant", api: "pi-messages", provider: "radius", model: "fixture-pi",
        responseId: "response-1", responseModel: "fixture-pi-runtime",
        content: [
          { type: "text", text: "answer", textSignature: "text-signature" },
          { type: "thinking", thinking: "analysis", thinkingSignature: "thinking-signature" },
          { type: "toolCall", id: "call-1", name: "weather", arguments: { city: "Taipei" }, thoughtSignature: "tool-signature", namespace: "fixture.namespace" },
        ],
        usage: { input: 1, output: 2, reasoning: 1, cacheRead: 3, cacheWrite: 4, totalTokens: 10, cost: zeroCost() },
        stopReason: "toolUse", rawStopReason: "tool_use", timestamp: 12,
      },
      {
        role: "toolResult", toolCallId: "call-1", toolName: "weather",
        content: [{ type: "text", text: "sunny" }],
        isError: false, timestamp: 13,
      },
    ] : [{ role: "user", content: "First", timestamp: 11 }],
    tools: [
      { name: "weather", description: "Weather", parameters: objectSchema("city"), constrainedSampling: { type: "json_schema", strict: "prefer" } },
      { name: "lookup", description: "Lookup", parameters: objectSchema("query") },
    ],
  };
}

function piModel() {
  return {
    id: "fixture-pi", name: "Fixture Pi", api: "pi-messages", provider: "radius",
    baseUrl: "https://radius.invalid/v1", reasoning: true, input: ["text", "image"],
    cost: zeroCost(), contextWindow: 128000, maxTokens: 4096,
  };
}

async function captureMistral(caseID) {
  const api = await providerStreams(
    upstreamRoot,
    await import(pathToFileURL(path.join(upstreamRoot, "packages/ai/src/api/mistral-conversations.ts")).href),
  );
  const model = mistralModel(caseID);
  const context = mistralContext(caseID);
  const options = mistralOptions(caseID);
  let payload;
  let requestUrl;
  let requestHeaders = {};
  options.onPayload = (value) => { payload = value; };
  options.fetch = (url, init) => {
    requestUrl = String(url);
    requestHeaders = Object.fromEntries(new Headers(init?.headers).entries());
    throw new CaptureComplete();
  };
  const providerSpecific = caseID === "mistral-tool-choice-any"
    || caseID === "mistral-tool-choice-required"
    || caseID === "mistral-tool-choice-named";
  await (providerSpecific ? api.stream(model, context, options) : api.streamSimple(model, context, options)).result();
  if (!payload || !requestUrl) throw new Error(`${caseID} did not capture Mistral request`);
  return {
    protocolID: "mistral-conversations",
    headers: selectedHeaders(requestHeaders, ["x-affinity"]),
    requestBody: canonicalize(mistralWirePayload(payload)),
  };
}

function mistralModel(caseID) {
  const effort = [
    "mistral-reasoning-effort",
    "mistral-medium-reasoning-effort",
    "mistral-zai-reasoning-effort",
  ].includes(caseID);
  const supportsImages = !caseID.includes("unsupported");
  const modelID = caseID === "mistral-medium-reasoning-effort"
    ? "mistral-medium-2606"
    : caseID === "mistral-zai-reasoning-effort"
      ? "zai-glm-5-2"
      : effort ? "mistral-small-2603" : "mistral-fixture";
  return {
    id: modelID,
    name: effort ? "Mistral Small" : "Mistral Fixture",
    api: "mistral-conversations", provider: "mistral", baseUrl: "https://api.mistral.ai/v1",
    reasoning: effort || caseID === "mistral-prompt-mode",
    input: supportsImages ? ["text", "image"] : ["text"],
    cost: zeroCost(), contextWindow: 128000, maxTokens: 4096,
  };
}

function mistralContext(caseID) {
  const messages = [{ role: "user", content: "Hello", timestamp: 1 }];
  if (caseID === "mistral-image-unsupported") {
    messages[0] = { role: "user", content: [{ type: "image", data: "AQI=", mimeType: "image/png" }], timestamp: 1 };
  }
  if (caseID === "mistral-tool-image-unsupported-error") {
    messages.push({
      role: "assistant", api: "mistral-conversations", provider: "mistral", model: "mistral-fixture",
      content: [{ type: "toolCall", id: "call-1", name: "weather", arguments: { city: "Taipei" } }],
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: zeroCost() },
      stopReason: "toolUse", timestamp: 2,
    });
    messages.push({
      role: "toolResult", toolCallId: "call-1", toolName: "weather",
      content: [{ type: "text", text: "failed" }, { type: "image", data: "AQI=", mimeType: "image/png" }],
      isError: true, timestamp: 3,
    });
  }
  return { systemPrompt: "Be concise", messages, tools: [{ name: "weather", description: "Weather", parameters: objectSchema("city") }] };
}

function mistralOptions(caseID) {
  const options = { apiKey: "fixture-key", maxTokens: 64, maxRetries: 0 };
  if (caseID.includes("reasoning-effort") || caseID === "mistral-prompt-mode") options.reasoning = "high";
  if (caseID === "mistral-cache-none") options.cacheRetention = "none";
  if (caseID === "mistral-cache-long") { options.cacheRetention = "long"; options.sessionId = "mistral-session"; }
  if (caseID === "mistral-tool-choice-any") options.toolChoice = "any";
  if (caseID === "mistral-tool-choice-required") options.toolChoice = "required";
  if (caseID === "mistral-tool-choice-named") options.toolChoice = { type: "function", function: { name: "weather" } };
  return options;
}

async function captureOpenRouter(caseID) {
  const api = await import(pathToFileURL(path.join(upstreamRoot, "packages/ai/src/api/openrouter-images.ts")).href);
  const input = caseID.includes("empty") ? []
    : caseID.includes("mixed") ? [{ type: "text", text: "Draw" }, { type: "image", data: "AQI=", mimeType: "image/png" }]
      : caseID.includes("image-input") ? [{ type: "image", data: "AQI=", mimeType: "image/png" }]
        : [{ type: "text", text: "Draw" }];
  const output = caseID === "openrouter-image-text-output" ? ["image", "text"] : ["image"];
  const model = {
    id: "openrouter/fixture-image", name: "Fixture Image", api: "openrouter-images", provider: "openrouter",
    baseUrl: "https://openrouter.ai/api/v1", input: ["text", "image"], output,
    cost: zeroCost(),
  };
  let payload;
  await api.generateImages(model, { input }, {
    apiKey: "fixture-key",
    onPayload(value) { payload = value; throw new CaptureComplete(); },
  });
  if (!payload) throw new Error(`${caseID} did not capture OpenRouter request`);
  return { protocolID: "openrouter-images", requestBody: canonicalize(payload) };
}

function mistralWirePayload(payload) {
  const body = { ...payload };
  for (const [source, target] of [["maxTokens", "max_tokens"], ["toolChoice", "tool_choice"], ["promptMode", "prompt_mode"], ["reasoningEffort", "reasoning_effort"], ["promptCacheKey", "prompt_cache_key"]]) {
    if (body[source] !== undefined) { body[target] = body[source]; delete body[source]; }
  }
  body.messages = body.messages.map((message) => {
    const wire = { ...message };
    if (wire.toolCalls !== undefined) { wire.tool_calls = wire.toolCalls; delete wire.toolCalls; }
    if (wire.toolCallId !== undefined) { wire.tool_call_id = wire.toolCallId; delete wire.toolCallId; }
    if (Array.isArray(wire.content)) wire.content = wire.content.map((chunk) => {
      const next = { ...chunk };
      if (next.imageUrl !== undefined) { next.image_url = next.imageUrl; delete next.imageUrl; }
      return next;
    });
    return wire;
  });
  return body;
}

function selectedHeaders(headers, names) {
  return Object.fromEntries(names.filter((name) => headers[name] !== undefined).map((name) => [name, headers[name]]));
}
function objectSchema(name) { return { type: "object", properties: { [name]: { type: "string" } }, required: [name] }; }
function zeroCost() { return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }; }
function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => [key, canonicalize(item)]));
  return value;
}
class CaptureComplete extends Error {}
