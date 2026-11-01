export * from "pi-conformance:upstream-compat";
export { getModel, getModels, getProviders } from "./bridge.mjs";
export { getSupportedThinkingLevels, clampThinkingLevel } from "./helpers.mjs";

import { stream as swiftStream, streamSimple as swiftStreamSimple } from "./bridge.mjs";
import { normalizeContext } from "pi-conformance:upstream-compat";
import { stream as upstreamStream, streamSimple as upstreamStreamSimple } from "pi-conformance:upstream-compat";

export function stream(model, context, options) {
  if (options?.apiKey !== undefined || ["cloudflare-ai-gateway", "cloudflare-workers-ai"].includes(model.provider)) return upstreamStream(model, context, options);
  return swiftStream(model, normalizeContext(context), options, "provider");
}

export function streamSimple(model, context, options) {
  if (options?.apiKey !== undefined || ["cloudflare-ai-gateway", "cloudflare-workers-ai"].includes(model.provider)) return upstreamStreamSimple(model, context, options);
  return swiftStreamSimple(model, normalizeContext(context), options, "provider");
}

export function complete(model, context, options) {
  return stream(model, context, options).result();
}

export function completeSimple(model, context, options) {
  return streamSimple(model, context, options).result();
}
