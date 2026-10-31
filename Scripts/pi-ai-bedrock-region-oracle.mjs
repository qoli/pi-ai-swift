import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { registerHooks } from "node:module";
import { pathToFileURL } from "node:url";
import path from "node:path";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Bedrock region revision mismatch");
const sourceURL = pathToFileURL(path.join(root, "packages/ai/src/api/bedrock-converse-stream.ts")).href;
registerHooks({
  load(url, context, nextLoad) {
    const loaded = nextLoad(url, context);
    if (url !== sourceURL) return loaded;
    const source = Buffer.from(loaded.source).toString("utf8");
    const expression = "new BedrockRuntimeClient(config)";
    if (source.split(expression).length !== 2) throw new Error("Bedrock client observation site changed");
    return { ...loaded, source: source.replace(expression,
      "(globalThis.__piBedrockObservedConfig = config, new BedrockRuntimeClient(config))") };
  },
});
const { stream } = await import(sourceURL);
const { normalizeContext } = await import(pathToFileURL(path.join(root, "packages/ai/src/utils/transcript.ts")));
delete process.env.AWS_REGION;
delete process.env.AWS_DEFAULT_REGION;
delete process.env.AWS_PROFILE;
const cases = [];
for (const spec of fixture.cases) {
  globalThis.__piBedrockObservedConfig = undefined;
  await stream({ id: spec.modelID, name: "Fixture", api: "bedrock-converse-stream", provider: "amazon-bedrock",
    baseUrl: spec.endpoint, reasoning: false, input: ["text"], contextWindow: 32768, maxTokens: 4096,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } },
    normalizeContext({ messages: [{ role: "user", content: "synthetic question", timestamp: 0 }] }),
    { env: { AWS_REGION: spec.region, AWS_BEDROCK_SKIP_AUTH: "1" }, cacheRetention: "none",
      onPayload: () => { throw new Error("fixture capture complete"); } }).result();
  const region = globalThis.__piBedrockObservedConfig?.region;
  if (typeof region !== "string") throw new Error(`${spec.id}: Source did not resolve a region`);
  cases.push({ id: spec.id, region });
}
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
