#!/usr/bin/env node

import http from "node:http";
import { createRequire } from "node:module";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import path from "node:path";

const [upstreamRoot, failureCasePath, requestCasePath] = process.argv.slice(2);
if (!upstreamRoot || !failureCasePath || !requestCasePath) {
  throw new Error(
    "usage: pi-ai-failure-oracle.mjs UPSTREAM_ROOT FAILURE_CASE REQUEST_CASE",
  );
}

const failureCase = JSON.parse(await readFile(failureCasePath, "utf8"));
const requestCase = JSON.parse(await readFile(requestCasePath, "utf8"));
if (failureCase.schemaVersion !== 1 || requestCase.schemaVersion !== 1) {
  throw new Error("unsupported differential case schema");
}
if (failureCase.protocolsFrom !== requestCase.caseID) {
  throw new Error("failure case protocol inventory does not match request case");
}

const results = {};
for (const protocol of requestCase.protocols) {
  results[protocol.protocolID] = await captureFailure(protocol);
}

process.stdout.write(`${JSON.stringify({
  schemaVersion: 1,
  caseID: failureCase.caseID,
  category: failureCase.expectedCategory,
  protocols: results,
}, null, 2)}\n`);

async function captureFailure(protocol) {
  if (failureCase.stimulusKind === "cancellation") {
    return captureCancellation(protocol);
  }
  const decoderInput = failureInput(protocol.protocolID);
  if (decoderInput === null) {
    return { outcome: "notApplicable", decoderInput: null };
  }
  if (protocol.protocolID === "bedrock-converse-stream") {
    return captureBedrockFailure(protocol, decoderInput);
  }
  if (protocol.protocolID === "openrouter-images") {
    return captureImageFailure(protocol, decoderInput);
  }

  const implementation = await import(
    pathToFileURL(path.join(
      upstreamRoot,
      "packages/ai/src/api",
      `${protocol.protocolID}.ts`,
    )).href
  );
  const fetch = failureFetch(protocol.protocolID, decoderInput);
  const priorFetch = globalThis.fetch;
  if (["google-generative-ai", "google-vertex"].includes(protocol.protocolID)) {
    globalThis.fetch = fetch;
  }
  try {
    const stream = implementation.streamSimple(
      textModel(protocol),
      { messages: [{ role: "user", content: "fixture", timestamp: 0 }] },
      streamOptions(protocol, fetch),
    );
    const events = [];
    for await (const event of stream) {
      events.push(structuredClone(event));
    }
    const terminal = events.at(-1);
    if (terminal?.type !== "error" || terminal.reason !== "error") {
      throw new Error(`${protocol.protocolID} did not surface an error terminal`);
    }
    if (!terminal.error?.errorMessage) {
      throw new Error(`${protocol.protocolID} omitted its source error message`);
    }
    return {
      outcome: "failure",
      decoderInput,
      sourceTerminal: { type: terminal.type, reason: terminal.reason },
      partialEventTypes: canonicalPartialEventTypes(events.slice(0, -1)),
    };
  } finally {
    globalThis.fetch = priorFetch;
  }
}

async function captureCancellation(protocol) {
  const controller = new AbortController();
  controller.abort();
  const abortError = () => new DOMException("The operation was aborted", "AbortError");
  const fetch = async () => { throw abortError(); };
  if (protocol.protocolID === "openrouter-images") {
    const implementation = await import(
      pathToFileURL(path.join(upstreamRoot, "packages/ai/src/api/openrouter-images.ts")).href
    );
    const result = await implementation.generateImages(
      { ...textModel(protocol), output: protocol.output ?? ["image"] },
      { input: [{ type: "text", text: "fixture" }] },
      { apiKey: "fixture-key", maxRetries: 0, signal: controller.signal, fetch },
    );
    if (result.stopReason !== "aborted" || !result.errorMessage) {
      throw new Error("openrouter-images did not surface aborted cancellation");
    }
    return {
      outcome: "failure",
      decoderInput: null,
      sourceTerminal: { type: "error", reason: result.stopReason },
      partialEventTypes: [],
    };
  }

  const implementation = await import(
    pathToFileURL(path.join(upstreamRoot, "packages/ai/src/api", `${protocol.protocolID}.ts`)).href
  );
  const options = streamOptions(protocol, fetch);
  options.signal = controller.signal;
  options.env = {
    ...options.env,
    AWS_BEDROCK_FORCE_HTTP1: "1",
    AWS_BEDROCK_SKIP_AUTH: "1",
    AWS_REGION: "us-east-1",
  };
  const priorFetch = globalThis.fetch;
  if (["google-generative-ai", "google-vertex"].includes(protocol.protocolID)) {
    globalThis.fetch = fetch;
  }
  try {
    const stream = implementation.streamSimple(
      textModel(protocol),
      { messages: [{ role: "user", content: "fixture", timestamp: 0 }] },
      options,
    );
    const events = [];
    for await (const event of stream) events.push(structuredClone(event));
    const terminal = events.at(-1);
    if (terminal?.type !== "error" || terminal.reason !== "aborted") {
      throw new Error(`${protocol.protocolID} did not surface aborted cancellation`);
    }
    return {
      outcome: "failure",
      decoderInput: null,
      sourceTerminal: { type: terminal.type, reason: terminal.reason },
      partialEventTypes: canonicalPartialEventTypes(events.slice(0, -1)),
    };
  } finally {
    globalThis.fetch = priorFetch;
  }
}

async function captureImageFailure(protocol, decoderInput) {
  const implementation = await import(
    pathToFileURL(path.join(upstreamRoot, "packages/ai/src/api/openrouter-images.ts")).href
  );
  const result = await implementation.generateImages(
    {
      ...textModel(protocol),
      output: protocol.output ?? ["image"],
    },
    { input: [{ type: "text", text: "fixture" }] },
    { apiKey: "fixture-key", maxRetries: 0, fetch: failureFetch(protocol.protocolID, decoderInput) },
  );
  if (result.stopReason !== "error" || !result.errorMessage) {
    throw new Error("openrouter-images did not surface an error result");
  }
  return {
    outcome: "failure",
    decoderInput,
    sourceTerminal: { type: "error", reason: result.stopReason },
    partialEventTypes: [],
  };
}

async function captureBedrockFailure(protocol, decoderInput) {
  const server = http.createServer((request, response) => {
    request.resume();
    request.on("end", () => {
      response.writeHead(decoderInput.status, decoderInput.headers);
      for (const value of decoderInput.chunksBase64 ?? []) {
        response.write(Buffer.from(value, "base64"));
      }
      if (decoderInput.rawBodyBase64) {
        response.write(Buffer.from(decoderInput.rawBodyBase64, "base64"));
      }
      if (decoderInput.body !== undefined) response.write(JSON.stringify(decoderInput.body));
      response.end();
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  try {
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("invalid loopback address");
    const implementation = await import(
      pathToFileURL(path.join(
        upstreamRoot,
        "packages/ai/src/api/bedrock-converse-stream.ts",
      )).href
    );
    const model = { ...textModel(protocol), baseUrl: `http://127.0.0.1:${address.port}` };
    const stream = implementation.streamSimple(
      model,
      { messages: [{ role: "user", content: "fixture", timestamp: 0 }] },
      {
        maxRetries: 0,
        env: {
          AWS_BEDROCK_FORCE_HTTP1: "1",
          AWS_BEDROCK_SKIP_AUTH: "1",
          AWS_REGION: "us-east-1",
        },
      },
    );
    const events = [];
    for await (const event of stream) events.push(structuredClone(event));
    const terminal = events.at(-1);
    if (terminal?.type !== "error" || terminal.reason !== "error") {
      throw new Error("bedrock-converse-stream did not surface an error terminal");
    }
    return {
      outcome: "failure",
      decoderInput,
      sourceTerminal: { type: terminal.type, reason: terminal.reason },
      partialEventTypes: canonicalPartialEventTypes(events.slice(0, -1)),
    };
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

function failureFetch(protocolID, decoderInput) {
  return async (input) => {
    const url = String(input);
    if (protocolID === "openai-codex-responses") {
      if (url === "https://api.github.com/repos/openai/codex/releases/latest") {
        return new Response(JSON.stringify({ tag_name: "rust-v0.0.0" }), { status: 200 });
      }
      if (url.startsWith("https://raw.githubusercontent.com/openai/codex/")) {
        return new Response("FIXTURE PROMPT", { status: 200, headers: { etag: '"fixture"' } });
      }
    }
    const body = decoderInput.rawBodyBase64
      ? Buffer.from(decoderInput.rawBodyBase64, "base64")
      : decoderInput.chunksBase64
        ? new ReadableStream({
          start(controller) {
            decoderInput.chunksBase64.forEach((value) => controller.enqueue(Buffer.from(value, "base64")));
            controller.close();
          },
        })
        : JSON.stringify(decoderInput.body);
    return new Response(body, {
      status: decoderInput.status,
      headers: decoderInput.headers,
    });
  };
}

function failureInput(protocolID) {
  if (failureCase.stimulusKind === "httpStatus") {
    return {
      kind: "http-json",
      status: failureCase.stimulus.status,
      headers: failureCase.stimulus.headers,
      body: failureCase.stimulus.body,
    };
  }
  if (failureCase.stimulusKind === "malformedWire") {
    if (protocolID === "bedrock-converse-stream") {
      return {
        kind: "aws-eventstream",
        status: 200,
        headers: {
          "content-type": "application/vnd.amazon.eventstream",
          "x-amzn-requestid": "bedrock-failure",
        },
        chunksBase64: [Buffer.from([0, 0, 0, 8, 0, 0, 0, 0]).toString("base64")],
      };
    }
    const raw = Buffer.from("data: {not-json}\n\n").toString("base64");
    return {
      kind: protocolID === "openrouter-images" ? "http-json" : "http-sse",
      status: 200,
      headers: {
        "content-type": protocolID === "openrouter-images"
          ? "application/json"
          : "text/event-stream",
      },
      rawBodyBase64: protocolID === "openrouter-images"
        ? Buffer.from("{not-json").toString("base64")
        : raw,
    };
  }
  if (failureCase.stimulusKind === "missingTerminal") {
    if (protocolID === "openrouter-images") return null;
    if (protocolID === "bedrock-converse-stream") {
      return {
        kind: "aws-eventstream",
        status: 200,
        headers: {
          "content-type": "application/vnd.amazon.eventstream",
          "x-amzn-requestid": "bedrock-failure",
        },
        chunksBase64: [encodeAWSEvent("messageStart", { role: "assistant" }).toString("base64")],
      };
    }
    const record = missingTerminalRecord(protocolID);
    return {
      kind: "http-sse",
      status: 200,
      headers: { "content-type": "text/event-stream" },
      rawBodyBase64: Buffer.from(`${record}\n\n`).toString("base64"),
    };
  }
  if (failureCase.stimulusKind === "providerDeclaredError") {
    if (protocolID === "bedrock-converse-stream") {
      return {
        kind: "aws-eventstream",
        status: 200,
        headers: {
          "content-type": "application/vnd.amazon.eventstream",
          "x-amzn-requestid": "bedrock-failure",
        },
        chunksBase64: [encodeAWSException(
          "modelStreamErrorException",
          { message: "fixture provider stream error" },
        ).toString("base64")],
      };
    }
    if (protocolID === "openrouter-images") {
      return {
        kind: "http-json",
        status: 200,
        headers: { "content-type": "application/json" },
        body: { error: { code: "fixture_error", message: "fixture provider error" } },
      };
    }
    return {
      kind: "http-sse",
      status: 200,
      headers: { "content-type": "text/event-stream" },
      rawBodyBase64: Buffer.from(`${providerErrorRecord(protocolID)}\n\n`).toString("base64"),
    };
  }
  throw new Error(`unsupported failure stimulus: ${failureCase.stimulusKind}`);
}

function providerErrorRecord(protocolID) {
  if (protocolID === "anthropic-messages") {
    return `event: error\ndata: ${JSON.stringify({ type: "error", error: { type: "overloaded_error", message: "fixture provider error" } })}`;
  }
  if (protocolID === "openai-completions") {
    return `data: ${JSON.stringify({ id: "failure", model: "fixture", choices: [{ delta: {}, finish_reason: "content_filter" }] })}`;
  }
  if (["openai-responses", "azure-openai-responses", "openai-codex-responses"].includes(protocolID)) {
    return `data: ${JSON.stringify({ type: "response.failed", response: { id: "failure", status: "failed", error: { code: "fixture_error", message: "fixture provider error" } } })}`;
  }
  if (protocolID === "google-generative-ai" || protocolID === "google-vertex") {
    return `data: ${JSON.stringify({ responseId: "failure", candidates: [{ finishReason: "SAFETY" }] })}`;
  }
  if (protocolID === "mistral-conversations") {
    return `data: ${JSON.stringify({ id: "failure", choices: [{ delta: {}, finish_reason: "error" }] })}`;
  }
  if (protocolID === "pi-messages") {
    return `data: ${JSON.stringify({ type: "start" })}\n\ndata: ${JSON.stringify({ type: "error", reason: "error", errorMessage: "fixture provider error" })}`;
  }
  throw new Error(`no provider-declared error stimulus for ${protocolID}`);
}

function missingTerminalRecord(protocolID) {
  if (protocolID === "anthropic-messages") {
    return `event: message_start\ndata: ${JSON.stringify({ type: "message_start", message: { id: "partial", model: "fixture", usage: { input_tokens: 1, output_tokens: 0 } } })}`;
  }
  if (protocolID === "openai-completions" || protocolID === "mistral-conversations") {
    return `data: ${JSON.stringify({ id: "partial", model: "fixture", choices: [{ delta: { content: "partial" }, finish_reason: null }] })}`;
  }
  if (["openai-responses", "azure-openai-responses", "openai-codex-responses"].includes(protocolID)) {
    return `data: ${JSON.stringify({ type: "response.created", response: { id: "partial", model: "fixture" } })}`;
  }
  if (protocolID === "google-generative-ai" || protocolID === "google-vertex") {
    return `data: ${JSON.stringify({ responseId: "partial", candidates: [{ content: { parts: [{ text: "partial" }] } }] })}`;
  }
  if (protocolID === "pi-messages") {
    return `data: ${JSON.stringify({ type: "start" })}`;
  }
  throw new Error(`no missing-terminal stimulus for ${protocolID}`);
}

function encodeAWSEvent(eventType, payload) {
  const require = createRequire(path.resolve(upstreamRoot, "package.json"));
  const { EventStreamCodec } = require("@smithy/core/event-streams");
  const codec = new EventStreamCodec(
    (bytes) => new TextDecoder().decode(bytes),
    (value) => new TextEncoder().encode(value),
  );
  return Buffer.from(codec.encode({
    headers: {
      ":message-type": { type: "string", value: "event" },
      ":event-type": { type: "string", value: eventType },
      ":content-type": { type: "string", value: "application/json" },
    },
    body: new TextEncoder().encode(JSON.stringify(payload)),
  }));
}

function encodeAWSException(exceptionType, payload) {
  const require = createRequire(path.resolve(upstreamRoot, "package.json"));
  const { EventStreamCodec } = require("@smithy/core/event-streams");
  const codec = new EventStreamCodec(
    (bytes) => new TextDecoder().decode(bytes),
    (value) => new TextEncoder().encode(value),
  );
  return Buffer.from(codec.encode({
    headers: {
      ":message-type": { type: "string", value: "exception" },
      ":exception-type": { type: "string", value: exceptionType },
      ":content-type": { type: "string", value: "application/json" },
    },
    body: new TextEncoder().encode(JSON.stringify(payload)),
  }));
}

function streamOptions(protocol, fetch) {
  const options = {
    apiKey: credential(protocol),
    maxRetries: 0,
    transport: "sse",
    env: {
      GOOGLE_CLOUD_PROJECT: "fixture-project",
      GOOGLE_CLOUD_LOCATION: "us-central1",
    },
  };
  if (["google-generative-ai", "google-vertex"].includes(protocol.protocolID)) {
    options.fetch = globalThis.fetch;
  } else {
    options.fetch = fetch;
  }
  return options;
}

function canonicalPartialEventTypes(events) {
  const names = [];
  for (const event of events) {
    switch (event.type) {
      case "start": break;
      case "text_delta": names.push("textDelta"); break;
      case "thinking_delta": names.push("reasoningDelta"); break;
      case "toolcall_start": names.push("toolCallStarted"); break;
      case "toolcall_delta": names.push("toolInputDelta"); break;
      case "toolcall_end": names.push("toolCallCompleted"); break;
      default: break;
    }
  }
  return names;
}

function textModel(protocol) {
  return {
    id: protocol.modelID,
    name: protocol.modelID,
    api: protocol.protocolID,
    provider: protocol.providerID,
    baseUrl: protocol.baseURL,
    reasoning: protocol.reasoning,
    input: ["text", "image"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 262144,
    maxTokens: protocol.maximumOutputTokens,
    ...(protocol.compat ? { compat: protocol.compat } : {}),
  };
}

function credential(protocol) {
  if (protocol.protocolID !== "openai-codex-responses") return "fixture-key";
  const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url");
  const body = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: "fixture-account" },
  })).toString("base64url");
  return `${header}.${body}.fixture`;
}
