import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct AnthropicBedrockRequestBranchDifferentialTests {
  @Test
  func sourceDerivedBranchMatrixMatchesPinnedAnthropicAndBedrockRequests() async throws {
    let root = repositoryRootForAnthropicBedrock()
    let fixture = try decodeAnthropicBedrockFixture(
      root.appending(path: "Fixtures/Differential/Cases/request-anthropic-bedrock.json"))
    let oracle = try decodeAnthropicBedrockOracle(
      root.appending(path: "Fixtures/Differential/Oracle/request-anthropic-bedrock.json"))
    #expect(fixture.caseID == oracle.caseID)
    #expect(fixture.upstreamRevision == oracle.upstreamRevision)
    #expect(Set(fixture.scenarios.map(\.caseID)) == Set(oracle.scenarios.keys))

    for scenario in fixture.scenarios
    where !["anthropic-server-fallback-source", "anthropic-missing-auth"].contains(scenario.caseID)
    {
      let expected = try #require(oracle.scenarios[scenario.caseID])
      let expectedBody = try #require(expected.requestBody)
      let actual = try await captureScenario(scenario.caseID)
      #expect(actual.body == expectedBody, "body drift for \(scenario.caseID)")
      if scenario.caseID.hasPrefix("anthropic-") {
        #expect(actual.headers == expected.headers, "header drift for \(scenario.caseID)")
      }
    }
  }

  @Test
  func sourceMissingAuthenticationFailsWithTypedMissingCredential() async throws {
    let root = repositoryRootForAnthropicBedrock()
    let oracle = try decodeAnthropicBedrockOracle(
      root.appending(path: "Fixtures/Differential/Oracle/request-anthropic-bedrock.json"))
    let source = try #require(oracle.scenarios["anthropic-missing-auth"])
    #expect(source.sourceFailure?.stopReason == "error")
    #expect(source.sourceFailure?.errorMessage.contains("No API key") == true)
    do {
      _ = try await captureScenario("anthropic-missing-auth")
      Issue.record("missing Anthropic authentication unexpectedly reached transport")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .missingCredential)
      #expect(error.operation == "anthropic.request.auth")
    }
  }

  @Test
  func sourceFallbackBranchIsRejectedWithTypedFailure() async throws {
    let root = repositoryRootForAnthropicBedrock()
    let oracle = try decodeAnthropicBedrockOracle(
      root.appending(path: "Fixtures/Differential/Oracle/request-anthropic-bedrock.json"))
    let source = try #require(oracle.scenarios["anthropic-server-fallback-source"])
    #expect(source.requestBody?.objectValue?["fallbacks"] != nil)
    do {
      _ = try await captureScenario("anthropic-server-fallback-source")
      Issue.record("server-side model fallback unexpectedly reached transport")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .unsupportedCapability)
      #expect(error.operation == "anthropic.request.server-fallback")
    }
  }

  private func captureScenario(_ caseID: String) async throws -> CapturedBranchRequest {
    let configuration = try scenarioConfiguration(caseID)
    let transport = BranchCaptureTransport()
    let adapter: any WireProtocolAdapter =
      configuration.protocolID == "anthropic-messages"
      ? AnthropicMessagesAdapter() : BedrockConverseStreamAdapter()
    do {
      for try await _ in adapter.stream(
        configuration.request, context: configuration.context, transport: transport)
      {}
    } catch {
      if await transport.request() == nil { throw error }
    }
    let sent = try #require(await transport.request())
    let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.httpBody))
    let selected = Set([
      "accept", "anthropic-beta", "anthropic-dangerous-direct-browser-access",
      "authorization", "x-api-key", "x-app", "x-session-affinity",
    ])
    let headers = Dictionary(
      uniqueKeysWithValues: sent.allHTTPHeaderFields?.compactMap { key, value in
        let lower = key.lowercased()
        return selected.contains(lower) ? (lower, value) : nil
      } ?? [])
    return CapturedBranchRequest(body: body, headers: headers)
  }

  private func scenarioConfiguration(_ caseID: String) throws -> BranchConfiguration {
    if caseID.hasPrefix("anthropic-") { return try anthropicConfiguration(caseID) }
    return try bedrockConfiguration(caseID)
  }

  private func anthropicConfiguration(_ caseID: String) throws -> BranchConfiguration {
    var modelID = "claude-sonnet-4-5"
    var providerID = "anthropic"
    var metadata: [String: JSONValue] = [:]
    var credential: ProviderCredential? = .apiKey(
      APIKeyCredential(key: "fixture-key", metadata: [:]))
    var headers: [String: String] = [:]
    var effort: ProviderReasoningEffort?
    var maximum = 4_096
    var temperature: Double?
    var cache: ProviderCacheRetention = .none
    var toolChoice: JSONValue?
    var providerOptions: [String: JSONValue] = [:]
    var budgets: [ProviderReasoningEffort: Int]?

    switch caseID {
    case "anthropic-api-key-system-cache-short":
      temperature = 0.25
      cache = .short
      toolChoice = .string("auto")
    case "anthropic-oauth-named-tool":
      credential = .oauth(
        OAuthCredential(
          accessToken: "sk-ant-oat-fixture", refreshToken: "",
          expiresAt: Date(timeIntervalSince1970: 4_102_444_800), metadata: [:]))
      toolChoice = .object(["type": .string("tool"), "name": .string("read")])
    case "anthropic-header-owned":
      credential = nil
      headers = ["x-api-key": "header-fixture"]
    case "anthropic-missing-auth":
      credential = nil
    case "anthropic-copilot":
      providerID = "github-copilot"
      credential = .apiKey(APIKeyCredential(key: "copilot-fixture", metadata: [:]))
    case "anthropic-compat-suppression":
      temperature = 0.4
      cache = .long
      metadata["compat"] = .object([
        "supportsEagerToolInputStreaming": .bool(false),
        "supportsCacheControlOnTools": .bool(false),
        "supportsTemperature": .bool(false),
        "supportsLongCacheRetention": .bool(false),
      ])
    case "anthropic-budget-custom-omitted":
      effort = .high
      maximum = 2_048
      temperature = 0.4
      budgets = [.high: 1_536]
    case "anthropic-budget-default-answer-room-clamp":
      effort = .high
      maximum = 2_048
    case "anthropic-adaptive-xhigh":
      modelID = "claude-opus-4-7"
      effort = .xhigh
      metadata["compat"] = .object(["forceAdaptiveThinking": .bool(true)])
      providerOptions["thinkingDisplay"] = .string("omitted")
    case "anthropic-tool-any":
      toolChoice = .string("any")
    case "anthropic-disabled": effort = .off
    case "anthropic-server-fallback-source":
      metadata["compat"] = .object([
        "allowedFallbackModels": .array([.object(["model": .string("claude-haiku-4-5")])])
      ])
    default: throw BranchFixtureError.unknownCase(caseID)
    }
    let modelMaximum = caseID == "anthropic-budget-default-answer-room-clamp" ? 2_048 : 64_000
    let model = branchModel(
      id: modelID, providerID: providerID, protocolID: "anthropic-messages",
      reasoning: true, maximumOutputTokens: modelMaximum)
    return BranchConfiguration(
      protocolID: "anthropic-messages",
      request: branchRequest(
        caseID: caseID, providerID: providerID, modelID: modelID, maximum: maximum,
        temperature: temperature, effort: effort, providerOptions: providerOptions,
        cache: cache, toolChoice: toolChoice, budgets: budgets),
      context: branchContext(
        model: model, headers: headers, credential: credential, metadata: metadata))
  }

  private func bedrockConfiguration(_ caseID: String) throws -> BranchConfiguration {
    var modelID = "amazon.nova-lite-v1:0"
    var modelName = modelID
    var reasoning = true
    var effort: ProviderReasoningEffort?
    var maximum = 4_096
    var cache: ProviderCacheRetention = .none
    var toolChoice: JSONValue?
    var providerOptions: [String: JSONValue] = [:]
    var budgets: [ProviderReasoningEffort: Int]?
    var metadata: [String: JSONValue] = [:]
    var credentialMetadata: [String: String] = [:]
    var messages: [ProviderMessage] = [.system("Be concise"), .user([.text("hello")])]

    switch caseID {
    case "bedrock-cache-short-signed":
      modelID = "anthropic.claude-sonnet-4-5"
      modelName = modelID
      cache = .short
      messages.append(
        .assistantMessage(branchAssistant(modelID: modelID, signature: "opaque-signature")))
    case "bedrock-cache-long-forced-nonclaude":
      cache = .long
      metadata["forcePromptCaching"] = .bool(true)
      messages.append(
        .assistantMessage(branchAssistant(modelID: modelID, signature: "opaque-signature")))
    case "bedrock-cache-unsupported-invalid-redacted":
      cache = .short
      messages.append(
        .assistantMessage(branchAssistant(modelID: modelID, signature: "%%%", redacted: true)))
    case "bedrock-budget-custom-interleaved":
      modelID = "anthropic.claude-sonnet-4-5"
      modelName = modelID
      effort = .high
      budgets = [.high: 1_536]
    case "bedrock-budget-default-answer-room-clamp":
      modelID = "anthropic.claude-sonnet-4-5"
      modelName = modelID
      effort = .high
      maximum = 2_048
    case "bedrock-adaptive-govcloud":
      modelID = "us-gov.anthropic.claude-sonnet-4-6"
      modelName = "Claude Sonnet 4.6"
      effort = .high
      credentialMetadata["region"] = "us-gov-west-1"
      providerOptions["thinkingDisplay"] = .string("omitted")
    case "bedrock-nonclaude-reasoning": effort = .high
    case "bedrock-tool-any": toolChoice = .string("any")
    case "bedrock-tool-named":
      toolChoice = .object(["type": .string("tool"), "name": .string("read")])
    default: throw BranchFixtureError.unknownCase(caseID)
    }
    if !modelID.contains("anthropic.claude") { reasoning = true }
    let modelMaximum = caseID == "bedrock-budget-default-answer-room-clamp" ? 2_048 : 64_000
    let model = branchModel(
      id: modelID, providerID: "amazon-bedrock", protocolID: "bedrock-converse-stream",
      reasoning: reasoning, maximumOutputTokens: modelMaximum, name: modelName)
    let request = ProviderRequest(
      id: caseID, providerID: "amazon-bedrock", modelID: modelID, messages: messages,
      tools: [branchTool()],
      options: ProviderGenerationOptions(
        maximumOutputTokens: maximum, temperature: nil, reasoningEffort: effort,
        responseSchema: nil, providerOptions: providerOptions, cacheRetention: cache,
        toolChoice: toolChoice, thinkingBudgets: budgets))
    return BranchConfiguration(
      protocolID: "bedrock-converse-stream", request: request,
      context: branchContext(
        model: model, headers: [:],
        credential: .apiKey(APIKeyCredential(key: "fixture-bearer", metadata: credentialMetadata)),
        metadata: metadata))
  }
}

private struct BranchConfiguration {
  let protocolID: String
  let request: ProviderRequest
  let context: WireProtocolContext
}

private struct CapturedBranchRequest {
  let body: JSONValue
  let headers: [String: String]
}

private actor BranchCaptureTransport: ProviderHTTPStreamingTransport {
  private var captured: URLRequest?
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    return ProviderHTTPStreamingResponse(
      statusCode: 418, headers: [:],
      body: AsyncThrowingStream { $0.finish() })
  }
  func request() -> URLRequest? { captured }
}

private func branchTool() -> ProviderToolDefinition {
  ProviderToolDefinition(
    name: "read", description: "Read data",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object(["path": .object(["type": .string("string")])]),
      "required": .array([.string("path")]),
    ]))
}

private func branchRequest(
  caseID: String, providerID: String, modelID: String, maximum: Int,
  temperature: Double?, effort: ProviderReasoningEffort?,
  providerOptions: [String: JSONValue], cache: ProviderCacheRetention,
  toolChoice: JSONValue?, budgets: [ProviderReasoningEffort: Int]?
) -> ProviderRequest {
  ProviderRequest(
    id: caseID, providerID: providerID, modelID: modelID,
    messages: [.system("Be concise"), .user([.text("hello")])], tools: [branchTool()],
    options: ProviderGenerationOptions(
      maximumOutputTokens: maximum, temperature: temperature, reasoningEffort: effort,
      responseSchema: nil, providerOptions: providerOptions, cacheRetention: cache,
      toolChoice: toolChoice, thinkingBudgets: budgets))
}

private func branchModel(
  id: String, providerID: String, protocolID: String, reasoning: Bool,
  maximumOutputTokens: Int, name: String? = nil
) -> ProviderModel {
  ProviderModel(
    id: id, providerID: providerID, name: name ?? id, protocolID: protocolID,
    capabilities: ProviderCapabilities(
      textInput: true, imageInput: true, toolCalling: true, reasoning: reasoning,
      structuredOutput: false, imageGeneration: false),
    contextWindow: 262_144, maximumOutputTokens: maximumOutputTokens)
}

private func branchContext(
  model: ProviderModel, headers: [String: String], credential: ProviderCredential?,
  metadata: [String: JSONValue]
) -> WireProtocolContext {
  WireProtocolContext(
    provider: ProviderDescriptor(
      id: model.providerID, name: model.providerID, authorizationMethods: [], models: [model]),
    model: model, baseURL: URL(string: "https://fixture.invalid")!, headers: headers,
    credential: credential,
    modelConfiguration: ProviderModelConfiguration(
      protocolID: model.protocolID, baseURL: nil, headers: [:], metadata: metadata))
}

private func branchAssistant(
  modelID: String, signature: String, redacted: Bool = false
) -> ProviderAssistantMessage {
  ProviderAssistantMessage(
    content: [
      .reasoning(
        ProviderReasoningContent(
          text: redacted ? "[Reasoning redacted]" : "inspect", signature: signature,
          isRedacted: redacted, providerMetadata: [:]))
    ],
    source: ProviderMessageSource(
      api: "bedrock-converse-stream", providerID: "amazon-bedrock", modelID: modelID),
    usage: ProviderUsage(
      inputTokens: 0, outputTokens: 0, reasoningTokens: nil, cachedInputTokens: 0,
      cacheWriteTokens: 0, totalTokens: 0, providerMetadata: [:]),
    stopReason: .stop, timestampMilliseconds: 1)
}

private struct AnthropicBedrockFixture: Decodable {
  let caseID: String
  let upstreamRevision: String
  let scenarios: [AnthropicBedrockScenario]
}
private struct AnthropicBedrockScenario: Decodable { let caseID: String }
private struct AnthropicBedrockOracle: Decodable {
  let caseID: String
  let upstreamRevision: String
  let scenarios: [String: AnthropicBedrockExpected]
}
private struct AnthropicBedrockExpected: Decodable {
  let requestBody: JSONValue?
  let headers: [String: String]
  let sourceFailure: AnthropicBedrockSourceFailure?
}
private struct AnthropicBedrockSourceFailure: Decodable {
  let stopReason: String
  let errorMessage: String
}
private enum BranchFixtureError: Error { case unknownCase(String) }

private func decodeAnthropicBedrockFixture(_ url: URL) throws -> AnthropicBedrockFixture {
  try JSONDecoder().decode(AnthropicBedrockFixture.self, from: Data(contentsOf: url))
}
private func decodeAnthropicBedrockOracle(_ url: URL) throws -> AnthropicBedrockOracle {
  try JSONDecoder().decode(AnthropicBedrockOracle.self, from: Data(contentsOf: url))
}
private func repositoryRootForAnthropicBedrock() -> URL {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
}
