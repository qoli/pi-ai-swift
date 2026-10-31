import { nativeCallbackOperation } from "./provider-retry.mjs";
export { abortableSleep } from "pi-conformance:upstream-device-code";

export function pollOAuthDeviceCodeFlow({ poll, signal, ...options }) {
  return nativeCallbackOperation("oauth.device-poll", poll, options, signal);
}
