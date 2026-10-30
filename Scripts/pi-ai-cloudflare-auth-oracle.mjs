#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";
const [root, casePath] = process.argv.slice(2);
const fixture = JSON.parse(await readFile(casePath, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Cloudflare auth revision mismatch");
const source = await import(pathToFileURL(path.join(root, "packages/ai/src/providers/cloudflare-auth.ts")));
const auth = id => id === "cloudflare-ai-gateway" ? source.cloudflareAIGatewayAuth() : source.cloudflareWorkersAIAuth();
const logins = {};
for (const spec of fixture.logins) {
  const prompts = [];
  let credential;
  let cancelled = false;
  try {
    credential = await auth(spec.providerID).login({
      signal: new AbortController().signal,
      async prompt(prompt) {
        const index = prompts.length;
        prompts.push(prompt);
        if (index === spec.stopAt) throw new Error("fixture cancellation");
        return spec.answers[index];
      },
    });
  } catch (error) {
    if (error.message !== "fixture cancellation") throw error;
    cancelled = true;
  }
  logins[spec.id] = { prompts, credential: credential ?? null, cancelled };
}
const resolutions = {};
for (const spec of fixture.resolutions) {
  resolutions[spec.id] = await auth(spec.providerID).resolve({
    ctx: { env: async () => undefined }, credential: spec.credential,
    signal: new AbortController().signal,
  }) ?? null;
}
process.stdout.write(JSON.stringify({ schemaVersion: 1, upstreamRevision: revision, logins, resolutions }, null, 2) + "\n");
