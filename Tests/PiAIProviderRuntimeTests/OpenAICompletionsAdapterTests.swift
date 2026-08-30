import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct OpenAICompletionsAdapterTests {
  @Test
  func honorsModelCompatibilityAndNormalizesToolStream() async throws {
    let transport = CompletionsFixtureTransport(chunks: completionsFixtureChunks())
    let adapter = OpenAICompletionsAdapter()
    let model = ProviderModel(
      id: "deepseek-fixture",
      providerID: "deepseek",
      name: "DeepSeek Fixture",
      protocolID: "openai-completions",
      capabilities: ProviderCapabilities(
        textInput: true,
        imageInput: false,
        toolCalling: true,
        reasoning: true,
        structuredOutput: true,
        imageGeneration: false
      ),
      contextWindow: 100_000,
      maximumOutputTokens: 8_192
    )
    let context = WireProtocolContext(
      provider: ProviderDescriptor(
        id: "deepseek",
        name: "DeepSeek",
        authorizationMethods: [],
        models: [model]
      ),
      model: model,
      baseURL: URL(string: "https://api.deepseek.com")!,
      headers: [:],
      credential: .apiKey(APIKeyCredential(key: "fixture", metadata: [:])),
      modelConfiguration: ProviderModelConfiguration(
        protocolID: model.protocolID,
        baseURL: nil,
        headers: [:],
        metadata: [
          "compat": .object([
            "maxTokensField": .string("max_tokens"),
            "supportsStore": .bool(false),
            "supportsReasoningEffort": .bool(false),
          ])
        ]
      )
    )
    let request = ProviderRequest(
      id: "request",
      providerID: "deepseek",
      modelID: model.id,
      messages: [.system("system"), .user([.text("hello")])],
      tools: [
        ProviderToolDefinition(
          name: "weather",
          description: "Weather",
          inputSchema: .object(["type": .string("object")])
        )
      ],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 100,
        temperature: 0.1,
        reasoningEffort: "high",
        responseSchema: nil,
        providerOptions: [:]
      )
    )
    var events: [ProviderEvent] = []
    for try await event in adapter.stream(request, context: context, transport: transport) {
      events.append(event)
    }
    #expect(events.contains(.textDelta("hello")))
    #expect(events.contains(.reasoningDelta("think")))
    #expect(events.contains(.toolCallStarted(id: "call-1", name: "weather")))
    #expect(
      events.contains(
        .toolCallCompleted(
          ProviderToolCall(
            id: "call-1",
            name: "weather",
            arguments: .object(["city": .string("Taipei")])
          )
        )
      )
    )
    #expect(events.last == .completed(.toolCalls))

    let sent = try #require(await transport.request())
    #expect(sent.url?.absoluteString == "https://api.deepseek.com/chat/completions")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(body.int("max_tokens") == 100)
    #expect(body["max_completion_tokens"] == nil)
    #expect(body["store"] == nil)
    #expect(body["reasoning_effort"] == nil)
  }

  @Test
  func rejectsStreamWithoutDoneSentinel() async {
    let adapter = OpenAICompletionsAdapter()
    let (request, context) = completionFixtureRequestAndContext()
    await #expect(throws: ProviderRuntimeFailure.self) {
      for try await _ in adapter.stream(
        request,
        context: context,
        transport: CompletionsFixtureTransport(
          chunks: [
            Data(
              #"data: {"id":"x","model":"m","choices":[]}"#.utf8
            )
          ]
        )
      ) {}
    }
  }
}

private actor CompletionsFixtureTransport: ProviderHTTPStreamingTransport {
  private let chunks: [Data]
  private var captured: URLRequest?

  init(chunks: [Data]) { self.chunks = chunks }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    let chunks = self.chunks
    return ProviderHTTPStreamingResponse(
      statusCode: 200,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      }
    )
  }

  func request() -> URLRequest? { captured }
}

private func completionsFixtureChunks() -> [Data] {
  let lines =
    [
      #"data: {"id":"chat-1","model":"deepseek-fixture","choices":[{"delta":{"content":"hello","reasoning_content":"think","tool_calls":[{"index":0,"id":"call-1","function":{"name":"weather","arguments":"{\"city\":"}}]},"finish_reason":null}]}"#,
      #"data: {"id":"chat-1","model":"deepseek-fixture","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Taipei\"}"}}]},"finish_reason":"tool_calls"}]}"#,
      #"data: {"id":"chat-1","model":"deepseek-fixture","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":1},"completion_tokens_details":{"reasoning_tokens":1}}}"#,
      "data: [DONE]",
    ].joined(separator: "\n\n") + "\n\n"
  let bytes = Array(lines.utf8)
  return [Data(bytes[..<91]), Data(bytes[91..<317]), Data(bytes[317...])]
}

private func completionFixtureRequestAndContext() -> (
  ProviderRequest, WireProtocolContext
) {
  let model = ProviderModel(
    id: "m",
    providerID: "p",
    name: "M",
    protocolID: "openai-completions",
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: false,
      toolCalling: true,
      reasoning: false,
      structuredOutput: false,
      imageGeneration: false
    ),
    contextWindow: 1_000,
    maximumOutputTokens: 100
  )
  return (
    ProviderRequest(
      id: "r",
      providerID: "p",
      modelID: "m",
      messages: [.user([.text("hi")])],
      tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: nil,
        temperature: nil,
        reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: [:]
      )
    ),
    WireProtocolContext(
      provider: ProviderDescriptor(
        id: "p",
        name: "P",
        authorizationMethods: [],
        models: [model]
      ),
      model: model,
      baseURL: URL(string: "https://fixture.invalid")!,
      headers: [:],
      credential: .apiKey(APIKeyCredential(key: "k", metadata: [:])),
      modelConfiguration: ProviderModelConfiguration(
        protocolID: model.protocolID,
        baseURL: nil,
        headers: [:],
        metadata: [:]
      )
    )
  )
}
