import { invokeNative, recordNative } from "./bridge.mjs";

export function parseToolCallArguments(text) {
  const result = invokeNative({ operation: "tool.arguments.complete", text });
  recordNative("tool.arguments.complete", "*");
  return result;
}

export function parseStreamingJson() {
  recordNative("tool.arguments.preview", "*", undefined, ["native-partial-tool-arguments-parser"]);
  throw new Error("Native partial tool argument previews are not represented");
}
