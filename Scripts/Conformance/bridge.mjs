import { spawn, spawnSync } from "node:child_process";
import { AsyncLocalStorage } from "node:async_hooks";
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
import { bedrockSDKPayload, bedrockWirePayload } from "./bedrock-payload.mjs";

const upstream = process.env.PI_CONFORMANCE_UPSTREAM;
const heapObservations = new AsyncLocalStorage();

export async function measureNativeAllocatedBytes(operation) {
  const samples = [];
  await heapObservations.run(samples, operation);
  if (!samples.length) throw new Error("No Swift heap measurement was returned");
  return samples.reduce((total, sample) => total + sample, 0);
}
const { AssistantMessageEventStream } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/utils/event-stream.ts")));
const { getCurrentSystemPrompt, getCurrentTools, normalizeContext } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/utils/transcript.ts")));
const { getSystemMessageText, renderSystemMessageUpdate } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/utils/text.ts")));
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

export { invoke as invokeNative, record as recordNative, probe as projectNativeRequest, fixtureInput };

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

function preserveUTF16(content) {
  const units = text => Array.from({ length: text.length }, (_, index) => text.charCodeAt(index));
  if (typeof content === "string") {
    return content.isWellFormed() ? content : [{ type: "text", textUTF16: units(content) }];
  }
  return content?.map(block => block.type === "text" && typeof block.text === "string" && !block.text.isWellFormed()
    ? { ...block, text: undefined, textUTF16: units(block.text) } : block);
}

function fixtureInput(model, context, options, responses, credential, requestSource = "api", generationMode = "raw") {
  const preservesSystemMessages = ["openai-completions", "anthropic-messages"].includes(model.api)
    && model.compat?.supportsMidConvoSystemMessages === true;
  const messages = preservesSystemMessages ? context.messages.map((message, index) => message.role === "system"
    ? { ...message, content: index === 0 ? getSystemMessageText(message) : renderSystemMessageUpdate(message) }
    : message).filter(message => model.api === "anthropic-messages" || message.role !== "system" || message.content.length > 0)
    : context.messages.filter(message => message.role !== "system");
  return {
    model, requestSource, generationMode,
    identityHost: { platform: process.platform, arch: process.arch, node: process.versions.node, bun: process.versions.bun, version: process.version },
    context: {
      systemPrompt: preservesSystemMessages ? undefined : getCurrentSystemPrompt(context.messages),
      tools: getCurrentTools(context.messages),
      messages: messages.map(message => ["user", "assistant"].includes(message.role)
        ? { ...message, content: preserveUTF16(message.content) } : message),
    },
    options: { ...options,
      ...(options.grammarToolInputProperties instanceof Map ? {
        grammarToolInputProperties: Object.fromEntries(options.grammarToolInputProperties),
      } : {}),
      cacheRetention: options.cacheRetention ||
      (getProviderEnvValue("PI_CACHE_RETENTION", options.env) === "long" ? "long" : model.api === "pi-messages" ? undefined : "short") },
    credential,
    environment: Object.fromEntries(Object.entries(process.env).filter(([key]) =>
      key.startsWith("AZURE_OPENAI_") || ["GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION"].includes(key))),
    responses,
    aborted: options.signal?.aborted ?? false,
    ...(hasNativeWireObserver(model) && (model.api === "anthropic-messages" || options.onPayload || options.onResponse || options.onProviderStreamEvent)
      ? { wireObserver: { payload: model.api === "anthropic-messages" || !!options.onPayload, response: !!options.onResponse, event: !!options.onProviderStreamEvent } } : {}),
  };
}

function hasNativeWireObserver(model) {
  return ["openai-completions", "anthropic-messages", "openai-responses", "azure-openai-responses", "openai-codex-responses", "mistral-conversations", "google-generative-ai", "google-vertex", "bedrock-converse-stream", "pi-messages"].includes(model.api);
}

function capabilities(options, model) {
  return [
    ...(options.fetch && ["google-generative-ai", "google-vertex"].includes(model.api)
      ? ["google-sdk-custom-fetch-contract"] : []),
    ...(model.api === "anthropic-messages" && options.env?.ANTHROPIC_FEDERATION_RULE_ID && !options.apiKey
      ? ["anthropic-workload-identity-federation"] : []),
    ...(options.onProviderStreamEvent && !hasNativeWireObserver(model) ? ["raw-provider-stream-event-hook"] : []),
    ...(options.onResponse && !hasNativeWireObserver(model) ? ["raw-response-hook"] : []),
    ...(options.timeoutMs !== undefined && model.api !== "mistral-conversations" ? ["request-timeout-option"] : []),
  ];
}

function probe(model, context, options, responses = [], credential = fixtureCredential(model, options)) {
  const samples = heapObservations.getStore();
  const result = invoke({ ...fixtureInput(model, context, options, responses, credential), measureHeap: !!samples });
  if (samples && result.allocatedBytes !== undefined) samples.push(result.allocatedBytes);
  record(result.failure?.unrepresentedCapability ? "input" : responses.length ? "decode" : "encode", model.api, result.failure, [
    ...capabilities(options, model),
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
  const result = probe({ ...model, compat: { ...model.compat, ...compat } }, context,
    { apiKey: "test", ...options, cacheRetention: "none" });
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
  if (decoded.failure) {
    Object.assign(partial, decoded.failure.providerMetadata);
    throw new Error(decoded.failure.message ?? decoded.failure.code);
  }
}

export function stream(model, context, options = {}, requestSource = "api", generationMode = "raw") {
  const output = new AssistantMessageEventStream();
  (async () => {
    const partial = {
      role: "assistant", api: model.api, provider: model.provider, model: model.id,
      content: [], stopReason: "pending", timestamp: Date.now(),
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    };
    try {
      await nativeStream(model, context, options, event => emit(event, partial, output), requestSource, generationMode);
      output.push(partial.stopReason === "error" || partial.stopReason === "aborted"
        ? { type: "error", reason: partial.stopReason, error: partial }
        : { type: "done", reason: partial.stopReason, message: partial });
      output.end(partial);
    } catch (error) {
      Object.assign(partial, error.providerMetadata);
      partial.stopReason = options.signal?.aborted ? "aborted" : "error";
      partial.errorMessage = error.message;
      output.push({ type: "error", reason: partial.stopReason, error: partial });
      output.end(partial);
    }
  })();
  return output;
}

export async function generateImages(model, context, options = {}) {
  const partial = { content: [], stopReason: "pending", timestamp: Date.now() };
  try {
    await nativeStream(model, normalizeContext({ messages: [{ role: "user", content: context.input, timestamp: 0 }] }),
      options, event => emit(event, partial, { push() {} }), "api", "raw");
  } catch (error) {
    partial.stopReason = options.signal?.aborted ? "aborted" : "error";
    partial.errorMessage = options.signal?.aborted ? "Request aborted" : error.message;
  }
  const { content, ...result } = partial;
  return { ...result, output: content };
}

async function nativeStream(model, context, options, emitEvent, requestSource, generationMode) {
  const heapSamples = heapObservations.getStore();
  const credential = fixtureCredential(model, options);
  const connection = { credential, providerEvents: [] };
  const child = spawn(process.env.PI_CONFORMANCE_PROBE, ["--stream"], { stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", data => { stderr += data; });
  const exited = new Promise((resolve, reject) => { child.once("close", resolve); child.once("error", reject); });
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  let finished = false;
  let failure;
  let requestController;
  const send = frame => {
    if (!child.stdin.destroyed && !child.stdin.writableEnded) child.stdin.write(JSON.stringify(frame) + "\n");
  };
  child.stdin.on("error", () => {});
  const cancel = () => send({ kind: "cancel" });
  options.signal?.addEventListener("abort", cancel, { once: true });
  record("encode", model.api, undefined, capabilities(options, model), "stream");
  send({ ...fixtureInput(model, context, options, [], credential, requestSource, generationMode), measureHeap: !!heapSamples });
  const serve = async request => {
    const controller = new AbortController();
    requestController = controller;
    const abort = () => controller.abort(options.signal.reason);
    options.signal?.addEventListener("abort", abort, { once: true });
    try {
      let body = request.body;
      const google = model.api === "google-generative-ai" || model.api === "google-vertex";
      const mistral = model.api === "mistral-conversations";
      const payload = model.api === "bedrock-converse-stream" ? { modelId: bedrockModelID(request.url), ...bedrockSDKPayload(body) } : google ? googleSDKPayload(body, model) : mistral ? mistralSDKPayload(body) : body;
      const replacement = hasNativeWireObserver(model) ? undefined : await options.onPayload?.(payload, model);
      if (replacement !== undefined) body = google ? googleWireBody(replacement) : mistral ? mistralWirePayload(replacement) : replacement;
      if (options.signal?.aborted) { cancel(); return; }
      if (controller.signal.aborted) return;
      if (options.timeoutMs !== undefined && !mistral) throw new Error("Swift ProviderRequest has no request-timeout option");
      const response = await mockResponse(model, request, body, { ...options, signal: controller.signal }, connection);
      if (finished) return;
      send({ kind: "response", status: response.status, headers: response.headers });
      for await (const data of response.chunks) {
        if (finished) break;
        send({ kind: "chunk", data });
      }
      send({ kind: "end" });
    } finally {
      options.signal?.removeEventListener("abort", abort);
      requestController = undefined;
    }
  };
  try {
    for await (const line of lines) {
      const frame = JSON.parse(line);
      if (frame.kind === "request") {
        void serve(frame.payload).catch(error => send({ kind: "failure", message: error.message }));
      } else if (frame.kind === "observer") {
        void (async () => {
          const { stage, value, context: observedContext } = frame.payload;
          expect(observedContext.model.id).toBe(model.id);
          expect(observedContext.model.providerID).toBe(model.provider);
          expect(observedContext.model.protocolID).toBe(model.api);
          if (stage === "payload") {
            const mistral = model.api === "mistral-conversations";
            const google = ["google-generative-ai", "google-vertex"].includes(model.api);
            const bedrock = model.api === "bedrock-converse-stream";
            const payload = bedrock ? bedrockSDKPayload(value) : google ? googleSDKPayload(value, model) : mistral ? mistralSDKPayload(value) : value;
            const replacement = await options.onPayload?.(payload, model);
            const modified = replacement === undefined ? payload : replacement;
            if (model.api === "anthropic-messages") connection.logicalPayload = modified;
            send({ kind: "observerReply", payload: bedrock ? bedrockWirePayload(modified) : google ? googleWireBody(modified) : mistral ? mistralWirePayload(modified) : modified, replaced: replacement !== undefined });
          } else if (stage === "response") {
            await options.onResponse(value, model);
            send({ kind: "observerReply" });
          } else if (stage === "event") {
            const original = connection.providerEvents.shift();
            if (original) expect(value).toEqual(original.serialized);
            await options.onProviderStreamEvent(original ? original.reference : value, model);
            send({ kind: "observerReply" });
          } else throw new Error(`Unknown native observer stage: ${stage}`);
        })().catch(error => send({ kind: "observerReply", error: error.message }));
      } else if (frame.kind === "cancelRequest") {
        requestController?.abort();
      } else if (frame.kind === "event") {
        emitEvent(frame.payload);
      } else if (frame.kind === "heap") {
        if (!heapSamples) throw new Error("Unexpected Swift heap measurement");
        heapSamples.push(frame.payload.allocatedBytes);
        const state = expect.getState();
        appendFileSync(path.join(process.env.PI_CONFORMANCE_OUTPUT, "heap-observations.jsonl"), JSON.stringify({
          file: state.testPath, test: state.currentTestName, protocol: model.api, allocatedBytes: frame.payload.allocatedBytes,
        }) + "\n");
      } else if (frame.kind === "finished") {
        finished = true;
        failure = frame.payload;
        record("decode", model.api, failure, failure?.unrepresentedCapability ? [failure.unrepresentedCapability] : [], "stream");
        child.stdin.end();
      } else throw new Error(`Unknown Swift probe frame: ${frame.kind}`);
    }
    const status = await exited;
    if (status !== 0 || !finished) throw new Error(`Swift conformance probe failed: ${stderr}`);
    if (failure) throw Object.assign(new Error(failure.message ?? failure.code), { providerMetadata: failure.providerMetadata });
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
  }, requestSource, "simple");
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
      response = await client.send(new ConverseStreamCommand({ modelId: bedrockModelID(request.url), ...bedrockSDKPayload(body) }),
        { abortSignal: options.signal });
    } catch (error) {
      const status = error.$metadata?.httpStatusCode ?? (error.name === "ValidationException" ? 400 : undefined);
      if (!status) throw error;
      if (typeof error.$response?.body === "string") {
        record("decode", model.api, undefined, ["parsed-sdk-error-object-versus-raw-http-response"]);
        return { status, headers: error.$response.headers ?? {},
          chunks: [Buffer.from(error.$response.body).toString("base64")] };
      }
      return { status, headers: { "x-amzn-errortype": error.name,
        ...(error.$metadata?.requestId ? { "x-amzn-requestid": error.$metadata.requestId } : {}) },
        chunks: [Buffer.from(JSON.stringify({ __type: error.name, message: error.message })).toString("base64")] };
    }
    const codec = new EventStreamCodec(bytes => new TextDecoder().decode(bytes), value => new TextEncoder().encode(value));
    const chunks = (async function* () {
      try {
        for await (const event of response.stream) {
          const [type, payload] = Object.entries(event)[0];
          const body = JSON.stringify(payload instanceof Error ? { ...payload, message: payload.message } : payload,
            (_key, value) => value instanceof Uint8Array ? Buffer.from(value).toString("base64") : value);
          if (hasNativeWireObserver(model) && options.onProviderStreamEvent) {
            connection.providerEvents.push({ reference: event, serialized: { [type]: JSON.parse(body) } });
          } else if (!hasNativeWireObserver(model)) await options.onProviderStreamEvent?.(event, model);
          yield Buffer.from(codec.encode({
            headers: {
              // The fixture has already yielded a parsed SDK item, including any error item.
              ":message-type": { type: "string", value: "event" },
              ":event-type": { type: "string", value: type },
              ":content-type": { type: "string", value: "application/json" },
            },
            body: new TextEncoder().encode(body),
          })).toString("base64");
        }
      } catch (error) {
        if (!(error instanceof Error) || !error.name.endsWith("Exception")) throw error;
        yield Buffer.from(codec.encode({
          headers: {
            ":message-type": { type: "string", value: "error" },
            ":error-code": { type: "string", value: error.name },
            ":error-message": { type: "string", value: error.message },
          },
          body: new Uint8Array(),
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
  const suffix = ["openai-completions", "openrouter-images"].includes(model.api) ? "/chat/completions" :
    model.api === "anthropic-messages" ? "/v1/messages" : "/responses";
  const defaultHeaders = { ...request.headers };
  for (const name of ["Authorization", "x-api-key"]) {
    if (!Object.keys(defaultHeaders).some(key => key.toLowerCase() === name.toLowerCase())) {
      defaultHeaders[name] = null;
    }
  }
  const config = { ...(model.api === "anthropic-messages" ? {
    apiKey: connection.credential.key?.includes("sk-ant-oat") ? null : connection.credential.key ?? null,
    authToken: connection.credential.key?.includes("sk-ant-oat") ? connection.credential.key : null,
  } : { apiKey: connection.credential.key }), baseURL: request.url.split(suffix)[0],
    defaultHeaders, dangerouslyAllowBrowser: true };
  if (model.api === "azure-openai-responses") {
    if (!request.azureConfiguration) throw new Error("Swift Azure configuration was not captured");
    Object.assign(config, request.azureConfiguration);
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
        if (hasNativeWireObserver(model) && options.onProviderStreamEvent) {
          connection.providerEvents.push({ reference: event, serialized: JSON.parse(JSON.stringify(event)) });
        } else if (!hasNativeWireObserver(model)) await options.onProviderStreamEvent?.(event, model);
        yield Buffer.from(`data: ${JSON.stringify(event)}\n\n`).toString("base64");
      }
    })();
    return { status: 200, headers: {}, chunks };
  }
  const OpenAI = model.api === "azure-openai-responses" ? OpenAISDK.AzureOpenAI : OpenAISDK.default;
  if (model.api === "anthropic-messages") {
    if (!connection.logicalPayload) throw new Error("Native Anthropic payload observation is missing");
    body = { ...body };
    for (const field of ["betas", "user_profile_id", "workspace_id"]) {
      if (Object.hasOwn(connection.logicalPayload, field)) body[field] = connection.logicalPayload[field];
    }
  }
  const client = connection.client ??= options.client ??
    (model.api === "anthropic-messages" ? new Anthropic(config) : new OpenAI(config));
  if (model.api === "anthropic-messages" && client.beta?.messages) {
    const response = await client.beta.messages.create(body, { signal: options.signal }).asResponse();
    return { status: response.status, headers: Object.fromEntries(response.headers), chunks: responseChunks(response, options.signal) };
  }
  const resource = model.api === "anthropic-messages" ? client.messages :
    ["openai-completions", "openrouter-images"].includes(model.api) ? client.chat.completions : client.responses;
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
  if (model.api === "openrouter-images") return {
    status: reply.response.status, headers: Object.fromEntries(reply.response.headers),
    chunks: [Buffer.from(JSON.stringify(reply.data)).toString("base64")],
  };
  const frames = (async function* () {
    for await (const event of reply.data) {
      if (hasNativeWireObserver(model) && options.onProviderStreamEvent) {
        // Verify Native's parsed value before restoring the SDK reference identity.
        connection.providerEvents.push({ reference: event, serialized: JSON.parse(JSON.stringify(event)) });
      } else if (!hasNativeWireObserver(model)) await options.onProviderStreamEvent?.(event, model);
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

function googleSDKPayload(body, model) {
  return { model: model.id, contents: body.contents,
    config: { ...body.generationConfig,
      ...(body.systemInstruction ? { systemInstruction: body.systemInstruction } : {}),
      ...(body.tools ? { tools: body.tools } : {}), ...(body.toolConfig ? { toolConfig: body.toolConfig } : {}) } };
}

function googleWireBody(payload) {
  const { systemInstruction, tools, toolConfig, ...generationConfig } = payload.config ?? {};
  return { contents: payload.contents, generationConfig,
    ...(systemInstruction ? { systemInstruction } : {}),
    ...(tools ? { tools } : {}), ...(toolConfig ? { toolConfig } : {}) };
}

const indexedBlockPartials = new WeakSet();

function emit(event, partial, output) {
  const [type, data] = Object.entries(event)[0];
  const value = data._0;
  if (type === "responseStarted") {
    if (value.responseID) partial.responseId = value.responseID;
    output.push({ type: "start", partial: structuredClone(partial) });
  } else if (type === "contentBlock") {
    indexedBlockPartials.add(partial);
    const [kind, payload] = Object.entries(value.content)[0];
    const block = payload._0;
    const category = kind === "text" ? "text" : "thinking";
    const [stage, update] = Object.entries(value.update)[0];
    const normalized = kind === "text"
      ? { type: "text", text: block.text, ...(block.signature !== undefined ? { textSignature: block.signature } : {}) }
      : { type: "thinking", thinking: block.text,
        ...(block.signature !== undefined ? { thinkingSignature: block.signature } : {}),
        ...(block.isRedacted !== undefined ? { redacted: block.isRedacted } : {}) };
    if (stage === "delta") normalized[category] = (partial.content[value.index]?.[category] ?? "") + update._0;
    partial.content[value.index] = normalized;
    partial.stopReason = { toolCalls: "toolUse", contentFilter: "error", cancelled: "aborted" }[value.provisionalFinishReason] ?? value.provisionalFinishReason ?? "pending";
    output.push({ type: `${category}_${stage === "started" ? "start" : stage === "completed" ? "end" : "delta"}`,
      contentIndex: value.index,
      ...(stage === "delta" ? { delta: update._0 } : stage === "completed" ? { content: block.text } : {}),
      partial: structuredClone(partial) });
  } else if (type === "textDelta" || type === "reasoningDelta") {
    if (indexedBlockPartials.has(partial)) return;
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
    if (indexedBlockPartials.has(partial)) return;
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
      if (kind === "toolCall") {
        const call = partial.content.find(block => block.type === "toolCall" && block.id === payload._0.id) ?? {};
        for (const key of Object.keys(call)) delete call[key];
        return Object.assign(call, { type: "toolCall", ...payload._0 });
      }
      if (kind === "asset") return { type: "image", mimeType: payload._0.mimeType, data: payload._0.data };
      throw new Error(`Unmapped Swift response content: ${kind}`);
    });
    partial.responseId = value.responseID;
    if (value.responseModelID) partial.responseModel = value.responseModelID;
    partial.rawStopReason = value.rawFinishReason;
    delete partial.errorMessage;
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
