import { createRequire } from "node:module";
import { afterEach } from "vitest";
import { isObservingNativeHeap, observeNativeAllocatedBytes, recordNative } from "./bridge.mjs";

const native = createRequire(import.meta.url)(process.env.PI_CONFORMANCE_JSON_MODULE);
const calls = new Map();
const handles = new Set();
const count = operation => calls.set(operation, (calls.get(operation) ?? 0) + 1);

function create(tool) {
  const result = native.create(tool, isObservingNativeHeap());
  const handle = result.value;
  observeNativeAllocatedBytes(result.allocatedBytes);
  handles.add(new WeakRef(handle));
  count(tool ? "tool.arguments-stream.create" : "tool.json-parser.create");
  return handle;
}

export function liveNativeJSONNodes() { return native.liveNodes(); }

afterEach(() => {
  for (const [operation] of calls) recordNative(operation, "*");
  calls.clear();
  for (const reference of handles) {
    const handle = reference.deref();
    if (handle) native.dispose(handle);
  }
  handles.clear();
});

function call(operation, method, handle, text) {
  const result = native[method](handle, text, isObservingNativeHeap());
  count(operation);
  observeNativeAllocatedBytes(result.allocatedBytes);
  return result.value;
}

export class StreamingJsonParser {
  #native = create(false);
  append(text) { return call("tool.json-parser.append", "append", this.#native, text); }
  snapshot() { return call("tool.json-parser.snapshot", "snapshot", this.#native); }
}

export class ToolCallArgumentsStream {
  #native = create(true);
  get text() { return call("tool.arguments-stream.text", "text", this.#native) ?? ""; }
  append(text) { return call("tool.arguments-stream.append", "append", this.#native, text); }
  replace(text) {
    const result = call("tool.arguments-stream.replace", "replace", this.#native, text);
    if (!Object.hasOwn(result, "delta")) result.delta = undefined;
    return result;
  }
  finish() { return call("tool.arguments-stream.finish", "finish", this.#native); }
}

export function parseStreamingJson(text) {
  const parser = create(false);
  call("tool.arguments.preview", "append", parser, text ?? "");
  return call("tool.arguments.preview", "snapshot", parser) ?? {};
}
