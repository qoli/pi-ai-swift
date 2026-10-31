import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("provider error revision mismatch");
const { normalizeProviderError, formatProviderError } = await import(pathToFileURL(path.join(root, "packages/ai/src/utils/error-body.ts")));
const cases = fixture.cases.map(({ id, isError, message, value, ...fields }) => {
  const normalized = normalizeProviderError(isError ? Object.assign(new Error(message), fields) : value);
  return { id, normalized, formatted: formatProviderError(normalized, "Provider") };
});
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
