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
  if (spec.operation === "googleThinkingLevel") {
    const shared = await import(pathToFileURL(path.join(root, "packages/ai/src/api/google-shared.ts")));
    let resolvedLevel, error;
    try { resolvedLevel = shared.resolveGoogleThinkingLevel(spec.model, spec.options.reasoningEffort); }
    catch (failure) { error = failure.message; }
    if (!!error !== !!spec.expectError) throw new Error(`${spec.id}: unexpected resolver outcome`);
    cases[spec.id] = error ? { error } : { resolvedLevel };
    continue;
  }
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
    ...(spec.model.api.startsWith("google-") ? {} : {
      fetch(_url, init) { body = JSON.parse(init.body); throw new Error("fixture wire capture complete"); },
    }),
  }).result();
  if (body === undefined) {
    if (!spec.expectError) throw new Error(`${spec.id}: ${result.errorMessage}`);
    cases[spec.id] = { error: result.errorMessage };
    continue;
  }
  if (spec.expectError) throw new Error(`${spec.id}: upstream unexpectedly accepted this schema`);
  if (spec.model.api === "bedrock-converse-stream") {
    if (body.modelId !== spec.model.id) throw new Error("Bedrock model identity changed");
    delete body.modelId;
  }
  if (spec.projectFields) {
    cases[spec.id] = { requestBody: Object.fromEntries(spec.projectFields.map(key => [key, body[key]])),
      ...(spec.rawOptions ? { providerThinkingLevel: result.providerThinkingLevel } : {}) };
    continue;
  }
  cases[spec.id] = { requestBody: spec.model.api.startsWith("google-")
    ? { thinkingConfig: body.config?.thinkingConfig ?? null } : body };
}
process.stdout.write(JSON.stringify({ schemaVersion: 1, upstreamRevision: revision, cases }, null, 2) + "\n");

function context(spec) {
  const messages = [{ role: "user", content: "hello", timestamp: 0 }];
  if (spec.history) messages.push({
    role: "assistant", api: spec.model.api, provider: spec.model.provider, model: spec.model.id,
    ...(spec.assistantSource ?? {}),
    providerThinkingLevel: "low", content: spec.assistantContent ?? [{ type: "text", text: "answer" }],
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { ...spec.model.cost, total: 0 } },
    stopReason: "stop", timestamp: 1,
  }, { role: "user", content: "again", timestamp: 2 });
  return { messages, ...(spec.tools ? { tools: spec.tools } : {}) };
}
