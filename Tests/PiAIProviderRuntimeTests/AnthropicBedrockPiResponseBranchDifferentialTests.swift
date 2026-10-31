import CryptoKit
import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct AnthropicBedrockPiResponseBranchDifferentialTests {
  @Test
  func anthropicWireObservationsMatchPinnedSource() async throws {
    let fixture = try responseBranchFixture()
    let oracle = try responseBranchOracle()
    for scenario in fixture.scenarios
    where scenario.protocolID == "anthropic-messages" && scenario.observeWire == true {
      let expected = try #require(oracle.scenarios[scenario.caseID])
      let capture = AnthropicWireCapture()
      let mode = scenario.payloadMode
      var input = responseBranchInput(protocolID: scenario.protocolID)
      input.context.wireObserver = ProviderWireObserver(
        onPayload: { payload, context in
          await Task.yield()
          await capture.stage("payload", context)
          if mode == "replacement" {
            return payload.merging(["stream": .bool(false)]) { _, new in new }
          }
          if mode == "mutation" { payload["stream"] = .bool(false) }
          return nil
        },
        onResponse: { response, context in
          await Task.yield()
          await capture.response(response, context)
        },
        onProviderStreamEvent: { event, context in
          await Task.yield()
          await capture.event(event, context)
        })
      do {
        for try await _ in AnthropicMessagesAdapter().stream(
          input.request, context: input.context,
          transport: ResponseBranchTransport(input: expected.decoderInput, capture: capture))
        {}
        #expect(expected.outcome == "success")
      } catch {
        #expect(expected.outcome == "failure")
      }
      #expect(await capture.value() == expected.wire, "wire observations for \(scenario.caseID)")
      #expect(await capture.requestIDs.allSatisfy { $0 == input.request.id })
    }
  }

  @Test
  func bedrockWireObservationsMatchPinnedSourceBeforeNormalizationAndSigning() async throws {
    let fixture = try responseBranchFixture()
    let oracle = try responseBranchOracle()
    for scenario in fixture.scenarios
    where scenario.protocolID == "bedrock-converse-stream" && scenario.observeWire == true {
      let expected = try #require(oracle.scenarios[scenario.caseID])
      let capture = AnthropicWireCapture()
      var input = responseBranchInput(protocolID: scenario.protocolID)
      if scenario.caseID == "bedrock-stop" {
        input.context = WireProtocolContext(
          provider: input.context.provider, model: input.context.model,
          baseURL: input.context.baseURL, headers: [:],
          credential: .apiKey(
            .init(
              key: "synthetic-fixture-secret",
              metadata: [
                "authentication": "sigv4", "accessKeyID": "SYNTHETICFIXTURE", "region": "us-east-1",
              ])), modelConfiguration: input.context.modelConfiguration)
      }
      input.context.wireObserver = .init(
        onPayload: { payload, context in
          await Task.yield()
          await capture.stage("payload", context)
          var config = payload["inferenceConfig"]?.objectValue ?? [:]
          config["temperature"] = .number(0.25)
          payload["inferenceConfig"] = .object(config)
          return nil
        },
        onResponse: { response, context in
          await Task.yield()
          await capture.response(response, context)
        },
        onProviderStreamEvent: { event, context in
          await Task.yield()
          await capture.event(event, context)
        })
      do {
        for try await _ in BedrockConverseStreamAdapter().stream(
          input.request, context: input.context,
          transport: ResponseBranchTransport(input: expected.decoderInput, capture: capture))
        {}
        #expect(expected.outcome == "success")
      } catch let failure as ProviderRuntimeFailure {
        #expect(expected.outcome == "failure")
        #expect(failure.message == expected.terminal.objectValue?.string("errorMessage"))
      }
      #expect(await capture.bedrockValue() == expected.wire, Comment(rawValue: scenario.caseID))
      #expect(await capture.requestIDs.allSatisfy { $0 == input.request.id })
    }
  }

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
    for scenario in fixture.scenarios
    where scenario.category != "success" && scenario.category != "failureDiagnostics" {
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
        if ["anthropic-raw-error", "anthropic-error-event"].contains(scenario.caseID)
          || scenario.protocolID == "pi-messages" && scenario.category == "providerError"
        {
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

  @Test
  func bedrockFailureDiagnosticsMatchPinnedHTTPAndStreamErrors() async throws {
    let fixture = try responseBranchFixture()
    let oracle = try responseBranchOracle()
    for scenario in fixture.scenarios where scenario.protocolID == "bedrock-converse-stream" {
      let expected = try #require(oracle.scenarios[scenario.caseID])
      guard expected.outcome == "failure", let source = expected.terminal.objectValue else {
        continue
      }
      let before = Int64(Date().timeIntervalSince1970 * 1_000)
      var failure: ProviderRuntimeFailure?
      do { _ = try await replay(scenario: scenario, expected: expected) } catch let value
        as ProviderRuntimeFailure
      { failure = value }
      let after = Int64(Date().timeIntervalSince1970 * 1_000)
      let error = try #require(failure, Comment(rawValue: scenario.caseID))
      let diagnostics = try (error.providerMetadata?.array("diagnostics") ?? []).map {
        value -> JSONValue in
        var object = try #require(value.objectValue)
        let timestamp = try #require(object.int("timestamp"))
        #expect(Int64(timestamp) >= before && Int64(timestamp) <= after)
        object.removeValue(forKey: "timestamp")
        return .object(object)
      }
      #expect(diagnostics == source.array("diagnostics") ?? [], Comment(rawValue: scenario.caseID))
      #expect(error.message == source.string("errorMessage"), Comment(rawValue: scenario.caseID))
      if scenario.category == "failureDiagnostics" { #expect(error.code == .transportFailed) }
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
  var capture: AnthropicWireCapture? = nil

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    if let capture {
      let payload = try decodeJSONObject(
        try #require(request.httpBody), providerID: "anthropic", operation: "test.observer.payload")
      await capture.sent(payload["stream"])
      await capture.sentTemperature(payload.object("inferenceConfig")?["temperature"])
      if let digest = request.value(forHTTPHeaderField: "x-amz-content-sha256") {
        #expect(
          digest
            == SHA256.hash(data: try #require(request.httpBody)).map { String(format: "%02x", $0) }
            .joined())
      }
    }
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
  case .contentBlock: return nil
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
  var value: [String: JSONValue] = [
    "responseID": snapshot.responseID.map(JSONValue.string) ?? .null,
    "responseModel": snapshot.responseModelID.map(JSONValue.string) ?? .null,
    "providerID": .string(snapshot.providerID),
    "modelID": .string(snapshot.modelID),
    "stopReason": .string(sourceStopReason(snapshot.finishReason)),
    "rawStopReason": snapshot.rawFinishReason.map(JSONValue.string) ?? .null,
    "errorMessage": .null,
    "content": .array(snapshot.content.map(canonicalBranchContent)),
    "usage": usage,
  ]
  if snapshot.protocolID == "pi-messages",
    let level = snapshot.providerMetadata["providerThinkingLevel"]
  {
    value["providerThinkingLevel"] = level
  }
  if let diagnostics = snapshot.providerMetadata.array("diagnostics") {
    value["diagnostics"] = .array(
      try diagnostics.map { value in
        var object = try #require(value.objectValue)
        #expect(object.int("timestamp") != nil)
        object.removeValue(forKey: "timestamp")
        return .object(object)
      })
  }
  return .object(value)
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
  let observeWire: Bool?
  let payloadMode: String?
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
  let wire: JSONValue?
}

private actor AnthropicWireCapture {
  var stages: [String] = []
  var requestIDs: [String] = []
  var events: [JSONValue] = []
  var models: [JSONValue] = []
  var responses: [JSONValue] = []
  var streaming: JSONValue?
  var temperature: JSONValue?

  func stage(_ name: String, _ context: ProviderWireObserver.Context) {
    stages.append(name)
    requestIDs.append(context.requestID)
  }
  func sent(_ value: JSONValue?) { streaming = value }
  func sentTemperature(_ value: JSONValue?) { temperature = value }
  func response(_ response: ProviderWireObserver.Response, _ context: ProviderWireObserver.Context)
  {
    stage("response", context)
    responses.append(
      .object([
        "status": .integer(Int64(response.status)),
        "headers": .object(response.headers.mapValues(JSONValue.string)),
      ]))
  }
  func event(_ event: JSONValue, _ context: ProviderWireObserver.Context) {
    stage("event", context)
    events.append(event)
    models.append(
      .object([
        "id": .string(context.model.id), "provider": .string(context.model.providerID),
        "api": .string(context.model.protocolID),
      ]))
  }
  func value() -> JSONValue {
    .object([
      "stages": .array(stages.map(JSONValue.string)), "events": .array(events),
      "models": .array(models), "responses": .array(responses), "stream": streaming ?? .null,
    ])
  }
  func bedrockValue() -> JSONValue {
    .object([
      "stages": .array(stages.map(JSONValue.string)), "events": .array(events),
      "models": .array(models), "responses": .array(responses), "temperature": temperature ?? .null,
    ])
  }
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
