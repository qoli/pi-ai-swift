import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct StrictFallbackDifferentialTests {
  @Test
  func sourceDerivedPreferredStrictRetriesPreserveRequiredAndFailureBoundaries() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let input = try JSONDecoder().decode(
      StrictFallbackInput.self,
      from: Data(
        contentsOf: root.appending(path: "Fixtures/Differential/Cases/strict-fallback.json")))
    let oracle = try JSONDecoder().decode(
      StrictFallbackOracle.self,
      from: Data(
        contentsOf: root.appending(path: "Fixtures/Differential/Oracle/strict-fallback.json")))
    #expect(input.upstreamRevision == oracle.upstreamRevision)
    for test in input.cases {
      let expected = try #require(oracle.cases[test.id])
      let bedrock = test.protocolID == "bedrock-converse-stream"
      let providerID = bedrock ? "amazon-bedrock" : "anthropic"
      let model = ProviderModel(
        id: "fixture-claude", providerID: providerID, name: "Claude Fixture",
        protocolID: test.protocolID,
        capabilities: .init(
          textInput: true, imageInput: false, toolCalling: true, reasoning: false,
          structuredOutput: false, imageGeneration: false),
        contextWindow: 200_000, maximumOutputTokens: 100)
      let context = WireProtocolContext(
        provider: .init(
          id: providerID, name: providerID, authorizationMethods: [], models: [model]),
        model: model,
        baseURL: URL(
          string: bedrock
            ? "https://bedrock-runtime.us-east-1.amazonaws.com" : "https://fixture.invalid")!,
        headers: [:], credential: .apiKey(.init(key: "synthetic-fixture-key", metadata: [:])),
        modelConfiguration: .init(
          protocolID: test.protocolID, baseURL: nil, headers: [:],
          metadata: [
            "compat": .object([bedrock ? "supportsStrictMode" : "supportsStrictTools": .bool(true)]
            ),
            "cost": .object([
              "input": .integer(0), "output": .integer(0), "cacheRead": .integer(0),
              "cacheWrite": .integer(0),
            ]),
          ]))
      let request = ProviderRequest(
        id: test.id, providerID: providerID, modelID: model.id,
        messages: [.user([.text("Hello")])],
        tools: test.preferences.enumerated().map { index, preference in
          ProviderToolDefinition(
            name: "tool_\(index)", description: "Fixture lookup", inputSchema: input.schema,
            constrainedSampling: preference.flatMap(ProviderStrictPreference.init(rawValue:))
              .map { .jsonSchema(strict: $0) })
        },
        options: .init(
          maximumOutputTokens: 100, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: [:], cacheRetention: .none))
      let transport = StrictFallbackTransport(test: test)
      let adapter = try #require(
        StandardWireProtocols.make().first { $0.protocolID == test.protocolID })
      for call in 0..<(test.calls ?? 1) {
        let task = Task {
          var completed = false
          for try await event in adapter.stream(request, context: context, transport: transport) {
            if case .completed = event { completed = true }
          }
          return completed
        }
        do {
          #expect(try await task.value, Comment(rawValue: test.id))
          #expect(expected.outcomes[call].stopReason == "stop", Comment(rawValue: test.id))
        } catch is CancellationError {
          #expect(expected.outcomes[call].stopReason == "aborted", Comment(rawValue: test.id))
        } catch let failure as ProviderRuntimeFailure {
          #expect(expected.outcomes[call].stopReason == "error", Comment(rawValue: test.id))
          #expect(
            failure.message == expected.outcomes[call].errorMessage, Comment(rawValue: test.id))
        }
      }
      let actual = await transport.requests
      #expect(
        actual == expected.requests,
        Comment(
          rawValue:
            "\(test.id): \(firstRequestDifference(.array(actual), .array(expected.requests)))"))
    }
  }
}

private struct StrictFallbackInput: Decodable {
  let upstreamRevision: String
  let schema: JSONValue
  let cases: [StrictFallbackCase]
}
private struct StrictFallbackCase: Decodable, Sendable {
  let id: String
  let protocolID: String
  let preferences: [String?]
  let failures: [Failure?]
  let cancelAfterFirst: Bool?
  let streamError: Bool?
  let calls: Int?
  struct Failure: Decodable, Sendable {
    let status: Int
    let type: String
    let message: String
    let body: String?
  }
}
private struct StrictFallbackOracle: Decodable {
  let upstreamRevision: String
  let cases: [String: Observation]
  struct Observation: Decodable {
    let requests: [JSONValue]
    let outcomes: [Outcome]
  }
  struct Outcome: Decodable {
    let stopReason: String
    let errorMessage: String?
  }
}
private actor StrictFallbackTransport: ProviderHTTPStreamingTransport {
  let test: StrictFallbackCase
  var requests: [JSONValue] = []
  init(test: StrictFallbackCase) { self.test = test }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    requests.append(try JSONDecoder().decode(JSONValue.self, from: request.httpBody!))
    if test.cancelAfterFirst == true && requests.count == 1 {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    if requests.count <= test.failures.count, let failure = test.failures[requests.count - 1] {
      let body: JSONValue =
        test.protocolID == "bedrock-converse-stream"
        ? .object(["__type": .string(failure.type), "message": .string(failure.message)])
        : .object([
          "type": .string("error"),
          "error": .object([
            "type": .string(failure.type), "message": .string(failure.message),
          ]),
        ])
      return response(
        status: failure.status,
        data: try failure.body.map { Data($0.utf8) } ?? JSONEncoder().encode(body))
    }
    if test.protocolID == "bedrock-converse-stream" {
      var data = Data()
      for (type, payload) in [
        ("messageStart", #"{"role":"assistant"}"#),
        ("messageStop", #"{"stopReason":"end_turn"}"#),
      ] {
        data.append(
          try AWSEventStreamDecoder.encode(
            headers: [
              ":message-type": "event", ":event-type": type, ":content-type": "application/json",
            ],
            payload: Data(payload.utf8)))
      }
      return response(status: 200, data: data)
    }
    let frames =
      test.streamError == true
      ? [
        #"{"type":"error","error":{"type":"invalid_request_error","message":"The compiled grammar is too large"}}"#
      ]
      : [
        #"{"type":"message_start","message":{"id":"msg_fixture","model":"fixture-claude","usage":{"input_tokens":0,"output_tokens":0}}}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}"#,
        #"{"type":"message_stop"}"#,
      ]
    let sse = try frames.map { frame in
      let object = try JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
      let name = try #require(object.objectValue?.string("type"))
      return "event: \(name)\ndata: \(frame)\n\n"
    }.joined()
    return response(status: 200, data: Data(sse.utf8))
  }
  private func response(status: Int, data: Data) -> ProviderHTTPStreamingResponse {
    ProviderHTTPStreamingResponse(
      statusCode: status, headers: ["x-amzn-requestid": "fixture-request"],
      body: AsyncThrowingStream {
        $0.yield(data)
        $0.finish()
      })
  }
}
