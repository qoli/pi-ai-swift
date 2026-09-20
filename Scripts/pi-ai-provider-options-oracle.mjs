#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [upstreamRoot, casePath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) throw new Error("usage: oracle UPSTREAM_ROOT CASE_JSON");
const fixture = JSON.parse(await readFile(casePath, "utf8"));
const revision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], {
  encoding: "utf8",
}).trim();
if (revision !== fixture.upstreamRevision) throw new Error(`revision mismatch: ${revision}`);

const cases = {
  "openrouter-completions-session": await captureHeaders("openai-completions", model({
    api: "openai-completions", provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1",
  })),
  "baseten-completions-session": await captureHeaders("openai-completions", model({
    api: "openai-completions", provider: "baseten", baseUrl: "https://inference.baseten.co/v1",
    compat: { sendSessionAffinityHeaders: true },
  })),
  "openrouter-responses-session": await captureHeaders("openai-responses", model({
    api: "openai-responses", provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1",
  })),
  "openrouter-anthropic-session": await captureHeaders("anthropic-messages", model({
    api: "anthropic-messages", provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1",
  })),
  "opencode-session-wrapper": await captureOpenCodeWrapper(),
  "vllm-priority": await capturePayload("openai-completions", model({
    api: "openai-completions", provider: "fixture", baseUrl: "https://fixture.invalid/v1",
    compat: { vllmPriority: 7 },
  })),
  "responses-max-output-disabled": await capturePayload("openai-responses", model({
    api: "openai-responses", provider: "fixture", baseUrl: "https://fixture.invalid/v1",
    compat: { supportsMaxOutputTokens: false },
  })),
};

process.stdout.write(`${JSON.stringify({ schemaVersion: 1, upstreamRevision: revision, cases }, null, 2)}\n`);

async function captureHeaders(protocolID, sourceModel) {
  const implementation = await load(protocolID);
  let captured = {};
  const options = baseOptions();
  options.fetch = async (input, init) => {
    const request = input instanceof Request ? input : new Request(input, init);
    const headers = Object.fromEntries(request.headers.entries());
    captured = selected(headers, [
      "session_id", "x-client-request-id", "x-session-affinity", "x-session-id",
    ]);
    throw new CaptureComplete();
  };
  await implementation.stream(sourceModel, context(), options).result();
  return { headers: captured };
}

async function capturePayload(protocolID, sourceModel) {
  const implementation = await load(protocolID);
  let payload;
  const options = baseOptions();
  options.onPayload = (value) => {
    payload = value;
    throw new CaptureComplete();
  };
  await implementation.stream(sourceModel, context(), options).result();
  return {
    requestBody: protocolID === "openai-completions"
      ? { priority: payload?.priority ?? null }
      : { maxOutputTokensPresent: payload?.max_output_tokens !== undefined },
  };
}

async function captureOpenCodeWrapper() {
  const module = await import(pathToFileURL(path.join(
    upstreamRoot, "packages/ai/src/providers/opencode-headers.ts",
  )).href);
  let observed;
  const wrapped = module.withOpenCodeSessionHeader({
    stream(_model, _context, options) { observed = options; return null; },
    streamSimple(_model, _context, options) { observed = options; return null; },
  });
  wrapped.stream({}, { messages: [] }, { sessionId: "fixture-session" });
  return { headers: selected(observed?.headers ?? {}, ["x-opencode-session"]) };
}

async function load(protocolID) {
  return providerStreams(
    upstreamRoot,
    await import(pathToFileURL(path.join(
      upstreamRoot, "packages/ai/src/api", `${protocolID}.ts`,
    )).href),
  );
}

function context() {
  return { systemPrompt: "system", messages: [{ role: "user", content: "hello", timestamp: 0 }] };
}
function baseOptions() {
  return {
    apiKey: "fixture-key", sessionId: "fixture-session", cacheRetention: "short",
    maxTokens: 32, maxRetries: 0,
  };
}
function model(overrides) {
  return {
    id: "fixture-model", name: "Fixture", reasoning: false, input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 128000, maxTokens: 4096, ...overrides,
  };
}
function selected(headers, names) {
  return Object.fromEntries(names.filter((name) => headers[name] !== undefined).map((name) => [name, headers[name]]));
}
class CaptureComplete extends Error {}
