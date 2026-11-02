import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import "./pi-ai-source-runtime.mjs";
const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Auth resolution revision mismatch");
const load = relative => import(pathToFileURL(path.join(root, "packages/ai/src", relative)));
const { resolveProviderAuth, refreshStoredOAuthCredential } = await load("auth/resolve.ts");
const { envApiKeyAuth } = await load("auth/helpers.ts");
const { InMemoryCredentialStore } = await load("auth/credential-store.ts");
const originalNow = Date.now;
const cases = [];
try {
  for (const spec of fixture.cases) {
    Date.now = () => spec.now;
    const memory = new InMemoryCredentialStore(), calls = [];
    if (spec.credential) await memory.modify("fixture", async () => spec.credential);
    const store = {
      read: async (...args) => { calls.push("read"); if (spec.readError) throw new Error(spec.readError); return memory.read(...args); },
      modify: async (...args) => { calls.push("modify"); if (spec.modifyError) throw new Error(spec.modifyError); return memory.modify(...args); },
      delete: (...args) => memory.delete(...args), list: (...args) => memory.list(...args),
    };
    const standard = envApiKeyAuth("Fixture API key", ["FIXTURE_API_KEY"]);
    const provider = { id: "fixture", auth: {
      ...(spec.primary ? { apiKey: { ...standard, resolve: async options => {
        calls.push({ primary: options.credential ?? null });
        if (spec.primaryError) throw new Error(spec.primaryError);
        return standard.resolve(options);
      } } } : {}),
      ...(spec.oauth ? { oauth: { name: "Fixture OAuth", login: async () => { throw new Error("unused"); },
        refresh: async current => {
          calls.push({ refresh: current.access });
          if (spec.refreshError) throw new Error(spec.refreshError);
          return { ...current, access: "fresh-access", refresh: "fresh-refresh", expires: spec.refreshedExpires ?? spec.now + 3_600_000 };
        }, toAuth: async current => {
          calls.push({ derive: current.access });
          if (spec.derivationError) throw new Error(spec.derivationError);
          return { apiKey: current.access };
        },
      } } : {}),
    } };
    const controller = new AbortController();
    if (spec.aborted) controller.abort();
    let result;
    try {
      result = spec.rawRefresh ? await refreshStoredOAuthCredential(store, "fixture", provider.auth.oauth, current => {
        calls.push({ needsRefresh: current.access });
        if (spec.needsRefreshError) throw new Error(spec.needsRefreshError);
        return spec.needsRefresh;
      }, controller.signal) ?? null : await resolveProviderAuth(provider, store, {
        env: async name => { calls.push({ env: name }); return spec.environment[name]; },
        fileExists: async () => false,
      }, { ...spec.overrides, signal: controller.signal }) ?? null;
    } catch (error) {
      result = { error: error.name === "AbortError" ? error.name : error.code ?? error.name,
        ...(error.name !== "AbortError" ? { message: error.message } : {}) };
    }
    cases.push({ id: spec.id, result, calls, stored: await memory.read("fixture") ?? null });
  }
} finally { Date.now = originalNow; }
console.log(JSON.stringify({ upstreamRevision: revision, sourceSHA256: Object.fromEntries(
  ["auth/resolve.ts", "auth/helpers.ts"].map(relative => [relative, createHash("sha256").update(readFileSync(path.join(root, "packages/ai/src", relative))).digest("hex")])) , cases }, null, 2));
