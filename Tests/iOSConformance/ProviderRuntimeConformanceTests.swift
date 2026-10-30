import Foundation
import XCTest

@testable import PiAIProviderRuntime

@MainActor
final class ProviderRuntimeConformanceTests: XCTestCase {
  func testCompletionsTerminationMatchesPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    let cases = try XCTUnwrap(fixture.object("completionTransportCases"))
    let expectedCases = try XCTUnwrap(
      oracle.object("cases")?.object("completions.transport-termination"))
    for name in cases.keys.sorted() {
      let spec = try XCTUnwrap(cases[name]?.objectValue)
      let expected = try XCTUnwrap(expectedCases[name]?.objectValue?.object("output"))
      let (request, context) = inputs(
        api: "openai-completions",
        metadata: [
          "compat": .object(["supportsFinishReason": try XCTUnwrap(spec["supportsFinishReason"])])
        ])
      let result = try await replay(
        OpenAICompletionsAdapter(), request: request, context: context,
        chunks: [Data(try XCTUnwrap(spec.string("sse")).utf8)])
      XCTAssertEqual(result.starts, 1, name)
      if expected.string("stopReason") == "error" {
        XCTAssertEqual(result.failure?.message, expected.string("errorMessage"), name)
        XCTAssertNil(result.snapshot, name)
      } else {
        XCTAssertNil(result.failure, name)
        let snapshot = try XCTUnwrap(result.snapshot, name)
        XCTAssertEqual(snapshot.finishReason, .stop, name)
        XCTAssertEqual(snapshot.rawFinishReason, expected.string("rawStopReason"), name)
        XCTAssertEqual(snapshot.responseID, expected.string("responseId"), name)
        XCTAssertEqual(content(snapshot), expected.array("content"), name)
        XCTAssertEqual(
          snapshot.usage?.totalTokens, expected.object("usage")?.int("totalTokens"), name)
      }
    }
  }

  func testAnthropicSSEMatchesPinnedSource() async throws {
    let oracle = try load("Differential/Oracle/response-anthropic-bedrock-pi.json")
    let cases = try XCTUnwrap(oracle.object("scenarios"))
    for name in [
      "anthropic-ignored-sse-envelopes", "anthropic-repaired-sse-tool",
      "anthropic-raw-error", "anthropic-error-event",
    ] {
      let spec = try XCTUnwrap(cases[name]?.objectValue)
      let decoder = try XCTUnwrap(spec.object("decoderInput"))
      let expected = try XCTUnwrap(spec.object("terminal"))
      let chunks = try XCTUnwrap(decoder.array("chunksBase64")).map {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap($0.stringValue)))
      }
      let (request, context) = inputs(api: "anthropic-messages")
      let result = try await replay(
        AnthropicMessagesAdapter(), request: request, context: context, chunks: chunks)
      if spec.string("outcome") == "failure" {
        XCTAssertEqual(result.failure?.code, .transportFailed, name)
        XCTAssertEqual(result.failure?.message, expected.string("errorMessage"), name)
      } else {
        XCTAssertNil(result.failure, name)
        let snapshot = try XCTUnwrap(result.snapshot, name)
        XCTAssertEqual(snapshot.responseID, expected.string("responseID"), name)
        XCTAssertEqual(content(snapshot), expected.array("content"), name)
        XCTAssertEqual(
          snapshot.usage?.totalTokens, expected.object("usage")?.int("totalTokens"), name)
      }
    }
  }

  func testMistralHTTPMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/mistral-http.json")
    let oracle = try load("Differential/Oracle/mistral-http.json")
    for item in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(item.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      let expected = try XCTUnwrap(oracle.object("cases")?.object(name))
      let (request, context) = inputs(
        api: "mistral-conversations",
        headers: (spec.object("modelHeaders") ?? [:]).compactMapValues(\.stringValue),
        options: .init(
          maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: ["headers": .object(spec.object("headers") ?? [:])],
          sessionID: spec.string("sessionId"),
          cacheRetention: spec.string("cacheRetention").flatMap(
            ProviderCacheRetention.init(rawValue:)) ?? .short))
      let transport = IOSMistralHTTPFixture(
        status: try XCTUnwrap(spec.int("status")),
        body: Data(try XCTUnwrap(spec.string("body")).utf8))
      do {
        for try await _ in MistralConversationsAdapter().stream(
          request, context: context, transport: transport)
        {}
        XCTFail("expected fixture HTTP failure: \(name)")
      } catch let failure as ProviderRuntimeFailure {
        XCTAssertEqual(failure.code, .transportFailed, name)
        XCTAssertEqual(failure.message, expected.string("errorMessage"), name)
      }
      let captured = await transport.sent
      let sent = try XCTUnwrap(captured)
      let actual = Dictionary(
        uniqueKeysWithValues: (sent.allHTTPHeaderFields ?? [:]).map {
          ($0.key.lowercased(), JSONValue.string($0.value))
        })
      XCTAssertEqual(actual, expected.object("headers"), name)
    }
  }

  func testMistralHeaderTimeoutMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/mistral-timeout.json")
    let oracle = try load("Differential/Oracle/mistral-timeout.json")
    for item in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(item.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      let expected = try XCTUnwrap(oracle.object("cases")?.object(name))
      let (request, context) = inputs(
        api: "mistral-conversations",
        options: .init(
          maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: ["timeoutMs": try XCTUnwrap(spec["timeoutMs"])]))
      let transport = IOSMistralTimeoutFixture(spec: spec)
      var snapshot: ProviderResponseSnapshot?
      var failure: ProviderRuntimeFailure?
      do {
        for try await event in MistralConversationsAdapter().stream(
          request, context: context, transport: transport)
        {
          if case .responseSnapshot(let value) = event { snapshot = value }
        }
      } catch let error as ProviderRuntimeFailure {
        failure = error
      }
      let requested = await transport.requested
      XCTAssertEqual(requested, expected.bool("requested"), name)
      if expected.bool("requested") == false {
        XCTAssertEqual(failure?.code, .invalidRequest, name)
      } else if expected.string("stopReason") == "error" {
        XCTAssertEqual(failure?.message, expected.string("errorMessage"), name)
        XCTAssertNil(snapshot)
      } else {
        XCTAssertNil(failure, name)
        XCTAssertEqual(snapshot?.finishReason, .stop, name)
        let reasoning = snapshot?.content.compactMap { content -> String? in
          guard case .reasoning(let value) = content else { return nil }
          return value.text
        }.joined()
        XCTAssertEqual(reasoning, expected.string("reasoning"), name)
      }
    }
  }

  func testResponsesToolSlotsMatchPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    let cases = try XCTUnwrap(fixture.object("responseToolSlotEvents"))
    let expectedCases = try XCTUnwrap(
      oracle.object("cases")?.object("responses.tool-slot-lifecycle"))
    for api in ["openai-responses", "azure-openai-responses", "openai-codex-responses"] {
      for name in cases.keys.sorted() {
        let expected = try XCTUnwrap(expectedCases[name]?.objectValue)
        let events = try XCTUnwrap(cases[name]?.arrayValue)
        let chunks = try events.map { value in
          let data = try JSONEncoder().encode(value)
          return Data(("data: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8)
        }
        let (request, context) = inputs(api: api)
        let adapter = OpenAIResponsesAdapter(
          protocolID: api,
          flavor: api == "azure-openai-responses"
            ? .azure : (api == "openai-codex-responses" ? .codex : .standard))
        let result = try await replay(
          adapter, request: request, context: context, chunks: chunks)
        if let thrown = expected.string("thrown") {
          XCTAssertEqual(result.failure?.message, thrown, "\(api):\(name)")
          XCTAssertNil(result.snapshot, "\(api):\(name)")
        } else {
          XCTAssertNil(result.failure, "\(api):\(name)")
          XCTAssertEqual(
            content(try XCTUnwrap(result.snapshot, "\(api):\(name)")),
            expected.array("content"), "\(api):\(name)")
        }
      }
    }
  }

  private func load(_ path: String) throws -> [String: JSONValue] {
    let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
    return try decodeJSONObject(
      Data(contentsOf: root.appending(path: path)), providerID: "fixture", operation: "ios.fixture")
  }

  private func content(_ snapshot: ProviderResponseSnapshot) -> [JSONValue] {
    snapshot.content.map {
      switch $0 {
      case .text(let value):
        return .object(["type": .string("text"), "text": .string(value.text)])
      case .toolCall(let value):
        return .object([
          "type": .string("toolCall"), "id": .string(value.id), "name": .string(value.name),
          "arguments": value.arguments,
        ])
      default:
        XCTFail("unexpected content in the selected source fixtures")
        return .null
      }
    }
  }

  private func inputs(
    api: String, metadata: [String: JSONValue] = [:], headers: [String: String] = [:],
    options: ProviderGenerationOptions? = nil
  ) -> (
    ProviderRequest, WireProtocolContext
  ) {
    let isCodex = api == "openai-codex-responses"
    let isAzure = api == "azure-openai-responses"
    let providerID =
      isCodex
      ? "openai-codex"
      : isAzure
        ? "azure-openai-responses"
        : api == "anthropic-messages"
          ? "anthropic"
          : (api == "mistral-conversations" ? "mistral" : "openai")
    let modelID = api == "openai-completions" ? "requested-model" : "fixture-model"
    let model = ProviderModel(
      id: modelID, providerID: providerID, name: modelID, protocolID: api,
      capabilities: .init(
        textInput: true, imageInput: false, toolCalling: true,
        reasoning: api != "mistral-conversations",
        structuredOutput: true, imageGeneration: false),
      contextWindow: 32_768, maximumOutputTokens: 4_096)
    var metadata = metadata
    metadata["cost"] = .object([
      "input": .integer(0), "output": .integer(0), "cacheRead": .integer(0),
      "cacheWrite": .integer(0),
    ])
    return (
      ProviderRequest(
        id: "ios-conformance", providerID: providerID, modelID: modelID,
        messages: [.user([.text("hello")])], tools: [],
        options: options
          ?? .init(
            maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
            responseSchema: nil, providerOptions: [:])),
      WireProtocolContext(
        provider: .init(
          id: providerID, name: providerID, authorizationMethods: [], models: [model]),
        model: model, baseURL: URL(string: "https://fixture.invalid")!, headers: headers,
        credential: isCodex
          ? .oauth(
            .init(
              accessToken: "synthetic-fixture-token", refreshToken: "synthetic-fixture-refresh",
              expiresAt: .distantFuture, metadata: ["accountID": "fixture-account"]))
          : .apiKey(
            .init(
              key: "synthetic-fixture-key", metadata: isAzure ? ["deploymentName": modelID] : [:])),
        modelConfiguration: .init(protocolID: api, baseURL: nil, headers: [:], metadata: metadata))
    )
  }

  private func replay(
    _ adapter: any WireProtocolAdapter, request: ProviderRequest, context: WireProtocolContext,
    chunks: [Data]
  ) async throws -> (
    snapshot: ProviderResponseSnapshot?, failure: ProviderRuntimeFailure?, starts: Int
  ) {
    var snapshot: ProviderResponseSnapshot?
    var starts = 0
    do {
      for try await event in adapter.stream(
        request, context: context, transport: IOSFixtureTransport(chunks: chunks))
      {
        if case .responseSnapshot(let value) = event { snapshot = value }
        if case .responseStarted = event { starts += 1 }
      }
      return (snapshot, nil, starts)
    } catch let error as ProviderRuntimeFailure {
      return (snapshot, error, starts)
    }
  }
}

private actor IOSMistralTimeoutFixture: ProviderHTTPStreamingTransport {
  let spec: [String: JSONValue]
  var requested = false
  init(spec: [String: JSONValue]) { self.spec = spec }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    requested = true
    if let delay = spec.int("headerDelayMs"), delay > 0 {
      try await Task.sleep(for: .milliseconds(delay))
    }
    let chunks = try XCTUnwrap(spec.array("chunks"))
    return .init(
      statusCode: 200, headers: ["content-type": "text/event-stream"],
      body: AsyncThrowingStream { continuation in
        let task = Task {
          do {
            for value in chunks {
              let chunk = try XCTUnwrap(value.objectValue)
              if let delay = chunk.int("delayMs"), delay > 0 {
                try await Task.sleep(for: .milliseconds(delay))
              }
              continuation.yield(Data(try XCTUnwrap(chunk.string("data")).utf8))
            }
            continuation.finish()
          } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
      })
  }
}

private actor IOSMistralHTTPFixture: ProviderHTTPStreamingTransport {
  let status: Int
  let body: Data
  var sent: URLRequest?

  init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    sent = request
    return .init(
      statusCode: status, headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.yield(body)
        continuation.finish()
      })
  }
}

private struct IOSFixtureTransport: ProviderHTTPStreamingTransport {
  let chunks: [Data]

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    .init(
      statusCode: 200, headers: ["content-type": "text/event-stream"],
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      })
  }
}
