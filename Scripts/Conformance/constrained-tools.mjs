import path from "node:path";
import { pathToFileURL } from "node:url";
const { normalizeContext } = await import(pathToFileURL(path.join(process.env.PI_CONFORMANCE_UPSTREAM, "packages/ai/src/utils/transcript.ts")));
import { projectNativeRequest, recordNative } from "./bridge.mjs";

export function convertResponsesTools(tools, options = {}) {
  const model = { api: "openai-responses", provider: "openai", id: "fixture", name: "fixture",
    baseUrl: "https://fixture.invalid/v1", reasoning: false, input: ["text"],
    contextWindow: 128000, maxTokens: 4096,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    compat: { supportsStrictMode: true, ...options } };
  const result = projectNativeRequest(model, normalizeContext({ messages: [], tools }), { apiKey: "fixture" });
  recordNative("sampling.tools", "openai-responses", result.failure);
  if (!result.request) throw new Error(result.failure?.message ?? "Native tool projection failed");
  return result.request.body.tools ?? [];
}
