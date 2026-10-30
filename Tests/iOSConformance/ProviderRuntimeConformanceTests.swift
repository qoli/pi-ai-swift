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

  private func inputs(api: String, metadata: [String: JSONValue] = [:]) -> (
    ProviderRequest, WireProtocolContext
  ) {
    let providerID = api == "anthropic-messages" ? "anthropic" : "openai"
    let modelID = api == "anthropic-messages" ? "fixture-model" : "requested-model"
    let model = ProviderModel(
      id: modelID, providerID: providerID, name: modelID, protocolID: api,
      capabilities: .init(
        textInput: true, imageInput: false, toolCalling: true, reasoning: true,
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
        options: .init(
          maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: [:])),
      WireProtocolContext(
        provider: .init(
          id: providerID, name: providerID, authorizationMethods: [], models: [model]),
        model: model, baseURL: URL(string: "https://fixture.invalid")!, headers: [:],
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
