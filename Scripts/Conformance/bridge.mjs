import { spawn } from "node:child_process";
import { AsyncLocalStorage } from "node:async_hooks";
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { zstdDecompressSync } from "node:zlib";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { expect, afterEach } from "vitest";
import * as OpenAISDK from "openai";
import Anthropic from "@anthropic-ai/sdk";
import { GoogleGenAI } from "@google/genai";
import { BedrockRuntimeClient, BedrockRuntimeServiceException, ConverseStreamCommand } from "@aws-sdk/client-bedrock-runtime";
import { EventStreamCodec } from "@smithy/core/event-streams";
import { NodeHttpHandler } from "@smithy/node-http-handler";
import { mistralSDKPayload, mistralWirePayload } from "./mistral-payload.mjs";
import { bedrockSDKPayload, bedrockWirePayload } from "./bedrock-payload.mjs";
import { codexProbeChild } from "./native-session.mjs";
import { resolveFixtureCloud, FixtureAnthropic } from "./cloud-authorization.mjs";
import { normalizeProviderError } from "./error-body.mjs";
import { invokeNative as invoke, recordNative as record } from "./native-operations.mjs";
import { getEnvApiKey } from "./environment.mjs";

const upstream = process.env.PI_CONFORMANCE_UPSTREAM;
const heapObservations = new AsyncLocalStorage();
const yieldIO = globalThis.setImmediate;
const streamLifetimes = [];
export function takeNativeStreamLifetimes() { return streamLifetimes.splice(0); }
afterEach(() => { streamLifetimes.length = 0; });

export async function measureNativeAllocatedBytes(operation) {
  const samples = [];
  await heapObservations.run(samples, operation);
  if (!samples.length) throw new Error("No Swift heap measurement was returned");
  return samples.reduce((total, sample) => total + sample, 0);
}

export function observeNativeAllocatedBytes(bytes) {
  heapObservations.getStore()?.push(bytes);
}

export function isObservingNativeHeap() { return !!heapObservations.getStore(); }
const { AssistantMessageEventStream } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/utils/event-stream.ts")));
const { getCurrentSystemPrompt, getCurrentTools, normalizeContext, resolveTranscriptTools } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/utils/transcript.ts")));
const { getSystemMessageText, renderSystemMessageUpdate } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/utils/text.ts")));
const { getProviderEnvValue } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/utils/provider-env.ts")));
const { clampMaxTokensToContext } = await import(pathToFileURL(path.join(upstream, "packages/ai/src/api/simple-options.ts")));

export function recordCapability(capability) {
  record("capability", "*", undefined, [capability]);
}

export { invoke as invokeNative, record as recordNative, probe as projectNativeRequest, fixtureInput };

function fixtureCredential(model, options) {
  const environment = { ...process.env, ...options.env };
  const environmentKey = model.api === "google-vertex" ? undefined : getEnvApiKey(model.provider, options.env);
  return {
    key: options.apiKey ?? (options.client ? "synthetic-sdk-fixture-key" :
      environmentKey === "<authenticated>" ? undefined : environmentKey),
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
  const preservesSystemMessages = ["openai-completions", "anthropic-messages", "openai-responses", "azure-openai-responses", "openai-codex-responses"].includes(model.api)
    && model.compat?.supportsMidConvoSystemMessages === true;
  let toolPlan;
  if (["openai-completions", "openai-responses", "azure-openai-responses", "openai-codex-responses"].includes(model.api)) {
    const mode = invoke({ operation: "tool-support", model });
    record("tool-support", model.api);
    toolPlan = resolveTranscriptTools(context.messages, mode);
  }
  let systemIndex = 0;
  const messages = preservesSystemMessages ? context.messages.map((message, index) => message.role === "system"
    ? { ...message, content: index === 0 ? getSystemMessageText(message) : renderSystemMessageUpdate(message),
      ...(toolPlan && systemIndex++ < toolPlan.foldedSystemMessages ? { toolsAdded: [], toolsRemoved: [] } : {}) }
    : message).filter(message => model.api === "anthropic-messages" || message.role !== "system"
      || message.content.length > 0 || message.toolsAdded?.length || message.toolsRemoved?.length)
    : context.messages.filter(message => message.role !== "system");
  return {
    model, requestSource, generationMode,
    requestTransportOverride: !!options.fetch && options.fetch !== globalThis.fetch,
    identityHost: { platform: process.platform, arch: process.arch, node: process.versions.node, bun: process.versions.bun, version: process.version },
    context: {
      systemPrompt: preservesSystemMessages ? undefined : getCurrentSystemPrompt(context.messages),
      tools: toolPlan?.requestTools ?? getCurrentTools(context.messages),
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
    cloudEnvironment: Object.fromEntries(Object.entries(process.env).filter(([key]) => /^(AWS_|GOOGLE_|GCLOUD_|ANTHROPIC_)/.test(key))),
    responses,
    aborted: options.signal?.aborted ?? false,
    ...(hasNativeWireObserver(model)
      ? { wireObserver: { payload: model.api === "anthropic-messages" || !!options.onPayload, response: !!options.onResponse, event: !!options.onProviderStreamEvent, toolArguments: true } } : {}),
  };
}

function hasNativeWireObserver(model) {
  return ["openai-completions", "anthropic-messages", "openai-responses", "azure-openai-responses", "openai-codex-responses", "mistral-conversations", "google-generative-ai", "google-vertex", "bedrock-converse-stream", "pi-messages"].includes(model.api);
}

function capabilities(options, model) {
  return [
    ...(options.onProviderStreamEvent && !hasNativeWireObserver(model) ? ["raw-provider-stream-event-hook"] : []),
    ...(options.onResponse && !hasNativeWireObserver(model) ? ["raw-response-hook"] : []),
    ...(options.timeoutMs !== undefined && !["mistral-conversations", "openai-codex-responses"].includes(model.api) ? ["request-timeout-option"] : []),
  ];
}

function probe(model, context, options, responses = [], credential = fixtureCredential(model, options)) {
  const samples = heapObservations.getStore();
  const result = invoke({ ...fixtureInput(model, context, options, responses, credential), measureHeap: !!samples });
  if (result.request?.rawBody) {
    expect(new Headers(result.request.headers).get("content-encoding")).toBe("zstd");
    result.request.body = JSON.parse(zstdDecompressSync(Buffer.from(result.request.rawBody, "base64")).toString("utf8"));
  }
  if (result.lifetime) streamLifetimes.push(result.lifetime);
  if (samples && result.allocatedBytes !== undefined) samples.push(result.allocatedBytes);
  record(result.failure?.unrepresentedCapability ? "input" : responses.length ? "decode" : "encode", model.api, result.failure, [
    ...(result.failure?.code === "missingCredential" ? [] : capabilities(options, model)),
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
  const apiKey = model.api === "openai-codex-responses"
    ? `header.${Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "synthetic-codec-account" } })).toString("base64")}.signature`
    : "synthetic-decoder-fixture-key";
  const decoded = probe({ ...model, compat: { ...model.compat, ...options } }, context, { apiKey, ...options });
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
  const credential = fixtureCredential(model, options);
  const synchronousAuth = !["google-vertex", "pi-messages", "bedrock-converse-stream", "anthropic-messages"].includes(model.api)
    || model.api === "anthropic-messages" && generationMode === "simple";
  if (!credential.key && synchronousAuth) {
    const result = probe(model, context, options, [], credential);
    if (result.failure?.code === "missingCredential") {
      record("encode", model.api, result.failure, [], "stream");
      throw new Error(`No API key for provider: ${model.provider}`);
    }
  }
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
  const argumentUpdates = new Map();
  const child = ["openai-codex-responses", "anthropic-messages", "google-vertex", "bedrock-converse-stream"].includes(model.api) || (model.api === "openai-completions" && options.maxRetries !== undefined) ? codexProbeChild()
    : spawn(process.env.PI_CONFORMANCE_PROBE, ["--stream"], { stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", data => { stderr += data; });
  const exited = new Promise((resolve, reject) => { child.once("close", resolve); child.once("error", reject); });
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  let finished = false;
  let failure;
  let requestController;
  let requestBodyRead;
  const transportOperations = [];
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
    let readRequested = false;
    let receiveRead;
    requestBodyRead = () => {
      if (receiveRead) { const receive = receiveRead; receiveRead = undefined; receive(); }
      else readRequested = true;
    };
    const waitForRead = async () => {
      if (readRequested) { readRequested = false; return; }
      await new Promise(resolve => { receiveRead = resolve; });
    };
    const abortRead = () => requestBodyRead?.();
    controller.signal.addEventListener("abort", abortRead, { once: true });
    let chunks;
    options.signal?.addEventListener("abort", abort, { once: true });
    try {
      let body = request.body;
      const google = model.api === "google-generative-ai" || model.api === "google-vertex";
      const mistral = model.api === "mistral-conversations";
      const payload = model.api === "bedrock-converse-stream" ? { modelId: bedrockModelID(request.url), ...bedrockSDKPayload(body) } : google ? googleSDKPayload(body, model) : mistral ? mistralSDKPayload(body) : body;
      const replacement = hasNativeWireObserver(model) ? undefined : await options.onPayload?.(payload, model);
      if (replacement !== undefined) body = google ? googleWireBody(replacement) : mistral ? mistralWirePayload(replacement) : replacement;
      if (controller.signal.aborted) return;
      if (options.timeoutMs !== undefined && !mistral && model.api !== "openai-codex-responses") throw new Error("Swift ProviderRequest has no request-timeout option");
      const preAborted = options.signal?.aborted;
      const pendingResponse = mockResponse(model, request, body, { ...options,
        signal: preAborted ? options.signal : controller.signal }, connection);
      if (preAborted) {
        cancel();
        try { await pendingResponse; } catch (error) { if (error.name === "AssertionError") throw error; }
        return;
      }
      child.waiting?.();
      const response = await pendingResponse;
      if (finished) return;
      send({ kind: "response", status: response.status, headers: response.headers });
      chunks = (async function* () { yield* response.chunks; })();
      while (!finished && !controller.signal.aborted) {
        await waitForRead();
        if (finished || controller.signal.aborted) break;
        child.waiting?.();
        const next = await chunks.next();
        if (next.done) { send({ kind: "end" }); break; }
        send({ kind: "chunk", data: next.value });
      }
    } finally {
      await chunks?.return();
      controller.signal.removeEventListener("abort", abortRead);
      options.signal?.removeEventListener("abort", abort);
      requestController = undefined;
      requestBodyRead = undefined;
    }
  };
  try {
    for await (const line of lines) {
      const frame = JSON.parse(line);
      if (frame.kind === "request") {
        transportOperations.push(serve(frame.payload).catch(error => {
          if (error.name === "AssertionError") {
            record("assertion", model.api, {
              code: "bridgeAssertion", operation: "conformance.fixture.assertion", message: error.message,
            });
          }
          send({ kind: "failure", message: error.message, providerMetadata: error.providerMetadata });
        }));
      } else if (frame.kind === "cloud") {
        void resolveFixtureCloud(frame.payload.stage, frame.payload.value, options, connection)
          .then(value => send({ kind: "cloudReply", value }))
          .catch(error => send({ kind: "cloudReply", error: error.message }));
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
          } else if (stage === "toolArguments") {
            let updates = argumentUpdates.get(value.id);
            if (!updates) argumentUpdates.set(value.id, updates = []);
            updates.push(value);
            send({ kind: "observerReply" });
          } else throw new Error(`Unknown native observer stage: ${stage}`);
        })().catch(error => {
          if (error.name === "AssertionError") record("assertion", model.api, {
            code: "bridgeAssertion", operation: "conformance.observer.assertion", message: error.message,
          });
          send({ kind: "observerReply", error: error.message });
        });
      } else if (frame.kind === "cancelRequest") {
        requestController?.abort();
      } else if (frame.kind === "readBody") {
        requestBodyRead?.();
      } else if (frame.kind === "event") {
        const id = frame.payload.toolCallStarted?.id ?? frame.payload.toolInputDelta?.id;
        if (id) {
          const update = argumentUpdates.get(id)?.shift();
          if (update) emitEvent({ toolArgumentsUpdate: { _0: update } });
        }
        if (!options.signal?.aborted) emitEvent(frame.payload);
        // Let the JavaScript consumer cancel before draining the next IPC event.
        await new Promise(yieldIO);
      } else if (frame.kind === "heap") {
        if (!heapSamples) throw new Error("Unexpected Swift heap measurement");
        heapSamples.push(frame.payload.allocatedBytes);
        const state = expect.getState();
        appendFileSync(path.join(process.env.PI_CONFORMANCE_OUTPUT, "heap-observations.jsonl"), JSON.stringify({
          file: state.testPath, test: state.currentTestName, protocol: model.api, allocatedBytes: frame.payload.allocatedBytes,
        }) + "\n");
      } else if (frame.kind === "lifetime") {
        streamLifetimes.push(frame.payload);
      } else if (frame.kind === "finished") {
        finished = true;
        failure = frame.payload;
        record("decode", model.api, failure, failure?.unrepresentedCapability ? [failure.unrepresentedCapability] : [], "stream");
        child.stdin.end();
      } else throw new Error(`Unknown Swift probe frame: ${frame.kind}`);
    }
    const status = await exited;
    await Promise.all(transportOperations);
    if (status !== 0 || !finished) throw new Error(`Swift conformance probe failed: ${stderr}`);
    if (options.signal?.aborted) throw new Error(model.api === "openai-codex-responses" ? "Request was aborted" : "Request aborted");
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
    const client = connection.client ??= new BedrockRuntimeClient({ ...(request.cloudConfiguration ?? {
      endpoint: new URL(request.url).origin,
      region: options.region ?? connection.credential.metadata.AWS_REGION ?? "us-east-1",
      credentials: { accessKeyId: "synthetic-sdk-fixture-key", secretAccessKey: "synthetic-sdk-fixture-secret" },
    }), ...(options.env?.AWS_BEDROCK_FORCE_HTTP1 === "1" ? { requestHandler: new NodeHttpHandler() } : {}),
    });
    if (!connection.headersRegistered) {
      connection.headersRegistered = true;
      if (options.onResponse) {
        client.middlewareStack.add(next => async args => {
          const result = await next(args);
          connection.rawResponse = result.response;
          return result;
        }, { step: "deserialize", name: "pi-ai-response-headers" });
      }
      const configured = invoke({ operation: "headers.bedrock", headers: options.headers });
      record("headers.bedrock", model.api);
      if (Object.values(options.headers ?? {}).some(value => value !== null && value !== undefined)) {
        client.middlewareStack.add(next => async args => {
          if (args.request && typeof args.request === "object" && "headers" in args.request) Object.assign(args.request.headers, configured);
          return next(args);
        }, { step: "build", name: "pi-ai-custom-headers", priority: "low" });
      }
    }
    let response;
    try {
      response = await client.send(new ConverseStreamCommand({ modelId: bedrockModelID(request.url), ...bedrockSDKPayload(body) }),
        { abortSignal: options.signal });
    } catch (error) {
      const status = error.$metadata?.httpStatusCode ?? (error.name === "ValidationException" ? 400 : undefined);
      if (!status) throw error;
      if (typeof error.$response?.body === "string") {
        const projected = invoke({ operation: "error.bedrock-format", ...normalizeProviderError(error),
          exceptionName: error instanceof BedrockRuntimeServiceException ? error.name : undefined,
          metadataStatus: error.$metadata?.httpStatusCode, errorCode: error instanceof Error ? error.name : undefined,
          requestID: error.$metadata?.requestId });
        record("error.bedrock-format", model.api);
        throw Object.assign(new Error(projected.message), { providerMetadata: projected.providerMetadata });
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
    return { status: connection.rawResponse?.statusCode ?? response.$metadata.httpStatusCode, chunks,
      headers: connection.rawResponse?.headers ??
        (response.$metadata.requestId ? { "x-amzn-requestid": response.$metadata.requestId } : {}) };
  }
  if (options.fetch || ["mistral-conversations", "pi-messages", "openai-codex-responses"].includes(model.api)) {
    const response = await (options.fetch ?? globalThis.fetch)(request.url, {
      method: "POST", headers: model.api === "openai-codex-responses" ? new Headers(request.headers) : request.headers,
      body: request.rawBody ? new Uint8Array(Buffer.from(request.rawBody, "base64")) : JSON.stringify(body), signal: options.signal,
    });
    return { status: response.status, headers: Object.fromEntries(response.headers), chunks: responseChunks(response, options.signal) };
  }
  const suffix = ["openai-completions", "openrouter-images"].includes(model.api) ? "/chat/completions" :
    model.api === "anthropic-messages" ? "/v1/messages" : "/responses";
  const defaultHeaders = { ...request.headers };
  for (const [name, value] of Object.entries(options.headers ?? {})) {
    if (value === null) {
      expect(new Headers(request.headers).has(name)).toBe(false);
      defaultHeaders[name] = null;
    }
  }
  for (const name of ["Authorization", "x-api-key"]) {
    if (!Object.keys(defaultHeaders).some(key => key.toLowerCase() === name.toLowerCase())) {
      defaultHeaders[name] = null;
    }
  }
  const config = { ...(model.api === "anthropic-messages" ? {
    apiKey: new Headers(request.headers).has("x-api-key") ? connection.credential.key ?? null : null,
    authToken: !new Headers(request.headers).has("x-api-key") && connection.credential.key !== undefined
      && new Headers(request.headers).get("authorization")?.startsWith("Bearer ") ? connection.credential.key : null,
  } : { apiKey: connection.credential.key }), baseURL: request.url.split(suffix)[0],
    defaultHeaders, dangerouslyAllowBrowser: true };
  if (model.api === "azure-openai-responses") {
    if (!request.azureConfiguration) throw new Error("Swift Azure configuration was not captured");
    Object.assign(config, request.azureConfiguration);
  }
  if (model.api === "google-generative-ai" || model.api === "google-vertex") {
    const client = connection.client ??= new GoogleGenAI(request.cloudConfiguration ?? { apiKey: options.apiKey,
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
    if (connection.federationClient) {
      expect(new Headers(request.headers).get("authorization")).toBe(connection.federationAuthorization);
      const headers = Object.fromEntries(Object.entries(defaultHeaders).filter(([name]) => name.toLowerCase() !== "authorization"));
      connection.client = connection.federationClient.withOptions({ defaultHeaders: headers });
    }
  }
  const client = connection.client ??= options.client ??
    (model.api === "anthropic-messages" ? new FixtureAnthropic(config) : new OpenAI(config));
  if (model.api === "anthropic-messages" && client.beta?.messages) {
    const response = await client.beta.messages.create(body, { signal: options.signal }).asResponse();
    return { status: response.status, headers: Object.fromEntries(response.headers), chunks: responseChunks(response, options.signal) };
  }
  const resource = model.api === "anthropic-messages" ? client.messages :
    ["openai-completions", "openrouter-images"].includes(model.api) ? client.chat.completions : client.responses;
  let reply;
  try {
    const pending = resource.create(body, { signal: options.signal, maxRetries: 0 });
    reply = typeof pending.withResponse === "function" ? await pending.withResponse() :
      { data: await pending, response: { status: 200, headers: new Headers() } };
  } catch (error) {
    if (!Number.isInteger(error.status)) throw error;
    return { status: error.status, headers: error.headers instanceof Headers ? Object.fromEntries(error.headers) : error.headers ?? {},
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
  const cancel = () => { void reader.cancel(signal.reason).catch(() => {}); };
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
const toolArgumentValues = new WeakMap();

function updateToolArguments(partial, update) {
  let calls = toolArgumentValues.get(partial);
  if (!calls) toolArgumentValues.set(partial, calls = new Map());
  let root = calls.get(update.id) ?? {};
  const decoded = units => units.reduce((text, unit) => text + String.fromCharCode(unit), "");
  for (const change of update.changes) {
    const [kind, value] = Object.entries(change)[0];
    const path = value.path.map(component => {
      const [kind, value] = Object.entries(component)[0];
      return kind === "keyUTF16" ? decoded(value._0) : value._0;
    });
    let parent = root;
    for (const key of path.slice(0, -1)) parent = parent[key];
    const key = path.at(-1);
    const replacement = kind === "set" ? value.value : (path.length ? parent[key] : root) + decoded(value.textUTF16);
    if (!path.length) root = replacement;
    else Object.defineProperty(parent, key, { value: replacement, writable: true, enumerable: true, configurable: true });
  }
  calls.set(update.id, root);
  const call = partial.content.find(block => block.type === "toolCall" && block.id === update.id);
  if (call) call.arguments = root;
}

function emit(event, partial, output) {
  const [type, data] = Object.entries(event)[0];
  const value = data._0;
  if (type === "toolArgumentsUpdate") {
    updateToolArguments(partial, value);
  } else if (type === "responseStarted") {
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
    const index = partial.content.push({ type: "toolCall", id: data.id, name: data.name,
      arguments: toolArgumentValues.get(partial)?.get(data.id) ?? {} }) - 1;
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
