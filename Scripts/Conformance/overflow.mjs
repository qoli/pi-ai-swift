export * from "pi-conformance:upstream-overflow";
import { invokeNative, recordNative } from "./bridge.mjs";

export function isContextOverflow(message, contextWindow) {
  const result = invokeNative({ operation: "failure.context-overflow", message, contextWindow });
  recordNative("failure.context-overflow", "*");
  return result;
}
