import { appendFileSync } from "node:fs";
import path from "node:path";
import { expect } from "vitest";
import { AsyncLocalStorage } from "node:async_hooks";

const invocation = new AsyncLocalStorage();

export function trace(operation, protocol, run) {
  const parent = invocation.getStore();
  if (parent && !(operation === "stream" && protocol && protocol !== parent.protocol)) return run();
  return invocation.run({ operation, protocol }, () => {
    const state = expect.getState();
    appendFileSync(path.join(process.env.PI_CONFORMANCE_OUTPUT, "upstream-invocations.jsonl"), JSON.stringify({
      file: state.testPath, test: state.currentTestName, operation, protocol,
    }) + "\n");
    return run();
  });
}

export function authorization(provider, source) {
  return {
    ...source,
    login: (...args) => trace(`authorization.${provider}.login`, undefined, () => source.login(...args)),
    refresh: (...args) => trace(`authorization.${provider}.refresh`, undefined, () => source.refresh(...args)),
    toAuth: (...args) => trace(`authorization.${provider}.toAuth`, undefined, () => source.toAuth(...args)),
  };
}
