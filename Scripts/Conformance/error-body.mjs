export * from "pi-conformance:upstream-error-body";
import { invokeNative, recordNative } from "./bridge.mjs";
import { afterEach } from "vitest";

const retention = [];
export function takeNativeErrorRetention() { return retention.splice(0); }
afterEach(() => { retention.length = 0; });

function hostValue(value) {
  let serialized;
  try { serialized = JSON.stringify(value); } catch {}
  const object = typeof value === "object" && value !== null;
  const prototype = object ? Object.getPrototypeOf(value) : undefined;
  return {
    text: typeof value === "string" ? value : undefined,
    serialized, stringValue: serialized === undefined ? String(value) : undefined,
    plain: object && (prototype === Object.prototype || prototype === null),
    ownKeys: object ? Object.keys(value).length : undefined,
    readable: object && "pipe" in value && typeof value.pipe === "function",
  };
}

export function normalizeProviderError(error) {
  const result = invokeNative({
    operation: "error.normalize-sdk-object", isError: error instanceof Error,
    message: error?.message, ...hostValue(error),
    statusCandidates: [error?.statusCode, error?.status, error?.$metadata?.httpStatusCode, error?.$response?.statusCode],
    body: hostValue(error?.body), error: hostValue(error?.error), responseBody: hostValue(error?.$response?.body),
  });
  recordNative("error.normalize-sdk-object", "*");
  return result;
}

export function formatProviderError(norm, prefix) {
  const result = invokeNative({ operation: "error.format", ...norm, prefix });
  recordNative("error.format", "*");
  return result;
}

export function truncateErrorText(text, maxChars) {
  const result = invokeNative({ operation: "error.truncate", text, maximumCharacters: maxChars });
  recordNative("error.truncate", "*");
  retention.push(result.retainedBytes);
  return result.value;
}
