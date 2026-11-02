import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";
import "./pi-ai-source-runtime.mjs";
const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("OAuth lifecycle revision mismatch");
const load = relative => import(pathToFileURL(path.join(root, "packages/ai/src", relative)));
const { resolveProviderAuth } = await load("auth/resolve.ts");
const { InMemoryCredentialStore } = await load("auth/credential-store.ts");
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const settled = promise => promise.then(value => value?.auth?.apiKey ?? null,
  error => ({ error: error.name === "AbortError" ? error.name : error.code ?? error.name,
    ...(error.cause ? { reason: error.cause.message } : {}) }));
const now = 2_000_000_000_000;
const originalNow = Date.now, originalTimeout = AbortSignal.timeout;
const cases = [];
try {
  Date.now = () => now;
  for (const spec of fixture.cases) {
    const timeouts = [];
    AbortSignal.timeout = ms => { timeouts.push(ms); return originalTimeout(ms); };
    const store = new InMemoryCredentialStore();
    const old = { type: "oauth", access: "old-access", refresh: "old-refresh", expires: now };
    const external = spec.scenario === "replace-kind" ? { type: "api_key", key: "external-key" }
      : { ...old, access: "external-access", expires: now + 3_600_000 };
    await store.modify("fixture", async () => old);
    const started = deferred(), release = deferred();
    let refreshCount = 0, refreshCancelled = false;
    const provider = { id: "fixture", auth: { oauth: { name: "Fixture OAuth",
      login: async () => { throw new Error("unused"); },
      refresh: async (current, signal) => {
        const index = ++refreshCount;
        if (spec.scenario === "refresh-failure") throw new Error("fixture-refresh-denied");
        started.resolve();
        if (["concurrent", "cancel-active", "logout"].includes(spec.scenario)) await release.promise;
        refreshCancelled = signal.aborted;
        return { ...current, access: `fresh-access-${index}`, refresh: `fresh-refresh-${index}`, expires: now + 3_600_000 };
      }, toAuth: async current => ({ apiKey: current.access }),
    } } };
    const controller = new AbortController();
    const resolve = () => settled(resolveProviderAuth(provider, store,
      { env: async () => undefined, fileExists: async () => false }, { signal: controller.signal }));
    let observation = {};
    if (spec.scenario === "refresh-failure") {
      observation.result = await resolve();
    } else if (["cancel-queued", "replace-oauth", "replace-kind"].includes(spec.scenario)) {
      const writeStarted = deferred(), writeRelease = deferred();
      const write = store.modify("fixture", async current => {
        writeStarted.resolve(); await writeRelease.promise;
        return spec.scenario === "cancel-queued" ? current : external;
      });
      await writeStarted.promise;
      const caller = resolve();
      await sleep(spec.observeMilliseconds);
      if (spec.scenario === "cancel-queued") {
        controller.abort();
        observation.beforeRelease = await Promise.race([caller, sleep(spec.observeMilliseconds).then(() => "pending")]);
      }
      writeRelease.resolve(); await write;
      observation.result = await caller;
    } else {
      const first = resolve();
      await started.promise;
      if (spec.scenario === "concurrent") {
        const second = resolve();
        await sleep(spec.observeMilliseconds); release.resolve();
        observation.results = await Promise.all([first, second]);
      } else if (spec.scenario === "cancel-active") {
        controller.abort();
        observation.beforeRelease = await Promise.race([first, sleep(spec.observeMilliseconds).then(() => "pending")]);
        release.resolve(); observation.result = await first;
        await store.modify("fixture", async () => undefined);
      } else {
        const deletion = store.delete("fixture");
        observation.deletedBeforeRelease = await Promise.race([deletion.then(() => true), sleep(spec.observeMilliseconds).then(() => false)]);
        release.resolve(); observation.result = await first; await deletion;
      }
    }
    cases.push({ id: spec.id, ...observation, refreshCount, refreshCancelled,
      timeouts, stored: await store.read("fixture") ?? null });
  }
} finally { Date.now = originalNow; AbortSignal.timeout = originalTimeout; }
const sourceSHA256 = Object.fromEntries(["auth/resolve.ts", "auth/credential-store.ts"].map(relative =>
  [relative, createHash("sha256").update(readFileSync(path.join(root, "packages/ai/src", relative))).digest("hex")]));
console.log(JSON.stringify({ upstreamRevision: revision, sourceSHA256, cases }, null, 2));
