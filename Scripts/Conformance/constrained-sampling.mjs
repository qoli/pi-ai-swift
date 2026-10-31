export * from "pi-conformance:upstream-constrained-sampling";
import { invokeNative, recordNative } from "./bridge.mjs";

function native(input) {
  const result = invokeNative(input);
  recordNative(input.operation, "*", result?.failure);
  if (result?.failure) throw new Error(result.failure.message);
  return result;
}

export function makeStrictJsonSchema(parameters) {
  return native({ operation: "sampling.strict", tool: {
    name: "fixture", parameters, constrainedSampling: { type: "json_schema", strict: "require" },
  } });
}

export function resolveJsonSchemaStrictSampling(tool, supportsStrictMode) {
  return native({ operation: "sampling.strict", tool, supportsStrictMode }) ?? undefined;
}

const buffers = new WeakMap();
function bufferOperation(buffer, property, kind, value) {
  const actions = [...(buffers.get(buffer) ?? []), { kind, value }];
  const result = native({ operation: "sampling.grammar-buffer", property, actions });
  buffers.set(buffer, actions);
  return result ?? undefined;
}
export function appendGrammarToolInputJsonDelta(buffer, property, value) {
  return bufferOperation(buffer, property, "append", value);
}
export function closeGrammarToolInputJson(buffer, property, value) {
  return bufferOperation(buffer, property, "close", value);
}
