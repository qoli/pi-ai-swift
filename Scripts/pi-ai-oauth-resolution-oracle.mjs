import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("OAuth resolution revision mismatch");
const load = relative => import(pathToFileURL(path.join(root, "packages/ai/src", relative)));
const { resolveProviderAuth } = await load("auth/resolve.ts");
const { InMemoryCredentialStore } = await load("auth/credential-store.ts");
const { anthropicOAuth } = await load("auth/oauth/anthropic.ts");
const originalNow = Date.now;
const originalFetch = globalThis.fetch;
const cases = [];
try {
  for (const spec of fixture.cases) {
    Date.now = () => spec.now;
    const store = new InMemoryCredentialStore();
    const credential = { type: "oauth", access: "old-access", refresh: "old-refresh",
      expires: spec.now + spec.expiresOffsetMilliseconds };
    await store.modify("fixture", async () => credential);
    let refreshCount = 0;
    const oauth = { name: "Fixture OAuth", login: async () => { throw new Error("unused"); },
      refresh: async () => {
        refreshCount++;
        return { type: "oauth", access: spec.refreshedAccess, refresh: spec.refreshedRefresh,
          expires: spec.now + spec.refreshedExpiresOffsetMilliseconds };
      },
      toAuth: async value => ({ apiKey: value.access }),
    };
    globalThis.fetch = async () => {
      refreshCount++;
      return new Response(JSON.stringify({ access_token: spec.refreshedAccess,
        refresh_token: spec.refreshedRefresh, expires_in: 3600 }), { status: 200 });
    };
    const result = await resolveProviderAuth({ id: "fixture", auth: {
      oauth: spec.provider === "anthropic" ? anthropicOAuth : oauth,
    } }, store,
      { env: async () => undefined, fileExists: async () => false });
    cases.push({ id: spec.id, result, refreshCount, stored: await store.read("fixture") });
  }
} finally { Date.now = originalNow; globalThis.fetch = originalFetch; }
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
