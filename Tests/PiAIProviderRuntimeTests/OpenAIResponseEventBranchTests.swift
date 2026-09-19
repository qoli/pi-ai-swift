import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct OpenAIResponseEventBranchTests {
  @Test
  func pinnedResponseEventOracleIsReproducible() throws {
    let root = responseEventRepositoryRoot()
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "node", "Scripts/openai-response-event-oracle.mjs", ".build/upstreams/pi",
      "Fixtures/OpenAIRequestBranches/Cases/response-event-branches.json",
    ]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let errorText =
      String(
        data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, Comment(rawValue: errorText))
    let observed = try JSONDecoder().decode(
      JSONValue.self, from: output.fileHandleForReading.readDataToEndOfFile())
    let expected = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(
        contentsOf: root.appending(
          path: "Fixtures/OpenAIRequestBranches/Oracle/response-event-branches.json")))
    #expect(observed == expected)
  }

  @Test
  func responsesCustomNamespaceUsageAndIncompleteTerminalMatchSource() async throws {
    let fixture = try responseEventFixture()
    let grammarTool = responseGrammarTool()

    let custom = try await responseEvents(
      protocolID: "openai-responses", modelID: "gpt-model",
      events: try #require(fixture.array("responsesCustomEvents")),
      tools: [grammarTool],
      metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])])
    #expect(custom.responseID == "resp-terminal")
    #expect(custom.finishReason == .toolCalls)
    #expect(custom.rawFinishReason == "completed")
    #expect(custom.usage?.inputTokens == 15)
    #expect(custom.usage?.outputTokens == 7)
    #expect(custom.usage?.cachedInputTokens == 2)
    #expect(custom.usage?.cacheWriteTokens == 3)
    #expect(custom.usage?.reasoningTokens == 1)
    #expect(custom.usage?.totalTokens == 27)
    guard case .toolCall(let call) = custom.content.first else {
      Issue.record("expected custom tool call snapshot")
      return
    }
    #expect(call.id == "call_1|ctc_1")
    #expect(call.arguments == .object(["payload": .string("abc")]))
    #expect(call.namespace == "dynamic_tools")

    let codex = try await responseEvents(
      protocolID: "openai-codex-responses", modelID: "gpt-5.1-codex",
      events: try #require(fixture.array("responsesCustomEvents")),
      tools: [grammarTool],
      metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])])
    #expect(codex.finishReason == .toolCalls)
    guard case .toolCall(let codexCall) = codex.content.first else {
      Issue.record("expected Codex custom tool call snapshot")
      return
    }
    #expect(codexCall.arguments == .object(["payload": .string("abc")]))
    #expect(codexCall.namespace == "dynamic_tools")

    let incomplete = try await responseEvents(
      protocolID: "openai-responses", modelID: "gpt-model",
      events: try #require(fixture.array("responsesIncompleteEvents")), tools: [], metadata: [:])
    #expect(incomplete.responseID == "resp-incomplete")
    #expect(incomplete.finishReason == .length)
    #expect(incomplete.rawFinishReason == "incomplete.max_output_tokens")
    #expect(incomplete.usage?.inputTokens == 25)
    #expect(incomplete.usage?.outputTokens == 12)
    #expect(incomplete.usage?.cachedInputTokens == 5)
    #expect(incomplete.usage?.cacheWriteTokens == 0)
    #expect(incomplete.usage?.totalTokens == 42)
  }

  @Test
  func responsesServiceTierMonetaryCostsMatchSourceAcrossFlavors() async throws {
    let fixture = try responseEventFixture()
    let usage = try #require(fixture.object("responsesServiceTierUsage"))
    let modelCost: [String: JSONValue] = [
      "input": .integer(1_000_000),
      "output": .integer(2_000_000),
      "cacheRead": .integer(3_000_000),
      "cacheWrite": .integer(4_000_000),
    ]
    let cases:
      [(
        protocolID: String, modelID: String, requestedTier: String?, responseTier: String?,
        expected: ProviderUsageCost
      )] = [
        (
          "openai-responses", "gpt-model", "flex", nil,
          ProviderUsageCost(input: 2.5, output: 4, cacheRead: 3, cacheWrite: 6, total: 15.5)
        ),
        (
          "openai-responses", "gpt-model", "flex", "priority",
          ProviderUsageCost(input: 10, output: 16, cacheRead: 12, cacheWrite: 24, total: 62)
        ),
        (
          "openai-responses", "gpt-5.5", nil, "priority",
          ProviderUsageCost(input: 12.5, output: 20, cacheRead: 15, cacheWrite: 30, total: 77.5)
        ),
        (
          "azure-openai-responses", "gpt-model", nil, "priority",
          ProviderUsageCost(input: 5, output: 8, cacheRead: 6, cacheWrite: 12, total: 31)
        ),
        (
          "openai-codex-responses", "gpt-model", "flex", "default",
          ProviderUsageCost(input: 2.5, output: 4, cacheRead: 3, cacheWrite: 6, total: 15.5)
        ),
        (
          "openai-codex-responses", "gpt-model", "flex", "priority",
          ProviderUsageCost(input: 10, output: 16, cacheRead: 12, cacheWrite: 24, total: 62)
        ),
      ]

    for testCase in cases {
      var response: [String: JSONValue] = [
        "id": .string("resp-cost"),
        "status": .string("completed"),
        "usage": .object(usage),
      ]
      if let tier = testCase.responseTier { response["service_tier"] = .string(tier) }
      let snapshot = try await responseEvents(
        protocolID: testCase.protocolID,
        modelID: testCase.modelID,
        events: [
          .object([
            "type": .string("response.created"),
            "response": .object(["id": .string("resp-cost"), "model": .string(testCase.modelID)]),
          ]),
          .object(["type": .string("response.completed"), "response": .object(response)]),
        ],
        tools: [], metadata: ["cost": .object(modelCost)],
        serviceTier: testCase.requestedTier)
      #expect(snapshot.usage?.cost == testCase.expected, Comment(rawValue: testCase.protocolID))
    }
  }

  @Test
  func malformedOpenAIPricingFailsExplicitly() async throws {
    do {
      _ = try await responseEvents(
        protocolID: "openai-responses", modelID: "gpt-model",
        events: [], tools: [],
        metadata: ["cost": .object(["input": .integer(1)])])
      Issue.record("expected malformed pricing failure")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .upstreamDrift)
      #expect(failure.operation == "openai-responses.usage.pricing")
    }

    do {
      _ = try await responseEvents(
        protocolID: "openai-responses", modelID: "gpt-model",
        events: [
          .object([
            "type": .string("response.created"),
            "response": .object(["id": .string("resp-missing-cost")]),
          ]),
          .object([
            "type": .string("response.completed"),
            "response": .object([
              "status": .string("completed"),
              "usage": .object(["input_tokens": .integer(1), "output_tokens": .integer(1)]),
            ]),
          ]),
        ], tools: [], metadata: ["cost": .null])
      Issue.record("expected missing pricing failure")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .upstreamDrift)
      #expect(failure.operation == "openai-responses.usage.pricing")
      #expect(failure.message.contains("missing"))
    }
  }

  @Test
  func responsesReasoningStopReasonsAndCustomCallsMatchAllFlavors() async throws {
    let fixture = try responseEventFixture()
    let flavors = [
      ("openai-responses", "gpt-model"),
      ("azure-openai-responses", "deployment-model"),
      ("openai-codex-responses", "gpt-5.1-codex"),
    ]
    for (protocolID, modelID) in flavors {
      let reasoning = try await responseEvents(
        protocolID: protocolID, modelID: modelID,
        events: try #require(fixture.array("responsesReasoningEvents")), tools: [], metadata: [:])
      #expect(reasoning.finishReason == .stop)
      #expect(reasoning.rawFinishReason == "completed")
      let reasoningContent = reasoning.content.compactMap { item -> ProviderReasoningContent? in
        guard case .reasoning(let value) = item else { return nil }
        return value
      }.first
      #expect(reasoningContent?.text == "summary")
      let signature = try #require(reasoningContent?.signature)
      let signatureJSON = try JSONDecoder().decode(JSONValue.self, from: Data(signature.utf8))
      #expect(signatureJSON.objectValue?.string("encrypted_content") == "encrypted")
      let textContent = reasoning.content.compactMap { item -> ProviderTextContent? in
        guard case .text(let value) = item else { return nil }
        return value
      }.first
      let textSignature = try #require(textContent?.signature)
      let textSignatureJSON = try JSONDecoder().decode(
        JSONValue.self, from: Data(textSignature.utf8))
      #expect(textSignatureJSON.objectValue?.string("phase") == "final_answer")

      let incomplete = try await responseEvents(
        protocolID: protocolID, modelID: modelID,
        events: try #require(fixture.array("responsesIncompleteEvents")), tools: [], metadata: [:])
      #expect(incomplete.finishReason == .length)
      #expect(incomplete.rawFinishReason == "incomplete.max_output_tokens")

      let custom = try await responseEvents(
        protocolID: protocolID, modelID: modelID,
        events: try #require(fixture.array("responsesCustomEvents")),
        tools: [responseGrammarTool()],
        metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])])
      #expect(custom.finishReason == .toolCalls)
      guard case .toolCall(let call) = custom.content.first else {
        Issue.record("expected custom tool call for \(protocolID)")
        continue
      }
      #expect(call.namespace == "dynamic_tools")
      #expect(call.arguments == .object(["payload": .string("abc")]))
    }
  }

  @Test
  func responsesFailureBranchesAreTypedAcrossAllFlavors() async throws {
    let fixture = try responseEventFixture()
    let failures = try #require(fixture.object("responsesFailureEvents"))
    let expectedCauses = [
      "failedError": "server_error",
      "failedDetails": "policy",
      "streamError": "bad_event",
      "contentFilter": "content_filter",
      "unknownStatus": "mystery",
    ]
    for (protocolID, modelID) in [
      ("openai-responses", "gpt-model"),
      ("azure-openai-responses", "deployment-model"),
      ("openai-codex-responses", "gpt-5.1-codex"),
    ] {
      for (name, cause) in expectedCauses {
        do {
          _ = try await responseEvents(
            protocolID: protocolID, modelID: modelID,
            events: try #require(failures[name]?.arrayValue), tools: [], metadata: [:])
          Issue.record("expected \(name) failure for \(protocolID)")
        } catch let failure as ProviderRuntimeFailure {
          #expect(failure.code == .transportFailed)
          #expect(failure.causeDescription == cause)
        }
      }
    }
  }

  @Test
  func completionsStructuredReasoningResponseModelAndUsageMatchSource() async throws {
    let fixture = try responseEventFixture()
    let chunks = try #require(fixture.array("completionChunks"))
    let transport = EventBranchTransport(chunks: completionSSE(chunks))
    let (request, context) = eventRequestContext(
      protocolID: "openai-completions", modelID: "requested-model", tools: [], metadata: [:])
    var snapshot: ProviderResponseSnapshot?
    for try await event in OpenAICompletionsAdapter().stream(
      request, context: context, transport: transport)
    {
      if case .responseSnapshot(let value) = event { snapshot = value }
    }
    let result = try #require(snapshot)
    #expect(result.responseID == "chat-1")
    #expect(result.modelID == "requested-model")
    #expect(result.responseModelID == "routed-model")
    #expect(result.finishReason == .stop)
    #expect(result.rawFinishReason == "stop")
    #expect(result.usage?.inputTokens == 7)
    #expect(result.usage?.outputTokens == 4)
    #expect(result.usage?.cachedInputTokens == 2)
    #expect(result.usage?.cacheWriteTokens == 1)
    #expect(result.usage?.reasoningTokens == 1)
    #expect(result.usage?.totalTokens == 14)
    let reasoning = result.content.compactMap { item -> ProviderReasoningContent? in
      guard case .reasoning(let value) = item else { return nil }
      return value
    }.first
    #expect(reasoning?.text == "think")
    let signatureData = try #require(reasoning?.signature?.data(using: .utf8))
    let details = try JSONDecoder().decode(JSONValue.self, from: signatureData)
    #expect(
      details
        == .array([
          .object([
            "type": .string("reasoning.text"), "text": .string("ab"),
            "id": .string("r1"), "signature": .string("sig"),
          ]),
          .object(["type": .string("reasoning.summary"), "summary": .string("sum")]),
          .object(["type": .string("reasoning.encrypted"), "data": .string("opaque")]),
        ]))
  }

  @Test
  func completionsStopReasonReasoningUsageCustomAndCompatBranchesMatchSource() async throws {
    let fixture = try responseEventFixture()
    let branches = try #require(fixture.object("completionBranchChunks"))

    let stop = try await completionEvents(try #require(branches["stop"]?.arrayValue))
    #expect(stop.finishReason == .stop)
    let length = try await completionEvents(try #require(branches["length"]?.arrayValue))
    #expect(length.finishReason == .length)
    let toolUse = try await completionEvents(try #require(branches["toolUse"]?.arrayValue))
    #expect(toolUse.finishReason == .toolCalls)

    let reasoning = try await completionEvents(
      try #require(branches["reasoningPrecedenceChoiceUsage"]?.arrayValue))
    let reasoningContent = reasoning.content.compactMap { item -> ProviderReasoningContent? in
      guard case .reasoning(let value) = item else { return nil }
      return value
    }.first
    #expect(reasoningContent?.text == "preferred")
    #expect(reasoningContent?.signature == "reasoning_content")
    #expect(reasoning.usage?.inputTokens == 4)
    #expect(reasoning.usage?.outputTokens == 3)
    #expect(reasoning.usage?.cachedInputTokens == 1)
    #expect(reasoning.usage?.reasoningTokens == 2)
    #expect(reasoning.usage?.totalTokens == 8)

    let custom = try await completionEvents(
      try #require(branches["customTool"]?.arrayValue), tools: [responseGrammarTool()],
      metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])])
    guard case .toolCall(let customCall) = custom.content.first else {
      Issue.record("expected custom completion tool call")
      return
    }
    #expect(customCall.arguments == .object(["payload": .string("abc")]))

    let missingFinish = try await completionEvents(
      try #require(branches["missingFinish"]?.arrayValue),
      metadata: ["compat": .object(["supportsFinishReason": .bool(false)])])
    #expect(missingFinish.finishReason == .stop)
    #expect(missingFinish.rawFinishReason == nil)
  }

  @Test
  func completionsErrorFinishReasonsAreTypedFailures() async throws {
    let branches = try #require(try responseEventFixture().object("completionBranchChunks"))
    for (name, cause, code) in [
      ("contentFilter", "content_filter", ProviderRuntimeFailure.Code.transportFailed),
      ("networkError", "network_error", ProviderRuntimeFailure.Code.transportFailed),
      ("unknownFinish", nil, ProviderRuntimeFailure.Code.invalidResponse),
    ] {
      do {
        _ = try await completionEvents(try #require(branches[name]?.arrayValue))
        Issue.record("expected \(name) completion failure")
      } catch let failure as ProviderRuntimeFailure {
        #expect(failure.code == code)
        #expect(failure.causeDescription == cause)
      }
    }
  }

  @Test
  func openAIAdaptersPreserveHTTPRawMetadataAndCancellation() async throws {
    let rawBody = Data(
      #"{"error":{"message":"bad request","metadata":{"raw":"provider raw detail"}}}"#.utf8)
    let rawTransport = EventBranchTransport(chunks: [rawBody], statusCode: 400)
    let (completionRequest, completionContext) = eventRequestContext(
      protocolID: "openai-completions", modelID: "requested-model", tools: [], metadata: [:])
    do {
      for try await _ in OpenAICompletionsAdapter().stream(
        completionRequest, context: completionContext, transport: rawTransport)
      {}
      Issue.record("expected HTTP raw metadata failure")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .transportFailed)
      #expect(failure.causeDescription?.contains("provider raw detail") == true)
    }

    for (protocolID, modelID) in [
      ("openai-completions", "requested-model"),
      ("openai-responses", "gpt-model"),
      ("azure-openai-responses", "deployment-model"),
      ("openai-codex-responses", "gpt-5.1-codex"),
    ] {
      let (request, context) = eventRequestContext(
        protocolID: protocolID, modelID: modelID, tools: [], metadata: [:])
      let stream =
        protocolID == "openai-completions"
        ? OpenAICompletionsAdapter().stream(
          request, context: context, transport: CancellationEventBranchTransport())
        : OpenAIResponsesAdapter(
          protocolID: protocolID,
          flavor: protocolID == "azure-openai-responses"
            ? .azure : (protocolID == "openai-codex-responses" ? .codex : .standard)
        ).stream(request, context: context, transport: CancellationEventBranchTransport())
      do {
        for try await _ in stream {}
        Issue.record("expected cancellation for \(protocolID)")
      } catch is CancellationError {
        // The adapters preserve the transport cancellation as the typed Swift cancellation.
      }
    }
  }
}

private actor EventBranchTransport: ProviderHTTPStreamingTransport {
  let chunks: [Data]
  let statusCode: Int
  init(chunks: [Data], statusCode: Int = 200) {
    self.chunks = chunks
    self.statusCode = statusCode
  }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    ProviderHTTPStreamingResponse(
      statusCode: statusCode, headers: [:],
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      })
  }
}

private actor CancellationEventBranchTransport: ProviderHTTPStreamingTransport {
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    throw CancellationError()
  }
}

private func completionEvents(
  _ chunks: [JSONValue],
  tools: [ProviderToolDefinition] = [],
  metadata: [String: JSONValue] = [:]
) async throws -> ProviderResponseSnapshot {
  let transport = EventBranchTransport(chunks: completionSSE(chunks))
  let (request, context) = eventRequestContext(
    protocolID: "openai-completions", modelID: "requested-model", tools: tools,
    metadata: metadata)
  var snapshot: ProviderResponseSnapshot?
  for try await event in OpenAICompletionsAdapter().stream(
    request, context: context, transport: transport)
  {
    if case .responseSnapshot(let value) = event { snapshot = value }
  }
  return try #require(snapshot)
}

private func responseGrammarTool() -> ProviderToolDefinition {
  ProviderToolDefinition(
    name: "sample_tool", description: "Sample tool",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object(["payload": .object(["type": .string("string")])]),
      "required": .array([.string("payload")]),
    ]),
    constrainedSampling: .grammar(variants: ["openai_lark": "start: /[a-z]+/"]))
}

private func responseEvents(
  protocolID: String,
  modelID: String,
  events: [JSONValue],
  tools: [ProviderToolDefinition],
  metadata: [String: JSONValue],
  serviceTier: String? = nil
) async throws -> ProviderResponseSnapshot {
  let transport = EventBranchTransport(chunks: responsesSSE(events))
  let (request, context) = eventRequestContext(
    protocolID: protocolID, modelID: modelID, tools: tools, metadata: metadata,
    serviceTier: serviceTier)
  var snapshot: ProviderResponseSnapshot?
  let adapter =
    protocolID == "openai-codex-responses"
    ? OpenAIResponsesAdapter(protocolID: protocolID, flavor: .codex)
    : protocolID == "azure-openai-responses"
      ? OpenAIResponsesAdapter(protocolID: protocolID, flavor: .azure)
      : OpenAIResponsesAdapter()
  for try await event in adapter.stream(
    request, context: context, transport: transport)
  {
    if case .responseSnapshot(let value) = event { snapshot = value }
  }
  return try #require(snapshot)
}

private func eventRequestContext(
  protocolID: String,
  modelID: String,
  tools: [ProviderToolDefinition],
  metadata: [String: JSONValue],
  serviceTier: String? = nil
) -> (ProviderRequest, WireProtocolContext) {
  let isCodex = protocolID == "openai-codex-responses"
  let isAzure = protocolID == "azure-openai-responses"
  let providerID = isCodex ? "openai-codex" : (isAzure ? "azure-openai-responses" : "openai")
  let model = ProviderModel(
    id: modelID,
    providerID: providerID,
    name: modelID, protocolID: protocolID,
    capabilities: ProviderCapabilities(
      textInput: true, imageInput: false, toolCalling: true, reasoning: true,
      structuredOutput: true, imageGeneration: false),
    contextWindow: 32_768, maximumOutputTokens: 4_096)
  let credential: ProviderCredential =
    isCodex
    ? .oauth(
      OAuthCredential(
        accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture,
        metadata: ["accountID": "fixture-account"]))
    : .apiKey(
      APIKeyCredential(
        key: "fixture", metadata: isAzure ? ["deploymentName": modelID] : [:]))
  var effectiveMetadata = metadata
  if effectiveMetadata["cost"] == nil {
    effectiveMetadata["cost"] = .object([
      "input": .integer(0), "output": .integer(0),
      "cacheRead": .integer(0), "cacheWrite": .integer(0),
    ])
  }
  return (
    ProviderRequest(
      id: "event", providerID: providerID, modelID: modelID,
      messages: [.user([.text("hello")])], tools: tools,
      options: ProviderGenerationOptions(
        maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
        responseSchema: nil, providerOptions: [:], serviceTier: serviceTier)),
    WireProtocolContext(
      provider: ProviderDescriptor(
        id: providerID, name: providerID, authorizationMethods: [], models: [model]),
      model: model, baseURL: URL(string: "https://fixture.invalid/v1")!, headers: [:],
      credential: credential,
      modelConfiguration: ProviderModelConfiguration(
        protocolID: protocolID, baseURL: nil, headers: [:], metadata: effectiveMetadata))
  )
}

private func responsesSSE(_ events: [JSONValue]) -> [Data] {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  let string = events.map { value in
    let data = try! encoder.encode(value)
    return "data: \(String(data: data, encoding: .utf8)!)\n\n"
  }.joined()
  return [Data(string.utf8)]
}

private func completionSSE(_ chunks: [JSONValue]) -> [Data] {
  responsesSSE(chunks) + [Data("data: [DONE]\n\n".utf8)]
}

private func responseEventFixture() throws -> [String: JSONValue] {
  try decodeJSONObject(
    Data(
      contentsOf: responseEventRepositoryRoot().appending(
        path: "Fixtures/OpenAIRequestBranches/Cases/response-event-branches.json")),
    providerID: "fixture", operation: "response-event.fixture")
}

private func responseEventRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
