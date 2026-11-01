import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Primary authorization revision mismatch");
const load = relative => import(pathToFileURL(path.join(root, "packages/ai/src", relative)));
const { envApiKeyAuth } = await load("auth/helpers.ts");
const factories = {};
for (const [id, name] of [["anthropic", "anthropicProvider"], ["amazon-bedrock", "amazonBedrockProvider"],
  ["google-vertex", "googleVertexProvider"], ["cloudflare-ai-gateway", "cloudflareAIGatewayProvider"]]) {
  factories[id] = (await load(`providers/${id}.ts`))[name];
}
const cases = [];
for (const spec of fixture.cases) {
  const auth = spec.provider === "generic" ? envApiKeyAuth(spec.name ?? "Fixture key", spec.variables) : factories[spec.provider]().auth.apiKey;
  const environmentReads = [], fileReads = [], prompts = [], notices = [];
  const controller = new AbortController();
  let result;
  if (spec.action === "login") {
    const responses = [...spec.responses];
    result = await auth.login({ signal: controller.signal,
      prompt: async prompt => { prompts.push(prompt); return responses.shift(); },
      notify: notice => notices.push(notice) });
  } else {
    result = await auth.resolve({ credential: spec.credential, signal: controller.signal, ctx: {
      env: async name => { environmentReads.push(name); return spec.environment[name]; },
      fileExists: async name => { fileReads.push(name); return spec.files.includes(name); },
    } });
  }
  cases.push({ id: spec.id, result: result ?? null, environmentReads, fileReads, prompts, notices });
}
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
