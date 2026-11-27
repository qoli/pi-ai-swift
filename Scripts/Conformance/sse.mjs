import { invokeNative, recordNative } from "./native-operations.mjs";

export class SseDecoder {
  state;
  push(bytes) { return this.invoke({ chunk: Buffer.from(bytes).toString("base64") }); }
  end() { return this.invoke({ finish: true }); }
  invoke(input) {
    const value = invokeNative({ operation: "sse", ...input, state: this.state });
    recordNative("sse", "*");
    this.state = value.state;
    return value.events;
  }
}
