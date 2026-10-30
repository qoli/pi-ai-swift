import { appendFileSync } from "node:fs";
import path from "node:path";
import { expect } from "vitest";

export function trace(operation, protocol) {
  const state = expect.getState();
  appendFileSync(path.join(process.env.PI_CONFORMANCE_OUTPUT, "upstream-invocations.jsonl"), JSON.stringify({
    file: state.testPath, test: state.currentTestName, operation, protocol,
  }) + "\n");
}
