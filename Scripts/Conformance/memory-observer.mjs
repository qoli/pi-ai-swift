import { measureNativeAllocatedBytes, recordCapability, takeNativeStreamLifetimes } from "./bridge.mjs";
import { collectGarbage as collectWrapperGarbage } from "pi-conformance:upstream-memory-observer";
import { expect } from "vitest";
import { liveNativeJSONNodes } from "./streaming-json.mjs";
import { takeNativeErrorRetention } from "./error-body.mjs";

export async function collectGarbage() {
  await collectWrapperGarbage();
  if (expect.getState().testPath.endsWith("/streaming-json.test.ts")) {
    expect(liveNativeJSONNodes()).toBe(0);
  } else if (expect.getState().testPath.endsWith("/error-body.test.ts")) {
    for (const retained of takeNativeErrorRetention()) expect(retained).toBeLessThan(1_000_000);
  } else if (expect.getState().testPath.endsWith("/streaming-tool-arguments.test.ts")) {
    if (/['"]?faux['"]? tool-call argument streaming/.test(expect.getState().currentTestName)) {
      expect(liveNativeJSONNodes()).toBe(0);
    } else {
      const lifetimes = takeNativeStreamLifetimes();
      expect(lifetimes.length).toBeGreaterThan(0);
      for (const value of lifetimes) {
        expect(value.observed).toBeGreaterThan(0);
        expect(value.live).toBe(0);
      }
    }
  } else {
    recordCapability("native-weak-reference-lifetime");
  }
}

export function allocatedBytes(operation) {
  return measureNativeAllocatedBytes(operation);
}
