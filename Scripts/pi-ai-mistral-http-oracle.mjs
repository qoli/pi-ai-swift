import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { providerStreams } from "./pi-ai-provider-context.mjs";

const [root, casePath] = process.argv.slice(2);
const fixture = JSON.parse(await readFile(casePath, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Mistral HTTP revision mismatch");
const implementation = await providerStreams(root,
  await import(pathToFileURL(path.join(root, "packages/ai/src/api/mistral-conversations.ts"))));
const cases = {};
for (const spec of fixture.cases) {
  const model = {
    id: "fixture-model", name: "Fixture", api: "mistral-conversations", provider: "mistral",
    baseUrl: "https://fixture.invalid", reasoning: false, input: ["text"],
    contextWindow: 32768, maxTokens: 4096,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, headers: spec.modelHeaders,
  };
  let headers;
  const output = await implementation.stream(model,
    { messages: [{ role: "user", content: "hello", timestamp: 0 }] }, {
      apiKey: "synthetic-fixture-key", headers: spec.headers, sessionId: spec.sessionId,
      cacheRetention: spec.cacheRetention ?? "short", maxTokens: 64,
      fetch: async (_url, init) => {
        headers = Object.fromEntries(new Headers(init.headers));
        return new Response(spec.body, { status: spec.status });
      },
    }).result();
  if (!headers || output.stopReason !== "error") throw new Error("Mistral HTTP fixture did not execute");
  cases[spec.id] = { headers, errorMessage: output.errorMessage };
}
const observers = {};
for (const spec of fixture.observerCases) {
  const model = {
    id: "fixture-model", name: "Fixture", api: "mistral-conversations", provider: "mistral",
    baseUrl: "https://fixture.invalid", reasoning: false, input: ["text"],
    contextWindow: 32768, maxTokens: 4096, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  };
  const body = spec.body ?? spec.events.map(event => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n" + (spec.trailingSSE ?? "");
  const headers = { "content-type": spec.status >= 400 ? "application/json" : "text/event-stream", "x-fixture-response": spec.id };
  const observed = { stages: [], responses: [], events: [], models: [] };
  const output = await implementation.stream(model, { messages: [{ role: "user", content: "hello", timestamp: 0 }] }, {
    apiKey: "synthetic-fixture-key", maxTokens: 64,
    onPayload: async payload => {
      await Promise.resolve();
      observed.stages.push("payload");
      payload.temperature = 0.25;
    },
    onResponse: async response => {
      await Promise.resolve();
      observed.stages.push("response");
      observed.responses.push(response);
    },
    onProviderStreamEvent: async (event, model) => {
      await Promise.resolve();
      observed.stages.push("event");
      observed.events.push(structuredClone(event));
      observed.models.push({ id: model.id, provider: model.provider, api: model.api });
    },
    fetch: async (_url, init) => {
      const sent = JSON.parse(init.body);
      observed.wireTemperature = sent.temperature;
      observed.wireMaxTokens = sent.max_tokens;
      return new Response(body, { status: spec.status, headers });
    },
  }).result();
  observers[spec.id] = { ...observed, outcome: output.stopReason, errorMessage: output.errorMessage ?? null,
    decoderInput: { status: spec.status, headers, chunksBase64: [Buffer.from(body).toString("base64")] } };
}
process.stdout.write(JSON.stringify({ upstreamRevision: revision, cases, observers }, null, 2) + "\n");
