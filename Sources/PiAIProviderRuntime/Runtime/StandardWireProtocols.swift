enum StandardWireProtocols {
  static let supportedProtocolIDs = Set(make().map(\.protocolID))

  static func make() -> [any WireProtocolAdapter] {
    [
      AnthropicMessagesAdapter(),
      OpenAICompletionsAdapter(),
      OpenAIResponsesAdapter(),
      OpenAIResponsesAdapter(
        protocolID: "azure-openai-responses",
        flavor: .azure
      ),
      OpenAIResponsesAdapter(
        protocolID: "openai-codex-responses",
        flavor: .codex
      ),
      GoogleGenerativeAIAdapter(),
      GoogleGenerativeAIAdapter(
        protocolID: "google-vertex",
        flavor: .vertex
      ),
      MistralConversationsAdapter(),
      PiMessagesAdapter(),
      BedrockConverseStreamAdapter(),
      OpenRouterImagesAdapter(),
    ]
  }
}
