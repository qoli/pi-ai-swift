import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(await readFile(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Mistral timeout revision mismatch");
const implementation = await providerStreams(root,
  await import(pathToFileURL(path.join(root, "packages/ai/src/api/mistral-conversations.ts"))));
const model = {
  id: "fixture-model", name: "Fixture", provider: "mistral", api: "mistral-conversations",
  baseUrl: "https://fixture.invalid", input: ["text"], reasoning: false,
  contextWindow: 32768, maxTokens: 4096,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
};
const cases = {};
for (const spec of fixture.cases) {
  let requested = false;
  const output = await implementation.stream(model,
    { messages: [{ role: "user", content: "hello", timestamp: 0 }] }, {
      apiKey: "synthetic-fixture-key", timeoutMs: spec.timeoutMs,
      fetch: async (_url, init) => {
        requested = true;
        if (spec.headerDelayMs) await delay(spec.headerDelayMs, undefined, { signal: init.signal });
        return new Response(new ReadableStream({
          async start(controller) {
            for (const chunk of spec.chunks) {
              if (chunk.delayMs) await delay(chunk.delayMs);
              controller.enqueue(new TextEncoder().encode(chunk.data));
            }
            controller.close();
          },
        }), { headers: { "content-type": "text/event-stream" } });
      },
    }).result();
  cases[spec.id] = {
    requested, stopReason: output.stopReason, errorMessage: output.errorMessage ?? null,
    reasoning: output.content.filter(item => item.type === "thinking").map(item => item.thinking).join(""),
  };
}
process.stdout.write(JSON.stringify({ upstreamRevision: revision, cases }, null, 2) + "\n");
