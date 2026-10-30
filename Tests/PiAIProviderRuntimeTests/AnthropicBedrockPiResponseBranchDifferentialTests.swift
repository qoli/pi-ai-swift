import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct AnthropicBedrockPiResponseBranchDifferentialTests {
  @Test
  func successResponseBranchesMatchPinnedSource() async throws {
    let fixture = try responseBranchFixture()
    let oracle = try responseBranchOracle()
    #expect(fixture.caseID == oracle.caseID)
    #expect(fixture.upstreamRevision == oracle.upstreamRevision)

    for scenario in fixture.scenarios where scenario.category == "success" {
      let expected = try #require(oracle.scenarios[scenario.caseID])
      let result = try await replay(scenario: scenario, expected: expected)
      #expect(result.events == expected.events, "response event drift for \(scenario.caseID)")
      #expect(
        result.terminal == expected.terminal, "terminal response drift for \(scenario.caseID)")
    }
  }

  @Test
  func providerErrorsAndInvalidWireDataFailExplicitly() async throws {
    let fixture = try responseBranchFixture()
    let oracle = try responseBranchOracle()
    for scenario in fixture.scenarios where scenario.category != "success" {
      let expected = try #require(oracle.scenarios[scenario.caseID])
      #expect(expected.outcome == "failure")
      do {
        _ = try await replay(scenario: scenario, expected: expected)
        Issue.record("\(scenario.caseID) unexpectedly completed")
      } catch let error as ProviderRuntimeFailure {
        let expectedCode: ProviderRuntimeFailure.Code =
          scenario.category == "providerError" ? .transportFailed : .invalidResponse
        #expect(error.code == expectedCode, "typed failure drift for \(scenario.caseID)")
        #expect(error.operation?.contains("event") == true)
        if ["anthropic-raw-error", "anthropic-error-event"].contains(scenario.caseID) {
          #expect(error.message == expected.terminal.objectValue?.string("errorMessage"))
        }
        if scenario.caseID == "bedrock-provider-stop-error"
          || (scenario.protocolID == "anthropic-messages"
            && expected.terminal.objectValue?.string("rawStopReason") != nil)
        {
          #expect(
            error.providerMetadata?.string("rawStopReason")
              == expected.terminal.objectValue?.string("rawStopReason"))
          #expect(error.message == expected.terminal.objectValue?.string("errorMessage"))
        }
      }
    }
  }

  private func replay(
    scenario: ResponseBranchScenario,
    expected: ResponseBranchExpected
  ) async throws -> ResponseBranchResult {
    let input = responseBranchInput(protocolID: scenario.protocolID, cost: scenario.cost)
    let adapter = try #require(
      StandardWireProtocols.make().first { $0.protocolID == scenario.protocolID })
    var events: [JSONValue] = []
    var terminal: JSONValue?
    for try await event in adapter.stream(
      input.request,
      context: input.context,
      transport: ResponseBranchTransport(input: expected.decoderInput)
    ) {
      if let value = canonicalBranchEvent(event) { events.append(value) }
      if case .responseSnapshot(let snapshot) = event {
        terminal = try canonicalBranchSnapshot(snapshot)
      }
    }
    return ResponseBranchResult(events: events, terminal: try #require(terminal))
  }
}

private struct ResponseBranchTransport: ProviderHTTPStreamingTransport {
  let input: ResponseBranchDecoderInput

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    let chunks = try input.chunksBase64.map { value in
      try #require(Data(base64Encoded: value))
    }
    return ProviderHTTPStreamingResponse(
      statusCode: input.status,
      headers: input.headers,
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      })
  }
}

private func responseBranchInput(
  protocolID: String, cost: [String: JSONValue]? = nil
) -> (request: ProviderRequest, context: WireProtocolContext) {
  let providerID: String
  switch protocolID {
  case "anthropic-messages": providerID = "anthropic"
  case "bedrock-converse-stream": providerID = "amazon-bedrock"
  default: providerID = "fixture-pi"
  }
  let model = ProviderModel(
    id: "fixture-model",
    providerID: providerID,
    name: "fixture-model",
    protocolID: protocolID,
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: true,
      reasoning: true,
      structuredOutput: false,
      imageGeneration: false),
    contextWindow: 262_144,
    maximumOutputTokens: 4_096)
  let context = WireProtocolContext(
    provider: ProviderDescriptor(
      id: providerID,
      name: providerID,
      authorizationMethods: [],
      models: [model]),
    model: model,
    baseURL: URL(string: "https://fixture.invalid")!,
    headers: [:],
    credential: .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:])),
    modelConfiguration: ProviderModelConfiguration(
      protocolID: protocolID,
      baseURL: nil,
      headers: [:],
      metadata: fixtureMetadataWithCost(cost.map { ["cost": .object($0)] } ?? [:])))
  let request = ProviderRequest(
    id: "response-branch",
    providerID: providerID,
    modelID: model.id,
    messages: [.user([.text("fixture")])],
    tools: [],
    options: ProviderGenerationOptions(
      maximumOutputTokens: 4_096,
      temperature: nil,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: [:],
      cacheRetention: .none))
  return (request, context)
}

private func canonicalBranchEvent(_ event: ProviderEvent) -> JSONValue? {
  switch event {
  case .textDelta(let delta):
    return .object(["type": .string("textDelta"), "delta": .string(delta)])
  case .reasoningDelta(let delta):
    return .object(["type": .string("reasoningDelta"), "delta": .string(delta)])
  case .reasoningSignatureDelta(let delta):
    return .object(["type": .string("reasoningSignatureDelta"), "delta": .string(delta)])
  case .toolCallStarted(let id, let name):
    return .object([
      "type": .string("toolCallStarted"), "id": .string(id), "name": .string(name),
    ])
  case .toolInputDelta(let id, let delta):
    return .object([
      "type": .string("toolInputDelta"), "id": .string(id), "delta": .string(delta),
    ])
  case .toolCallCompleted(let call):
    var value: [String: JSONValue] = [
      "type": .string("toolCall"),
      "id": .string(call.id),
      "name": .string(call.name),
      "arguments": call.arguments,
    ]
    if let signature = call.thoughtSignature { value["thoughtSignature"] = .string(signature) }
    if let namespace = call.namespace { value["namespace"] = .string(namespace) }
    return .object([
      "type": .string("toolCallCompleted"), "toolCall": .object(value),
    ])
  case .responseStarted, .usage, .responseSnapshot, .completed, .asset:
    return nil
  }
}

private func canonicalBranchNumber(_ value: Double?) throws -> JSONValue {
  guard let value else { return .null }
  return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func canonicalBranchSnapshot(_ snapshot: ProviderResponseSnapshot) throws -> JSONValue {
  let usage: JSONValue
  if let value = snapshot.usage {
    usage = .object([
      "input": value.inputTokens.map { .integer(Int64($0)) } ?? .null,
      "output": value.outputTokens.map { .integer(Int64($0)) } ?? .null,
      "reasoning": value.reasoningTokens.map { .integer(Int64($0)) } ?? .null,
      "cacheRead": value.cachedInputTokens.map { .integer(Int64($0)) } ?? .null,
      "cacheWrite": value.cacheWriteTokens.map { .integer(Int64($0)) } ?? .null,
      "cacheWrite1h": value.providerMetadata["cacheWrite1h"] ?? .null,
      "cacheWriteCost": try canonicalBranchNumber(value.cost?.cacheWrite),
      "totalTokens": value.totalTokens.map { .integer(Int64($0)) } ?? .null,
    ])
  } else {
    usage = .null
  }
  return .object([
    "responseID": snapshot.responseID.map(JSONValue.string) ?? .null,
    "responseModel": snapshot.responseModelID.map(JSONValue.string) ?? .null,
    "providerID": .string(snapshot.providerID),
    "modelID": .string(snapshot.modelID),
    "stopReason": .string(sourceStopReason(snapshot.finishReason)),
    "rawStopReason": snapshot.rawFinishReason.map(JSONValue.string) ?? .null,
    "errorMessage": .null,
    "content": .array(snapshot.content.map(canonicalBranchContent)),
    "usage": usage,
  ])
}

private func sourceStopReason(_ reason: ProviderFinishReason) -> String {
  reason == .toolCalls ? "toolUse" : reason.rawValue
}

private func canonicalBranchContent(_ content: ProviderResponseContent) -> JSONValue {
  switch content {
  case .text(let text):
    var value: [String: JSONValue] = ["type": .string("text"), "text": .string(text.text)]
    if let signature = text.signature { value["textSignature"] = .string(signature) }
    return .object(value)
  case .reasoning(let reasoning):
    var value: [String: JSONValue] = [
      "type": .string("thinking"), "thinking": .string(reasoning.text),
    ]
    if let signature = reasoning.signature { value["thinkingSignature"] = .string(signature) }
    if let redacted = reasoning.isRedacted { value["redacted"] = .bool(redacted) }
    return .object(value)
  case .toolCall(let call):
    var value: [String: JSONValue] = [
      "type": .string("toolCall"),
      "id": .string(call.id),
      "name": .string(call.name),
      "arguments": call.arguments,
    ]
    if let signature = call.thoughtSignature { value["thoughtSignature"] = .string(signature) }
    if let namespace = call.namespace { value["namespace"] = .string(namespace) }
    return .object(value)
  case .asset(let asset):
    return .object([
      "type": .string("image"),
      "data": .string(asset.data.base64EncodedString()),
      "mimeType": .string(asset.mimeType),
    ])
  }
}

private struct ResponseBranchResult {
  let events: [JSONValue]
  let terminal: JSONValue
}

private struct ResponseBranchFixture: Decodable {
  let caseID: String
  let upstreamRevision: String
  let scenarios: [ResponseBranchScenario]
}

private struct ResponseBranchScenario: Decodable {
  let caseID: String
  let protocolID: String
  let category: String
  let cost: [String: JSONValue]?
}

private struct ResponseBranchOracle: Decodable {
  let caseID: String
  let upstreamRevision: String
  let scenarios: [String: ResponseBranchExpected]
}

private struct ResponseBranchExpected: Decodable {
  let outcome: String
  let events: [JSONValue]
  let terminal: JSONValue
  let decoderInput: ResponseBranchDecoderInput
}

private struct ResponseBranchDecoderInput: Decodable, Sendable {
  let kind: String
  let status: Int
  let headers: [String: String]
  let chunksBase64: [String]
}

private func responseBranchFixture() throws -> ResponseBranchFixture {
  try responseBranchDecode(
    ResponseBranchFixture.self,
    path: "Fixtures/Differential/Cases/response-anthropic-bedrock-pi.json")
}

private func responseBranchOracle() throws -> ResponseBranchOracle {
  try responseBranchDecode(
    ResponseBranchOracle.self,
    path: "Fixtures/Differential/Oracle/response-anthropic-bedrock-pi.json")
}

private func responseBranchDecode<Value: Decodable>(
  _ type: Value.Type,
  path: String
) throws -> Value {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  return try JSONDecoder().decode(type, from: Data(contentsOf: root.appending(path: path)))
}
