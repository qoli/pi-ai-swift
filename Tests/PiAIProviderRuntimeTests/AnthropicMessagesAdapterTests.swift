import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct AnthropicMessagesAdapterTests {
  @Test
  func encodesKimiRequestAndNormalizesTextToolUsageAndTerminalEvents() async throws {
    let transport = AnthropicFixtureTransport(
      chunks: anthropicFixtureChunks(),
      statusCode: 200
    )
    let adapter = AnthropicMessagesAdapter()
    let request = ProviderRequest(
      id: "request-1",
      providerID: "kimi-coding",
      modelID: "k3-256k",
      messages: [
        .system("Be concise"),
        .user([.text("Use the weather tool")]),
      ],
      tools: [
        ProviderToolDefinition(
          name: "weather",
          description: "Read weather",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
              "city": .object(["type": .string("string")])
            ]),
          ])
        )
      ],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 512,
        temperature: 0.2,
        reasoningEffort: "high",
        responseSchema: nil,
        providerOptions: [:]
      )
    )
    let model = ProviderModel(
      id: "k3-256k",
      providerID: "kimi-coding",
      name: "Kimi K3 256K",
      protocolID: "anthropic-messages",
      capabilities: ProviderCapabilities(
        textInput: true,
        imageInput: true,
        toolCalling: true,
        reasoning: true,
        structuredOutput: false,
        imageGeneration: false
      ),
      contextWindow: 262_144,
      maximumOutputTokens: 32_768
    )
    let context = WireProtocolContext(
      provider: ProviderDescriptor(
        id: "kimi-coding",
        name: "Kimi For Coding",
        authorizationMethods: [],
        models: [model]
      ),
      model: model,
      baseURL: URL(string: "https://api.kimi.com/coding")!,
      headers: [:],
      credential: .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:])),
      modelConfiguration: ProviderModelConfiguration(
        protocolID: model.protocolID,
        baseURL: nil,
        headers: [:],
        metadata: [:]
      )
    )

    var events: [ProviderEvent] = []
    for try await event in adapter.stream(request, context: context, transport: transport) {
      events.append(event)
    }

    #expect(events.count == 8)
    #expect(events[1] == .textDelta("Checking"))
    #expect(events[2] == .toolCallStarted(id: "tool-1", name: "weather"))
    #expect(events[3] == .toolInputDelta(id: "tool-1", delta: "{\"city\":\"Tai"))
    #expect(events[4] == .toolInputDelta(id: "tool-1", delta: "pei\"}"))
    #expect(
      events[5]
        == .toolCallCompleted(
          ProviderToolCall(
            id: "tool-1",
            name: "weather",
            arguments: .object(["city": .string("Taipei")])
          )
        )
    )
    #expect(events[7] == .completed(.toolCalls))

    let sent = try #require(await transport.request())
    #expect(sent.url?.absoluteString == "https://api.kimi.com/coding/v1/messages")
    #expect(sent.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
    #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(body.string("model") == "k3-256k")
    #expect(body.int("max_tokens") == 512)
    #expect(body.object("thinking")?.string("type") == "adaptive")
    #expect(body.object("output_config")?.string("effort") == "high")
  }

  @Test
  func rejectsHTTPFailureAndMissingTerminalEvent() async {
    let adapter = AnthropicMessagesAdapter()
    let model = fixtureAnthropicModel()
    let context = fixtureAnthropicContext(model: model)
    let request = fixtureAnthropicRequest()

    await #expect(throws: ProviderRuntimeFailure.self) {
      for try await _ in adapter.stream(
        request,
        context: context,
        transport: AnthropicFixtureTransport(
          chunks: [Data("{\"error\":\"denied\"}".utf8)],
          statusCode: 401
        )
      ) {}
    }

    await #expect(throws: ProviderRuntimeFailure.self) {
      for try await _ in adapter.stream(
        request,
        context: context,
        transport: AnthropicFixtureTransport(
          chunks: [Data("data: {\"type\":\"ping\"}\n\n".utf8)],
          statusCode: 200
        )
      ) {}
    }
  }
}

private actor AnthropicFixtureTransport: ProviderHTTPStreamingTransport {
  private let chunks: [Data]
  private let statusCode: Int
  private var capturedRequest: URLRequest?

  init(chunks: [Data], statusCode: Int) {
    self.chunks = chunks
    self.statusCode = statusCode
  }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    capturedRequest = request
    let chunks = self.chunks
    return ProviderHTTPStreamingResponse(
      statusCode: statusCode,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      }
    )
  }

  func request() -> URLRequest? { capturedRequest }
}

private func anthropicFixtureChunks() -> [Data] {
  let stream =
    [
      #"data: {"type":"message_start","message":{"id":"message-1","model":"k3-256k","usage":{"input_tokens":12,"output_tokens":0,"cache_read_input_tokens":2}}}"#,
      #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking"}}"#,
      #"data: {"type":"content_block_stop","index":0}"#,
      #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool-1","name":"weather","input":{}}}"#,
      #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Tai"}}"#,
      #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"pei\"}"}}"#,
      #"data: {"type":"content_block_stop","index":1}"#,
      #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":8}}"#,
      #"data: {"type":"message_stop"}"#,
    ].joined(separator: "\n\n") + "\n\n"
  let bytes = Array(stream.utf8)
  return [
    Data(bytes[0..<37]),
    Data(bytes[37..<211]),
    Data(bytes[211..<517]),
    Data(bytes[517...]),
  ]
}

private func fixtureAnthropicModel() -> ProviderModel {
  ProviderModel(
    id: "fixture-model",
    providerID: "fixture-provider",
    name: "Fixture",
    protocolID: "anthropic-messages",
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: true,
      reasoning: true,
      structuredOutput: false,
      imageGeneration: false
    ),
    contextWindow: 100_000,
    maximumOutputTokens: 4_096
  )
}

private func fixtureAnthropicContext(model: ProviderModel) -> WireProtocolContext {
  WireProtocolContext(
    provider: ProviderDescriptor(
      id: "fixture-provider",
      name: "Fixture",
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: URL(string: "https://fixture.invalid")!,
    headers: [:],
    credential: .apiKey(APIKeyCredential(key: "fixture", metadata: [:])),
    modelConfiguration: ProviderModelConfiguration(
      protocolID: model.protocolID,
      baseURL: nil,
      headers: [:],
      metadata: [:]
    )
  )
}

private func fixtureAnthropicRequest() -> ProviderRequest {
  ProviderRequest(
    id: "request",
    providerID: "fixture-provider",
    modelID: "fixture-model",
    messages: [.user([.text("hello")])],
    tools: [],
    options: ProviderGenerationOptions(
      maximumOutputTokens: nil,
      temperature: nil,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: [:]
    )
  )
}
