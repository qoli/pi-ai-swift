import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct MistralConversationsAdapterTests {
  @Test
  func encodesConversationAndNormalizesTextReasoningToolUsageAndTerminal()
    async throws
  {
    let transport = MistralFixtureTransport(
      statusCode: 200,
      chunks: mistralSuccessChunks()
    )
    let adapter = MistralConversationsAdapter()
    let model = mistralFixtureModel()
    let request = ProviderRequest(
      id: "logical-request",
      providerID: "mistral",
      modelID: model.id,
      messages: [
        .system("Be precise"),
        .user([.text("Find the weather")]),
        .assistant([
          .toolCall(
            ProviderToolCall(
              id: "prior-call",
              name: "weather",
              arguments: .object(["city": .string("Paris")])
            ))
        ]),
        .toolResult(
          ProviderToolResult(
            toolCallID: "prior-call",
            toolName: "weather",
            content: [.text("sunny")],
            isError: false
          )),
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
        temperature: 0.25,
        reasoningEffort: "high",
        responseSchema: nil,
        providerOptions: [:]
      )
    )

    var events: [ProviderEvent] = []
    for try await event in adapter.stream(
      request,
      context: mistralFixtureContext(model: model),
      transport: transport
    ) {
      events.append(event)
    }

    #expect(
      events.first
        == .responseStarted(
          ProviderResponseMetadata(
            responseID: "mistral-response",
            providerID: "mistral",
            modelID: model.id,
            providerMetadata: [:]
          )))
    #expect(events.contains(.textDelta("Checking")))
    #expect(events.contains(.reasoningDelta("Need a lookup")))
    #expect(events.contains(.toolCallStarted(id: "call-1", name: "weather")))
    #expect(events.contains(.toolInputDelta(id: "call-1", delta: #"{"city":"Tai"#)))
    #expect(events.contains(.toolInputDelta(id: "call-1", delta: #"pei"}"#)))
    #expect(
      events.contains(
        .toolCallCompleted(
          ProviderToolCall(
            id: "call-1",
            name: "weather",
            arguments: .object(["city": .string("Taipei")])
          )))
    )
    #expect(
      events.contains(
        .usage(
          ProviderUsage(
            inputTokens: 9,
            outputTokens: 7,
            reasoningTokens: 2,
            cachedInputTokens: 3,
            providerMetadata: ["totalTokens": .integer(19)]
          )))
    )
    #expect(events.last == .completed(.toolCalls))

    let sent = try #require(await transport.request())
    #expect(sent.url?.absoluteString == "https://api.mistral.ai/v1/chat/completions")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(body.string("model") == model.id)
    #expect(body.int("max_tokens") == 512)
    #expect(body.string("prompt_mode") == "reasoning")
    #expect(body.array("tools")?.count == 1)
    let messages = try #require(body.array("messages"))
    #expect(messages.count == 4)
    #expect(messages.first?.objectValue?.string("role") == "system")
    #expect(messages[2].objectValue?.array("tool_calls")?.count == 1)
    #expect(messages[3].objectValue?.string("tool_call_id") == "prior-call")
  }

  @Test
  func failsExplicitlyForHTTPStreamAndMissingTerminalErrors() async {
    let adapter = MistralConversationsAdapter()
    let model = mistralFixtureModel()
    let request = mistralFixtureRequest(model: model)
    let context = mistralFixtureContext(model: model)

    await expectMistralFailure(code: .transportFailed) {
      adapter.stream(
        request,
        context: context,
        transport: MistralFixtureTransport(
          statusCode: 401,
          chunks: [Data(#"{"error":"denied"}"#.utf8)]
        )
      )
    }
    await expectMistralFailure(code: .transportFailed) {
      adapter.stream(
        request,
        context: context,
        transport: MistralFixtureTransport(
          statusCode: 200,
          chunks: [
            Data(
              #"data: {"error":{"message":"quota","code":"limit"}}"#.utf8
                + Data("\n\n".utf8)
            )
          ]
        )
      )
    }
    await expectMistralFailure(code: .invalidResponse) {
      adapter.stream(
        request,
        context: context,
        transport: MistralFixtureTransport(
          statusCode: 200,
          chunks: [
            Data(
              #"data: {"id":"response","choices":[{"delta":{"content":"partial"}}]}"#.utf8
                + Data("\n\n".utf8)
            )
          ]
        )
      )
    }
  }

  @Test
  func propagatesCancellationWithoutSubstituteOutput() async {
    let adapter = MistralConversationsAdapter()
    let model = mistralFixtureModel()
    do {
      for try await _ in adapter.stream(
        mistralFixtureRequest(model: model),
        context: mistralFixtureContext(model: model),
        transport: MistralCancellingTransport()
      ) {
        Issue.record("cancelled Mistral stream emitted an event")
      }
      Issue.record("cancelled Mistral stream completed successfully")
    } catch is CancellationError {
    } catch {
      Issue.record("unexpected cancellation error: \(error)")
    }
  }
}

private actor MistralFixtureTransport: ProviderHTTPStreamingTransport {
  private let statusCode: Int
  private let chunks: [Data]
  private var captured: URLRequest?

  init(statusCode: Int, chunks: [Data]) {
    self.statusCode = statusCode
    self.chunks = chunks
  }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
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

  func request() -> URLRequest? { captured }
}

private struct MistralCancellingTransport: ProviderHTTPStreamingTransport {
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    ProviderHTTPStreamingResponse(
      statusCode: 200,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.finish(throwing: CancellationError())
      }
    )
  }
}

private func mistralFixtureModel() -> ProviderModel {
  ProviderModel(
    id: "magistral-small",
    providerID: "mistral",
    name: "Magistral Small",
    protocolID: "mistral-conversations",
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: false,
      toolCalling: true,
      reasoning: true,
      structuredOutput: false,
      imageGeneration: false
    ),
    contextWindow: 128_000,
    maximumOutputTokens: 128_000
  )
}

private func mistralFixtureContext(model: ProviderModel) -> WireProtocolContext {
  WireProtocolContext(
    provider: ProviderDescriptor(
      id: "mistral",
      name: "Mistral",
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: URL(string: "https://api.mistral.ai")!,
    headers: [:],
    credential: .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:])),
    modelConfiguration: ProviderModelConfiguration(
      baseURL: nil,
      headers: [:],
      metadata: [:]
    )
  )
}

private func mistralFixtureRequest(model: ProviderModel) -> ProviderRequest {
  ProviderRequest(
    id: "request",
    providerID: "mistral",
    modelID: model.id,
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

private func mistralSuccessChunks() -> [Data] {
  let events =
    [
      #"data: {"id":"mistral-response","model":"magistral-small","choices":[{"delta":{"content":"Checking"}}]}"#,
      #"data: {"id":"mistral-response","choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"Need a lookup"}]}]}}]}"#,
      #"data: {"id":"mistral-response","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"weather","arguments":"{\"city\":\"Tai"}}]}}]}"#,
      #"data: {"id":"mistral-response","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"","arguments":"pei\"}"}}]}}]}"#,
      #"data: {"id":"mistral-response","usage":{"prompt_tokens":12,"completion_tokens":7,"total_tokens":19,"prompt_tokens_details":{"cached_tokens":3},"completion_tokens_details":{"reasoning_tokens":2}},"choices":[{"finish_reason":"tool_calls","delta":{}}]}"#,
      "data: [DONE]",
    ].joined(separator: "\n\n") + "\n\n"
  let bytes = Array(events.utf8)
  return [
    Data(bytes[..<81]),
    Data(bytes[81..<267]),
    Data(bytes[267..<511]),
    Data(bytes[511...]),
  ]
}

private func expectMistralFailure(
  code: ProviderRuntimeFailure.Code,
  stream: () -> AsyncThrowingStream<ProviderEvent, any Error>
) async {
  do {
    for try await _ in stream() {}
    Issue.record("expected Mistral failure")
  } catch let error as ProviderRuntimeFailure {
    #expect(error.code == code)
  } catch {
    Issue.record("unexpected Mistral error: \(error)")
  }
}
