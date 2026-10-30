function contentBlock(block) {
  if (typeof block.reasoningContent?.redactedContent === "string") {
    return { ...block, reasoningContent: { ...block.reasoningContent,
      redactedContent: new Uint8Array(Buffer.from(block.reasoningContent.redactedContent, "base64")) } };
  }
  if (typeof block.image?.source?.bytes === "string") {
    return { ...block, image: { ...block.image, source: { ...block.image.source,
      bytes: new Uint8Array(Buffer.from(block.image.source.bytes, "base64")) } } };
  }
  if (block.toolResult) {
    return { ...block, toolResult: { ...block.toolResult,
      content: block.toolResult.content.map(contentBlock) } };
  }
  return block;
}

export function bedrockSDKPayload(body) {
  return { ...body, messages: body.messages.map(message => ({ ...message,
    content: message.content.map(contentBlock) })) };
}
