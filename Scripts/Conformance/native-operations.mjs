import { spawnSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import path from "node:path";
import { expect } from "vitest";
import { getCurrentTest } from "@vitest/runner";

export function recordNative(operation, protocol, failure, unrepresentedCapabilities = [], entrypoint = "helper", valueOrigin) {
  const state = expect.getState();
  appendFileSync(path.join(process.env.PI_CONFORMANCE_OUTPUT, "swift-invocations.jsonl"), JSON.stringify({
    file: state.testPath, test: state.currentTestName, caseInstanceID: getCurrentTest()?.id,
    operation, protocol, entrypoint,
    ...(valueOrigin ? { valueOrigin } : {}),
    ...(failure ? { failure } : {}),
    ...(unrepresentedCapabilities.length ? { unrepresentedCapabilities } : {}),
  }) + "\n");
}

export function invokeNative(input) {
  const result = spawnSync(process.env.PI_CONFORMANCE_PROBE, [], {
    input: JSON.stringify(input), encoding: "utf8", maxBuffer: Infinity,
  });
  if (result.status !== 0) throw new Error(`Swift conformance probe failed: ${result.stderr}`);
  return JSON.parse(result.stdout);
}
