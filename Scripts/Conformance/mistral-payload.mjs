const payloadFields = [
  ["topP", "top_p"], ["maxTokens", "max_tokens"], ["randomSeed", "random_seed"],
  ["responseFormat", "response_format"], ["toolChoice", "tool_choice"],
  ["presencePenalty", "presence_penalty"], ["frequencyPenalty", "frequency_penalty"],
  ["parallelToolCalls", "parallel_tool_calls"], ["reasoningEffort", "reasoning_effort"],
  ["promptMode", "prompt_mode"], ["promptCacheKey", "prompt_cache_key"], ["safePrompt", "safe_prompt"],
];
const contentFields = [
  ["imageUrl", "image_url"], ["documentUrl", "document_url"], ["documentName", "document_name"],
  ["fileId", "file_id"], ["referenceIds", "reference_ids"], ["inputAudio", "input_audio"],
];

function remap(value, fields, sdk) {
  const result = { ...value };
  for (const [camel, snake] of fields) {
    const from = sdk ? snake : camel;
    if (Object.hasOwn(result, from)) {
      result[sdk ? camel : snake] = result[from];
      delete result[from];
    }
  }
  return result;
}

function project(payload, sdk) {
  const result = remap(payload, payloadFields, sdk);
  result.messages = payload.messages.map(message => {
    const value = remap(message, [["toolCalls", "tool_calls"], ["toolCallId", "tool_call_id"]], sdk);
    if (Array.isArray(message.content)) value.content = message.content.map(part => remap(part, contentFields, sdk));
    return value;
  });
  const formatKey = sdk ? "responseFormat" : "response_format";
  const schemaKey = sdk ? "jsonSchema" : "json_schema";
  if (result[formatKey] && typeof result[formatKey] === "object" && !Array.isArray(result[formatKey])) {
    result[formatKey] = remap(result[formatKey], [["jsonSchema", "json_schema"]], sdk);
    if (result[formatKey][schemaKey] && typeof result[formatKey][schemaKey] === "object" && !Array.isArray(result[formatKey][schemaKey])) {
      result[formatKey][schemaKey] = remap(result[formatKey][schemaKey], [["schemaDefinition", "schema"]], sdk);
    }
  }
  return result;
}

export const mistralSDKPayload = payload => project(payload, true);
export const mistralWirePayload = payload => project(payload, false);
