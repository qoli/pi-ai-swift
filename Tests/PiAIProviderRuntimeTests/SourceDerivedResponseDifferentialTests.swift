import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct SourceDerivedResponseDifferentialTests {
  @Test
  func responseIdentityMatchesSourceForAliasesAndLateModelMetadata() async throws {
    let repository = responseRepositoryRoot()
    let fixture = try responseDecode(
      ResponseCase.self,
      at: repository.appending(path: "Fixtures/Differential/Cases/response-rich.json"))
    let oracle = try responseDecode(
      ResponseOracle.self,
      at: repository.appending(path: "Fixtures/Differential/Oracle/response-rich.json"))
    #expect(Set(fixture.identityCases.map(\.caseID)) == Set(oracle.identityCases.keys))
    for identityCase in fixture.identityCases {
      let expected = try #require(oracle.identityCases[identityCase.caseID])
      let protocolCase = identityCase.protocolCase
      let adapter = try #require(
        StandardWireProtocols.make().first { $0.protocolID == protocolCase.protocolID })
      let input = responseInput(protocolCase)
      var events: [ProviderEvent] = []
      for try await event in adapter.stream(
        input.request, context: input.context,
        transport: try ResponseReplayTransport(input: expected.decoderInput))
      {
        events.append(event)
      }
      #expect(
        events.compactMap(canonicalResponseEvent) == expected.normalizedEvents,
        Comment(rawValue: identityCase.caseID))
      let starts = events.compactMap { event -> ProviderResponseMetadata? in
        guard case .responseStarted(let metadata) = event else { return nil }
        return metadata
      }
      let start = try #require(starts.count == 1 ? starts.first : nil)
      #expect(start.providerID == input.request.providerID)
      #expect(start.modelID == input.request.modelID)
      let snapshots = events.compactMap { event -> ProviderResponseSnapshot? in
        guard case .responseSnapshot(let snapshot) = event else { return nil }
        return snapshot
      }
      let snapshot = try #require(snapshots.count == 1 ? snapshots.first : nil)
      #expect(snapshot.providerID == start.providerID)
      #expect(snapshot.modelID == start.modelID)
      #expect(
        canonicalResponseSnapshot(snapshot, images: protocolCase.protocolID == "openrouter-images")
          == expected.terminalReplay,
        Comment(rawValue: identityCase.caseID))
      if protocolCase.protocolID != "openrouter-images" {
        let replay = try snapshot.replayAssistantMessage()
        #expect(replay.source.modelID == input.request.modelID)
        #expect(replay.responseModelID == snapshot.responseModelID)
      }
    }
  }

  @Test
  func supportedResponseProtocolsMatchPinnedSourceNormalizedEvents() async throws {
    let repository = responseRepositoryRoot()
    let fixture = try responseDecode(
      ResponseCase.self,
      at: repository.appending(path: "Fixtures/Differential/Cases/response-rich.json")
    )
    let oracle = try responseDecode(
      ResponseOracle.self,
      at: repository.appending(path: "Fixtures/Differential/Oracle/response-rich.json")
    )

    #expect(fixture.caseID == oracle.caseID)
    #expect(fixture.upstreamRevision == oracle.upstreamRevision)
    #expect(Set(fixture.protocols.map(\.protocolID)) == Set(oracle.protocols.keys))
    #expect(Set(oracle.protocolSet) == Set(oracle.protocols.keys))

    for protocolCase in fixture.protocols {
      let expected = try #require(oracle.protocols[protocolCase.protocolID])
      let adapter = try #require(
        StandardWireProtocols.make().first { $0.protocolID == protocolCase.protocolID }
      )
      let input = responseInput(protocolCase)
      let transport = try ResponseReplayTransport(input: expected.decoderInput)
      var events: [ProviderEvent] = []
      for try await event in adapter.stream(
        input.request,
        context: input.context,
        transport: transport
      ) {
        events.append(event)
      }
      let actual = events.compactMap(canonicalResponseEvent)
      #expect(
        actual == expected.normalizedEvents,
        "source-derived response event drift for \(protocolCase.protocolID)"
      )
      let snapshots = events.compactMap { event -> ProviderResponseSnapshot? in
        guard case .responseSnapshot(let snapshot) = event else { return nil }
        return snapshot
      }
      let snapshot = try #require(
        snapshots.count == 1 ? snapshots[0] : nil,
        "successful stream must emit exactly one response snapshot for \(protocolCase.protocolID)"
      )
      #expect(snapshot.protocolID == protocolCase.protocolID)
      #expect(events.count >= 2)
      if events.count >= 2 {
        guard case .responseSnapshot = events[events.count - 2] else {
          Issue.record(
            "response snapshot must immediately precede completion for \(protocolCase.protocolID)")
          continue
        }
        guard case .completed(let reason) = events[events.count - 1] else {
          Issue.record("completion must be the final event for \(protocolCase.protocolID)")
          continue
        }
        #expect(snapshot.finishReason == reason)
      }
      #expect(
        canonicalResponseSnapshot(snapshot, images: protocolCase.protocolID == "openrouter-images")
          == expected.terminalReplay,
        "source-derived terminal replay drift for \(protocolCase.protocolID)"
      )

      if let expectedTierCost = expected.costVariants?["tier"] {
        let tierInput = responseInput(
          protocolCase,
          costMetadata: .object([
            "input": .integer(1_000_000), "output": .integer(2_000_000),
            "cacheRead": .integer(3_000_000), "cacheWrite": .integer(4_000_000),
            "tiers": .array([
              .object([
                "inputTokensAbove": .integer(0),
                "input": .integer(5_000_000), "output": .integer(6_000_000),
                "cacheRead": .integer(7_000_000), "cacheWrite": .integer(8_000_000),
              ])
            ]),
          ]))
        var tierSnapshot: ProviderResponseSnapshot?
        for try await event in adapter.stream(
          tierInput.request,
          context: tierInput.context,
          transport: try ResponseReplayTransport(input: expected.decoderInput)
        ) {
          if case .responseSnapshot(let snapshot) = event { tierSnapshot = snapshot }
        }
        let tierCost = try #require(tierSnapshot?.usage?.cost)
        #expect(
          canonicalUsageCost(tierCost) == expectedTierCost,
          "source-derived tier cost drift for \(protocolCase.protocolID)")
      }
    }
  }
}

private struct ResponseReplayTransport: ProviderHTTPStreamingTransport {
  let input: ResponseDecoderInput

  init(input: ResponseDecoderInput) throws {
    self.input = input
  }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    let chunks = try replayChunks()
    return ProviderHTTPStreamingResponse(
      statusCode: input.status ?? 200,
      headers: input.headers ?? [:],
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      }
    )
  }

  private func replayChunks() throws -> [Data] {
    switch input.kind {
    case "http-sse", "aws-eventstream":
      return try (input.chunksBase64 ?? []).map { value in
        try #require(Data(base64Encoded: value))
      }
    case "decoded-sdk-events":
      let encoder = JSONEncoder()
      let records = try (input.events ?? []).map { event in
        "data: \(String(decoding: try encoder.encode(event), as: UTF8.self))"
      }
      return [Data((records.joined(separator: "\n\n") + "\n\n").utf8)]
    case "http-json":
      return [try JSONEncoder().encode(input.body ?? .null)]
    default:
      throw ProviderRuntimeFailure(
        code: .upstreamDrift,
        message: "unsupported response differential input kind: \(input.kind)",
        providerID: nil,
        operation: "fixture.response.replay",
        causeDescription: nil
      )
    }
  }
}

private func responseInput(
  _ protocolCase: ResponseProtocolCase,
  costMetadata: JSONValue? = nil
) -> (request: ProviderRequest, context: WireProtocolContext) {
  let isImage = protocolCase.protocolID == "openrouter-images"
  let model = ProviderModel(
    id: protocolCase.modelID,
    providerID: protocolCase.providerID,
    name: protocolCase.modelID,
    protocolID: protocolCase.protocolID,
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: !isImage,
      reasoning: !isImage,
      structuredOutput: !isImage,
      imageGeneration: isImage
    ),
    contextWindow: 262_144,
    maximumOutputTokens: 4096
  )
  var metadata: [String: JSONValue] = [:]
  if protocolCase.protocolID != "pi-messages" {
    metadata["cost"] =
      costMetadata
      ?? .object([
        "input": .integer(1_000_000), "output": .integer(2_000_000),
        "cacheRead": .integer(3_000_000), "cacheWrite": .integer(4_000_000),
      ])
  }
  if protocolCase.protocolID == "google-vertex" {
    metadata["project"] = .string("fixture-project")
    metadata["location"] = .string("us-central1")
  }
  if isImage { metadata["output"] = .array([.string("text"), .string("image")]) }
  let credential =
    protocolCase.protocolID == "openai-codex-responses"
    ? "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiZml4dHVyZS1hY2NvdW50In19.fixture"
    : "fixture-key"
  let context = WireProtocolContext(
    provider: ProviderDescriptor(
      id: protocolCase.providerID,
      name: protocolCase.providerID,
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: URL(string: protocolCase.baseURL)!,
    headers: [:],
    credential: .apiKey(APIKeyCredential(key: credential, metadata: [:])),
    modelConfiguration: ProviderModelConfiguration(
      protocolID: protocolCase.protocolID,
      baseURL: nil,
      headers: [:],
      metadata: metadata
    )
  )
  let request = ProviderRequest(
    id: "response-rich-v1",
    providerID: protocolCase.providerID,
    modelID: protocolCase.modelID,
    messages: [.user([.text(isImage ? "create an image" : "Use the weather tool")])],
    tools: isImage
      ? []
      : [
        ProviderToolDefinition(
          name: "weather",
          description: "Read weather",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["city": .object(["type": .string("string")])]),
            "required": .array([.string("city")]),
          ])
        )
      ],
    options: ProviderGenerationOptions(
      maximumOutputTokens: isImage ? nil : 4096,
      temperature: nil,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: protocolCase.protocolID == "google-vertex"
        ? [
          "project": .string("fixture-project"),
          "location": .string("us-central1"),
        ] : [:],
      outputModality: isImage ? .image : .text
    )
  )
  return (request, context)
}

private func canonicalResponseEvent(_ event: ProviderEvent) -> JSONValue? {
  switch event {
  case .responseStarted(let metadata):
    return .object([
      "type": .string("responseStarted"),
      "responseID": metadata.responseID.map(JSONValue.string) ?? .null,
      "providerID": .string(metadata.providerID),
      "modelID": .string(metadata.modelID),
    ])
  case .textDelta(let delta):
    return .object(["type": .string("textDelta"), "delta": .string(delta)])
  case .reasoningDelta(let delta):
    return .object(["type": .string("reasoningDelta"), "delta": .string(delta)])
  case .reasoningSignatureDelta(let delta):
    return .object(["type": .string("reasoningSignatureDelta"), "delta": .string(delta)])
  case .toolCallStarted(let id, let name):
    return .object([
      "type": .string("toolCallStarted"),
      "id": .string(id),
      "name": .string(name),
    ])
  case .toolInputDelta(let id, let delta):
    return .object([
      "type": .string("toolInputDelta"),
      "id": .string(id),
      "delta": .string(delta),
    ])
  case .toolCallCompleted(let call):
    return .object([
      "type": .string("toolCallCompleted"),
      "toolCall": .object([
        "id": .string(call.id),
        "name": .string(call.name),
        "arguments": call.arguments,
      ]),
    ])
  case .asset(let asset):
    return .object([
      "type": .string("asset"),
      "id": .string(asset.id),
      "kind": .string(asset.kind.rawValue),
      "mimeType": .string(asset.mimeType),
      "dataBase64": .string(asset.data.base64EncodedString()),
    ])
  case .usage(let usage):
    var object: [String: JSONValue] = [
      "type": .string("usage"),
      "inputTokens": usage.inputTokens.map { .integer(Int64($0)) } ?? .null,
      "outputTokens": usage.outputTokens.map { .integer(Int64($0)) } ?? .null,
      "reasoningTokens": usage.reasoningTokens.map { .integer(Int64($0)) } ?? .null,
      "cachedInputTokens": usage.cachedInputTokens.map { .integer(Int64($0)) } ?? .null,
    ]
    if let cost = usage.cost { object["cost"] = canonicalUsageCost(cost) }
    return .object(object)
  case .responseSnapshot:
    return nil
  case .completed(let reason):
    return .object([
      "type": .string("completed"),
      "reason": .string(reason.rawValue),
    ])
  }
}

private func canonicalResponseSnapshot(
  _ snapshot: ProviderResponseSnapshot,
  images: Bool
) -> JSONValue {
  var usage: JSONValue = .null
  if let value = snapshot.usage {
    var object: [String: JSONValue] = [
      "input": value.inputTokens.map { .integer(Int64($0)) } ?? .null,
      "output": value.outputTokens.map { .integer(Int64($0)) } ?? .null,
      "cacheRead": value.cachedInputTokens.map { .integer(Int64($0)) } ?? .null,
      "cacheWrite": value.cacheWriteTokens.map { .integer(Int64($0)) } ?? .null,
      "totalTokens": value.totalTokens.map { .integer(Int64($0)) } ?? .null,
    ]
    if !images {
      object["reasoning"] = value.reasoningTokens.map { .integer(Int64($0)) } ?? .null
    }
    if let cost = value.cost { object["cost"] = canonicalUsageCost(cost) }
    usage = .object(object)
  }
  if images {
    return .object([
      "responseID": snapshot.responseID.map(JSONValue.string) ?? .null,
      "providerID": .string(snapshot.providerID),
      "modelID": .string(snapshot.modelID),
      "stopReason": .string(snapshot.finishReason.rawValue),
      "output": .array(snapshot.content.map(canonicalImageOutput)),
      "usage": usage,
    ])
  }
  return .object([
    "responseID": snapshot.responseID.map(JSONValue.string) ?? .null,
    "responseModel": snapshot.responseModelID.map(JSONValue.string) ?? .null,
    "providerID": .string(snapshot.providerID),
    "modelID": .string(snapshot.modelID),
    "stopReason": .string(snapshot.finishReason.rawValue),
    "rawStopReason": snapshot.rawFinishReason.map(JSONValue.string) ?? .null,
    "content": .array(snapshot.content.map(canonicalAssistantContent)),
    "usage": usage,
  ])
}

private func canonicalUsageCost(_ cost: ProviderUsageCost) -> JSONValue {
  .object([
    "input": canonicalNumber(cost.input),
    "output": canonicalNumber(cost.output),
    "cacheRead": canonicalNumber(cost.cacheRead),
    "cacheWrite": canonicalNumber(cost.cacheWrite),
    "total": canonicalNumber(cost.total),
  ])
}

private func canonicalNumber(_ value: Double) -> JSONValue {
  if value.rounded() == value, let integer = Int64(exactly: value) { return .integer(integer) }
  return .number(value)
}

private func canonicalAssistantContent(_ content: ProviderResponseContent) -> JSONValue {
  switch content {
  case .text(let text):
    var object: [String: JSONValue] = ["type": .string("text"), "text": .string(text.text)]
    if let signature = text.signature { object["textSignature"] = .string(signature) }
    return .object(object)
  case .reasoning(let reasoning):
    var object: [String: JSONValue] = [
      "type": .string("thinking"),
      "thinking": .string(reasoning.text),
    ]
    if let signature = reasoning.signature { object["thinkingSignature"] = .string(signature) }
    if let redacted = reasoning.isRedacted { object["redacted"] = .bool(redacted) }
    return .object(object)
  case .toolCall(let call):
    var object: [String: JSONValue] = [
      "type": .string("toolCall"),
      "id": .string(call.id),
      "name": .string(call.name),
      "arguments": call.arguments,
    ]
    if let signature = call.thoughtSignature { object["thoughtSignature"] = .string(signature) }
    if let namespace = call.namespace { object["namespace"] = .string(namespace) }
    return .object(object)
  case .asset(let asset):
    return .object([
      "type": .string("image"),
      "data": .string(asset.data.base64EncodedString()),
      "mimeType": .string(asset.mimeType),
    ])
  }
}

private func canonicalImageOutput(_ content: ProviderResponseContent) -> JSONValue {
  canonicalAssistantContent(content)
}

private struct ResponseCase: Decodable {
  let caseID: String
  let upstreamRevision: String
  let protocols: [ResponseProtocolCase]
  let identityCases: [ResponseIdentityCase]
}

private struct ResponseIdentityCase: Decodable {
  let caseID: String
  let protocolID: String
  let providerID: String
  let modelID: String
  let baseURL: String

  var protocolCase: ResponseProtocolCase {
    ResponseProtocolCase(
      protocolID: protocolID, providerID: providerID, modelID: modelID, baseURL: baseURL)
  }
}

private struct ResponseProtocolCase: Decodable {
  let protocolID: String
  let providerID: String
  let modelID: String
  let baseURL: String
}

private struct ResponseOracle: Decodable {
  let caseID: String
  let upstreamRevision: String
  let protocolSet: [String]
  let protocols: [String: ResponseOracleProtocol]
  let identityCases: [String: ResponseOracleProtocol]
}

private struct ResponseOracleProtocol: Decodable {
  let decoderInput: ResponseDecoderInput
  let normalizedEvents: [JSONValue]
  let terminalReplay: JSONValue
  let costVariants: [String: JSONValue]?
}

private struct ResponseDecoderInput: Decodable, Sendable {
  let kind: String
  let status: Int?
  let headers: [String: String]?
  let chunksBase64: [String]?
  let events: [JSONValue]?
  let body: JSONValue?
}

private func responseRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

private func responseDecode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
  try JSONDecoder().decode(type, from: Data(contentsOf: url))
}
