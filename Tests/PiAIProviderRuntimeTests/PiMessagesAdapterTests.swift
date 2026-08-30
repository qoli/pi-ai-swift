import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct PiMessagesAdapterTests {
  @Test
  func encodesContextAndNormalizesTextReasoningToolUsageAndTerminal() async throws {
    let transport = PiMessagesFixtureTransport(
      statusCode: 200,
      chunks: piMessagesSuccessChunks()
    )
    let adapter = PiMessagesAdapter()
    let model = piMessagesFixtureModel()
    let request = ProviderRequest(
      id: "logical-request",
      providerID: "radius",
      modelID: model.id,
      messages: [
        .system("Be precise"),
        .user([.text("Use a tool")]),
        .assistant([
          .reasoning(
            ProviderReasoningContent(
              text: "prior thought",
              signature: "opaque",
              providerMetadata: [:]
            )),
          .toolCall(
            ProviderToolCall(
              id: "prior-call",
              name: "lookup",
              arguments: .object(["query": .string("Swift")])
            )),
        ]),
        .toolResult(
          ProviderToolResult(
            toolCallID: "prior-call",
            toolName: "lookup",
            content: [.text("result")],
            isError: false
          )),
      ],
      tools: [
        ProviderToolDefinition(
          name: "lookup",
          description: "Look up a value",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
              "query": .object(["type": .string("string")])
            ]),
          ])
        )
      ],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 256,
        temperature: 0.5,
        reasoningEffort: "high",
        responseSchema: nil,
        providerOptions: [
          "cacheRetention": .string("long"),
          "sessionId": .string("session-1"),
          "toolChoice": .string("auto"),
          "debug": .bool(true),
        ]
      )
    )

    var events: [ProviderEvent] = []
    for try await event in adapter.stream(
      request,
      context: piMessagesFixtureContext(model: model),
      transport: transport
    ) {
      events.append(event)
    }

    #expect(
      events.first
        == .responseStarted(
          ProviderResponseMetadata(
            responseID: "logical-request",
            providerID: "radius",
            modelID: model.id,
            providerMetadata: [:]
          )))
    #expect(events.contains(.textDelta("hello")))
    #expect(events.contains(.reasoningDelta("thinking")))
    #expect(events.contains(.toolCallStarted(id: "call-1", name: "lookup")))
    #expect(events.contains(.toolInputDelta(id: "call-1", delta: #"{"query":"Sw"#)))
    #expect(events.contains(.toolInputDelta(id: "call-1", delta: #"ift"}"#)))
    #expect(
      events.contains(
        .toolCallCompleted(
          ProviderToolCall(
            id: "call-1",
            name: "lookup",
            arguments: .object(["query": .string("Swift")])
          )))
    )
    #expect(
      events.contains(
        .usage(
          ProviderUsage(
            inputTokens: 8,
            outputTokens: 5,
            reasoningTokens: 2,
            cachedInputTokens: 3,
            providerMetadata: ["totalTokens": .integer(16)]
          )))
    )
    #expect(events.last == .completed(.toolCalls))

    let sent = try #require(await transport.request())
    #expect(sent.url?.absoluteString == "https://radius.invalid/messages?debug=1")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer radius-key")
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(body.string("model") == model.id)
    let context = try #require(body.object("context"))
    #expect(context.string("systemPrompt") == "Be precise")
    #expect(context.array("messages")?.count == 3)
    #expect(context.array("tools")?.count == 1)
    let options = try #require(body.object("options"))
    #expect(options.int("maxTokens") == 256)
    #expect(options.string("reasoning") == "high")
    #expect(options.string("sessionId") == "session-1")
    #expect(options["debug"] == nil)
  }

  @Test
  func failsExplicitlyForHTTPServerAndMissingTerminalErrors() async {
    let adapter = PiMessagesAdapter()
    let model = piMessagesFixtureModel()
    let request = piMessagesFixtureRequest(model: model)
    let context = piMessagesFixtureContext(model: model)

    await expectPiMessagesFailure(code: .transportFailed) {
      adapter.stream(
        request,
        context: context,
        transport: PiMessagesFixtureTransport(
          statusCode: 429,
          chunks: [
            Data(#"{"error":{"message":"limited","code":"rate_limit"}}"#.utf8)
          ]
        )
      )
    }
    await expectPiMessagesFailure(code: .transportFailed) {
      adapter.stream(
        request,
        context: context,
        transport: PiMessagesFixtureTransport(
          statusCode: 200,
          chunks: piMessagesSSE([
            #"{"type":"start"}"#,
            #"{"type":"error","reason":"error","errorMessage":"gateway failed","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0}}"#,
          ])
        )
      )
    }
    await expectPiMessagesFailure(code: .invalidResponse) {
      adapter.stream(
        request,
        context: context,
        transport: PiMessagesFixtureTransport(
          statusCode: 200,
          chunks: piMessagesSSE([
            #"{"type":"start"}"#,
            #"{"type":"text_delta","contentIndex":0,"delta":"partial"}"#,
          ])
        )
      )
    }
  }

  @Test
  func propagatesCancellationWithoutSubstituteOutput() async {
    let adapter = PiMessagesAdapter()
    let model = piMessagesFixtureModel()
    do {
      for try await _ in adapter.stream(
        piMessagesFixtureRequest(model: model),
        context: piMessagesFixtureContext(model: model),
        transport: PiMessagesCancellingTransport()
      ) {
        Issue.record("cancelled pi-messages stream emitted an event")
      }
      Issue.record("cancelled pi-messages stream completed successfully")
    } catch is CancellationError {
    } catch {
      Issue.record("unexpected cancellation error: \(error)")
    }
  }
}

private actor PiMessagesFixtureTransport: ProviderHTTPStreamingTransport {
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

private struct PiMessagesCancellingTransport: ProviderHTTPStreamingTransport {
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

private func piMessagesFixtureModel() -> ProviderModel {
  ProviderModel(
    id: "gateway-model",
    providerID: "radius",
    name: "Gateway Model",
    protocolID: "pi-messages",
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: true,
      reasoning: true,
      structuredOutput: false,
      imageGeneration: false
    ),
    contextWindow: 100_000,
    maximumOutputTokens: 8_192
  )
}

private func piMessagesFixtureContext(model: ProviderModel) -> WireProtocolContext {
  WireProtocolContext(
    provider: ProviderDescriptor(
      id: "radius",
      name: "Radius",
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: URL(string: "https://radius.invalid")!,
    headers: ["X-Fixture": "value"],
    credential: .apiKey(APIKeyCredential(key: "radius-key", metadata: [:])),
    modelConfiguration: ProviderModelConfiguration(
      protocolID: model.protocolID,
      baseURL: nil,
      headers: [:],
      metadata: [:]
    )
  )
}

private func piMessagesFixtureRequest(model: ProviderModel) -> ProviderRequest {
  ProviderRequest(
    id: "request",
    providerID: "radius",
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

private func piMessagesSuccessChunks() -> [Data] {
  piMessagesSSE([
    #"{"type":"start"}"#,
    #"{"type":"text_start","contentIndex":0}"#,
    #"{"type":"text_delta","contentIndex":0,"delta":"hello"}"#,
    #"{"type":"text_end","contentIndex":0,"content":"hello"}"#,
    #"{"type":"thinking_start","contentIndex":1}"#,
    #"{"type":"thinking_delta","contentIndex":1,"delta":"thinking"}"#,
    #"{"type":"thinking_end","contentIndex":1,"content":"thinking","contentSignature":"opaque"}"#,
    #"{"type":"toolcall_start","contentIndex":2,"id":"call-1","toolName":"lookup"}"#,
    #"{"type":"toolcall_delta","contentIndex":2,"delta":"{\"query\":\"Sw"}"#,
    #"{"type":"toolcall_delta","contentIndex":2,"delta":"ift\"}"}"#,
    #"{"type":"toolcall_end","contentIndex":2,"toolCall":{"type":"toolCall","id":"call-1","name":"lookup","arguments":{"query":"Swift"}}}"#,
    #"{"type":"done","reason":"toolUse","usage":{"input":8,"output":5,"reasoning":2,"cacheRead":3,"cacheWrite":0,"totalTokens":16},"responseId":"response-1"}"#,
  ])
}

private func piMessagesSSE(_ events: [String]) -> [Data] {
  let value = events.map { "data: \($0)" }.joined(separator: "\n\n") + "\n\n"
  let bytes = Array(value.utf8)
  guard bytes.count > 80 else { return [Data(bytes)] }
  return [
    Data(bytes[..<31]),
    Data(bytes[31..<80]),
    Data(bytes[80...]),
  ]
}

private func expectPiMessagesFailure(
  code: ProviderRuntimeFailure.Code,
  stream: () -> AsyncThrowingStream<ProviderEvent, any Error>
) async {
  do {
    for try await _ in stream() {}
    Issue.record("expected pi-messages failure")
  } catch let error as ProviderRuntimeFailure {
    #expect(error.code == code)
  } catch {
    Issue.record("unexpected pi-messages error: \(error)")
  }
}
