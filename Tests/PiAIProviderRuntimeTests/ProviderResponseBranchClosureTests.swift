import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ProviderResponseBranchClosureTests {
  @Test
  func googleWireObserversMatchPinnedSourceAcrossFlavors() async throws {
    let oracle = try providerResponseDecode(
      ProviderResponseBranchOracle.self,
      at: providerResponseRepositoryRoot().appending(
        path: "Fixtures/Differential/Oracle/response-provider-branches.json"))
    for api in ["google-generative-ai", "google-vertex"] {
      let expected = try #require(oracle.cases["google-native-wire-observer"]?[api])
      let wire = try #require(expected.wire?.objectValue)
      let capture = GoogleObserverCapture()
      var input = providerResponseInput(protocolID: api, caseID: "google-native-wire-observer")
      input.context.wireObserver = .init(
        onPayload: { payload, context in
          await Task.yield()
          await capture.stage("payload", context)
          var config = payload["generationConfig"]?.objectValue ?? [:]
          config["temperature"] = .number(0.5)
          payload["generationConfig"] = .object(config)
          return nil
        },
        onResponse: { _, context in await capture.stage("response", context) },
        onProviderStreamEvent: { event, context in
          await Task.yield()
          await capture.event(event, context)
        })
      let adapter = try #require(StandardWireProtocols.make().first { $0.protocolID == api })
      for try await _ in adapter.stream(
        input.request, context: input.context,
        transport: ProviderResponseBranchTransport(
          input: expected.decoderInput, observerCapture: capture))
      {}
      #expect(await capture.events == wire.array("events"), Comment(rawValue: api))
      #expect(await capture.models == wire.array("models"), Comment(rawValue: api))
      #expect(
        await capture.stages.map(JSONValue.string) == wire.array("stages"), Comment(rawValue: api))
      #expect(await capture.temperature == wire["temperature"], Comment(rawValue: api))
      #expect(wire.array("responses") == [])
      #expect(await capture.requestIDs.allSatisfy { $0 == input.request.id })
    }
  }

  @Test
  func googleMistralAndOpenRouterResponsesMatchPinnedSource() async throws {
    let repository = providerResponseRepositoryRoot()
    let fixture = try providerResponseDecode(
      ProviderResponseBranchFixture.self,
      at: repository.appending(
        path: "Fixtures/Differential/Cases/response-provider-branches.json")
    )
    let oracle = try providerResponseDecode(
      ProviderResponseBranchOracle.self,
      at: repository.appending(
        path: "Fixtures/Differential/Oracle/response-provider-branches.json")
    )
    #expect(fixture.schemaVersion == 1)
    #expect(oracle.schemaVersion == 1)
    #expect(fixture.upstreamRevision == oracle.upstreamRevision)

    var observedStopReasons: [String: Set<String>] = [:]

    for scenario in fixture.scenarios {
      for protocolID in scenario.protocolIDs {
        let expected = try #require(oracle.cases[scenario.caseID]?[protocolID])
        let adapter = try #require(
          StandardWireProtocols.make().first { $0.protocolID == protocolID })
        let input = providerResponseInput(protocolID: protocolID, caseID: scenario.caseID)
        var emitted: [ProviderEvent] = []
        do {
          for try await event in adapter.stream(
            input.request,
            context: input.context,
            transport: ProviderResponseBranchTransport(input: expected.decoderInput)
          ) {
            emitted.append(event)
          }
          if expected.sourceOutcome.kind == "failure" || expected.swiftExplicitFailure == true {
            Issue.record("\(scenario.caseID)/\(protocolID) accepted an invalid response")
            continue
          }
          let actualEvents = emitted.compactMap(providerBranchCanonicalEvent)
          #expect(
            actualEvents == expected.sourceOutcome.events,
            "event drift for \(scenario.caseID)/\(protocolID)"
          )
          let snapshots = emitted.compactMap { event -> ProviderResponseSnapshot? in
            guard case .responseSnapshot(let snapshot) = event else { return nil }
            return snapshot
          }
          let snapshot = try #require(snapshots.count == 1 ? snapshots[0] : nil)
          observedStopReasons[protocolID, default: []].insert(snapshot.finishReason.rawValue)
          #expect(
            providerBranchCanonicalSnapshot(
              snapshot,
              images: protocolID == "openrouter-images"
            ) == expected.sourceOutcome.terminalReplay,
            "terminal replay drift for \(scenario.caseID)/\(protocolID)"
          )
        } catch let failure as ProviderRuntimeFailure {
          #expect(
            expected.sourceOutcome.kind == "failure" || expected.swiftExplicitFailure == true,
            "unexpected typed failure for \(scenario.caseID)/\(protocolID): \(failure)"
          )
          #expect(failure.operation != nil)
          switch scenario.caseID {
          case "google-safety-stop", "google-sdk-error", "mistral-error-stop",
            "mistral-unknown-stop",
            "mistral-http-error", "openrouter-provider-error", "openrouter-http-error":
            #expect(failure.code == .transportFailed)
          default:
            #expect(failure.code == .invalidResponse)
          }
          if ["mistral-error-stop", "mistral-unknown-stop"].contains(scenario.caseID) {
            #expect(failure.message == expected.sourceOutcome.errorMessage)
            #expect(
              failure.providerMetadata?.string("rawStopReason")
                == expected.sourceOutcome.rawStopReason)
          }
          #expect(
            !emitted.contains { event in
              if case .completed = event { return true }
              return false
            })
        } catch {
          Issue.record(
            "\(scenario.caseID)/\(protocolID) emitted an untyped error: \(error)")
        }
      }
    }
    for (protocolID, expectedReasons) in fixture.stopReasonApplicability {
      #expect(
        observedStopReasons[protocolID, default: []] == Set(expectedReasons),
        "stop-reason applicability drift for \(protocolID)"
      )
    }
  }
}

private struct ProviderResponseBranchTransport: ProviderHTTPStreamingTransport {
  let input: ProviderResponseBranchDecoderInput
  var observerCapture: GoogleObserverCapture? = nil

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    if let observerCapture {
      let body = try decodeJSONObject(
        try #require(request.httpBody), providerID: "google", operation: "test.observer")
      await observerCapture.sent(body.object("generationConfig")?["temperature"])
    }
    if input.kind == "decoded-sdk-error" {
      throw NSError(
        domain: "ProviderResponseBranchFixture",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: input.errorMessage ?? "fixture SDK failure"]
      )
    }
    let data: Data
    switch input.kind {
    case "decoded-sdk-events", "http-sse":
      let records = try (input.events ?? []).map { value in
        "data: \(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))"
      }
      data = Data((records.joined(separator: "\n\n") + "\n\ndata: [DONE]\n\n").utf8)
    case "http-sse-raw":
      let records = (input.rawEvents ?? []).map { "data: \($0)" }
      data = Data((records.joined(separator: "\n\n") + "\n\ndata: [DONE]\n\n").utf8)
    case "http-json":
      data = try JSONEncoder().encode(input.body ?? .null)
    case "http-raw":
      data = Data((input.rawBody ?? "").utf8)
    default:
      throw ProviderRuntimeFailure(
        code: .upstreamDrift,
        message: "unsupported provider response fixture driver: \(input.kind)",
        providerID: nil,
        operation: "fixture.provider-response",
        causeDescription: nil
      )
    }
    return ProviderHTTPStreamingResponse(
      statusCode: input.status,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.yield(data)
        continuation.finish()
      }
    )
  }
}

private func providerResponseInput(
  protocolID: String,
  caseID: String
) -> (request: ProviderRequest, context: WireProtocolContext) {
  let isImage = protocolID == "openrouter-images"
  let providerID: String
  let modelID: String
  let baseURL: URL
  switch protocolID {
  case "google-generative-ai":
    providerID = "fixture-google"
    modelID = "gemini-3-flash-preview"
    baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
  case "google-vertex":
    providerID = "fixture-vertex"
    modelID = "gemini-3-flash-preview"
    baseURL = URL(string: "https://aiplatform.googleapis.com")!
  case "mistral-conversations":
    providerID = "fixture-mistral"
    modelID = "mistral-fixture"
    baseURL = URL(string: "https://api.mistral.ai")!
  default:
    providerID = "fixture-openrouter"
    modelID = "fixture-image"
    baseURL = URL(string: "https://openrouter.ai/api/v1")!
  }
  let model = ProviderModel(
    id: modelID,
    providerID: providerID,
    name: modelID,
    protocolID: protocolID,
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: !isImage,
      reasoning: !isImage,
      structuredOutput: !isImage,
      imageGeneration: isImage
    ),
    contextWindow: 262_144,
    maximumOutputTokens: 4_096
  )
  let metadata: [String: JSONValue] =
    isImage
    ? ["output": .array([.string("text"), .string("image")])]
    : [:]
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
    credential: .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:])),
    modelConfiguration: ProviderModelConfiguration(
      protocolID: protocolID,
      baseURL: nil,
      headers: [:],
      metadata: fixtureMetadataWithCost(metadata)
    )
  )
  let request = ProviderRequest(
    id: caseID,
    providerID: providerID,
    modelID: modelID,
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
      maximumOutputTokens: isImage ? nil : 4_096,
      temperature: nil,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: [:],
      outputModality: isImage ? .image : .text
    )
  )
  return (request, context)
}

private func providerBranchCanonicalEvent(_ event: ProviderEvent) -> JSONValue? {
  switch event {
  case .contentBlock: return nil
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
      "type": .string("toolCallStarted"), "id": .string(id), "name": .string(name),
    ])
  case .toolInputDelta(let id, let delta):
    return .object([
      "type": .string("toolInputDelta"), "id": .string(id), "delta": .string(delta),
    ])
  case .toolCallCompleted(let call):
    return .object([
      "type": .string("toolCallCompleted"),
      "toolCall": .object([
        "id": .string(call.id), "name": .string(call.name), "arguments": call.arguments,
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
    return .object([
      "type": .string("usage"),
      "inputTokens": usage.inputTokens.map { .integer(Int64($0)) } ?? .null,
      "outputTokens": usage.outputTokens.map { .integer(Int64($0)) } ?? .null,
      "reasoningTokens": usage.reasoningTokens.map { .integer(Int64($0)) } ?? .null,
      "cachedInputTokens": usage.cachedInputTokens.map { .integer(Int64($0)) } ?? .null,
    ])
  case .responseSnapshot:
    return nil
  case .completed(let reason):
    return .object(["type": .string("completed"), "reason": .string(reason.rawValue)])
  }
}

private func providerBranchCanonicalSnapshot(
  _ snapshot: ProviderResponseSnapshot,
  images: Bool
) -> JSONValue {
  let usage: JSONValue
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
    usage = .object(object)
  } else {
    usage = .null
  }
  if images {
    return .object([
      "responseID": snapshot.responseID.map(JSONValue.string) ?? .null,
      "providerID": .string(snapshot.providerID),
      "modelID": .string(snapshot.modelID),
      "stopReason": .string(snapshot.finishReason.rawValue),
      "output": .array(snapshot.content.map(providerBranchCanonicalContent)),
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
    "content": .array(snapshot.content.map(providerBranchCanonicalContent)),
    "usage": usage,
  ])
}

private func providerBranchCanonicalContent(_ content: ProviderResponseContent) -> JSONValue {
  switch content {
  case .text(let text):
    var object: [String: JSONValue] = ["type": .string("text"), "text": .string(text.text)]
    if let signature = text.signature { object["textSignature"] = .string(signature) }
    return .object(object)
  case .reasoning(let reasoning):
    var object: [String: JSONValue] = [
      "type": .string("thinking"), "thinking": .string(reasoning.text),
    ]
    if let signature = reasoning.signature { object["thinkingSignature"] = .string(signature) }
    return .object(object)
  case .toolCall(let call):
    var object: [String: JSONValue] = [
      "type": .string("toolCall"),
      "id": .string(call.id),
      "name": .string(call.name),
      "arguments": call.arguments,
    ]
    if let signature = call.thoughtSignature { object["thoughtSignature"] = .string(signature) }
    return .object(object)
  case .asset(let asset):
    return .object([
      "type": .string("image"),
      "data": .string(asset.data.base64EncodedString()),
      "mimeType": .string(asset.mimeType),
    ])
  }
}

private struct ProviderResponseBranchFixture: Decodable {
  let schemaVersion: Int
  let upstreamRevision: String
  let stopReasonApplicability: [String: [String]]
  let scenarios: [ProviderResponseBranchScenario]
}

private struct ProviderResponseBranchScenario: Decodable {
  let caseID: String
  let protocolIDs: [String]
}

private struct ProviderResponseBranchOracle: Decodable {
  let schemaVersion: Int
  let upstreamRevision: String
  let cases: [String: [String: ProviderResponseBranchOutcome]]
}

private struct ProviderResponseBranchOutcome: Decodable {
  let decoderInput: ProviderResponseBranchDecoderInput
  let sourceOutcome: ProviderResponseBranchSourceOutcome
  let swiftExplicitFailure: Bool?
  let wire: JSONValue?
}

private actor GoogleObserverCapture {
  var events: [JSONValue] = []
  var models: [JSONValue] = []
  var stages: [String] = []
  var requestIDs: [String] = []
  var temperature: JSONValue?
  func sent(_ value: JSONValue?) { temperature = value }
  func stage(_ name: String, _ context: ProviderWireObserver.Context) {
    stages.append(name)
    requestIDs.append(context.requestID)
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
}

private struct ProviderResponseBranchSourceOutcome: Decodable {
  let kind: String
  let events: [JSONValue]?
  let terminalReplay: JSONValue?
  let rawStopReason: String?
  let errorMessage: String?
}

private struct ProviderResponseBranchDecoderInput: Decodable, Sendable {
  let kind: String
  let status: Int
  let events: [JSONValue]?
  let body: JSONValue?
  let rawEvents: [String]?
  let rawBody: String?
  let errorMessage: String?
}

private func providerResponseRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

private func providerResponseDecode<Value: Decodable>(
  _ type: Value.Type,
  at url: URL
) throws -> Value {
  try JSONDecoder().decode(type, from: Data(contentsOf: url))
}
