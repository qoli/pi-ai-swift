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
    let providerID =
      api == "anthropic-messages"
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
        credential: .apiKey(.init(key: "synthetic-fixture-key", metadata: [:])),
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
