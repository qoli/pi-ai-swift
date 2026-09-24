import { readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { providerStreams } from "./pi-ai-provider-context.mjs";
const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(await readFile(input, "utf8"));
const implementation = await providerStreams(root, await import(pathToFileURL(path.join(root, "packages/ai/src/api/openai-completions.ts"))));
const cases = [];
for (const baseURL of fixture.baseURLs) {
  let requestURL;
  const model = { id: "my-model", name: "my-model", provider: "my-provider", api: "openai-completions", baseUrl: baseURL, reasoning: false, input: ["text"], contextWindow: 16384, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  const stream = implementation.streamSimple(model, { messages: [{ role: "user", content: "fixture", timestamp: 0 }] }, {
    apiKey: "fixture-key", maxRetries: 0,
    fetch: async (request) => {
      requestURL = typeof request === "string" ? request : request.url ?? request.toString();
      return new Response('data: {"id":"response","model":"my-model","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n', { headers: { "content-type": "text/event-stream" } });
    }
  });
  const result = await stream.result();
  if (!requestURL || result.stopReason === "error") throw new Error(result.errorMessage ?? "No request");
  cases.push({ baseURL, requestURL });
}
process.stdout.write(JSON.stringify({ revision: fixture.revision, cases }, null, 2) + "\n");
