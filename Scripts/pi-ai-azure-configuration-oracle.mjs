#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [upstreamRoot, casePath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) {
  throw new Error("usage: pi-ai-azure-configuration-oracle.mjs UPSTREAM_ROOT CASE_JSON");
}

const fixture = JSON.parse(await readFile(casePath, "utf8"));
if (fixture.schemaVersion !== 1 || !Array.isArray(fixture.cases)) {
  throw new Error("unsupported Azure OpenAI configuration fixture");
}
const repositoryRoot = path.resolve(path.dirname(casePath), "../../..");
const lock = JSON.parse(await readFile(path.join(repositoryRoot, "Upstream.lock.json"), "utf8"));
const revision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], {
  encoding: "utf8",
}).trim();
if (revision !== lock.revision) {
  throw new Error(`Azure configuration oracle revision mismatch: expected ${lock.revision}, found ${revision}`);
}

const implementation = await providerStreams(
  upstreamRoot,
  await import(pathToFileURL(path.join(
    upstreamRoot,
    "packages/ai/src/api/azure-openai-responses.ts",
  )).href),
);
for (const name of [
  "AZURE_OPENAI_BASE_URL",
  "AZURE_OPENAI_RESOURCE_NAME",
  "AZURE_OPENAI_API_VERSION",
  "AZURE_OPENAI_DEPLOYMENT_NAME_MAP",
]) {
  delete process.env[name];
}
const results = {};
for (const testCase of fixture.cases) {
  results[testCase.id] = await capture(testCase);
}
process.stdout.write(`${JSON.stringify({ schemaVersion: 1, upstreamRevision: revision, cases: results }, null, 2)}\n`);

async function capture(testCase) {
  let captured;
  const model = {
    id: testCase.modelID,
    name: testCase.modelID,
    api: "azure-openai-responses",
    provider: "azure-openai-responses",
    ...(testCase.modelBaseURL !== undefined ? { baseUrl: testCase.modelBaseURL } : {}),
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 32768,
    maxTokens: 4096,
  };
  const context = {
    systemPrompt: "Azure source fixture",
    messages: [{ role: "user", content: "hello", timestamp: 0 }],
  };
  const stream = implementation.stream(model, context, {
    apiKey: "sanitized-fixture-key",
    ...testCase.options,
    maxRetries: 0,
    fetch(input, init) {
      const body = JSON.parse(init?.body ?? "{}");
      captured = { url: String(input), model: body.model };
      throw new Error("fixture request captured");
    },
  });
  const result = await stream.result();
  if (captured !== undefined) return captured;
  return { errorMessage: result.errorMessage ?? "unknown error" };
}
