#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [upstreamRoot, casePath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) {
  throw new Error("usage: pi-ai-source-oracle.mjs UPSTREAM_ROOT CASE_JSON");
}

const fixture = JSON.parse(await readFile(casePath, "utf8"));
if (fixture.schemaVersion !== 1) {
  throw new Error(`unsupported differential case schema: ${fixture.schemaVersion}`);
}

const apiRoot = path.join(upstreamRoot, "packages/ai/src/api");
const results = {};

for (const protocol of fixture.protocols) {
  results[protocol.protocolID] = await captureProtocol(protocol);
}

process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  caseID: fixture.caseID,
  protocols: results,
}, null, 2)}\n`);

async function captureProtocol(protocol) {
  if (protocol.protocolID === "openrouter-images") {
    return captureImages(protocol);
  }

  const modulePath = path.join(apiRoot, `${protocol.protocolID}.ts`);
  const implementation = await import(pathToFileURL(modulePath).href);
  if (typeof implementation.streamSimple !== "function") {
    throw new Error(`${protocol.protocolID} has no streamSimple oracle`);
  }

  let payload;
  const model = textModel(protocol);
  const context = {
    systemPrompt: fixture.systemPrompt,
    messages: [{ role: "user", content: fixture.userText, timestamp: 0 }],
    tools: [{
      name: fixture.tool.name,
      description: fixture.tool.description,
      parameters: fixture.tool.parameters,
    }],
  };
  const options = {
    apiKey: credential(protocol),
    maxTokens: fixture.options.maximumOutputTokens,
    temperature: fixture.options.temperature,
    sessionId: fixture.options.sessionID,
    cacheRetention: fixture.options.cacheRetention,
    toolChoice: fixture.options.toolChoice,
    maxRetries: 0,
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
  if (!["google-generative-ai", "google-vertex", "bedrock-converse-stream"].includes(
    protocol.protocolID,
  )) {
    options.fetch = () => {
      throw new Error(`unexpected network request: ${protocol.protocolID}`);
    };
  }
  const stream = implementation.streamSimple(model, context, options);
  const result = await stream.result();
  if (payload === undefined) {
    throw new Error(
      `${protocol.protocolID} did not expose a request payload: ` +
        `${result.errorMessage ?? "unknown"}`,
    );
  }
  return { requestBody: canonicalize(canonicalRequestBody(protocol.protocolID, payload)) };
}

async function captureImages(protocol) {
  const modulePath = path.join(apiRoot, "openrouter-images.ts");
  const implementation = await import(pathToFileURL(modulePath).href);
  let payload;
  const model = {
    id: protocol.modelID,
    name: protocol.modelID,
    api: protocol.protocolID,
    provider: protocol.providerID,
    baseUrl: protocol.baseURL,
    input: ["text", "image"],
    output: ["text", "image"],
    cost: zeroCost(),
  };
  const result = await implementation.generateImages(
    model,
    { input: [{ type: "text", text: fixture.userText }] },
    {
      apiKey: "fixture-key",
      maxRetries: 0,
      onPayload(value) {
        payload = value;
        throw new OracleCaptureComplete();
      },
      fetch() {
        throw new Error("unexpected network request: openrouter-images");
      },
    },
  );
  if (payload === undefined) {
    throw new Error(`openrouter-images did not expose a request payload: ${result.errorMessage ?? "unknown"}`);
  }
  return { requestBody: canonicalize(payload) };
}

function textModel(protocol) {
  return {
    id: protocol.modelID,
    name: protocol.modelID,
    api: protocol.protocolID,
    provider: protocol.providerID,
    baseUrl: protocol.baseURL,
    reasoning: protocol.reasoning,
    input: ["text", "image"],
    cost: zeroCost(),
    contextWindow: 262144,
    maxTokens: protocol.maximumOutputTokens,
    ...(protocol.compat ? { compat: protocol.compat } : {}),
  };
}

function credential(protocol) {
  if (protocol.protocolID !== "openai-codex-responses") return "fixture-key";
  const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url");
  const body = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: "fixture-account" },
  })).toString("base64url");
  return `${header}.${body}.fixture`;
}

function zeroCost() {
  return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
        .map(([key, item]) => [key, canonicalize(item)]),
    );
  }
  return value;
}

function canonicalRequestBody(protocolID, payload) {
  if (protocolID === "mistral-conversations") {
    const body = { ...payload };
    for (const [source, target] of [
      ["maxTokens", "max_tokens"],
      ["toolChoice", "tool_choice"],
      ["promptMode", "prompt_mode"],
      ["reasoningEffort", "reasoning_effort"],
      ["promptCacheKey", "prompt_cache_key"],
    ]) {
      if (body[source] !== undefined) {
        body[target] = body[source];
        delete body[source];
      }
    }
    body.messages = body.messages.map((message) => {
      const wire = { ...message };
      if (wire.toolCalls !== undefined) {
        wire.tool_calls = wire.toolCalls;
        delete wire.toolCalls;
      }
      if (wire.toolCallId !== undefined) {
        wire.tool_call_id = wire.toolCallId;
        delete wire.toolCallId;
      }
      return wire;
    });
    return body;
  }
  if (protocolID === "bedrock-converse-stream") {
    const body = { ...payload };
    delete body.modelId;
    return body;
  }
  if (!["google-generative-ai", "google-vertex"].includes(protocolID)) return payload;
  const config = payload.config ?? {};
  const body = { contents: payload.contents };
  if (config.systemInstruction !== undefined) {
    body.systemInstruction = { parts: [{ text: config.systemInstruction }] };
  }
  const generationConfig = {};
  for (const key of [
    "maxOutputTokens",
    "temperature",
    "responseMimeType",
    "responseJsonSchema",
    "thinkingConfig",
  ]) {
    if (config[key] !== undefined) generationConfig[key] = config[key];
  }
  if (Object.keys(generationConfig).length > 0) body.generationConfig = generationConfig;
  if (config.tools !== undefined) body.tools = config.tools;
  if (config.toolConfig !== undefined) body.toolConfig = config.toolConfig;
  return body;
}

class OracleCaptureComplete extends Error {
  constructor() {
    super("source oracle request captured");
  }
}
