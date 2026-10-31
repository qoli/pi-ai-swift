import { invokeNative, recordNative } from "./bridge.mjs";

export function parseToolCallArguments(text) {
  const result = invokeNative({ operation: "tool.arguments.complete", text });
  recordNative("tool.arguments.complete", "*");
  return result;
}

export { parseStreamingJson } from "./streaming-json.mjs";
