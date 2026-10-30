import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct MistralHTTPTests {
  @Test
  func headersAndErrorBodiesMatchPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Cases/mistral-http.json")),
      providerID: "fixture", operation: "mistral.http.fixture")
    let oracle = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Oracle/mistral-http.json")),
      providerID: "fixture", operation: "mistral.http.oracle")
    for item in try #require(fixture.array("cases")) {
      let spec = try #require(item.objectValue)
      let id = try #require(spec.string("id"))
      let expected = try #require(oracle.object("cases")?.object(id))
      let model = ProviderModel(
        id: "fixture-model", providerID: "mistral", name: "Fixture",
        protocolID: "mistral-conversations",
        capabilities: .init(
          textInput: true, imageInput: false, toolCalling: true, reasoning: false,
          structuredOutput: true, imageGeneration: false),
        contextWindow: 32768, maximumOutputTokens: 4096)
      let context = WireProtocolContext(
        provider: .init(id: "mistral", name: "Mistral", authorizationMethods: [], models: [model]),
        model: model, baseURL: URL(string: "https://fixture.invalid")!,
        headers: (spec.object("modelHeaders") ?? [:]).compactMapValues(\.stringValue),
        credential: .apiKey(.init(key: "synthetic-fixture-key", metadata: [:])),
        modelConfiguration: .init(
          protocolID: model.protocolID, baseURL: nil, headers: [:], metadata: [:]))
      let request = ProviderRequest(
        id: id, providerID: "mistral", modelID: model.id, messages: [.user([.text("hello")])],
        tools: [],
        options: .init(
          maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: ["headers": .object(spec.object("headers") ?? [:])],
          sessionID: spec.string("sessionId"),
          cacheRetention: spec.string("cacheRetention").flatMap(
            ProviderCacheRetention.init(rawValue:)) ?? .short))
      let transport = MistralHTTPFixture(
        status: try #require(spec.int("status")), body: Data(try #require(spec.string("body")).utf8)
      )
      do {
        for try await _ in MistralConversationsAdapter().stream(
          request, context: context, transport: transport)
        {}
        Issue.record("expected fixture HTTP error")
      } catch let failure as ProviderRuntimeFailure {
        #expect(failure.code == .transportFailed)
        #expect(failure.message == expected.string("errorMessage"), Comment(rawValue: id))
      }
      let sent = try #require(await transport.sent)
      let actualHeaders = Dictionary(
        uniqueKeysWithValues: (sent.allHTTPHeaderFields ?? [:]).map {
          ($0.key.lowercased(), JSONValue.string($0.value))
        })
      #expect(actualHeaders == expected.object("headers"), Comment(rawValue: id))
      let body = try decodeJSONObject(
        try #require(sent.httpBody), providerID: "fixture", operation: "mistral.http.body")
      #expect(body["headers"] == nil)
    }
  }
}

private actor MistralHTTPFixture: ProviderHTTPStreamingTransport {
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
