#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [upstreamRoot, casePath] = process.argv.slice(2);
if (!upstreamRoot || !casePath) {
  throw new Error("usage: openai-request-branch-oracle.mjs UPSTREAM_ROOT CASE_JSON");
}

const fixture = JSON.parse(await readFile(casePath, "utf8"));
if (fixture.schemaVersion !== 1 || !Array.isArray(fixture.cases)) {
  throw new Error("unsupported OpenAI request branch fixture");
}
const repositoryRoot = path.resolve(path.dirname(casePath), "../../..");
const lock = JSON.parse(await readFile(path.join(repositoryRoot, "Upstream.lock.json"), "utf8"));
const revision = execFileSync("git", ["-C", upstreamRoot, "rev-parse", "HEAD"], {
  encoding: "utf8",
}).trim();
if (revision !== lock.revision) {
  throw new Error(`OpenAI request oracle revision mismatch: expected ${lock.revision}, found ${revision}`);
}

const results = {};
for (const testCase of [...fixture.cases, ...expandMatrices(fixture.matrices)]) {
  results[testCase.id] = await capture(testCase);
}

function expandMatrices(matrices = {}) {
  const result = [];
  const protocols = [
    ["openai-completions", "fixture", "https://fixture.invalid/v1"],
    ["openai-responses", "openai", "https://api.openai.com/v1"],
    ["azure-openai-responses", "azure-openai-responses", "https://fixture.openai.azure.com/openai/v1"],
    ["openai-codex-responses", "openai-codex", "https://chatgpt.com/backend-api/codex"],
  ];
  for (const [protocolID, providerID, baseURL] of protocols) {
    for (const grammar of matrices.grammarValid ?? []) {
      if (grammar.protocols && !grammar.protocols.includes(protocolID)) continue;
      result.push({
        id: `${protocolID}.grammar-${grammar.id}`, protocolID, providerID, baseURL,
        modelID: "matrix-model", reasoning: protocolID === "openai-codex-responses",
        compat: { supportsOpenAIGrammarTools: true },
        toolConstraint: { type: "grammar", variants: grammar.variants },
        options: {}, projectFields: ["tools"],
      });
    }
    for (const variant of matrices.grammarFailures ?? []) {
      result.push({
        id: `${protocolID}.grammar-failure-${variant}`, protocolID, providerID, baseURL,
        modelID: "matrix-model", reasoning: protocolID === "openai-codex-responses",
        compat: { supportsOpenAIGrammarTools: true }, grammarSchemaVariant: variant,
        toolConstraint: {
          type: "grammar",
          variants: variant === "empty-variants" ? {} : variant === "empty-values"
            ? { openai_lark: "  ", openai_regex: "" }
            : { openai_lark: "start: /[a-z]+/" },
        },
        options: {},
      });
    }
    if ((matrices.requiredToolChoiceProtocols ?? []).includes(protocolID)) {
      result.push({
        id: `${protocolID}.tool-choice-required`, protocolID, providerID, baseURL,
        modelID: "matrix-model", reasoning: protocolID === "openai-codex-responses",
        options: { toolChoice: "required" }, projectFields: ["tool_choice"],
      });
    }
    for (const replayVariant of matrices.replayVariants ?? []) {
      if (protocolID === "openai-completions") continue;
      result.push({
        id: `${protocolID}.replay-${replayVariant}`, protocolID, providerID, baseURL,
        modelID: "matrix-model", reasoning: protocolID === "openai-codex-responses",
        replayVariant,
        compat: replayVariant === "custom-output" ? { supportsOpenAIGrammarTools: true } : undefined,
        toolConstraint: replayVariant === "custom-output"
          ? { type: "grammar", variants: { openai_lark: "start: /[a-z]+/" } } : undefined,
        options: {}, projectFields: ["input"],
      });
    }
  }
  for (const entry of matrices.reasoningFormats ?? []) {
    for (const state of ["enabled", "off", "mapped-null"]) {
      const thinkingLevelMap = state === "mapped-null"
        ? { low: "source-low", off: null }
        : { low: "source-low" };
      result.push({
        id: `completions.reasoning-${entry.format}-${state}`,
        protocolID: "openai-completions", providerID: entry.providerID ?? "fixture",
        modelID: "reasoning-model", baseURL: "https://fixture.invalid/v1", reasoning: true,
        thinkingLevelMap,
        compat: {
          thinkingFormat: entry.format, supportsReasoningEffort: true,
          ...(entry.compat ?? {}),
        },
        options: state === "enabled" ? { reasoningEffort: "low", maxTokens: 4096 } : {},
        projectFields: [
          "reasoning", "reasoning_effort", "thinking", "enable_thinking",
          "chat_template_kwargs", "chat_template_args",
        ],
      });
    }
  }
  for (const field of matrices.budgetFields ?? []) {
    result.push({
      id: `completions.budget-${field}`, protocolID: "openai-completions", providerID: "fixture",
      modelID: "reasoning-model", baseURL: "https://fixture.invalid/v1", reasoning: true,
      compat: { supportsReasoningEffort: true, thinkingTokenBudgetField: field },
      options: { reasoningEffort: "high", maxTokens: 2048, thinkingBudgets: { high: 9999 } },
      projectFields: ["max_completion_tokens", "reasoning_effort", field],
    });
  }
  for (const entry of matrices.additionalCases ?? []) result.push(entry);
  return result;
}
process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  upstreamRevision: revision,
  cases: results,
}, null, 2)}\n`);

async function capture(testCase) {
  const modulePath = path.join(
    upstreamRoot,
    "packages/ai/src/api",
    `${testCase.protocolID}.ts`,
  );
  const implementation = await import(pathToFileURL(modulePath).href);
  let payload;
  const schema = grammarSchema(testCase.grammarSchemaVariant, testCase);
  const tool = {
    name: "sample_tool",
    description: "Sample tool",
    parameters: schema,
    ...(testCase.toolConstraint
      ? { constrainedSampling: testCase.toolConstraint }
      : {}),
  };
  const model = {
    id: testCase.modelID,
    name: testCase.modelID,
    api: testCase.protocolID,
    provider: testCase.providerID,
    baseUrl: testCase.baseURL,
    reasoning: testCase.reasoning,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 32768,
    maxTokens: 4096,
    ...(testCase.thinkingLevelMap ? { thinkingLevelMap: testCase.thinkingLevelMap } : {}),
    ...(testCase.compat ? { compat: testCase.compat } : {}),
  };
  const deferredTool = {
    name: "lookup",
    description: "Deferred lookup",
    parameters: {
      type: "object",
      properties: { query: { type: "string" } },
      required: ["query"],
    },
  };
  const toolCallID = testCase.protocolID.includes("responses")
    ? "call_loader|fc_loader"
    : "call-loader";
  const replayUsage = {
    input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
  const context = testCase.transcriptVariant
    ? compatTranscript(testCase, tool, replayUsage)
    : testCase.replayVariant === "text-id-hash"
    ? {
        systemPrompt: testCase.emptySystemPrompt ? "" : "System branch fixture",
        messages: [{
          role: "assistant", api: testCase.protocolID, provider: testCase.providerID,
          model: testCase.modelID,
          content: [{
            type: "text", text: "answer",
            textSignature: JSON.stringify({ v: 1, id: "x".repeat(70), phase: "final_answer" }),
          }],
          usage: replayUsage, stopReason: "stop", timestamp: 1,
        }],
        tools: [tool],
      }
    : testCase.replayVariant === "different-model"
      ? {
          systemPrompt: "System branch fixture",
          messages: [
            {
              role: "assistant", api: testCase.protocolID, provider: testCase.providerID,
              model: "other-model",
              content: [{
                type: "toolCall", id: "call_1|fc_item", name: tool.name,
                arguments: { payload: "abc" }, namespace: "dynamic_tools",
              }],
              usage: replayUsage, stopReason: "toolUse", timestamp: 1,
            },
            {
              role: "toolResult", toolCallId: "call_1|fc_item", toolName: tool.name,
              content: [{ type: "text", text: "done" }], isError: false, timestamp: 2,
            },
          ],
          tools: [tool],
        }
      : testCase.replayVariant === "custom-output"
        ? {
            systemPrompt: "System branch fixture",
            messages: [
              {
                role: "assistant", api: testCase.protocolID, provider: testCase.providerID,
                model: testCase.modelID,
                content: [{
                  type: "toolCall", id: "call_1|ctc_1", name: tool.name,
                  arguments: { payload: "abc" }, namespace: "dynamic_tools",
                }],
                usage: replayUsage, stopReason: "toolUse", timestamp: 1,
              },
              {
                role: "toolResult", toolCallId: "call_1|ctc_1", toolName: tool.name,
                content: [{ type: "text", text: "done" }], isError: false, timestamp: 2,
              },
            ],
            tools: [tool],
          }
        : testCase.deferredTranscript
    ? {
        systemPrompt: testCase.emptySystemPrompt ? "" : "System branch fixture",
        messages: [
          { role: "user", content: "load a tool", timestamp: 0 },
          {
            role: "assistant",
            api: testCase.protocolID,
            provider: testCase.providerID,
            model: testCase.modelID,
            content: [{
              type: "toolCall",
              id: toolCallID,
              name: tool.name,
              arguments: { payload: "lookup" },
            }],
            usage: {
              input: 1, output: 1, cacheRead: 0, cacheWrite: 0,
              totalTokens: 2,
              cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
            },
            stopReason: "toolUse",
            timestamp: 1,
          },
          {
            role: "toolResult",
            toolCallId: toolCallID,
            toolName: tool.name,
            content: [{ type: "text", text: "loaded" }],
            isError: false,
            addedToolNames: [deferredTool.name],
            timestamp: 2,
          },
        ],
        tools: [tool, deferredTool],
      }
    : {
          systemPrompt: testCase.emptySystemPrompt ? "" : "System branch fixture",
        messages: [{ role: "user", content: "hello", timestamp: 0 }],
        tools: [tool],
      };
  const options = {
    apiKey: credential(testCase.protocolID),
    maxRetries: 0,
    ...testCase.options,
    onPayload(value) {
      payload = value;
      throw new CaptureComplete();
    },
    fetch() {
      throw new Error("unexpected network request");
    },
  };
  const stream = implementation.stream(model, context, options);
  const result = await stream.result();
  if (payload !== undefined) return { requestBody: canonicalize(project(testCase, payload)) };
  return { errorMessage: result.errorMessage ?? "unknown error" };
}

function project(testCase, payload) {
  if (Array.isArray(testCase.projectFields)) {
    return Object.fromEntries(testCase.projectFields.map((key) => [key, payload[key]]));
  }
  const caseID = testCase.id;
  switch (caseID) {
    case "completions.compat-flags":
      return {
        max_tokens: payload.max_tokens,
        stream_options: payload.stream_options,
        store: payload.store,
        tool_choice: payload.tool_choice,
        tool: payload.tools?.[0],
      };
    case "completions.grammar":
      return { tool: payload.tools?.[0] };
    case "completions.routing-and-cache":
      return {
        prompt_cache_key: payload.prompt_cache_key,
        prompt_cache_retention: payload.prompt_cache_retention,
        provider: payload.provider,
        reasoning: payload.reasoning,
      };
    case "responses.cache-reasoning-default":
      return {
        prompt_cache_options: payload.prompt_cache_options,
        prompt_cache_key: payload.prompt_cache_key,
        reasoning: payload.reasoning,
      };
    case "azure.configuration":
    case "azure.environment-configuration":
    case "azure.resource-configuration":
      return {
        model: payload.model,
        prompt_cache_key: payload.prompt_cache_key,
        reasoning: payload.reasoning,
        include: payload.include,
        tool: payload.tools?.[0],
      };
    case "codex.defaults-and-cache":
      return {
        instructions: payload.instructions,
        include: payload.include,
        parallel_tool_calls: payload.parallel_tool_calls,
        prompt_cache_key: payload.prompt_cache_key,
        service_tier: payload.service_tier,
        store: payload.store,
        temperature: payload.temperature,
        text: payload.text,
        tool_choice: payload.tool_choice,
        tool: payload.tools?.[0],
      };
    case "responses.deferred-additional-tools":
    case "codex.deferred-additional-tools":
      return {
        topLevelToolNames: payload.tools?.map((tool) => tool.name ?? tool.function?.name),
        added: payload.input?.filter((item) => item.type === "additional_tools"),
      };
    case "responses.deferred-tool-search":
      return {
        topLevelToolNames: payload.tools?.map((tool) => tool.name ?? tool.function?.name),
        calls: payload.input?.filter((item) => item.type === "tool_search_call"),
        outputs: payload.input?.filter((item) => item.type === "tool_search_output"),
      };
    case "completions.deferred-kimi":
      return {
        topLevelToolNames: payload.tools?.map((tool) => tool.function?.name),
        systemTools: payload.messages
          ?.filter((message) => message.role === "system" && Array.isArray(message.tools))
          .map((message) => message.tools),
      };
    case "completions.sampling-last-wins":
      return {
        max_completion_tokens: payload.max_completion_tokens,
        temperature: payload.temperature,
      };
    case "responses.sampling-last-wins":
    case "azure.sampling-last-wins":
      return {
        max_output_tokens: payload.max_output_tokens,
        temperature: payload.temperature,
      };
    case "responses.replay-text-id-hash":
      return {
        items: payload.input?.filter((item) => item.type === "message"),
      };
    case "responses.replay-different-model":
      return {
        items: payload.input?.filter((item) =>
          item.type === "function_call" || item.type === "function_call_output"),
      };
    case "responses.replay-custom-output":
      return {
        items: payload.input?.filter((item) =>
          item.type === "custom_tool_call" || item.type === "custom_tool_call_output"),
      };
    case "completions.custom-reasoning-budget":
    case "completions.named-tool-choice":
    case "responses.named-tool-choice":
    case "azure.named-tool-choice":
      return payload;
    default:
      return payload;
  }
}

function grammarSchema(variant, testCase) {
  if (variant === "non-object") return { type: "string" };
  if (variant === "required-zero") {
    return { type: "object", properties: { payload: { type: "string" } }, required: [] };
  }
  if (variant === "required-two") {
    return {
      type: "object",
      properties: { payload: { type: "string" }, extra: { type: "string" } },
      required: ["payload", "extra"],
    };
  }
  if (variant === "missing-required-property") {
    return { type: "object", properties: { payload: { type: "string" } }, required: ["missing"] };
  }
  if (variant === "non-string") {
    return { type: "object", properties: { payload: { type: "number" } }, required: ["payload"] };
  }
  return {
    type: "object",
    properties: { payload: { type: testCase.grammarInvalidSchema ? "number" : "string" } },
    required: [testCase.invalidRequired ? "missing" : "payload"],
  };
}

function compatTranscript(testCase, tool, usage) {
  const source = {
    role: "assistant", api: testCase.protocolID, provider: testCase.providerID,
    model: testCase.modelID,
    content: [
      { type: "thinking", thinking: "private thought", thinkingSignature: testCase.thinkingSignature ?? "reasoning_content" },
      { type: "text", text: "answer" },
      { type: "toolCall", id: "call_compat", name: tool.name, arguments: { payload: "abc" } },
    ],
    usage, stopReason: "toolUse", timestamp: 1,
  };
  return {
        systemPrompt: testCase.emptySystemPrompt ? "" : "System branch fixture",
    messages: [
      source,
      { role: "toolResult", toolCallId: "call_compat", toolName: tool.name, content: [{ type: "text", text: "done" }], isError: false, timestamp: 2 },
      { role: "user", content: "continue", timestamp: 3 },
    ],
    tools: [tool],
  };
}

function credential(protocolID) {
  if (protocolID !== "openai-codex-responses") return "fixture-key";
  const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url");
  const body = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: "fixture-account" },
  })).toString("base64url");
  return `${header}.${body}.fixture`;
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([, item]) => item !== undefined)
        .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
        .map(([key, item]) => [key, canonicalize(item)]),
    );
  }
  return value;
}

class CaptureComplete extends Error {
  constructor() { super("source oracle request captured"); }
}
