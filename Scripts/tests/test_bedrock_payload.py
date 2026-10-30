from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BedrockPayloadTests(unittest.TestCase):
    def test_sdk_binary_fields_are_decoded_without_changing_tool_arguments(self):
        subprocess.run(["node", "--input-type=module", "-e", """
import assert from 'node:assert/strict';
import { bedrockSDKPayload } from './Scripts/Conformance/bedrock-payload.mjs';
const bytes = new Uint8Array([0, 255, 128, 65]);
const encoded = Buffer.from(bytes).toString('base64');
const image = { image: { format: 'png', source: { bytes: encoded } } };
const argumentsValue = { bytes: encoded, redactedContent: encoded };
const input = { messages: [{ role: 'assistant', content: [
  { reasoningContent: { redactedContent: encoded } },
  { toolUse: { input: argumentsValue } }, image,
  { toolResult: { content: [image, { text: encoded }] } },
] }] };
const output = bedrockSDKPayload(input).messages[0].content;
assert.deepEqual(output[0].reasoningContent.redactedContent, bytes);
assert.deepEqual(output[2].image.source.bytes, bytes);
assert.deepEqual(output[3].toolResult.content[0].image.source.bytes, bytes);
assert.deepEqual(output[1].toolUse.input, argumentsValue);
assert.equal(output[3].toolResult.content[1].text, encoded);
assert.equal(input.messages[0].content[0].reasoningContent.redactedContent, encoded);
"""], cwd=ROOT, check=True, capture_output=True, text=True)

    def test_sdk_payloads_with_existing_byte_arrays_keep_them(self):
        subprocess.run(["node", "--input-type=module", "-e", """
import assert from 'node:assert/strict';
import { bedrockSDKPayload } from './Scripts/Conformance/bedrock-payload.mjs';
const bytes = new Uint8Array([1, 2, 3]);
const input = { messages: [{ role: 'assistant', content: [
  { reasoningContent: { redactedContent: bytes } },
] }] };
assert.equal(bedrockSDKPayload(input).messages[0].content[0].reasoningContent.redactedContent, bytes);
"""], cwd=ROOT, check=True, capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
