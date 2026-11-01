import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Reasoning selection revision mismatch");
const { getSupportedThinkingLevels, clampThinkingLevel } = await import(pathToFileURL(path.join(root, "packages/ai/src/models.ts")));
const cases = fixture.cases.map(spec => ({ id: spec.id,
  supported: getSupportedThinkingLevels(spec.model), clamped: clampThinkingLevel(spec.model, spec.requested) }));
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
