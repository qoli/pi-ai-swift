import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct MistralTimeoutTests {
  @Test
  func headerDeadlineAndActiveBodyMatchPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Cases/mistral-timeout.json")),
      providerID: "fixture", operation: "mistral.timeout.fixture")
    let oracle = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Oracle/mistral-timeout.json")),
      providerID: "fixture", operation: "mistral.timeout.oracle")
    for value in try #require(fixture.array("cases")) {
      let spec = try #require(value.objectValue)
      let id = try #require(spec.string("id"))
      let expected = try #require(oracle.object("cases")?.object(id))
      let transport = MistralTimeoutFixture(spec: spec)
      let model = ProviderModel(
        id: "fixture-model", providerID: "mistral", name: "Fixture",
        protocolID: "mistral-conversations",
        capabilities: .init(
          textInput: true, imageInput: false, toolCalling: true, reasoning: false,
          structuredOutput: true, imageGeneration: false),
        contextWindow: 32768, maximumOutputTokens: 4096)
      let context = WireProtocolContext(
        provider: .init(id: "mistral", name: "Mistral", authorizationMethods: [], models: [model]),
        model: model, baseURL: URL(string: "https://fixture.invalid")!, headers: [:],
        credential: .apiKey(.init(key: "synthetic-fixture-key", metadata: [:])),
        modelConfiguration: .init(
          protocolID: model.protocolID, baseURL: nil, headers: [:],
          metadata: [
            "cost": .object([
              "input": .integer(0), "output": .integer(0), "cacheRead": .integer(0),
              "cacheWrite": .integer(0),
            ])
          ]))
      let request = ProviderRequest(
        id: id, providerID: "mistral", modelID: model.id, messages: [.user([.text("hello")])],
        tools: [],
        options: .init(
          maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: ["timeoutMs": try #require(spec["timeoutMs"])]))
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
      let captured = await transport.sent
      #expect((captured != nil) == expected.bool("requested"), Comment(rawValue: id))
      if expected.bool("requested") == false {
        #expect(failure?.code == .invalidRequest, Comment(rawValue: id))
      } else if expected.string("stopReason") == "error" {
        #expect(failure?.message == expected.string("errorMessage"), Comment(rawValue: id))
        #expect(snapshot == nil)
      } else {
        #expect(failure == nil, Comment(rawValue: id))
        #expect(snapshot?.finishReason == .stop)
        let reasoning = snapshot?.content.compactMap { content -> String? in
          guard case .reasoning(let value) = content else { return nil }
          return value.text
        }.joined()
        #expect(reasoning == expected.string("reasoning"))
      }
      if let captured {
        let body = try decodeJSONObject(
          try #require(captured.httpBody), providerID: "fixture",
          operation: "mistral.timeout.capture")
        #expect(body["timeoutMs"] == nil)
      }
    }
  }
}

private actor MistralTimeoutFixture: ProviderHTTPStreamingTransport {
  let spec: [String: JSONValue]
  var sent: URLRequest?
  init(spec: [String: JSONValue]) { self.spec = spec }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    sent = request
    if let delay = spec.int("headerDelayMs"), delay > 0 {
      try await Task.sleep(for: .milliseconds(delay))
    }
    let chunks = try #require(spec.array("chunks"))
    return .init(
      statusCode: 200, headers: ["content-type": "text/event-stream"],
      body: AsyncThrowingStream { continuation in
        let task = Task {
          do {
            for value in chunks {
              let chunk = try #require(value.objectValue)
              if let delay = chunk.int("delayMs"), delay > 0 {
                try await Task.sleep(for: .milliseconds(delay))
              }
              continuation.yield(Data(try #require(chunk.string("data")).utf8))
            }
            continuation.finish()
          } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
      })
  }
}
