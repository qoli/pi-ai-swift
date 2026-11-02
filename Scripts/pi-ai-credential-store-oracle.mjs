import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { execFileSync } from "node:child_process";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Credential store revision mismatch");
const source = path.join(root, "packages/ai/src/auth/credential-store.ts");
const { InMemoryCredentialStore } = await import(pathToFileURL(source));
const key = value => ({ type: "api_key", key: value });
const deferred = () => {
  let resolve;
  const promise = new Promise(complete => { resolve = complete; });
  return { promise, resolve };
};
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const cases = [];
for (const spec of fixture.cases) {
  const store = new InMemoryCredentialStore();
  let observation = {};
  if (["serial-modify", "independent-providers"].includes(spec.scenario)) {
    const independent = spec.scenario === "independent-providers";
    await store.modify("fixture", async () => key("0"));
    if (independent) await store.modify("other", async () => key("0"));
    const reads = [], started = deferred();
    let active = 0, maximumActive = 0;
    const increment = async current => {
      reads.push(current.key);
      maximumActive = Math.max(maximumActive, ++active);
      started.resolve();
      await sleep(spec.holdMilliseconds);
      active--;
      return key(String(Number(current.key) + 1));
    };
    const first = store.modify("fixture", increment);
    await started.promise;
    const second = store.modify(independent ? "other" : "fixture", increment);
    const results = await Promise.all([first, second]);
    observation = { reads, maximumActive, results };
  } else if (spec.scenario === "delete-after-modify") {
    const started = deferred();
    const first = store.modify("fixture", async () => {
      started.resolve(); await sleep(spec.holdMilliseconds); return key("rotated");
    });
    await started.promise;
    await store.delete("fixture");
    await first;
  } else if (["cancel-queued-modify", "cancel-active-modify", "read-during-modify"].includes(spec.scenario)) {
    await store.modify("fixture", async () => key("old"));
    const started = deferred(), gate = deferred(), settled = deferred();
    const controller = new AbortController();
    const first = store.modify("fixture", async () => {
      started.resolve(); await gate.promise; settled.resolve(); return key("new");
    }, spec.scenario === "cancel-active-modify" ? { signal: controller.signal } : undefined);
    await started.promise;
    if (spec.scenario === "read-during-modify") {
      observation = { during: await store.read("fixture") };
    } else {
      let queuedRan = false;
      const cancelled = spec.scenario === "cancel-active-modify" ? first
        : store.modify("fixture", async () => { queuedRan = true; return key("queued"); }, { signal: controller.signal });
      controller.abort();
      observation.error = await Promise.race([
        cancelled.then(() => null, error => error.name),
        sleep(spec.observeMilliseconds).then(() => "pending"),
      ]);
      if (spec.scenario === "cancel-queued-modify") observation.queuedRan = queuedRan;
    }
    gate.resolve();
    await Promise.allSettled([first, settled.promise]);
    await new Promise(setImmediate);
  } else if (spec.scenario === "noop-stored" || spec.scenario === "noop-missing") {
    if (spec.scenario === "noop-stored") await store.modify("fixture", async () => key("old"));
    observation.result = await store.modify("fixture", async () => undefined) ?? null;
  } else if (spec.scenario === "rejected-modify") {
    await store.modify("fixture", async () => key("old"));
    try { await store.modify("fixture", async () => { throw new Error("fixture-rejection"); }); }
    catch (error) { observation.error = error.message; }
    observation.next = await store.modify("fixture", async () => key("next"));
  } else if (spec.scenario === "list-insertion-order") {
    await store.modify("z-provider", async () => key("private-fixture-z"));
    await store.modify("a-provider", async () => ({ type: "oauth", access: "fixture", refresh: "fixture", expires: 0 }));
    observation.initial = await store.list();
    await store.modify("z-provider", async () => key("replacement"));
    observation.replaced = await store.list();
    await store.delete("z-provider");
    await store.modify("z-provider", async () => key("reinserted"));
    observation.reinserted = await store.list();
  } else if (spec.scenario === "empty-key") {
    observation.result = await store.modify("fixture", async () => key(""));
  } else throw new Error("Unknown credential store fixture: " + spec.scenario);
  cases.push({ id: spec.id, ...observation, stored: await store.read("fixture") ?? null });
}
console.log(JSON.stringify({ upstreamRevision: revision,
  sourceSHA256: createHash("sha256").update(readFileSync(source)).digest("hex"), cases }, null, 2));
