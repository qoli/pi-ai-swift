import { appendFileSync } from "node:fs";
import path from "node:path";
import { afterEach, expect } from "vitest";
import { getCurrentTest } from "@vitest/runner";
import { AsyncLocalStorage } from "node:async_hooks";
import { observeValue } from "./value-observer.mjs";

const invocation = new AsyncLocalStorage();
const parserCalls = new Map();

export function traceParser(operation, run) {
  if (invocation.getStore()) return run();
  parserCalls.set(operation, (parserCalls.get(operation) ?? 0) + 1);
  return invocation.run({ operation }, run);
}

afterEach(() => {
  for (const [operation] of parserCalls) trace(operation, undefined, () => {});
  parserCalls.clear();
});

export function trace(operation, protocol, run) {
  const parent = invocation.getStore();
  if (parent?.operation && !(operation === "stream" && protocol && protocol !== parent.protocol)) return run();
  const ownership = parent?.ownership === "caller" && ["identity.merge", "identity.session-headers"].includes(operation)
    ? "caller" : "provider";
  return invocation.run({ operation, protocol }, () => {
    const state = expect.getState();
    appendFileSync(path.join(process.env.PI_CONFORMANCE_OUTPUT, "upstream-invocations.jsonl"), JSON.stringify({
      file: state.testPath, test: state.currentTestName, caseInstanceID: getCurrentTest()?.id,
      operation, protocol, ownership,
    }) + "\n");
    const value = run();
    return operation === "catalog" && Array.isArray(value) && !getCurrentTest()
      ? observeSourceCatalogValue(value, operation) : value;
  });
}

export function observeSourceCatalogValue(value, operation) {
  return observeValue(value, () => trace(operation, undefined, () => {}));
}

export function traceCallerModels(models) {
  return new Proxy(models, { get(target, name) {
    const value = Reflect.get(target, name);
    if (typeof value !== "function") return value;
    return (...args) => invocation.run({ ownership: "caller" }, () => value.apply(target, args));
  } });
}

export function tracePrimaryAuthorization(source) {
  return { ...source,
    resolve: (...args) => trace("authorization.primary.resolve", undefined, () => source.resolve(...args)),
    login: (...args) => trace("authorization.primary.login", undefined, () => source.login(...args)),
  };
}

export function authorization(provider, source) {
  return traceOAuthMetadata(provider, {
    ...source,
    login: (...args) => trace(`authorization.${provider}.login`, undefined, () => source.login(...args)),
    refresh: (...args) => trace(`authorization.${provider}.refresh`, undefined, () => source.refresh(...args)),
    toAuth: (...args) => trace(`authorization.${provider}.toAuth`, undefined, () => source.toAuth(...args)),
  });
}

function traceOAuthMetadata(provider, source) {
  if (provider === "radius") return source;
  const result = { ...source };
  for (const field of ["name", "isSubscription", "loginLabel"]) {
    Object.defineProperty(result, field, { enumerable: true, configurable: true,
      get: () => trace(`authorization.${provider}.metadata`, undefined, () => source[field]),
    });
  }
  return result;
}

export function traceBuiltinProvider(provider, args, factory) {
  const wrapped = { ...provider };
  if (provider.auth?.apiKey) wrapped.auth = { ...provider.auth, apiKey: tracePrimaryAuthorization(provider.auth.apiKey) };
  if (provider.auth?.oauth) wrapped.auth = { ...(wrapped.auth ?? provider.auth),
    oauth: traceOAuthMetadata(provider.id, provider.auth.oauth) };
  if (factory === "radiusProvider") {
    wrapped.getModels = (...values) => trace("catalog.radius", undefined, () => provider.getModels(...values));
    wrapped.refreshModels = (...values) => trace("catalog.radius.refresh", undefined, () => provider.refreshModels(...values));
  }
  if (!args.length && provider.id !== "radius") {
    for (const [name, operation] of [["getModels", "catalog"], ["getAllModels", "catalog.all-models"]]) {
      if (provider[name]) wrapped[name] = (...values) => trace(operation, undefined, () => provider[name](...values));
    }
  }
  for (const name of ["filterModels", "filterAllModels"]) {
    if (provider[name]) wrapped[name] = (...values) => trace("provider." + name, undefined, () => provider[name](...values));
  }
  return wrapped;
}
