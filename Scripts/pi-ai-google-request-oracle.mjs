#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [upstreamRoot, casePath, outputPath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) {
  throw new Error("usage: pi-ai-google-request-oracle.mjs UPSTREAM_ROOT CASE_JSON");
}

const fixture = JSON.parse(await readFile(casePath, "utf8"));
if (fixture.schemaVersion !== 1) throw new Error(`unsupported Google case schema: ${fixture.schemaVersion}`);
const revision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) {
  throw new Error(`Google oracle revision mismatch: expected ${fixture.upstreamRevision}, found ${revision}`);
}

const results = {};
for (const testCase of fixture.cases) {
  results[testCase.caseID] = {};
  for (const protocolID of testCase.protocols ?? fixture.protocols) {
    results[testCase.caseID][protocolID] = await capture(protocolID, testCase);
  }
}

const output = `${JSON.stringify({
  schemaVersion: 1,
  upstreamRevision: revision,
  cases: results,
}, null, 2)}\n`;
if (outputPath) await writeFile(outputPath, output);
else process.stdout.write(output);

async function capture(protocolID, testCase) {
  const implementation = await import(
    pathToFileURL(path.join(upstreamRoot, "packages/ai/src/api", `${protocolID}.ts`)).href
  );
  let payload;
  const providerID = protocolID === "google-vertex" ? "fixture-vertex" : "fixture-google";
  const model = {
    id: testCase.modelID,
    name: testCase.modelID,
    api: protocolID,
    provider: providerID,
    baseUrl: protocolID === "google-vertex"
      ? (testCase.baseURL ?? "https://{location}-aiplatform.googleapis.com")
      : "https://generativelanguage.googleapis.com/v1beta",
    reasoning: testCase.variant === "reasoning",
    input: ["text", "image"],
    cost: zeroCost(),
    contextWindow: 262144,
    maxTokens: 8192,
  };
  let wireRequest;
  const originalFetch = globalThis.fetch;
  if (testCase.variant === "vertex-wire") {
    globalThis.fetch = async (input, init) => {
      const request = input instanceof Request ? input : new Request(input, init);
      wireRequest = {
        url: request.url,
        headers: Object.fromEntries(request.headers.entries()),
      };
      return new Response(
        'data: {"responseId":"fixture","candidates":[{"finishReason":"STOP"}]}\n\n',
        { status: 200, headers: { "content-type": "text/event-stream" } },
      );
    };
  }
  const options = {
    apiKey: protocolID === "google-vertex"
      ? vertexAPIKey(testCase.vertexAuth)
      : "fixture-key",
    maxRetries: 0,
    maxTokens: testCase.variant === "generation" ? 321 : 64,
    ...(testCase.cacheRetention ? { cacheRetention: testCase.cacheRetention } : {}),
    ...(testCase.variant === "generation" ? { temperature: 0.25 } : {}),
    ...(testCase.reasoning && testCase.reasoning !== "off" ? { reasoning: testCase.reasoning } : {}),
    ...(testCase.customBudget !== undefined
      ? { thinkingBudgets: { minimal: 11, low: testCase.customBudget, medium: 33, high: 44 } }
      : {}),
    ...(testCase.toolChoice ? { toolChoice: testCase.toolChoice } : {}),
    ...(testCase.project ? { project: testCase.project } : {}),
    ...(testCase.location ? { location: testCase.location } : {}),
    env: {
      ...(protocolID === "google-vertex" && testCase.variant !== "vertex-config"
        ? { GOOGLE_CLOUD_PROJECT: "fixture-project", GOOGLE_CLOUD_LOCATION: "us-central1" }
        : {}),
      ...(testCase.envProject ? { GOOGLE_CLOUD_PROJECT: testCase.envProject } : {}),
      ...(testCase.envLocation ? { GOOGLE_CLOUD_LOCATION: testCase.envLocation } : {}),
    },
    ...(testCase.variant === "vertex-wire" ? {} : {
      onPayload(value) {
        payload = value;
        throw new OracleCaptureComplete();
      },
    }),
  };
  const directVertexConfiguration = protocolID === "google-vertex"
    && testCase.variant === "vertex-config"
    && (testCase.project || testCase.location);
  const result = await (directVertexConfiguration
    ? implementation.stream(model, context(protocolID, providerID, testCase), options)
    : implementation.streamSimple(model, context(protocolID, providerID, testCase), options)
  ).result();
  globalThis.fetch = originalFetch;
  if (wireRequest !== undefined) return { wireRequest };
  if (payload !== undefined) {
    return { requestBody: canonicalize(canonicalRequestBody(payload)) };
  }
  return { error: result.errorMessage ?? "unknown Google source failure" };
}

function context(protocolID, providerID, testCase) {
  const source = {
    api: protocolID,
    provider: providerID,
    model: testCase.modelID,
  };
  let messages = [{ role: "user", content: "hello", timestamp: 0 }];
  if (testCase.variant === "replay") {
    const messageSource = testCase.sameSource ? source : { api: protocolID, provider: providerID, model: "other-model" };
    messages = [
      { role: "user", content: "first", timestamp: 0 },
      {
        role: "assistant",
        ...messageSource,
        content: [
          { type: "text", text: "answer", textSignature: "dGV4dA==" },
          { type: "thinking", thinking: "analysis", thinkingSignature: "dGhpbms=" },
          { type: "toolCall", id: "call-1", name: "weather", arguments: { city: "Taipei" }, thoughtSignature: "dG9vbA==" },
        ],
        usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: zeroCost() },
        stopReason: "toolUse",
        timestamp: 1,
      },
    ];
  } else if (["tool-result", "consecutive-tool-results"].includes(testCase.variant)) {
    messages = [
      { role: "user", content: "first", timestamp: 0 },
      {
        role: "assistant", ...source,
        content: [
          { type: "toolCall", id: "call-1", name: "weather", arguments: { city: "Taipei" } },
          ...(testCase.variant === "consecutive-tool-results"
            ? [{ type: "toolCall", id: "call-2", name: "time", arguments: { zone: "UTC" } }]
            : []),
        ],
        usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: zeroCost() },
        stopReason: "toolUse", timestamp: 1,
      },
      {
        role: "toolResult", toolCallId: "call-1", toolName: "weather",
        content: [
          { type: "text", text: "sunny" },
          ...(testCase.toolImage ? [{ type: "image", data: "AQI=", mimeType: "image/png" }] : []),
        ],
        isError: testCase.toolError === true, timestamp: 2,
      },
      ...(testCase.variant === "consecutive-tool-results"
        ? [{ role: "toolResult", toolCallId: "call-2", toolName: "time", content: [{ type: "text", text: "12:00" }], isError: false, timestamp: 3 }]
        : []),
    ];
  }
  const strict = testCase.variant === "strict-tools";
  const usesTools = ["tools", "strict-tools", "generation"].includes(testCase.variant);
  return {
    systemPrompt: testCase.variant === "generation" ? "be concise" : undefined,
    messages,
    tools: usesTools ? [{
      name: "weather",
      description: "Read weather",
      parameters: {
        type: "object",
        properties: {
          city: { type: "string" },
          units: { type: "string" },
        },
        required: ["city"],
      },
      ...(strict ? { constrainedSampling: { type: "json_schema", strict: "prefer" } } : {}),
    }] : undefined,
  };
}

function canonicalRequestBody(payload) {
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

function vertexAPIKey(kind) {
  if (kind === "api-key") return "fixture-key";
  if (kind === "placeholder") return "<vertex-api-key>";
  return "gcp-vertex-credentials";
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => [key, canonicalize(item)]));
  }
  return value;
}

function zeroCost() { return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }; }

class OracleCaptureComplete extends Error {}
