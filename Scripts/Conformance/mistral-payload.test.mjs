import assert from "node:assert/strict";
import test from "node:test";
import { mistralSDKPayload, mistralWirePayload } from "./mistral-payload.mjs";

test("Mistral fixture DTO projection preserves opaque schemas and arguments", () => {
  const schema = { type: "object", properties: { maxTokens: { type: "number" }, image_url: { type: "string" } } };
  const arguments_ = '{"toolCalls":"opaque"}';
  const wire = {
    model: "fixture", stream: true, max_tokens: 123, reasoning_effort: "high", prompt_cache_key: "session",
    messages: [
      { role: "user", content: [{ type: "image_url", image_url: "data:image/png;base64,aGk=" }] },
      { role: "assistant", tool_calls: [{ id: "call", function: { name: "lookup", arguments: arguments_ } }] },
      { role: "tool", tool_call_id: "call", content: "done" },
    ],
    tools: [{ type: "function", function: { name: "lookup", parameters: schema } }],
    response_format: { type: "json_schema", json_schema: { name: "result", schema } },
  };
  const original = structuredClone(wire);
  const sdk = mistralSDKPayload(wire);
  assert.equal(sdk.maxTokens, 123);
  assert.equal(sdk.reasoningEffort, "high");
  assert.equal(sdk.promptCacheKey, "session");
  assert.equal(sdk.messages[0].content[0].imageUrl, wire.messages[0].content[0].image_url);
  assert.equal(sdk.messages[1].toolCalls[0].function.arguments, arguments_);
  assert.deepEqual(sdk.tools[0].function.parameters, schema);
  assert.deepEqual(sdk.responseFormat.jsonSchema.schemaDefinition, schema);
  assert.deepEqual(mistralWirePayload(sdk), wire);
  assert.deepEqual(wire, original);
});

test("non-record response formats retain their original DTO shape", () => {
  const wire = { messages: [], response_format: [] };
  assert.deepEqual(mistralWirePayload(mistralSDKPayload(wire)), wire);
});
