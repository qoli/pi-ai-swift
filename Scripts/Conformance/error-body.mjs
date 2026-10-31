export * from "pi-conformance:upstream-error-body";
import { invokeNative, recordNative } from "./bridge.mjs";

export function formatProviderError(norm, prefix) {
  const result = invokeNative({ operation: "error.format", ...norm, prefix });
  recordNative("error.format", "*");
  return result;
}

export function truncateErrorText(text, maxChars) {
  const result = invokeNative({ operation: "error.truncate", text, maximumCharacters: maxChars });
  recordNative("error.truncate", "*");
  return result;
}
