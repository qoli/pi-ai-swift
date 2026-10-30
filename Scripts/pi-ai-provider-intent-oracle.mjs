#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [root, casePath] = process.argv.slice(2);
const fixture = JSON.parse(await readFile(casePath, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("provider intent revision mismatch");
const cases = {};
for (const spec of fixture.cases) {
  const source = spec.azureProvider
    ? (await import(pathToFileURL(path.join(root, "packages/ai/src/providers/azure.ts")))).azureProvider()
    : await import(pathToFileURL(path.join(root, "packages/ai/src/api", `${spec.model.api}.ts`)));
  const implementation = await providerStreams(root, source);
  let body;
  const result = await implementation[spec.entrypoint ?? "stream"](spec.model, context(spec), {
    apiKey: spec.apiKey ?? "sk-fixture", maxRetries: 0, maxTokens: 4096, cacheRetention: "none",
    ...(spec.options ?? {}),
    env: { AWS_REGION: "us-east-1", AWS_BEDROCK_SKIP_AUTH: "1", ...(spec.options?.env ?? {}) },
    onPayload(value) { body = value; if (spec.model.api !== "mistral-conversations") throw new Error("fixture capture complete"); },
    fetch(_url, init) { body = JSON.parse(init.body); throw new Error("fixture wire capture complete"); },
  }).result();
  if (body === undefined) throw new Error(`${spec.id}: ${result.errorMessage}`);
  if (spec.model.api === "bedrock-converse-stream") {
    if (body.modelId !== spec.model.id) throw new Error("Bedrock model identity changed");
    delete body.modelId;
  }
  cases[spec.id] = { requestBody: body };
}
process.stdout.write(JSON.stringify({ schemaVersion: 1, upstreamRevision: revision, cases }, null, 2) + "\n");

function context(spec) {
  const messages = [{ role: "user", content: "hello", timestamp: 0 }];
  if (spec.history) messages.push({
    role: "assistant", api: spec.model.api, provider: spec.model.provider, model: spec.model.id,
    providerThinkingLevel: "low", content: [{ type: "text", text: "answer" }],
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { ...spec.model.cost, total: 0 } },
    stopReason: "stop", timestamp: 1,
  }, { role: "user", content: "again", timestamp: 2 });
  return { messages, ...(spec.tools ? { tools: spec.tools } : {}) };
}
