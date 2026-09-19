#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [upstreamRoot, casePath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) throw new Error("usage: openai-response-event-oracle.mjs UPSTREAM CASE");
const fixture = JSON.parse(await readFile(casePath, "utf8"));
const repositoryRoot = path.resolve(path.dirname(casePath), "../../..");
const lock = JSON.parse(await readFile(path.join(repositoryRoot, "Upstream.lock.json"), "utf8"));
const revision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (revision !== lock.revision) throw new Error(`response oracle revision mismatch: ${revision}`);

const shared = await import(pathToFileURL(path.join(
  upstreamRoot, "packages/ai/src/api/openai-responses-shared.ts",
)).href);
const eventStreamModule = await import(pathToFileURL(path.join(
  upstreamRoot, "packages/ai/src/utils/event-stream.ts",
)).href);

const responsesCustom = await runResponses(fixture.responsesCustomEvents, {
  grammarToolInputProperties: new Map([["sample_tool", "payload"]]),
});
const responsesIncomplete = await runResponses(fixture.responsesIncompleteEvents, {});
const responsesReasoning = await runResponses(fixture.responsesReasoningEvents, {});
const responseServiceTierCosts = {};
for (const testCase of [
  { name: "standard-request-flex", api: "openai-responses", provider: "openai", model: "gpt-model", request: "flex" },
  { name: "standard-response-priority", api: "openai-responses", provider: "openai", model: "gpt-model", request: "flex", response: "priority" },
  { name: "standard-gpt-5.5-priority", api: "openai-responses", provider: "openai", model: "gpt-5.5", response: "priority" },
  { name: "azure-response-priority-unadjusted", api: "azure-openai-responses", provider: "azure-openai-responses", model: "gpt-model", response: "priority" },
  { name: "codex-default-resolves-request-flex", api: "openai-codex-responses", provider: "openai-codex", model: "gpt-model", request: "flex", response: "default" },
  { name: "codex-response-priority", api: "openai-codex-responses", provider: "openai-codex", model: "gpt-model", request: "flex", response: "priority" },
]) {
  responseServiceTierCosts[testCase.name] = projectResponses(
    await runResponsesFlavor(testCase, fixture.responsesServiceTierUsage),
  );
}
const responseFailures = {};
for (const [name, events] of Object.entries(fixture.responsesFailureEvents)) {
  responseFailures[name] = await runResponsesOutcome(events);
}
const completions = await runCompletions(fixture.completionChunks);
const completionHTTPRawMetadata = await runCompletionHTTPRawMetadata();
const completionAbort = await runCompletionAbort();
const completionBranches = {};
for (const [name, chunks] of Object.entries(fixture.completionBranchChunks)) {
  completionBranches[name] = projectCompletions(await runCompletions(chunks, {
    supportsFinishReason: name !== "missingFinish",
    supportsOpenAIGrammarTools: name === "customTool",
    tools: name === "customTool" ? [grammarTool()] : [],
  }));
}

process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  upstreamRevision: revision,
  cases: {
    "responses.custom-namespace-usage": projectResponses(responsesCustom),
    "responses.incomplete-raw-total": projectResponses(responsesIncomplete),
    "responses.reasoning-signature-backfill-phase": projectResponsesWithSignatures(responsesReasoning),
    "responses.service-tier-cost-matrix": responseServiceTierCosts,
    "responses.failure-branches": responseFailures,
    "completions.reasoning-details-response-model": projectCompletions(completions),
    "completions.stop-reason-response-branches": completionBranches,
    "completions.http-raw-metadata": projectCompletions(completionHTTPRawMetadata),
    "completions.abort": projectCompletions(completionAbort),
  },
}, null, 2)}\n`);

async function runResponses(events, options) {
  const model = modelFor("openai-responses", "openai", "gpt-model");
  const output = outputFor(model);
  const stream = new eventStreamModule.AssistantMessageEventStream();
  await shared.processResponsesStream(iterate(events), output, stream, model, options);
  return output;
}

async function runResponsesFlavor(testCase, usage) {
  const implementation = await import(pathToFileURL(path.join(
    upstreamRoot, `packages/ai/src/api/${testCase.api}.ts`,
  )).href);
  const model = modelFor(testCase.api, testCase.provider, testCase.model);
  model.cost = { input: 1_000_000, output: 2_000_000, cacheRead: 3_000_000, cacheWrite: 4_000_000 };
  const response = {
    id: `resp-${testCase.name}`,
    status: "completed",
    usage,
    ...(testCase.response ? { service_tier: testCase.response } : {}),
  };
  const sse = [
    `data: ${JSON.stringify({ type: "response.created", response: { id: response.id, model: model.id } })}\n\n`,
    `data: ${JSON.stringify({ type: "response.completed", response })}\n\n`,
    "data: [DONE]\n\n",
  ].join("");
  const codexToken = `${Buffer.from("{}").toString("base64url")}.${Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: "fixture-account" },
  })).toString("base64url")}.signature`;
  const options = {
    apiKey: testCase.api === "openai-codex-responses" ? codexToken : "fixture",
    maxRetries: 0,
    ...(testCase.request ? { serviceTier: testCase.request } : {}),
    ...(testCase.api === "azure-openai-responses" ? { azureBaseUrl: "https://fixture.invalid/openai/v1" } : {}),
    fetch: async () => new Response(sse, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    }),
  };
  const stream = implementation.stream(model, {
    systemPrompt: "system",
    messages: [{ role: "user", content: "hello", timestamp: 0 }],
  }, options);
  return stream.result();
}

async function runResponsesOutcome(events) {
  try {
    const output = await runResponses(events, {});
    return {
      stopReason: output.stopReason,
      rawStopReason: output.rawStopReason,
      errorMessage: output.errorMessage,
    };
  } catch (error) {
    return { thrown: error instanceof Error ? error.message : String(error) };
  }
}

async function runCompletions(chunks, options = {}) {
  const implementation = await import(pathToFileURL(path.join(
    upstreamRoot, "packages/ai/src/api/openai-completions.ts",
  )).href);
  const model = modelFor("openai-completions", "fixture", "requested-model");
  model.compat = {
    supportsFinishReason: options.supportsFinishReason ?? true,
    supportsOpenAIGrammarTools: options.supportsOpenAIGrammarTools ?? false,
  };
  const sse = [...chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`), "data: [DONE]\n\n"].join("");
  const stream = implementation.stream(model, {
    systemPrompt: "system",
    messages: [{ role: "user", content: "hello", timestamp: 0 }],
    tools: options.tools ?? [],
  }, {
    apiKey: "fixture",
    maxRetries: 0,
    fetch: async () => new Response(sse, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    }),
  });
  return stream.result();
}

async function runCompletionHTTPRawMetadata() {
  const implementation = await import(pathToFileURL(path.join(
    upstreamRoot, "packages/ai/src/api/openai-completions.ts",
  )).href);
  const model = modelFor("openai-completions", "openrouter", "requested-model");
  const stream = implementation.stream(model, {
    messages: [{ role: "user", content: "hello", timestamp: 0 }],
  }, {
    apiKey: "fixture",
    maxRetries: 0,
    fetch: async () => new Response(JSON.stringify({
      error: {
        message: "bad request",
        type: "invalid_request_error",
        metadata: { raw: "provider raw detail" },
      },
    }), {
      status: 400,
      headers: { "content-type": "application/json" },
    }),
  });
  return stream.result();
}

async function runCompletionAbort() {
  const implementation = await import(pathToFileURL(path.join(
    upstreamRoot, "packages/ai/src/api/openai-completions.ts",
  )).href);
  const controller = new AbortController();
  controller.abort();
  const model = modelFor("openai-completions", "fixture", "requested-model");
  const stream = implementation.stream(model, {
    messages: [{ role: "user", content: "hello", timestamp: 0 }],
  }, {
    apiKey: "fixture",
    maxRetries: 0,
    signal: controller.signal,
    fetch: async () => new Response("", { status: 200 }),
  });
  return stream.result();
}

function grammarTool() {
  return {
    name: "sample_tool",
    description: "Sample tool",
    parameters: {
      type: "object",
      properties: { payload: { type: "string" } },
      required: ["payload"],
    },
    constrainedSampling: {
      type: "grammar",
      variants: { openai_lark: "start: /[a-z]+/" },
    },
  };
}

function projectResponses(output) {
  return {
    responseId: output.responseId,
    stopReason: output.stopReason,
    rawStopReason: output.rawStopReason,
    errorMessage: output.errorMessage,
    usage: {
      input: output.usage.input,
      output: output.usage.output,
      cacheRead: output.usage.cacheRead,
      cacheWrite: output.usage.cacheWrite,
      reasoning: output.usage.reasoning,
      totalTokens: output.usage.totalTokens,
      cost: output.usage.cost,
    },
    content: output.content,
  };
}

function projectResponsesWithSignatures(output) {
  return {
    ...projectResponses(output),
    content: output.content.map((item) => {
      if (item.type === "thinking") {
        return { ...item, thinkingSignature: JSON.parse(item.thinkingSignature) };
      }
      if (item.type === "text") {
        return { ...item, textSignature: JSON.parse(item.textSignature) };
      }
      return item;
    }),
  };
}

function projectCompletions(output) {
  return {
    responseId: output.responseId,
    responseModel: output.responseModel,
    stopReason: output.stopReason,
    rawStopReason: output.rawStopReason,
    errorMessage: output.errorMessage,
    usage: {
      input: output.usage.input,
      output: output.usage.output,
      cacheRead: output.usage.cacheRead,
      cacheWrite: output.usage.cacheWrite,
      reasoning: output.usage.reasoning,
      totalTokens: output.usage.totalTokens,
    },
    content: output.content.map((item) => {
      if (item.type !== "thinking") return item;
      try {
        return { ...item, thinkingSignature: JSON.parse(item.thinkingSignature) };
      } catch {
        return item;
      }
    }),
  };
}

function modelFor(api, provider, id) {
  return {
    id, name: id, api, provider, baseUrl: "https://fixture.invalid/v1",
    reasoning: true, input: ["text"], contextWindow: 32768, maxTokens: 4096,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  };
}

function outputFor(model) {
  return {
    role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
    usage: {
      input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "pending", timestamp: 0,
  };
}

async function* iterate(values) {
  for (const value of values) yield value;
}
