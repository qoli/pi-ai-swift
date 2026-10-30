#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { providerStreams } from "./pi-ai-provider-context.mjs";

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
const { normalizeContext } = await import(pathToFileURL(path.join(
  upstreamRoot, "packages/ai/src/utils/transcript.ts",
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
  { name: "standard-response-fast", api: "openai-responses", provider: "openai", model: "gpt-model", response: "fast" },
  { name: "standard-gpt-5.5-priority", api: "openai-responses", provider: "openai", model: "gpt-5.5", response: "priority" },
  { name: "azure-response-priority-unadjusted", api: "azure-openai-responses", provider: "azure-openai-responses", model: "gpt-model", response: "priority" },
  { name: "codex-default-resolves-request-flex", api: "openai-codex-responses", provider: "openai-codex", model: "gpt-model", request: "flex", response: "default" },
  { name: "codex-response-priority", api: "openai-codex-responses", provider: "openai-codex", model: "gpt-model", request: "flex", response: "priority" },
]) {
  responseServiceTierCosts[testCase.name] = projectResponses(
    await runResponsesFlavor(testCase, fixture.responsesServiceTierUsage),
  );
}
const providerErrors = {};
for (const spec of fixture.responsesProviderErrorCases) providerErrors[spec.id] = await runProviderError(spec);
const codexFailureBranches = {};
for (const name of ["failedError", "failedDetails", "streamError"]) {
  const body = fixture.responsesFailureEvents[name].map(event => `data: ${JSON.stringify(event)}\n\n`).join("");
  codexFailureBranches[name] = { body, ...await runProviderError({
    id: name, api: "openai-codex-responses", provider: "openai-codex", status: 200, body,
  }) };
}
const responseFailures = {};
for (const [name, events] of Object.entries(fixture.responsesFailureEvents)) {
  responseFailures[name] = await runResponsesOutcome(events);
}
const toolSlots = {};
for (const [name, events] of Object.entries(fixture.responseToolSlotEvents)) {
  toolSlots[name] = await runToolSlots(events);
}
const blockLifecycle = {};
for (const [name, events] of Object.entries(fixture.responsesBlockLifecycleEvents)) {
  const model = modelFor("openai-responses", "openai", "gpt-model");
  const output = outputFor(model);
  const stream = new eventStreamModule.AssistantMessageEventStream();
  const observed = [];
  const push = stream.push.bind(stream);
  stream.push = event => {
    if (/^(text|thinking)_(start|delta|end)$/.test(event.type)) {
      const block = event.partial.content[event.contentIndex];
      const signature = block.textSignature ?? block.thinkingSignature;
      observed.push({ type: event.type, contentIndex: event.contentIndex,
        text: block.text ?? block.thinking, stopReason: event.partial.stopReason,
        ...(event.delta !== undefined ? { delta: event.delta } : {}),
        ...(signature !== undefined ? { signature: JSON.parse(signature) } : {}),
      });
    }
    return push(event);
  };
  await shared.processResponsesStream(iterate(events), output, stream, model, {});
  blockLifecycle[name] = { events: observed, stopReason: output.stopReason,
    content: output.content.map(block => ({
      type: block.type, text: block.text ?? block.thinking,
      ...((block.textSignature ?? block.thinkingSignature) !== undefined
        ? { signature: JSON.parse(block.textSignature ?? block.thinkingSignature) } : {}),
    })),
  };
}
const grammarReplay = {};
const replay = fixture.responsesGrammarReplay;
for (const [name, spec] of Object.entries(replay.cases)) {
  const model = modelFor(spec.target.api, spec.target.provider, spec.target.id);
  const assistant = {
    ...outputFor(modelFor(replay.source.api, replay.source.provider, replay.source.model)),
    content: [{ type: "toolCall", ...replay.call, arguments: spec.arguments }], stopReason: "toolUse",
  };
  const messages = [assistant, {
    role: "toolResult", toolCallId: replay.call.id, toolName: replay.call.name,
    content: [{ type: "text", text: replay.result }], isError: false, timestamp: 0,
  }];
  try {
    const input = shared.convertResponsesMessages(model, normalizeContext({ messages }),
      new Set(["openai", "openai-codex", "opencode", ...(model.api === "azure-openai-responses" ? ["azure"] : [])]),
      { grammarToolInputProperties: new Map(Object.entries(spec.grammarToolInputProperties)) });
    grammarReplay[name] = { input, thrown: null };
  } catch (error) { grammarReplay[name] = { thrown: error.message }; }
}
const terminalWithoutStart = {};
for (const [name, events] of Object.entries(fixture.responsesTerminalWithoutStartEvents)) {
  terminalWithoutStart[name] = projectResponses(await runResponses(events, {}));
}
const terminalStatuses = {};
for (const [name, events] of Object.entries(fixture.responsesTerminalStatusEvents)) {
  try { terminalStatuses[name] = projectResponses(await runResponses(events, {})); }
  catch (error) { terminalStatuses[name] = { thrown: error.message }; }
}
const completions = await runCompletions(fixture.completionChunks);
const completionReasoningDetails = {};
for (const [name, chunks] of Object.entries(fixture.completionReasoningDetailChunks)) {
  const output = await runCompletions(chunks);
  completionReasoningDetails[name] = {
    sse: chunks.map(chunk => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n",
    content: output.content,
  };
}
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
const completionBlockLifecycle = {};
for (const [name, spec] of Object.entries(fixture.completionBlockLifecycleCases)) {
  completionBlockLifecycle[name] = await runCompletions(spec.chunks, {
    supportsFinishReason: spec.supportsFinishReason, collectBlockEvents: true,
  });
}
const completionObserved = { events: [], models: [] };
completionObserved.output = projectCompletions(await runCompletions(fixture.completionObserverChunks, {
  onProviderStreamEvent: async (event, model) => {
    await Promise.resolve();
    completionObserved.events.push(structuredClone(event));
    completionObserved.models.push({ id: model.id, provider: model.provider, api: model.api });
  },
}));
const completionNonObjectObserved = { events: [], models: [] };
completionNonObjectObserved.output = projectCompletions(await runCompletions(fixture.completionObserverNonObjectChunks, {
  onProviderStreamEvent: async (event, model) => {
    completionNonObjectObserved.events.push(structuredClone(event));
    completionNonObjectObserved.models.push({ id: model.id, provider: model.provider, api: model.api });
  },
}));
const completionTransport = {};
for (const [name, spec] of Object.entries(fixture.completionTransportCases)) {
  completionTransport[name] = await runCompletions([], {
    supportsFinishReason: spec.supportsFinishReason, rawSSE: spec.sse, collectEvents: true,
  });
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
    "responses.provider-errors": providerErrors,
    "responses.codex-failure-branches": codexFailureBranches,
    "responses.tool-slot-lifecycle": toolSlots,
    "responses.block-lifecycle": blockLifecycle,
    "responses.grammar-history-replay": grammarReplay,
    "responses.terminal-without-start": terminalWithoutStart,
    "responses.terminal-status": terminalStatuses,
    "completions.reasoning-details-response-model": projectCompletions(completions),
    "completions.reasoning-detail-signatures": completionReasoningDetails,
    "completions.stop-reason-response-branches": completionBranches,
    "completions.transport-termination": completionTransport,
    "completions.block-lifecycle": completionBlockLifecycle,
    "completions.provider-stream-observer": completionObserved,
    "completions.non-object-provider-events": completionNonObjectObserved,
    "completions.http-raw-metadata": projectCompletions(completionHTTPRawMetadata),
    "completions.abort": projectCompletions(completionAbort),
  },
}, null, 2)}\n`);

async function runProviderError(spec) {
  const implementation = await providerStreams(upstreamRoot,
    await import(pathToFileURL(path.join(upstreamRoot, "packages/ai/src/api", `${spec.api}.ts`))));
  const model = modelFor(spec.api, spec.provider, "gpt-model");
  const codexToken = `${Buffer.from("{}").toString("base64url")}.${Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: "fixture-account" },
  })).toString("base64url")}.signature`;
  const result = await implementation.stream(model, {
    messages: [{ role: "user", content: "hello", timestamp: 0 }],
  }, {
    apiKey: spec.api === "openai-codex-responses" ? codexToken : "fixture",
    maxRetries: 0, transport: "sse",
    ...(spec.api === "azure-openai-responses" ? { azureBaseUrl: "https://fixture.invalid/openai/v1" } : {}),
    fetch: async () => new Response(spec.body, {
      status: spec.status, headers: { "content-type": spec.status === 200 ? "text/event-stream" : "application/json" },
    }),
  }).result();
  if (result.stopReason !== "error") throw new Error(`${spec.id}: source unexpectedly succeeded`);
  return { errorMessage: result.errorMessage, rawStopReason: result.rawStopReason };
}

async function runResponses(events, options) {
  const model = modelFor("openai-responses", "openai", "gpt-model");
  const output = outputFor(model);
  const stream = new eventStreamModule.AssistantMessageEventStream();
  await shared.processResponsesStream(iterate(events), output, stream, model, options);
  return output;
}

async function runResponsesFlavor(testCase, usage) {
  const implementation = await providerStreams(
    upstreamRoot,
    await import(pathToFileURL(path.join(
      upstreamRoot, `packages/ai/src/api/${testCase.api}.ts`,
    )).href),
  );
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

async function runToolSlots(events) {
  const model = modelFor("openai-responses", "openai", "gpt-model");
  const output = outputFor(model);
  const stream = new eventStreamModule.AssistantMessageEventStream();
  const observed = [];
  const push = stream.push.bind(stream);
  stream.push = event => {
    observed.push(structuredClone(event));
    return push(event);
  };
  let thrown = null;
  try { await shared.processResponsesStream(iterate(events), output, stream, model, {}); }
  catch (error) { thrown = error.message; }
  const projected = observed.flatMap(event => {
    const call = event.toolCall ?? event.partial?.content?.[event.contentIndex];
    if (event.type === "toolcall_start") return [{ type: "toolCallStarted", id: call.id, name: call.name }];
    if (event.type === "toolcall_delta") return [{ type: "toolInputDelta", id: call.id, delta: event.delta }];
    if (event.type === "toolcall_end") return [{ type: "toolCallCompleted", id: call.id, name: call.name, arguments: call.arguments,
      ...(call.namespace !== undefined ? { namespace: call.namespace } : {}) }];
    return [];
  });
  return { thrown, events: projected, content: output.content, stopReason: output.stopReason };
}

async function runCompletions(chunks, options = {}) {
  const implementation = await providerStreams(
    upstreamRoot,
    await import(pathToFileURL(path.join(
      upstreamRoot, "packages/ai/src/api/openai-completions.ts",
    )).href),
  );
  const model = modelFor("openai-completions", "fixture", "requested-model");
  model.compat = {
    supportsFinishReason: options.supportsFinishReason ?? true,
    supportsOpenAIGrammarTools: options.supportsOpenAIGrammarTools ?? false,
  };
  const sse = options.rawSSE ?? [...chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`), "data: [DONE]\n\n"].join("");
  const stream = implementation.stream(model, {
    systemPrompt: "system",
    messages: [{ role: "user", content: "hello", timestamp: 0 }],
    tools: options.tools ?? [],
  }, {
    apiKey: "fixture",
    maxRetries: 0,
    onProviderStreamEvent: options.onProviderStreamEvent,
    fetch: async () => new Response(sse, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    }),
  });
  if (options.collectBlockEvents) {
    const events = [];
    const push = stream.push.bind(stream);
    stream.push = event => {
      if (!/^(text|thinking)_(start|delta|end)$/.test(event.type)) return push(event);
      const block = event.partial.content[event.contentIndex];
      const signature = block.textSignature ?? block.thinkingSignature;
      events.push({ type: event.type, contentIndex: event.contentIndex,
        text: block.text ?? block.thinking, stopReason: event.partial.stopReason,
        ...(event.delta !== undefined ? { delta: event.delta } : {}),
        ...(signature !== undefined ? { signature: parsedSignature(signature) } : {}),
      });
      return push(event);
    };
    const output = await stream.result();
    return { events, stopReason: output.stopReason, content: output.content
      .filter(block => block.type === "text" || block.type === "thinking")
      .map(block => ({ type: block.type, text: block.text ?? block.thinking,
        ...((block.textSignature ?? block.thinkingSignature) !== undefined
          ? { signature: parsedSignature(block.textSignature ?? block.thinkingSignature) } : {}),
      })),
    };
  }
  if (options.collectEvents) {
    const eventTypes = [];
    for await (const event of stream) eventTypes.push(event.type);
    return { eventTypes, output: projectCompletions(await stream.result()) };
  }
  return stream.result();
}

async function runCompletionHTTPRawMetadata() {
  const implementation = await providerStreams(
    upstreamRoot,
    await import(pathToFileURL(path.join(
      upstreamRoot, "packages/ai/src/api/openai-completions.ts",
    )).href),
  );
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
  const implementation = await providerStreams(
    upstreamRoot,
    await import(pathToFileURL(path.join(
      upstreamRoot, "packages/ai/src/api/openai-completions.ts",
    )).href),
  );
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

function parsedSignature(signature) {
  try { return JSON.parse(signature); } catch { return signature; }
}
