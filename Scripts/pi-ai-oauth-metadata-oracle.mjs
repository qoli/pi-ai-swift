import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("OAuth metadata revision mismatch");
const exports = { anthropic: "anthropicOAuth", "openai-chatgpt": "openaiChatGPTOAuth",
  "openai-codex": "openaiCodexOAuth", "github-copilot": "githubCopilotOAuth",
  "kimi-coding": "kimiCodingOAuth", xai: "xaiOAuth", openrouter: "openRouterOAuth", meta: "metaOAuth" };
const cases = [];
for (const provider of fixture.providers) {
  const source = await import(pathToFileURL(path.join(root, "packages/ai/src/auth/oauth", provider + ".ts")));
  const { name, isSubscription, loginLabel } = source[exports[provider]];
  cases.push({ provider, metadata: { name, isSubscription, loginLabel } });
}
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
