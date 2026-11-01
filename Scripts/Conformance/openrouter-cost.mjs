export * from "pi-conformance:upstream-openrouter-cost";
import { invokeNative, recordNative } from "./bridge.mjs";

export function isOpenRouterModel(model) {
  const result = invokeNative({ operation: "usage.is-openrouter", model });
  recordNative("usage.is-openrouter", "*");
  return result;
}

export function applyOpenRouterReportedCost(usage, reported) {
  const cost = invokeNative({ operation: "usage.openrouter-cost", usage, reported });
  recordNative("usage.openrouter-cost", "*");
  usage.cost = cost;
}
