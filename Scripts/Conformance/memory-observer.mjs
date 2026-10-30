import { allocatedBytes as observeJavaScriptHeap } from "pi-conformance:upstream-memory-observer";
import { recordCapability } from "./bridge.mjs";

export function allocatedBytes(operation) {
  recordCapability("swift-process-heap-observer");
  return observeJavaScriptHeap(operation);
}
