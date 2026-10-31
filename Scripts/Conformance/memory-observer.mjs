import { measureNativeAllocatedBytes, recordCapability } from "./bridge.mjs";
import { collectGarbage as collectWrapperGarbage } from "pi-conformance:upstream-memory-observer";

export async function collectGarbage() {
  recordCapability("native-weak-reference-lifetime");
  await collectWrapperGarbage();
}

export function allocatedBytes(operation) {
  return measureNativeAllocatedBytes(operation);
}
