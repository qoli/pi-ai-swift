import { createHash, randomUUID } from "node:crypto";
import { getCurrentTest } from "@vitest/runner";
import { invokeNative, recordNative } from "./native-operations.mjs";
import { observeValue } from "./value-observer.mjs";

export function observeNativeCatalogValue(value, operation, protocol) {
  if (getCurrentTest()) return value;
  const origin = { id: randomUUID(), sha256: createHash("sha256").update(JSON.stringify(value)).digest("hex") };
  recordNative(operation, protocol, undefined, [], "value-produced", origin);
  return observeValue(value, () => recordNative(operation, protocol, undefined, [], "value-access", origin));
}

const catalogs = new Map();
export function nativeCatalogObject(provider, operation) {
  if (!catalogs.has(operation)) catalogs.set(operation, invokeNative({ operation }));
  recordNative(operation, provider);
  const models = Object.values(catalogs.get(operation)).filter(model => model.provider === provider);
  return observeNativeCatalogValue(Object.fromEntries(models.map(model => [model.id, model])), operation, provider);
}
