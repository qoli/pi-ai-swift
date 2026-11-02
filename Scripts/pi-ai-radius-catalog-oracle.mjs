import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Radius catalog revision mismatch");
const load = relative => import(pathToFileURL(path.join(root, "packages/ai/src", relative)));
const { radiusProvider } = await load("providers/radius.ts");
const { createModels } = await load("models.ts");
const { InMemoryCredentialStore } = await load("auth/credential-store.ts");
const fetch = globalThis.fetch;
const cases = [];
const project = models => models.map(model => ({
  id: model.id, provider: model.provider, api: model.api, name: model.name,
  contextWindow: model.contextWindow,
})).sort((a, b) => a.id.localeCompare(b.id));
try {
  for (const spec of fixture.cases) {
    const provider = radiusProvider(spec.gateway === undefined ? {} : { gateway: spec.gateway });
    const credentials = new InMemoryCredentialStore();
    const requests = [];
    globalThis.fetch = async (input, init) => {
      const request = new Request(input, init); requests.push({ url: request.url, method: request.method });
      if (!spec.config) throw new Error("Unexpected Radius catalog request");
      return new Response(JSON.stringify(spec.config), { headers: { "content-type": "application/json" } });
    };
    const before = project(provider.getModels());
    if (spec.config) {
      await credentials.modify("radius", async () => ({ type: "api_key", key: "fixture-key" }));
      const models = createModels({ credentials }); models.setProvider(provider);
      const refreshed = await models.refresh();
      if (refreshed.errors.size) throw [...refreshed.errors.values()][0];
    }
    cases.push({ id: spec.id, before, after: project(provider.getModels()), requests });
  }
} finally { globalThis.fetch = fetch; }
console.log(JSON.stringify({ upstreamRevision: revision, sourceSHA256: Object.fromEntries(
  ["providers/radius.ts", "providers/radius-config.ts"].map(relative => [relative,
    createHash("sha256").update(readFileSync(path.join(root, "packages/ai/src", relative))).digest("hex")])) , cases }, null, 2));
