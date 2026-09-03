import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct GoogleGenerativeAIAdapterTests {
  @Test(arguments: ["gemini-3.1-pro", "gemini-2.5-pro"])
  func rejectsOffWhenGoogleCanOnlyHideThoughts(modelID: String) async throws {
    let model = googleModel(id: modelID)
    let transport = GoogleFixtureTransport(statusCode: 200, chunks: googleFixtureChunks())
    let request = ProviderRequest(
      id: "effort", providerID: model.providerID, modelID: model.id,
      messages: [.user([.text("hello")])], tools: [],
      options: .init(
        maximumOutputTokens: nil, temperature: nil, reasoningEffort: .off, responseSchema: nil,
        providerOptions: [:]))
    await #expect(throws: ProviderRuntimeFailure.self) {
      for try await _ in GoogleGenerativeAIAdapter().stream(
        request, context: googleContext(model: model), transport: transport)
      {}
    }
    #expect(await transport.request() == nil)
  }

  @Test
  func encodesDisabledAndMappedBudgetReasoning() async throws {
    for effort in [ProviderReasoningEffort.off, .low] {
      let model = googleModel()
      let transport = GoogleFixtureTransport(statusCode: 200, chunks: googleFixtureChunks())
      let request = ProviderRequest(
        id: "effort", providerID: model.providerID, modelID: model.id,
        messages: [.user([.text("hello")])], tools: [],
        options: .init(
          maximumOutputTokens: nil, temperature: nil, reasoningEffort: effort, responseSchema: nil,
          providerOptions: [:]))
      let context = googleContext(
        model: model, metadata: ["thinkingLevelMap": .object(["low": .string("HIGH")])])
      for try await _ in GoogleGenerativeAIAdapter().stream(
        request, context: context, transport: transport)
      {}
      let sent = try #require(await transport.request())
      let body = try decodeJSONObject(
        try #require(sent.httpBody), providerID: "fixture", operation: "fixture")
      let thinking = try #require(body.object("generationConfig")?.object("thinkingConfig"))
      #expect(thinking.int("thinkingBudget") == (effort == .off ? 0 : 24_576))
      #expect(thinking["includeThoughts"] == (effort == .off ? nil : .bool(true)))
    }
  }

  @Test
  func encodesMultimodalToolReasoningRequestAndNormalizesStream() async throws {
    let transport = GoogleFixtureTransport(
      statusCode: 200,
      chunks: googleFixtureChunks()
    )
    let model = googleModel()
    let request = ProviderRequest(
      id: "request-1",
      providerID: "google",
      modelID: model.id,
      messages: [
        .system("Be concise"),
        .user([
          .text("Inspect this image"),
          .image(.data(Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")),
        ]),
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
        reasoningEffort: .high,
        responseSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "answer": .object(["type": .string("string")])
          ]),
        ]),
        providerOptions: ["toolChoice": .string("any")]
      )
    )

    var events: [ProviderEvent] = []
    for try await event in GoogleGenerativeAIAdapter().stream(
      request,
      context: googleContext(model: model),
      transport: transport
    ) {
      events.append(event)
    }

    #expect(
      events.first
        == .responseStarted(
          ProviderResponseMetadata(
            responseID: "google-response-1",
            providerID: "google",
            modelID: model.id,
            providerMetadata: [:]
          )
        )
    )
    #expect(events.contains(.reasoningSignatureDelta("YWJjZA==")))
    #expect(events.contains(.reasoningSignatureDelta("ZWZnaA==")))
    #expect(events.contains(.reasoningDelta("checking")))
    #expect(events.contains(.textDelta("ready")))
    #expect(events.contains(.toolCallStarted(id: "call-1", name: "weather")))
    #expect(
      events.contains(
        .toolCallCompleted(
          ProviderToolCall(
            id: "call-1",
            name: "weather",
            arguments: .object(["city": .string("Taipei")])
          )
        ))
    )
    #expect(events.last == .completed(.toolCalls))

    let sent = try #require(await transport.request())
    #expect(
      sent.url?.absoluteString
        == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
    )
    #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-key")
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(
      body.object("systemInstruction")?.array("parts")?.first?.objectValue?.string("text")
        == "Be concise"
    )
    let userParts = try #require(body.array("contents")?.first?.objectValue?.array("parts"))
    #expect(userParts.count == 2)
    #expect(userParts[1].objectValue?.object("inlineData")?.string("mimeType") == "image/png")
    let generation = try #require(body.object("generationConfig"))
    #expect(generation.int("maxOutputTokens") == 512)
    #expect(generation.object("thinkingConfig")?.int("thinkingBudget") == 24_576)
    #expect(generation.string("responseMimeType") == "application/json")
    #expect(generation.object("responseJsonSchema")?.string("type") == "object")
    #expect(
      body.object("toolConfig")?.object("functionCallingConfig")?.string("mode")
        == "ANY"
    )
  }

  @Test
  func vertexRequiresProjectLocationAndAuthenticationMetadata() async throws {
    let model = vertexModel()
    let request = fixtureRequest(providerID: "google-vertex", modelID: model.id)
    let adapter = GoogleGenerativeAIAdapter(
      protocolID: "google-vertex",
      flavor: .vertex
    )

    await expectFailure(
      adapter: adapter,
      request: request,
      context: vertexContext(
        model: model,
        credential: .apiKey(
          APIKeyCredential(key: "key", metadata: ["location": "us-central1"])
        )
      ),
      expectedCode: .invalidCredential,
      messageFragment: "project"
    )
    await expectFailure(
      adapter: adapter,
      request: request,
      context: vertexContext(
        model: model,
        credential: .apiKey(
          APIKeyCredential(key: "key", metadata: ["project": "sample-project"])
        )
      ),
      expectedCode: .invalidCredential,
      messageFragment: "location"
    )
    await expectFailure(
      adapter: adapter,
      request: request,
      context: vertexContext(model: model, credential: nil),
      expectedCode: .invalidCredential,
      messageFragment: "project"
    )
    let configuredRequest = ProviderRequest(
      id: request.id,
      providerID: request.providerID,
      modelID: request.modelID,
      messages: request.messages,
      tools: request.tools,
      options: ProviderGenerationOptions(
        maximumOutputTokens: nil,
        temperature: nil,
        reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: [
          "project": .string("sample-project"),
          "location": .string("us-central1"),
        ]
      )
    )
    await expectFailure(
      adapter: adapter,
      request: configuredRequest,
      context: vertexContext(model: model, credential: nil),
      expectedCode: .missingCredential,
      messageFragment: "missing"
    )
  }

  @Test
  func vertexBuildsScopedOAuthRequestAndNormalizesLengthFinish() async throws {
    let transport = GoogleFixtureTransport(
      statusCode: 200,
      chunks: [
        Data(
          "data: {\"responseId\":\"vertex-response\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"partial\"}]},\"finishReason\":\"MAX_TOKENS\"}]}\n\n"
            .utf8
        )
      ]
    )
    let model = vertexModel()
    let credential = OAuthCredential(
      accessToken: "vertex-token",
      refreshToken: "refresh",
      expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
      metadata: [
        "project": "sample-project",
        "location": "us-central1",
      ]
    )
    let adapter = GoogleGenerativeAIAdapter(
      protocolID: "google-vertex",
      flavor: .vertex
    )
    var events: [ProviderEvent] = []
    for try await event in adapter.stream(
      fixtureRequest(providerID: "google-vertex", modelID: model.id),
      context: vertexContext(model: model, credential: .oauth(credential)),
      transport: transport
    ) {
      events.append(event)
    }

    #expect(events.contains(.textDelta("partial")))
    #expect(events.last == .completed(.length))
    let sent = try #require(await transport.request())
    #expect(
      sent.url?.absoluteString
        == "https://us-central1-aiplatform.googleapis.com/v1/projects/sample-project/locations/us-central1/publishers/google/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
    )
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer vertex-token")
  }

  @Test
  func rejectsHTTPStreamErrorUnsafeFinishAndMissingTerminal() async {
    let adapter = GoogleGenerativeAIAdapter()
    let model = googleModel()
    let request = fixtureRequest(providerID: "google", modelID: model.id)
    let context = googleContext(model: model)

    await #expect(throws: ProviderRuntimeFailure.self) {
      for try await _ in adapter.stream(
        request,
        context: context,
        transport: GoogleFixtureTransport(
          statusCode: 429,
          chunks: [Data(#"{"error":{"message":"rate limited"}}"#.utf8)]
        )
      ) {}
    }
    await #expect(throws: ProviderRuntimeFailure.self) {
      for try await _ in adapter.stream(
        request,
        context: context,
        transport: GoogleFixtureTransport(
          statusCode: 200,
          chunks: [
            Data(
              "data: {\"responseId\":\"blocked\",\"candidates\":[{\"finishReason\":\"SAFETY\"}]}\n\n"
                .utf8
            )
          ]
        )
      ) {}
    }
    await #expect(throws: ProviderRuntimeFailure.self) {
      for try await _ in adapter.stream(
        request,
        context: context,
        transport: GoogleFixtureTransport(
          statusCode: 200,
          chunks: [
            Data("data: {\"responseId\":\"unterminated\",\"candidates\":[]}\n\n".utf8)
          ]
        )
      ) {}
    }
  }

  @Test
  func propagatesConsumerCancellationIntoTransportBody() async throws {
    let transport = GoogleCancellationTransport()
    let model = googleModel()
    let stream = GoogleGenerativeAIAdapter().stream(
      fixtureRequest(providerID: "google", modelID: model.id),
      context: googleContext(model: model),
      transport: transport
    )
    let collector = Task {
      for try await _ in stream {}
    }
    while await !transport.didStart() {
      await Task.yield()
    }
    collector.cancel()

    do {
      try await collector.value
    } catch is CancellationError {
      // AsyncThrowingStream may either finish its cancelled iterator or throw.
    } catch {
      Issue.record("unexpected cancellation error: \(error)")
    }
    for _ in 0..<100 where await !transport.didCancelBody() {
      await Task.yield()
    }
    #expect(await transport.didCancelBody())
  }
}

private actor GoogleFixtureTransport: ProviderHTTPStreamingTransport {
  private let statusCode: Int
  private let chunks: [Data]
  private var capturedRequest: URLRequest?

  init(statusCode: Int, chunks: [Data]) {
    self.statusCode = statusCode
    self.chunks = chunks
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

private actor GoogleCancellationTransport: ProviderHTTPStreamingTransport {
  private var started = false
  private var bodyCancelled = false

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    started = true
    return ProviderHTTPStreamingResponse(
      statusCode: 200,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.onTermination = { _ in
          Task { await self.recordCancellation() }
        }
      }
    )
  }

  func didStart() -> Bool { started }
  func didCancelBody() -> Bool { bodyCancelled }
  private func recordCancellation() { bodyCancelled = true }
}

private func googleFixtureChunks() -> [Data] {
  let stream =
    [
      #"data: {"responseId":"google-response-1","candidates":[{"content":{"role":"model","parts":[{"text":"checking","thought":true,"thoughtSignature":"YWJjZA=="},{"text":"ready"},{"functionCall":{"id":"call-1","name":"weather","args":{"city":"Taipei"}},"thoughtSignature":"ZWZnaA=="}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":5,"thoughtsTokenCount":2,"cachedContentTokenCount":3,"totalTokenCount":19}}"#
    ].joined(separator: "\n\n") + "\n\n"
  let bytes = Array(stream.utf8)
  return [Data(bytes[..<79]), Data(bytes[79..<221]), Data(bytes[221...])]
}

private func googleModel(id: String = "gemini-2.5-flash") -> ProviderModel {
  ProviderModel(
    id: id,
    providerID: "google",
    name: "Gemini 2.5 Flash",
    protocolID: "google-generative-ai",
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: true,
      reasoning: true,
      structuredOutput: true,
      imageGeneration: false
    ),
    contextWindow: 1_048_576,
    maximumOutputTokens: 65_536
  )
}

private func vertexModel() -> ProviderModel {
  ProviderModel(
    id: "gemini-2.5-flash",
    providerID: "google-vertex",
    name: "Gemini 2.5 Flash",
    protocolID: "google-vertex",
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: true,
      reasoning: true,
      structuredOutput: true,
      imageGeneration: false
    ),
    contextWindow: 1_048_576,
    maximumOutputTokens: 65_536
  )
}

private func googleContext(model: ProviderModel, metadata: [String: JSONValue] = [:])
  -> WireProtocolContext
{
  WireProtocolContext(
    provider: ProviderDescriptor(
      id: model.providerID,
      name: "Google",
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
    headers: [:],
    credential: .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:])),
    modelConfiguration: ProviderModelConfiguration(
      protocolID: model.protocolID,
      baseURL: nil,
      headers: [:],
      metadata: metadata
    )
  )
}

private func vertexContext(
  model: ProviderModel,
  credential: ProviderCredential?
) -> WireProtocolContext {
  WireProtocolContext(
    provider: ProviderDescriptor(
      id: "google-vertex",
      name: "Google Vertex AI",
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: URL(string: "https://us-central1-aiplatform.googleapis.com")!,
    headers: [:],
    credential: credential,
    modelConfiguration: ProviderModelConfiguration(
      protocolID: model.protocolID,
      baseURL: nil,
      headers: [:],
      metadata: [:]
    )
  )
}

private func fixtureRequest(providerID: String, modelID: String) -> ProviderRequest {
  ProviderRequest(
    id: "fixture-request",
    providerID: providerID,
    modelID: modelID,
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

private func expectFailure(
  adapter: GoogleGenerativeAIAdapter,
  request: ProviderRequest,
  context: WireProtocolContext,
  expectedCode: ProviderRuntimeFailure.Code,
  messageFragment: String
) async {
  do {
    for try await _ in adapter.stream(
      request,
      context: context,
      transport: GoogleFixtureTransport(statusCode: 200, chunks: [])
    ) {}
    Issue.record("expected Google adapter failure")
  } catch let error as ProviderRuntimeFailure {
    #expect(error.code == expectedCode)
    #expect(error.message.contains(messageFragment))
  } catch {
    Issue.record("unexpected Google adapter error: \(error)")
  }
}
