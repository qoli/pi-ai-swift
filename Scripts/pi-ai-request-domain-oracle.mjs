#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [upstreamRoot, casePath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) {
  throw new Error("usage: pi-ai-request-domain-oracle.mjs UPSTREAM_ROOT CASE_JSON");
}

const fixture = JSON.parse(await readFile(casePath, "utf8"));
if (fixture.schemaVersion !== 1) throw new Error(`unsupported request-domain case schema: ${fixture.schemaVersion}`);
const revision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const models = await import(pathToFileURL(path.join(upstreamRoot, "packages/ai/src/models.ts")).href);
const supportedWithNullMap = models.getSupportedThinkingLevels({
  reasoning: true,
  thinkingLevelMap: { off: null, minimal: null, xhigh: null, max: "max" },
});
if (supportedWithNullMap.join(",") !== "low,medium,high,max") {
  throw new Error(`pinned null reasoning mapping changed: ${supportedWithNullMap.join(",")}`);
}

process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  upstreamRevision: revision,
  caseID: fixture.caseID,
  sourcePath: fixture.sourcePath,
  sourceSymbol: fixture.sourceSymbol,
  sourceSupportedLevels: supportedWithNullMap,
  swiftDisposition: { outcome: "typedFailure", code: "unsupportedCapability" },
}, null, 2)}\n`);
