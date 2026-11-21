export * from "pi-conformance:upstream-google-shared";
export { resolveGoogleThinkingLevel, convertMessages } from "./bridge.mjs";
export {
  convertTools, requiresToolCallId, resolveGoogleFunctionCallingMode, supportsGoogleStrictToolSampling,
  isThinkingPart, retainThoughtSignature,
} from "./helpers.mjs";

import { invokeNative, recordNative } from "./bridge.mjs";

export function mapStopReason(reason) {
  const result = invokeNative({ operation: "google.stop-reason", reason });
  recordNative("google.stop-reason", "google-generative-ai");
  if (result == null) throw new Error(`Unhandled stop reason: ${reason}`);
  return result;
}
