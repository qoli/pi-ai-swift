import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("streaming JSON revision mismatch");
const { StreamingJsonParser } = await import(pathToFileURL(path.join(root, "packages/ai/src/utils/streaming-json.ts")));
const cases = fixture.cases.map(({ id, chunks }) => {
  const parser = new StreamingJsonParser();
  const observations = chunks.map(chunk => ({
    changes: structuredClone(parser.append(chunk)),
    snapshot: structuredClone(parser.snapshot()),
  }));
  return { id, observations };
});
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
