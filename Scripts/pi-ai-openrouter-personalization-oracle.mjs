import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("OpenRouter personalization revision mismatch");
const { personalizeOpenRouterCatalog } = await import(pathToFileURL(path.join(root, "packages/ai/src/providers/openrouter.ts")));
const cases = [];
for (const spec of fixture.cases) {
  const requests = [];
  globalThis.fetch = async (url, options) => {
    requests.push({ url: String(url), headers: Object.fromEntries(new Headers(options.headers)) });
    return Response.json(spec.body, { status: spec.status });
  };
  let result;
  try {
    const catalog = await personalizeOpenRouterCatalog(spec.catalog, {
      credential: spec.credential ?? undefined, baseUrl: spec.baseURL,
      signal: new AbortController().signal, allowNetwork: true, publish: async () => true,
    });
    result = { catalog, personalized: catalog !== spec.catalog,
      retainedIndices: catalog.map(model => spec.catalog.indexOf(model)) };
  } catch (error) { result = { error: error.message }; }
  cases.push({ id: spec.id, requests, ...result });
}
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
