import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { registerHooks } from "node:module";
import { pathToFileURL } from "node:url";
import path from "node:path";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Cloud authorization revision mismatch");
globalThis.__piObserveCloudConstructor = Original => class extends Original {
  constructor(options) { globalThis.__piCloudConfigurations.push(JSON.parse(JSON.stringify(options))); super(options); }
};
const apiRoot = pathToFileURL(path.join(root, "packages/ai/src/api/")).href;
registerHooks({
  load(url, context, nextLoad) {
    const loaded = nextLoad(url, context);
    if (!url.startsWith(apiRoot) || !["google-vertex.ts", "bedrock-converse-stream.ts", "anthropic-messages.ts"].some(name => url.endsWith(name))) return loaded;
    const source = Buffer.from(loaded.source).toString("utf8");
    return { ...loaded, source: source.replace(/new (GoogleGenAI|BedrockRuntimeClient|PiAnthropic)\(/g,
      "new (globalThis.__piObserveCloudConstructor($1))(") };
  },
});
const implementations = {};
for (const api of ["google-vertex", "bedrock-converse-stream", "anthropic-messages"]) {
  implementations[api] = await import(pathToFileURL(path.join(root, "packages/ai/src/api", api + ".ts")));
}
const { normalizeContext } = await import(pathToFileURL(path.join(root, "packages/ai/src/utils/transcript.ts")));
const cases = [];
for (const spec of fixture.cases) {
  for (const name of Object.keys(process.env)) if (/^(AWS_|GOOGLE_|GCLOUD_|ANTHROPIC_)/.test(name)) delete process.env[name];
  Object.assign(process.env, spec.ambient);
  globalThis.__piCloudConfigurations = [];
  const provider = spec.providerID ?? ({ "google-vertex": "google-vertex", "bedrock-converse-stream": "amazon-bedrock", "anthropic-messages": "anthropic" })[spec.api];
  const base = spec.baseURL ?? ({ "google-vertex": "https://{location}-aiplatform.googleapis.com/v1/projects/{project}/locations/{location}",
    "bedrock-converse-stream": "https://bedrock-runtime.us-east-1.amazonaws.com", "anthropic-messages": "https://api.anthropic.com" })[spec.api];
  const result = await implementations[spec.api].stream({
    id: spec.modelID ?? "fixture-model", name: "Fixture", api: spec.api, provider,
    baseUrl: base, reasoning: false, input: ["text"], contextWindow: 32768, maxTokens: 4096,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  }, normalizeContext({ messages: [{ role: "user", content: "synthetic question", timestamp: 0 }] }), {
    ...spec.options, cacheRetention: "none", onPayload: () => { throw new Error("fixture capture complete"); },
  }).result();
  const config = globalThis.__piCloudConfigurations.at(-1);
  if (!config) throw new Error(`${spec.id}: no Source configuration: ${result.errorMessage}`);
  const fields = spec.api === "google-vertex" ? ["vertexai", "project", "location", "apiKey", "apiVersion", "googleAuthOptions", "httpOptions"]
    : spec.api === "bedrock-converse-stream" ? ["endpoint", "region", "profile", "credentials", "token", "authSchemePreference"]
    : ["apiKey", "authToken", "config"];
  cases.push({ id: spec.id, configuration: Object.fromEntries(fields.filter(name => config[name] !== undefined).map(name => [name, config[name]])) });
}
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
