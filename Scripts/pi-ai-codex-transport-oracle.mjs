import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";
import "./pi-ai-source-runtime.mjs";

const [root, input] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(input, "utf8"));
const revision = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== fixture.upstreamRevision) throw new Error("Codex transport revision mismatch");
const { stream, closeOpenAICodexWebSocketSessions } = await import(pathToFileURL(path.join(root, "packages/ai/src/api/openai-codex-responses.ts")));
const { normalizeContext } = await import(pathToFileURL(path.join(root, "packages/ai/src/utils/transcript.ts")));
const { zstdDecompressSync } = await import("node:zlib");
const model = { id: "gpt-5.1-codex", name: "Codex", api: "openai-codex-responses", provider: "openai-codex",
  baseUrl: "https://chatgpt.com/backend-api", reasoning: false, input: ["text"], contextWindow: 400000,
  maxTokens: 128000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const token = "aaa." + Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "fixture" } })).toString("base64") + ".bbb";
const terminal = { type: "response.completed", response: { id: "fixture", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0 } } };
const selected = headers => Object.fromEntries(["originator", "accept", "content-type", "openai-beta"].flatMap(name => {
  const value = new Headers(headers).get(name);
  return value === null ? [] : [[name, value]];
}));
const cases = [];
for (const spec of fixture.cases) {
  const requests = [];
  globalThis.fetch = async (_url, options) => {
    const bytes = typeof options.body === "string" ? options.body : zstdDecompressSync(options.body);
    const body = JSON.parse(Buffer.from(bytes).toString("utf8"));
    requests.push({ transport: "sse", headers: selected(options.headers),
      ...(spec.captureInstructions ? { instructions: body.instructions, input: body.input } : {}) });
    return new Response(`data: ${JSON.stringify(terminal)}\n\n`, { status: 200 });
  };
  globalThis.WebSocket = class extends EventTarget {
    constructor(_url, options) { super(); this.headers = selected(options.headers); queueMicrotask(() => this.dispatchEvent(new Event("open"))); }
    send(text) {
      requests.push({ transport: "websocket", headers: this.headers, type: JSON.parse(text).type });
      queueMicrotask(() => this.dispatchEvent(Object.assign(new Event("message"), { data: JSON.stringify(terminal) })));
    }
    close() {}
  };
  const result = await stream({ ...model, compat: spec.compat }, normalizeContext({ messages: spec.messages ?? [] }), {
    apiKey: token, sessionId: "fixture", transport: spec.transport, headers: spec.headers,
    maxRetries: spec.maxRetries, onPayload: body => { Object.assign(body, spec.payload); },
  }).result();
  cases.push({ id: spec.id, requests, stopReason: result.stopReason, ...(result.errorMessage ? { errorMessage: result.errorMessage } : {}) });
  closeOpenAICodexWebSocketSessions();
}
console.log(JSON.stringify({ upstreamRevision: revision, cases }, null, 2));
