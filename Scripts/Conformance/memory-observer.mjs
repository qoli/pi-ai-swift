import { measureNativeAllocatedBytes } from "./bridge.mjs";

export function allocatedBytes(operation) {
  return measureNativeAllocatedBytes(operation);
}
