import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct OpenAICompletionsAdapterTests {
  @Test
  func reasoningFormatsEncodeOffAndMappedEffort() async throws {
    for format in [
      "openai", "openrouter", "deepseek", "zai", "qwen", "qwen-chat-template", "together",
      "string-thinking", "ant-ling", "chat-template", "baseten",
    ] {
      for effort in [ProviderReasoningEffort.off, .low] {
        let transport = CompletionsFixtureTransport(chunks: completionsFixtureChunks())
        let (request, context) = completionFixtureRequestAndContext(
          effort: effort,
          metadata: [
            "thinkingLevelMap": .object(["off": .string("none"), "low": .string("high")]),
            "compat": .object([
              "thinkingFormat": .string(format),
              "chatTemplateKwargs": .object([
                "enabled": .object(["$var": .string("thinking.enabled")]),
                "level": .object(["$var": .string("thinking.level")]),
              ]),
              "chatTemplateArgs": .object([
                "enabled": .object(["$var": .string("thinking.enabled")]),
                "level": .object(["$var": .string("thinking.level")]),
              ]),
            ]),
          ])
        for try await _ in OpenAICompletionsAdapter().stream(
          request, context: context, transport: transport)
        {}
        let sent = try #require(await transport.request())
        let body = try decodeJSONObject(
          try #require(sent.httpBody), providerID: "fixture", operation: "fixture")
        let enabled = effort != .off
        let wire = enabled ? "high" : "none"
        switch format {
        case "openai": #expect(body.string("reasoning_effort") == wire)
        case "openrouter", "ant-ling": #expect(body.object("reasoning")?.string("effort") == wire)
        case "deepseek", "zai":
          #expect(body.object("thinking")?.string("type") == (enabled ? "enabled" : "disabled"))
        case "qwen": #expect(body.bool("enable_thinking") == enabled)
        case "qwen-chat-template":
          #expect(body.object("chat_template_kwargs")?.bool("enable_thinking") == enabled)
        case "together": #expect(body.object("reasoning")?.bool("enabled") == enabled)
        case "string-thinking": #expect(body.string("thinking") == wire)
        default:
          let template = body.object(
            format == "baseten" ? "chat_template_args" : "chat_template_kwargs")
          #expect(template?.bool("enabled") == enabled)
          #expect(template?.string("level") == wire)
        }
      }
    }
  }

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
            "thinkingFormat": .string("deepseek"),
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
        reasoningEffort: .high,
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
    #expect(body.object("thinking")?.string("type") == "enabled")
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

private func completionFixtureRequestAndContext(
  effort: ProviderReasoningEffort? = nil, metadata: [String: JSONValue] = [:]
) -> (
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
      reasoning: true,
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
        reasoningEffort: effort,
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
        metadata: metadata
      )
    )
  )
}
