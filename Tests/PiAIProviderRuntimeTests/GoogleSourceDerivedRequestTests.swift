import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct GoogleSourceDerivedRequestTests {
  @Test
  func googleAndVertexRequestBranchesMatchPinnedSourceOracle() async throws {
    let repository = googleRepositoryRoot()
    let fixture = try googleDecode(
      GoogleBranchFixture.self,
      at: repository.appending(path: "Fixtures/Differential/Cases/request-google-branches.json")
    )
    let oracle = try googleDecode(
      GoogleBranchOracle.self,
      at: repository.appending(path: "Fixtures/Differential/Oracle/request-google-branches.json")
    )
    #expect(fixture.schemaVersion == 1)
    #expect(oracle.schemaVersion == 1)
    #expect(fixture.upstreamRevision == oracle.upstreamRevision)

    for testCase in fixture.cases {
      for protocolID in testCase.protocols ?? fixture.protocols {
        let expected = try #require(oracle.cases[testCase.caseID]?[protocolID])
        let outcome = await captureGoogleRequest(testCase, protocolID: protocolID)
        if let expectedBody = expected.requestBody {
          let request = try #require(
            outcome.request,
            "\(testCase.caseID)/\(protocolID) failed before transport: \(String(describing: outcome.error))"
          )
          let body = try JSONDecoder().decode(
            JSONValue.self,
            from: try #require(request.httpBody)
          )
          #expect(body == expectedBody, "request drift for \(testCase.caseID)/\(protocolID)")
        } else if let sourceError = expected.error {
          #expect(outcome.request == nil)
          let failure = outcome.error as? ProviderRuntimeFailure
          #expect(failure != nil, "expected explicit failure matching: \(sourceError)")
          if sourceError.contains("project ID") {
            #expect(failure?.message.contains("project") == true)
          }
          if sourceError.contains("location") {
            #expect(failure?.message.contains("location") == true)
          }
        } else if let wire = expected.wireRequest {
          let request = try #require(outcome.request)
          #expect(request.url?.absoluteString == wire.url)
          #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-key")
        } else {
          Issue.record("oracle has no outcome for \(testCase.caseID)/\(protocolID)")
        }
      }
    }
  }

  @Test
  func builtinVertexAPIKeyIgnoresLocationPlaceholderLikePinnedSource() async throws {
    let repository = googleRepositoryRoot()
    let oracle = try googleDecode(
      GoogleBranchOracle.self,
      at: repository.appending(path: "Fixtures/Differential/Oracle/request-google-branches.json")
    )
    let expectedURL = try #require(
      oracle.cases["placeholder-base"]?["google-vertex"]?.wireRequest?.url)
    let store = InMemoryProviderCredentialStore(credentials: [
      "google-vertex": .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:]))
    ])
    let transport = GoogleBuiltinCaptureTransport()
    let runtime = try BuiltinProviderRuntime(
      credentialStore: store,
      streamingTransport: transport
    )
    let request = ProviderRequest(
      id: "vertex-api-key",
      providerID: "google-vertex",
      modelID: "gemini-2.5-flash",
      messages: [.user([.text("hello")])],
      tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 64,
        temperature: nil,
        reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: [:]
      )
    )
    do {
      for try await _ in runtime.stream(request) {}
    } catch {
      // The capture transport returns HTTP 418 after retaining the request.
    }
    #expect(await transport.request()?.url?.absoluteString == expectedURL)
  }
}

private func captureGoogleRequest(
  _ testCase: GoogleBranchCase,
  protocolID: String
) async -> (request: URLRequest?, error: (any Error)?) {
  let isVertex = protocolID == "google-vertex"
  let providerID = isVertex ? "fixture-vertex" : "fixture-google"
  let model = ProviderModel(
    id: testCase.modelID,
    providerID: providerID,
    name: testCase.modelID,
    protocolID: protocolID,
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: true,
      reasoning: testCase.variant == "reasoning",
      structuredOutput: true,
      imageGeneration: false
    ),
    contextWindow: 262_144,
    maximumOutputTokens: 8_192
  )
  let transport = GoogleBranchCaptureTransport()
  let credential = googleCredential(testCase, isVertex: isVertex)
  let baseURL: URL
  if let configured = testCase.baseURL, !configured.contains("{location}") {
    baseURL = URL(string: configured)!
  } else if isVertex, testCase.vertexAuth == "api-key" {
    baseURL = URL(string: "https://aiplatform.googleapis.com")!
  } else if isVertex {
    baseURL = URL(string: "https://us-central1-aiplatform.googleapis.com")!
  } else {
    baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
  }
  let context = WireProtocolContext(
    provider: ProviderDescriptor(
      id: providerID,
      name: providerID,
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: baseURL,
    headers: [:],
    credential: credential,
    modelConfiguration: ProviderModelConfiguration(
      protocolID: protocolID,
      baseURL: nil,
      headers: [:],
      metadata: [:]
    )
  )
  let adapter = GoogleGenerativeAIAdapter(
    protocolID: protocolID,
    flavor: isVertex ? .vertex : .generativeAI
  )
  do {
    for try await _ in adapter.stream(
      googleRequest(testCase, protocolID: protocolID, providerID: providerID),
      context: context,
      transport: transport
    ) {}
    return (await transport.request(), nil)
  } catch {
    return (await transport.request(), error)
  }
}

private func googleRequest(
  _ testCase: GoogleBranchCase,
  protocolID: String,
  providerID: String
) -> ProviderRequest {
  let source = ProviderMessageSource(
    api: protocolID, providerID: providerID, modelID: testCase.modelID)
  var messages: [ProviderMessage] = [.user([.text("hello")])]
  if testCase.variant == "replay" {
    let replaySource =
      testCase.sameSource == true
      ? source
      : ProviderMessageSource(api: protocolID, providerID: providerID, modelID: "other-model")
    messages = [
      .user([.text("first")]),
      .assistantMessage(
        ProviderAssistantMessage(
          content: [
            .signedText(ProviderTextContent(text: "answer", signature: "dGV4dA==")),
            .reasoning(
              ProviderReasoningContent(
                text: "analysis",
                signature: "dGhpbms=",
                providerMetadata: [:]
              )),
            .toolCall(
              ProviderToolCall(
                id: "call-1",
                name: "weather",
                arguments: .object(["city": .string("Taipei")]),
                thoughtSignature: "dG9vbA=="
              )),
          ],
          source: replaySource,
          usage: googleZeroUsage(),
          stopReason: .toolUse,
          timestampMilliseconds: 1
        )),
    ]
  } else if ["tool-result", "consecutive-tool-results"].contains(testCase.variant) {
    let calls: [ProviderAssistantContent] =
      [
        .toolCall(
          ProviderToolCall(
            id: "call-1",
            name: "weather",
            arguments: .object(["city": .string("Taipei")])
          ))
      ]
      + (testCase.variant == "consecutive-tool-results"
        ? [
          .toolCall(
            ProviderToolCall(
              id: "call-2",
              name: "time",
              arguments: .object(["zone": .string("UTC")])
            ))
        ] : [])
    messages = [
      .user([.text("first")]),
      .assistantMessage(
        ProviderAssistantMessage(
          content: calls,
          source: source,
          usage: googleZeroUsage(),
          stopReason: .toolUse,
          timestampMilliseconds: 1
        )),
      .toolResult(
        ProviderToolResult(
          toolCallID: "call-1",
          toolName: "weather",
          content: [.text("sunny")]
            + (testCase.toolImage == true
              ? [.image(.data(Data([1, 2]), mimeType: "image/png"))]
              : []),
          isError: testCase.toolError == true,
          timestampMilliseconds: 2
        )),
    ]
    if testCase.variant == "consecutive-tool-results" {
      messages.append(
        .toolResult(
          ProviderToolResult(
            toolCallID: "call-2",
            toolName: "time",
            content: [.text("12:00")],
            isError: false,
            timestampMilliseconds: 3
          )))
    }
  }
  if testCase.variant == "generation" {
    messages.insert(.system("be concise"), at: 0)
  }
  let usesTools = ["tools", "strict-tools", "generation"].contains(testCase.variant)
  let tools: [ProviderToolDefinition] =
    usesTools
    ? [
      ProviderToolDefinition(
        name: "weather",
        description: "Read weather",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "city": .object(["type": .string("string")]),
            "units": .object(["type": .string("string")]),
          ]),
          "required": .array([.string("city")]),
        ]),
        constrainedSampling: testCase.variant == "strict-tools"
          ? .jsonSchema(strict: .prefer) : nil
      )
    ] : []
  var providerOptions: [String: JSONValue] = [:]
  if let project = testCase.project { providerOptions["project"] = .string(project) }
  if let location = testCase.location { providerOptions["location"] = .string(location) }
  let budgets: [ProviderReasoningEffort: Int]? = testCase.customBudget.map {
    [.minimal: 11, .low: $0, .medium: 33, .high: 44]
  }
  return ProviderRequest(
    id: testCase.caseID,
    providerID: providerID,
    modelID: testCase.modelID,
    messages: messages,
    tools: tools,
    options: ProviderGenerationOptions(
      maximumOutputTokens: testCase.variant == "generation" ? 321 : 64,
      temperature: testCase.variant == "generation" ? 0.25 : nil,
      reasoningEffort: testCase.reasoning.flatMap(ProviderReasoningEffort.init(rawValue:)),
      responseSchema: nil,
      providerOptions: providerOptions,
      cacheRetention: ProviderCacheRetention(rawValue: testCase.cacheRetention ?? "short")!,
      toolChoice: testCase.toolChoice.map(JSONValue.string),
      thinkingBudgets: budgets
    )
  )
}

private func googleCredential(
  _ testCase: GoogleBranchCase,
  isVertex: Bool
) -> ProviderCredential {
  guard isVertex else {
    return .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:]))
  }
  if testCase.vertexAuth == "api-key" || testCase.variant == "vertex-wire" {
    return .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:]))
  }
  var metadata: [String: String] = [:]
  if let project = testCase.envProject { metadata["project"] = project }
  if let location = testCase.envLocation { metadata["location"] = location }
  if testCase.variant != "vertex-config" {
    metadata["project"] = "fixture-project"
    metadata["location"] = "us-central1"
  }
  return .oauth(
    OAuthCredential(
      accessToken: "fixture-token",
      refreshToken: "fixture-refresh",
      expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
      metadata: metadata
    ))
}

private func googleZeroUsage() -> ProviderUsage {
  ProviderUsage(
    inputTokens: 1,
    outputTokens: 1,
    reasoningTokens: nil,
    cachedInputTokens: 0,
    cacheWriteTokens: 0,
    totalTokens: 2,
    providerMetadata: [:]
  )
}

private actor GoogleBranchCaptureTransport: ProviderHTTPStreamingTransport {
  private var captured: URLRequest?

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    return ProviderHTTPStreamingResponse(
      statusCode: 418,
      headers: [:],
      body: AsyncThrowingStream { continuation in continuation.finish() }
    )
  }

  func request() -> URLRequest? { captured }
}

private actor GoogleBuiltinCaptureTransport: ProviderHTTPStreamingTransport {
  private var captured: URLRequest?

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    return ProviderHTTPStreamingResponse(
      statusCode: 418,
      headers: [:],
      body: AsyncThrowingStream { continuation in continuation.finish() }
    )
  }

  func request() -> URLRequest? { captured }
}

private struct GoogleBranchFixture: Decodable {
  let schemaVersion: Int
  let upstreamRevision: String
  let protocols: [String]
  let cases: [GoogleBranchCase]
}

private struct GoogleBranchCase: Decodable {
  let caseID: String
  let modelID: String
  let variant: String
  let protocols: [String]?
  let sameSource: Bool?
  let toolError: Bool?
  let toolImage: Bool?
  let reasoning: String?
  let customBudget: Int?
  let toolChoice: String?
  let cacheRetention: String?
  let vertexAuth: String?
  let project: String?
  let location: String?
  let envProject: String?
  let envLocation: String?
  let baseURL: String?
}

private struct GoogleBranchOracle: Decodable {
  let schemaVersion: Int
  let upstreamRevision: String
  let cases: [String: [String: GoogleOracleOutcome]]
}

private struct GoogleOracleOutcome: Decodable {
  let requestBody: JSONValue?
  let error: String?
  let wireRequest: GoogleWireRequest?
}

private struct GoogleWireRequest: Decodable {
  let url: String
}

private func googleRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

private func googleDecode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
  try JSONDecoder().decode(type, from: Data(contentsOf: url))
}
