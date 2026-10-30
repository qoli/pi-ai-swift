import { spawn, spawnSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { expect } from "vitest";
import * as OpenAISDK from "openai";
import Anthropic from "@anthropic-ai/sdk";
import { GoogleGenAI } from "@google/genai";
import { BedrockRuntimeClient, ConverseStreamCommand } from "@aws-sdk/client-bedrock-runtime";
import { EventStreamCodec } from "@smithy/core/event-streams";
import { mistralSDKPayload, mistralWirePayload } from "./mistral-payload.mjs";

const upstream = process.env.PI_CONFORMANCE_UPSTREAM;
const { AssistantMessageEventStream } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/utils/event-stream.ts")));
const { getCurrentSystemPrompt, getCurrentTools } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/utils/transcript.ts")));
const { getEnvApiKey } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/env-api-keys.ts")));
const { getProviderEnvValue } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/utils/provider-env.ts")));
const { clampMaxTokensToContext } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/api/simple-options.ts")));

function record(operation, protocol, failure, unrepresentedCapabilities = [], entrypoint = "helper") {
  const state = expect.getState();
  appendFileSync(path.join(process.env.PI_CONFORMANCE_OUTPUT, "swift-invocations.jsonl"), JSON.stringify({
    file: state.testPath, test: state.currentTestName, operation, protocol, entrypoint,
    ...(failure ? { failure } : {}),
    ...(unrepresentedCapabilities.length ? { unrepresentedCapabilities } : {}),
  }) + "\n");
}

export function recordCapability(capability) {
  record("capability", "*", undefined, [capability]);
}

function invoke(input) {
  const processResult = spawnSync(process.env.PI_CONFORMANCE_PROBE, [], {
    input: JSON.stringify(input), encoding: "utf8", maxBuffer: Infinity,
  });
  if (processResult.status !== 0) throw new Error(`Swift conformance probe failed: ${processResult.stderr}`);
  return JSON.parse(processResult.stdout);
}

function fixtureCredential(model, options) {
  const environment = { ...process.env, ...options.env };
  return {
    key: options.apiKey ?? (model.api === "bedrock-converse-stream" || options.client ? "synthetic-sdk-fixture-key" :
      model.api === "google-vertex" ? undefined : getEnvApiKey(model.provider, options.env)),
    metadata: Object.fromEntries(Object.entries(environment).filter(([key, value]) =>
      /^(AZURE_OPENAI_|CLOUDFLARE_|AWS_|GOOGLE_|GCLOUD_)/.test(key) && typeof value === "string")
      .concat(options.region ? [["region", options.region]] : environment.AWS_REGION ? [["region", environment.AWS_REGION]] : [])),
  };
}

function fixtureInput(model, context, options, responses, credential, requestSource = "api") {
  return {
    model, requestSource,
    context: {
      systemPrompt: getCurrentSystemPrompt(context.messages),
      tools: getCurrentTools(context.messages),
      messages: context.messages.filter(message => message.role !== "system"),
    },
    options: { ...options, cacheRetention: options.cacheRetention ||
      (getProviderEnvValue("PI_CACHE_RETENTION", options.env) === "long" ? "long" : "short") },
    credential,
    environment: Object.fromEntries(Object.entries(process.env).filter(([key]) =>
      key.startsWith("AZURE_OPENAI_") || ["GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION"].includes(key))),
    responses,
    aborted: options.signal?.aborted ?? false,
  };
}

function capabilities(options) {
  return [
    ...(options.onProviderStreamEvent ? ["raw-provider-stream-event-hook"] : []),
    ...(options.onResponse ? ["raw-response-hook"] : []),
    ...(options.timeoutMs !== undefined ? ["request-timeout-option"] : []),
  ];
}

function probe(model, context, options, responses = [], credential = fixtureCredential(model, options)) {
  const result = invoke(fixtureInput(model, context, options, responses, credential));
  record(result.failure?.unrepresentedCapability ? "input" : responses.length ? "decode" : "encode", model.api, result.failure, [
    ...capabilities(options),
    ...(result.failure?.unrepresentedCapability ? [result.failure.unrepresentedCapability] : []),
  ]);
  return result;
}

let catalog;
export function getModel(provider, id) {
  catalog ??= invoke({ operation: "catalog" });
  const model = catalog[`${provider}/${id}`];
  record("catalog", model?.api ?? "*");
  return structuredClone(model);
}

export function getModels(provider) {
  catalog ??= invoke({ operation: "catalog" });
  record("catalog", provider);
  return Object.values(catalog).filter(model => model.provider === provider).map(model => structuredClone(model));
}

export function getProviders() {
  catalog ??= invoke({ operation: "catalog" });
  record("catalog", "*");
  return [...new Set(Object.values(catalog).map(model => model.provider))];
}

export function convertMessages(model, context, compat, options = {}) {
  const result = probe({ ...model, compat: { ...model.compat, ...compat } }, context, { apiKey: "test", ...options });
  if (!result.request) throw new Error(result.failure?.message ?? "Swift did not project messages");
  return result.request.body.messages ?? result.request.body.contents;
}

export function resolveGoogleThinkingLevel(model, level) {
  const result = invoke({
    ...fixtureInput(model, { messages: [] }, { reasoningEffort: level }, [], fixtureCredential(model, { apiKey: "test" })),
    operation: "google-thinking-level",
  });
  record("encode", model.api, result.failure);
  if (typeof result !== "string") throw new Error(result.failure?.message ?? "Swift did not resolve a thinking level");
  return result;
}

export function convertResponsesMessages(model, context, _allowedToolCallProviders, options = {}) {
  const decoded = probe(model, context, { apiKey: "synthetic-decoder-fixture-key", ...options });
  if (!decoded.request) throw new Error(decoded.failure?.message ?? "Swift did not project Responses input");
  return decoded.request.body.input;
}

export async function processResponsesStream(events, partial, output, model, options = {}) {
  const chunks = [];
  for await (const event of events) chunks.push(Buffer.from(`data: ${JSON.stringify(event)}\n\n`).toString("base64"));
  const decoded = probe(model, { messages: [{ role: "user", content: "fixture", timestamp: 0 }] },
    { apiKey: "synthetic-decoder-fixture-key", ...options }, [{ status: 200, headers: {}, chunks }]);
  for (const event of decoded.events) emit(event, partial, output);
  if (decoded.failure) throw new Error(decoded.failure.message ?? decoded.failure.code);
}

export function stream(model, context, options = {}, requestSource = "api") {
  const output = new AssistantMessageEventStream();
  (async () => {
    const partial = {
      role: "assistant", api: model.api, provider: model.provider, model: model.id,
      content: [], stopReason: "pending", timestamp: Date.now(),
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    };
    try {
      await nativeStream(model, context, options, event => emit(event, partial, output), requestSource);
      output.push({ type: "done", reason: partial.stopReason, message: partial });
      output.end(partial);
    } catch (error) {
      partial.stopReason = options.signal?.aborted ? "aborted" : "error";
      partial.errorMessage = error.message;
      output.push({ type: "error", reason: partial.stopReason, error: partial });
      output.end(partial);
    }
  })();
  return output;
}

async function nativeStream(model, context, options, emitEvent, requestSource) {
  const credential = fixtureCredential(model, options);
  const connection = { credential };
  const child = spawn(process.env.PI_CONFORMANCE_PROBE, ["--stream"], { stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", data => { stderr += data; });
  const exited = new Promise((resolve, reject) => { child.once("close", resolve); child.once("error", reject); });
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  let finished = false;
  let failure;
  const send = frame => {
    if (!child.stdin.destroyed && !child.stdin.writableEnded) child.stdin.write(JSON.stringify(frame) + "\n");
  };
  child.stdin.on("error", () => {});
  const cancel = () => send({ kind: "cancel" });
  options.signal?.addEventListener("abort", cancel, { once: true });
  record("encode", model.api, undefined, capabilities(options), "stream");
  send(fixtureInput(model, context, options, [], credential, requestSource));
  const serve = async request => {
    let body = request.body;
    const google = model.api === "google-generative-ai" || model.api === "google-vertex";
    const mistral = model.api === "mistral-conversations";
    const payload = model.api === "bedrock-converse-stream" ? { modelId: bedrockModelID(request.url), ...body } : google ? {
      model: model.id, contents: body.contents,
      config: { ...body.generationConfig,
        ...(body.systemInstruction ? { systemInstruction: body.systemInstruction } : {}),
        ...(body.tools ? { tools: body.tools } : {}), ...(body.toolConfig ? { toolConfig: body.toolConfig } : {}) },
    } : mistral ? mistralSDKPayload(body) : body;
    const replacement = await options.onPayload?.(payload, model);
    if (replacement !== undefined) body = google ? googleWireBody(replacement) : mistral ? mistralWirePayload(replacement) : replacement;
    if (options.signal?.aborted) { cancel(); return; }
    if (options.timeoutMs !== undefined) throw new Error("Swift ProviderRequest has no request-timeout option");
    const response = await mockResponse(model, request, body, options, connection);
    if (finished) return;
    send({ kind: "response", status: response.status, headers: response.headers });
    for await (const data of response.chunks) {
      if (finished) break;
      send({ kind: "chunk", data });
    }
    send({ kind: "end" });
  };
  try {
    for await (const line of lines) {
      const frame = JSON.parse(line);
      if (frame.kind === "request") {
        void serve(frame.payload).catch(error => send({ kind: "failure", message: error.message }));
      } else if (frame.kind === "event") {
        emitEvent(frame.payload);
      } else if (frame.kind === "finished") {
        finished = true;
        failure = frame.payload;
        record("decode", model.api, failure, failure?.unrepresentedCapability ? [failure.unrepresentedCapability] : [], "stream");
        child.stdin.end();
      } else throw new Error(`Unknown Swift probe frame: ${frame.kind}`);
    }
    const status = await exited;
    if (status !== 0 || !finished) throw new Error(`Swift conformance probe failed: ${stderr}`);
    if (failure) throw new Error(failure.message ?? failure.code);
  } finally {
    options.signal?.removeEventListener("abort", cancel);
    if (!finished) child.kill();
  }
}

export function streamSimple(model, context, options = {}, requestSource = "api") {
  const { reasoning, ...base } = options;
  let reasoningEffort;
  if (reasoning) {
    const available = invoke({
      ...fixtureInput(model, context, options, [], fixtureCredential(model, options)),
      operation: "reasoning-levels",
    });
    record("catalog", model.api, available.failure);
    if (!Array.isArray(available)) throw new Error(available.failure?.message ?? "Swift did not return reasoning levels");
    const order = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
    const requested = order.indexOf(reasoning);
    const candidates = requested < 0 ? available : [
      ...order.slice(requested), ...order.slice(0, requested).reverse(),
    ];
    reasoningEffort = candidates.find(level => available.includes(level));
  }
  const disableGoogleThinking = ["google-generative-ai", "google-vertex"].includes(model.api)
    && (!reasoning || reasoningEffort === "off");
  return stream(model, context, {
    ...base,
    maxTokens: clampMaxTokensToContext(model, context, options.maxTokens ?? model.maxTokens),
    reasoningEffort: disableGoogleThinking ? undefined : reasoningEffort,
    ...(disableGoogleThinking ? { thinking: { enabled: false } } : {}),
  }, requestSource);
}

async function mockResponse(model, request, body, options, connection) {
  if (model.api === "bedrock-converse-stream") {
    const client = connection.client ??= new BedrockRuntimeClient({
      endpoint: new URL(request.url).origin,
      region: options.region ?? connection.credential.metadata.AWS_REGION ?? "us-east-1",
      credentials: { accessKeyId: "synthetic-sdk-fixture-key", secretAccessKey: "synthetic-sdk-fixture-secret" },
    });
    let response;
    try {
      response = await client.send(new ConverseStreamCommand({ modelId: bedrockModelID(request.url), ...body }),
        { abortSignal: options.signal });
    } catch (error) {
      const status = error.$metadata?.httpStatusCode ?? (error.name === "ValidationException" ? 400 : undefined);
      if (!status) throw error;
      return { status, headers: { "x-amzn-errortype": error.name },
        chunks: [Buffer.from(JSON.stringify({ __type: error.name, message: error.message })).toString("base64")] };
    }
    const codec = new EventStreamCodec(bytes => new TextDecoder().decode(bytes), value => new TextEncoder().encode(value));
    const chunks = (async function* () {
      for await (const event of response.stream) {
        await options.onProviderStreamEvent?.(event, model);
        const [type, payload] = Object.entries(event)[0];
        const exception = type.endsWith("Exception");
        yield Buffer.from(codec.encode({
          headers: {
            ":message-type": { type: "string", value: exception ? "exception" : "event" },
            [exception ? ":exception-type" : ":event-type"]: { type: "string", value: type },
            ":content-type": { type: "string", value: "application/json" },
          },
          body: new TextEncoder().encode(JSON.stringify(payload instanceof Error ? { ...payload, message: payload.message } : payload,
            (_key, value) => value instanceof Uint8Array ? Buffer.from(value).toString("base64") : value)),
        })).toString("base64");
      }
    })();
    return { status: response.$metadata.httpStatusCode, chunks,
      headers: response.$metadata.requestId ? { "x-amzn-requestid": response.$metadata.requestId } : {} };
  }
  if (options.fetch || ["mistral-conversations", "pi-messages"].includes(model.api)) {
    const response = await (options.fetch ?? globalThis.fetch)(request.url, {
      method: "POST", headers: request.headers, body: JSON.stringify(body), signal: options.signal,
    });
    return { status: response.status, headers: Object.fromEntries(response.headers), chunks: responseChunks(response, options.signal) };
  }
  const suffix = model.api === "openai-completions" ? "/chat/completions" :
    model.api === "anthropic-messages" ? "/v1/messages" : "/responses";
  const defaultHeaders = { ...request.headers };
  for (const name of ["Authorization", "x-api-key"]) {
    if (!Object.keys(defaultHeaders).some(key => key.toLowerCase() === name.toLowerCase())) {
      defaultHeaders[name] = null;
    }
  }
  const config = { apiKey: connection.credential.key, baseURL: request.url.split(suffix)[0],
    defaultHeaders, dangerouslyAllowBrowser: true };
  if (model.api === "azure-openai-responses") {
    config.apiVersion = new URL(request.url).searchParams.get("api-version") ?? "v1";
  }
  if (model.api === "google-generative-ai" || model.api === "google-vertex") {
    const client = connection.client ??= new GoogleGenAI({ apiKey: options.apiKey,
      httpOptions: { headers: request.headers },
      ...(model.api === "google-vertex" ? { vertexai: true, project: options.project, location: options.location } : {}),
    });
    const { systemInstruction, tools, toolConfig, generationConfig, contents } = body;
    const data = await client.models.generateContentStream({ model: model.id, contents,
      config: { ...generationConfig, ...(systemInstruction ? { systemInstruction } : {}),
        ...(tools ? { tools } : {}), ...(toolConfig ? { toolConfig } : {}) } });
    const chunks = (async function* () {
      for await (const event of data) {
        await options.onProviderStreamEvent?.(event, model);
        yield Buffer.from(`data: ${JSON.stringify(event)}\n\n`).toString("base64");
      }
    })();
    return { status: 200, headers: {}, chunks };
  }
  const OpenAI = model.api === "azure-openai-responses" ? OpenAISDK.AzureOpenAI : OpenAISDK.default;
  const client = connection.client ??= options.client ??
    (model.api === "anthropic-messages" ? new Anthropic(config) : new OpenAI(config));
  if (model.api === "anthropic-messages" && options.client?.beta?.messages) {
    const response = await options.client.beta.messages.create(body, { signal: options.signal }).asResponse();
    return { status: response.status, headers: Object.fromEntries(response.headers), chunks: responseChunks(response, options.signal) };
  }
  const resource = model.api === "anthropic-messages" ? client.messages :
    model.api === "openai-completions" ? client.chat.completions : client.responses;
  let reply;
  try {
    const pending = resource.create(body, { signal: options.signal });
    reply = typeof pending.withResponse === "function" ? await pending.withResponse() :
      { data: await pending, response: { status: 200, headers: new Headers() } };
  } catch (error) {
    if (!Number.isInteger(error.status)) throw error;
    return { status: error.status, headers: {},
      chunks: [Buffer.from(JSON.stringify(error.error ?? { message: error.message })).toString("base64")] };
  }
  const frames = (async function* () {
    for await (const event of reply.data) {
      await options.onProviderStreamEvent?.(event, model);
      const label = model.api === "anthropic-messages" ? `event: ${event.type}\n` : "";
      yield Buffer.from(`${label}data: ${JSON.stringify(event)}\n\n`).toString("base64");
    }
    if (model.api === "openai-completions") yield Buffer.from("data: [DONE]\n\n").toString("base64");
  })();
  return { status: reply.response.status, headers: Object.fromEntries(reply.response.headers), chunks: frames };
}

async function* responseChunks(response, signal) {
  if (!response.body) return;
  const reader = response.body.getReader();
  const cancel = () => { void reader.cancel(signal.reason); };
  signal?.addEventListener("abort", cancel, { once: true });
  if (signal?.aborted) cancel();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) return;
      yield Buffer.from(value).toString("base64");
    }
  } finally {
    signal?.removeEventListener("abort", cancel);
    reader.releaseLock();
  }
}

function bedrockModelID(url) {
  const match = new URL(url).pathname.match(/\/model\/([^/]+)\/converse-stream$/);
  if (!match) throw new Error("Swift Bedrock request did not encode a model route");
  return decodeURIComponent(match[1]);
}

function googleWireBody(payload) {
  const { systemInstruction, tools, toolConfig, ...generationConfig } = payload.config ?? {};
  return { contents: payload.contents, generationConfig,
    ...(systemInstruction ? { systemInstruction } : {}),
    ...(tools ? { tools } : {}), ...(toolConfig ? { toolConfig } : {}) };
}

function emit(event, partial, output) {
  const [type, data] = Object.entries(event)[0];
  const value = data._0;
  if (type === "responseStarted") {
    if (value.responseID) partial.responseId = value.responseID;
    output.push({ type: "start", partial: structuredClone(partial) });
  } else if (type === "textDelta" || type === "reasoningDelta") {
    const kind = type === "textDelta" ? "text" : "thinking";
    let index = partial.content.findLastIndex(block => block.type === kind);
    if (index < 0) {
      index = partial.content.push({ type: kind, [kind]: "" }) - 1;
      output.push({ type: `${kind}_start`, contentIndex: index, partial: structuredClone(partial) });
    }
    partial.content[index][kind] += value;
    output.push({ type: `${kind}_delta`, contentIndex: index, delta: value, partial: structuredClone(partial) });
  } else if (type === "toolCallStarted") {
    const index = partial.content.push({ type: "toolCall", id: data.id, name: data.name, arguments: {} }) - 1;
    output.push({ type: "toolcall_start", contentIndex: index, partial: structuredClone(partial) });
  } else if (type === "reasoningSignatureDelta") {
    const index = partial.content.findLastIndex(block => block.type === "thinking");
    if (index >= 0) partial.content[index].thinkingSignature =
      (partial.content[index].thinkingSignature ?? "") + value;
  } else if (type === "toolInputDelta") {
    const index = partial.content.findIndex(block => block.id === data.id);
    output.push({ type: "toolcall_delta", contentIndex: index, delta: data.delta, partial: structuredClone(partial) });
  } else if (type === "toolCallCompleted") {
    const index = partial.content.findIndex(block => block.id === value.id);
    const call = { ...value, type: "toolCall" };
    partial.content[index] = call;
    output.push({ type: "toolcall_end", contentIndex: index, toolCall: call, partial: structuredClone(partial) });
  } else if (type === "responseSnapshot") {
    partial.content = value.content.map(block => {
      const [kind, payload] = Object.entries(block)[0];
      if (kind === "text") return { type: "text", text: payload._0.text, textSignature: payload._0.signature };
      if (kind === "reasoning") return { type: "thinking", thinking: payload._0.text, thinkingSignature: payload._0.signature,
        ...(payload._0.isRedacted !== undefined ? { redacted: payload._0.isRedacted } : {}) };
      if (kind === "toolCall") return { type: "toolCall", ...payload._0 };
      throw new Error(`Unmapped Swift response content: ${kind}`);
    });
    partial.responseId = value.responseID;
    if (value.responseModelID) partial.responseModel = value.responseModelID;
    partial.rawStopReason = value.rawFinishReason;
    Object.assign(partial, value.providerMetadata);
    if (value.usage) partial.usage = usage(value.usage);
  } else if (type === "usage") partial.usage = usage(value);
  else if (type === "completed") partial.stopReason = { toolCalls: "toolUse", contentFilter: "error", cancelled: "aborted" }[value] ?? value;
}

function usage(raw) {
  return {
    input: raw.inputTokens ?? 0, output: raw.outputTokens ?? 0,
    cacheRead: raw.cachedInputTokens ?? 0, cacheWrite: raw.cacheWriteTokens ?? 0,
    ...(raw.providerMetadata?.cacheWrite1h !== undefined ? { cacheWrite1h: raw.providerMetadata.cacheWrite1h } : {}),
    ...(raw.reasoningTokens !== undefined ? { reasoning: raw.reasoningTokens } : {}),
    totalTokens: raw.totalTokens ?? (raw.inputTokens ?? 0) + (raw.outputTokens ?? 0),
    cost: raw.cost ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
}
