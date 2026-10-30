import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [root, casePath] = process.argv.slice(2);
const fixture = JSON.parse(await readFile(casePath, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Bedrock input revision mismatch");
const implementation = await providerStreams(root, await import(pathToFileURL(path.join(root, "packages/ai/src/api/bedrock-converse-stream.ts"))));
const model = { id: "fixture-model", name: "Fixture", api: "bedrock-converse-stream", provider: "amazon-bedrock", baseUrl: "https://fixture.invalid", reasoning: false, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 4096 };
const cases = {};
for (const spec of fixture.cases) {
  const content = spec.content.map(({ utf16, ...block }) => utf16 ? { ...block, text: String.fromCharCode(...utf16) } : block);
  const message = { role: spec.role, content, timestamp: 1, ...(spec.role === "assistant" ? { api: model.api, provider: model.provider, model: model.id, stopReason: "stop", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } } : {}) };
  let captured;
  await implementation.stream(model, { messages: [message] }, {
    maxTokens: 64, cacheRetention: "none", env: { AWS_BEDROCK_SKIP_AUTH: "1", AWS_REGION: "us-east-1" },
    onPayload: payload => { captured = structuredClone(payload.messages); throw new Error("fixture capture complete"); },
  }).result();
  if (!captured) throw new Error(`${spec.id}: source did not project the input`);
  cases[spec.id] = captured;
}
process.stdout.write(JSON.stringify({ upstreamRevision: revision, cases }, null, 2) + "\n");
