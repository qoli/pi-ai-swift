import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct OpenAIResponsesAdapterTests {
  @Test
  func encodesStructuredRequestAndNormalizesResponsesEvents() async throws {
    let transport = ResponsesFixtureTransport(chunks: responsesFixtureChunks())
    let adapter = OpenAIResponsesAdapter()
    let model = ProviderModel(
      id: "gpt-fixture",
      providerID: "openai",
      name: "GPT Fixture",
      protocolID: "openai-responses",
      capabilities: ProviderCapabilities(
        textInput: true,
        imageInput: true,
        toolCalling: true,
        reasoning: true,
        structuredOutput: true,
        imageGeneration: false
      ),
      contextWindow: 100_000,
      maximumOutputTokens: 8_192
    )
    let request = ProviderRequest(
      id: "request",
      providerID: "openai",
      modelID: model.id,
      messages: [.system("system"), .user([.text("hello")])],
      tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 100,
        temperature: nil,
        reasoningEffort: .high,
        responseSchema: .object(["type": .string("object")]),
        providerOptions: [:]
      )
    )
    let context = WireProtocolContext(
      provider: ProviderDescriptor(
        id: "openai",
        name: "OpenAI",
        authorizationMethods: [],
        models: [model]
      ),
      model: model,
      baseURL: URL(string: "https://api.openai.com/v1")!,
      headers: [:],
      credential: .apiKey(APIKeyCredential(key: "fixture", metadata: [:])),
      modelConfiguration: ProviderModelConfiguration(
        protocolID: model.protocolID,
        baseURL: nil,
        headers: [:],
        metadata: zeroCostMetadata()
      )
    )
    var events: [ProviderEvent] = []
    for try await event in adapter.stream(request, context: context, transport: transport) {
      events.append(event)
    }
    #expect(
      events.first
        == .responseStarted(
          ProviderResponseMetadata(
            responseID: nil,
            providerID: "openai",
            modelID: "gpt-fixture",
            providerMetadata: [:]
          )))
    #expect(events.contains(.textDelta("hello")))
    #expect(
      events.contains(
        .reasoningSignatureDelta(
          #"{"encrypted_content":"encrypted-reasoning","type":"reasoning"}"#
        )))
    #expect(events.last == .completed(.stop))
    guard case .responseSnapshot(let snapshot) = events[events.count - 2] else {
      Issue.record("expected terminal response snapshot")
      return
    }
    #expect(snapshot.responseID == "response-1")

    let sent = try #require(await transport.request())
    #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(body["instructions"] == nil)
    #expect(body.array("input")?.first?.objectValue?.string("role") == "developer")
    #expect(body.array("input")?.first?.objectValue?.string("content") == "system")
    #expect(body.int("max_output_tokens") == 100)
    #expect(body.object("reasoning")?.string("effort") == "high")
    #expect(body.object("text")?.object("format")?.string("type") == "json_schema")
  }

  @Test
  func selectedEffortMapsToWireWhileNilUsesPinnedDefaultOff() async throws {
    let cases: [(ProviderReasoningEffort?, String?)] = [
      (nil, "none"), (.off, "none"), (.minimal, "low"), (.high, "high"), (.max, "max"),
    ]
    for (effort, expected) in cases {
      let fixture = responsesFixture(
        providerID: "openai", protocolID: "openai-responses",
        baseURL: "https://api.openai.com/v1",
        credential: .apiKey(APIKeyCredential(key: "fixture", metadata: [:])),
        options: ProviderGenerationOptions(
          maximumOutputTokens: nil, temperature: nil, reasoningEffort: effort,
          responseSchema: nil, providerOptions: [:]),
        metadata: [
          "thinkingLevelMap": .object([
            "minimal": .string("low"), "max": .string("max"),
          ])
        ]
      )
      let transport = ResponsesFixtureTransport(chunks: responsesFixtureChunks())
      for try await _ in OpenAIResponsesAdapter().stream(
        fixture.request, context: fixture.context, transport: transport)
      {}
      let sent = try #require(await transport.request())
      let body = try decodeJSONObject(
        try #require(sent.httpBody), providerID: "fixture", operation: "fixture")
      #expect(body.object("reasoning")?.string("effort") == expected)
    }
  }

  @Test
  func azureAndCodexFlavorsKeepEndpointAndCredentialSemanticsSeparate() async throws {
    let azureTransport = ResponsesFixtureTransport(chunks: responsesFixtureChunks())
    let azure = responsesFixture(
      providerID: "azure-openai-responses",
      protocolID: "azure-openai-responses",
      baseURL: "https://fixture.openai.azure.com/openai/v1",
      credential: .apiKey(
        APIKeyCredential(
          key: "azure-key",
          metadata: [:]
        )
      ),
      connectionOptions: ProviderConnectionOptions(
        azureOpenAIResponses: AzureOpenAIResponsesConnectionOptions(
          azureAPIVersion: "2025-04-01-preview",
          azureDeploymentName: "deployment-1"
        ))
    )
    for try await _ in OpenAIResponsesAdapter(
      protocolID: "azure-openai-responses",
      flavor: .azure
    ).stream(azure.request, context: azure.context, transport: azureTransport) {}
    let azureRequest = try #require(await azureTransport.request())
    #expect(
      azureRequest.url?.absoluteString
        == "https://fixture.openai.azure.com/openai/v1/responses?api-version=2025-04-01-preview"
    )
    #expect(azureRequest.value(forHTTPHeaderField: "api-key") == "azure-key")
    #expect(azureRequest.value(forHTTPHeaderField: "Authorization") == nil)
    let azureBody = try decodeJSONObject(
      try #require(azureRequest.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(azureBody.string("model") == "deployment-1")

    let codexTransport = ResponsesFixtureTransport(chunks: responsesFixtureChunks())
    let codex = responsesFixture(
      providerID: "openai-codex",
      protocolID: "openai-codex-responses",
      baseURL: "https://chatgpt.com/backend-api",
      credential: .oauth(
        OAuthCredential(
          accessToken: "codex-access",
          refreshToken: "codex-refresh",
          expiresAt: Date.distantFuture,
          metadata: ["accountID": "account-1"]
        )
      )
    )
    for try await _ in OpenAIResponsesAdapter(
      protocolID: "openai-codex-responses",
      flavor: .codex
    ).stream(codex.request, context: codex.context, transport: codexTransport) {}
    let codexRequest = try #require(await codexTransport.request())
    #expect(codexRequest.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
    #expect(codexRequest.value(forHTTPHeaderField: "Authorization") == "Bearer codex-access")
    #expect(codexRequest.value(forHTTPHeaderField: "chatgpt-account-id") == "account-1")
    #expect(codexRequest.value(forHTTPHeaderField: "originator") == "pi")
  }

  @Test
  func azureRequestServiceTierFailsExplicitlyBecausePinnedSourceDoesNotExposeIt() async throws {
    let fixture = responsesFixture(
      providerID: "azure-openai-responses",
      protocolID: "azure-openai-responses",
      baseURL: "https://fixture.openai.azure.com/openai/v1",
      credential: .apiKey(APIKeyCredential(key: "azure-key", metadata: [:])),
      options: ProviderGenerationOptions(
        maximumOutputTokens: 100,
        temperature: nil,
        reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: [:],
        serviceTier: "priority"))
    let transport = ResponsesFixtureTransport(chunks: responsesFixtureChunks())
    do {
      for try await _ in OpenAIResponsesAdapter(
        protocolID: "azure-openai-responses", flavor: .azure
      ).stream(fixture.request, context: fixture.context, transport: transport) {}
      Issue.record("expected unsupported Azure service tier failure")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .unsupportedCapability)
      #expect(failure.operation == "azure-openai-responses.request.service-tier")
    }
    #expect(await transport.request() == nil)
  }

  @Test
  func codexSSEPreservesCacheAffinityAndNormalizesDoneAlias() async throws {
    let terminal =
      [
        #"data: {"type":"response.created","response":{"id":"response-codex","model":"gpt-fixture"}}"#,
        #"data: {"type":"response.output_text.delta","delta":"hello"}"#,
        #"data: {"type":"response.done","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":1}}}"#,
      ].joined(separator: "\n\n") + "\n\n"
    let transport = ResponsesFixtureTransport(chunks: [Data(terminal.utf8)])
    let sessionID = String(repeating: "session-", count: 12)
    let fixture = responsesFixture(
      providerID: "openai-codex",
      protocolID: "openai-codex-responses",
      baseURL: "https://chatgpt.com/backend-api",
      credential: .oauth(
        OAuthCredential(
          accessToken: "codex-access",
          refreshToken: "codex-refresh",
          expiresAt: .distantFuture,
          metadata: ["accountID": "account-1"]
        )
      ),
      options: ProviderGenerationOptions(
        maximumOutputTokens: 100,
        temperature: nil,
        reasoningEffort: .high,
        responseSchema: nil,
        providerOptions: [:],
        sessionID: sessionID,
        cacheRetention: .short,
        serviceTier: "priority"
      )
    )
    var events: [ProviderEvent] = []
    for try await event in OpenAIResponsesAdapter(
      protocolID: "openai-codex-responses",
      flavor: .codex
    ).stream(fixture.request, context: fixture.context, transport: transport) {
      events.append(event)
    }

    #expect(events.last == .completed(.stop))
    let sent = try #require(await transport.request())
    let clampedSessionID = String(sessionID.prefix(64))
    #expect(sent.value(forHTTPHeaderField: "session-id") == clampedSessionID)
    #expect(sent.value(forHTTPHeaderField: "x-client-request-id") == clampedSessionID)
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(body.string("prompt_cache_key") == clampedSessionID)
    #expect(body.string("instructions") == "You are a helpful assistant.")
    #expect(body.object("text")?.string("verbosity") == "low")
    #expect(body.string("tool_choice") == "auto")
    #expect(body.bool("parallel_tool_calls") == true)
    #expect(body.string("service_tier") == "priority")
    #expect(body["max_output_tokens"] == nil)
  }
}

private actor ResponsesFixtureTransport: ProviderHTTPStreamingTransport {
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

private func responsesFixtureChunks() -> [Data] {
  let stream =
    [
      #"data: {"type":"response.created","response":{"id":"response-1","model":"gpt-fixture"}}"#,
      #"data: {"type":"response.output_text.delta","delta":"hello"}"#,
      #"data: {"type":"response.output_item.done","item":{"type":"reasoning","encrypted_content":"encrypted-reasoning"}}"#,
      #"data: {"type":"response.completed","response":{"usage":{"input_tokens":4,"output_tokens":2,"input_tokens_details":{"cached_tokens":1},"output_tokens_details":{"reasoning_tokens":1}}}}"#,
    ].joined(separator: "\n\n") + "\n\n"
  let bytes = Array(stream.utf8)
  return [Data(bytes[..<53]), Data(bytes[53..<159]), Data(bytes[159...])]
}

private func responsesFixture(
  providerID: String,
  protocolID: String,
  baseURL: String,
  credential: ProviderCredential,
  options: ProviderGenerationOptions? = nil,
  metadata: [String: JSONValue] = [:],
  connectionOptions: ProviderConnectionOptions = .init()
) -> (request: ProviderRequest, context: WireProtocolContext) {
  var effectiveMetadata = metadata
  if effectiveMetadata["cost"] == nil {
    effectiveMetadata.merge(zeroCostMetadata()) { current, _ in current }
  }
  let model = ProviderModel(
    id: "gpt-fixture",
    providerID: providerID,
    name: "Fixture",
    protocolID: protocolID,
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: true,
      reasoning: true,
      structuredOutput: true,
      imageGeneration: false
    ),
    contextWindow: 100_000,
    maximumOutputTokens: 8_192
  )
  return (
    ProviderRequest(
      id: "request",
      providerID: providerID,
      modelID: model.id,
      messages: [.user([.text("hello")])],
      tools: [],
      options: options
        ?? ProviderGenerationOptions(
          maximumOutputTokens: 100,
          temperature: nil,
          reasoningEffort: nil,
          responseSchema: nil,
          providerOptions: [:]
        ),
      connectionOptions: connectionOptions
    ),
    WireProtocolContext(
      provider: ProviderDescriptor(
        id: providerID,
        name: providerID,
        authorizationMethods: [],
        models: [model]
      ),
      model: model,
      baseURL: URL(string: baseURL)!,
      headers: [:],
      credential: credential,
      modelConfiguration: ProviderModelConfiguration(
        protocolID: model.protocolID,
        baseURL: nil,
        headers: [:],
        metadata: effectiveMetadata
      )
    )
  )
}

private func zeroCostMetadata() -> [String: JSONValue] {
  [
    "cost": .object([
      "input": .integer(0), "output": .integer(0),
      "cacheRead": .integer(0), "cacheWrite": .integer(0),
    ])
  ]
}
