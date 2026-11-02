import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Context overflow revision mismatch");
const { isContextOverflow } = await import(pathToFileURL(path.join(root, "packages/ai/src/utils/overflow.ts")));
const cases = fixture.cases.map(spec => ({ id: spec.id, overflow: isContextOverflow({
  role: "assistant", content: [], api: "openai-completions", provider: spec.provider, model: "fixture",
  usage: { input: spec.input, cacheRead: spec.cacheRead, cacheWrite: 0, output: spec.output,
    totalTokens: spec.input + spec.cacheRead + spec.output, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  stopReason: spec.finishReason, errorMessage: spec.errorMessage, timestamp: 0,
}, spec.contextWindow ?? undefined) }));
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
