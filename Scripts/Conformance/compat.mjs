export * from "pi-conformance:upstream-compat";
export { getModel, getModels, getProviders } from "./bridge.mjs";

import { stream as swiftStream, streamSimple as swiftStreamSimple } from "./bridge.mjs";
import { normalizeContext } from "pi-conformance:upstream-compat";

export function stream(model, context, options) {
  return swiftStream(model, normalizeContext(context), options, "provider");
}

export function streamSimple(model, context, options) {
  return swiftStreamSimple(model, normalizeContext(context), options, "provider");
}

export function complete(model, context, options) {
  return stream(model, context, options).result();
}

export function completeSimple(model, context, options) {
  return streamSimple(model, context, options).result();
}
