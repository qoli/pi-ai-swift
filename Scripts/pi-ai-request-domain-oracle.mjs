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
const source = await readFile(path.join(upstreamRoot, fixture.sourcePath), "utf8");
const context = source.match(/export interface Context\s*\{([\s\S]*?)\n\}/)?.[1];
if (!context || !/(?:^|\n)\s*systemPrompt\?:\s*string;/.test(context)) {
  throw new Error("pinned Context.systemPrompt is no longer an optional string");
}
if (/(?:^|\n)\s*systemPrompt\?:\s*(?:string\[\]|Array<string>);/.test(context)) {
  throw new Error("pinned Context.systemPrompt unexpectedly accepts multiple prompts");
}
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
  sourceContract: { type: "optional-string", maximumSystemPrompts: 1 },
  swiftDisposition: { outcome: "typedFailure", code: "invalidRequest" },
  additionalCases: {
    "reasoning-mapped-null-explicit-failure": {
      sourceSymbol: "getSupportedThinkingLevels",
      sourceSupportedLevels: supportedWithNullMap,
      swiftDisposition: { outcome: "typedFailure", code: "unsupportedCapability" },
    },
  },
}, null, 2)}\n`);
