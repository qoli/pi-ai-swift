import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ClientIdentityDifferentialTests {
  @Test
  func identityHeaderVectorsMatchPinnedSource() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Cases/client-identity.json")),
      providerID: "fixture", operation: "identity.fixture")
    let oracle = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Oracle/client-identity.json")),
      providerID: "fixture", operation: "identity.oracle")
    for value in try #require(fixture.array("cases")) {
      let spec = try #require(value.objectValue)
      let name = try #require(spec.string("id"))
      let target = try #require(spec.object("target"))
      let host = try JSONDecoder().decode(
        ProviderIdentityHost.self, from: JSONEncoder().encode(try #require(spec["host"])))
      let headers = ProviderClientIdentity.headers(
        providerID: try #require(target.string("provider")),
        baseURL: try #require(target.string("baseUrl")), identity: spec.object("identity"),
        host: host)
      #expect(
        JSONValue.object(headers.mapValues(JSONValue.string)) == oracle.object("cases")?[name],
        Comment(rawValue: name))
    }
  }

  @Test
  func runtimeSendsSourceDefaultIdentityBeforeHeaderOverrides() async throws {
    let transport = IdentityCaptureTransport()
    let runtime = try CustomProviderRuntime(
      providers: [
        .init(
          id: "fixture", baseURL: URL(string: "https://fixture.invalid")!,
          api: "openai-completions",
          models: [
            .init(
              id: "fixture-model",
              capabilities: .init(
                textInput: true, imageInput: false, toolCalling: true, reasoning: false,
                structuredOutput: false, imageGeneration: false))
          ])
      ],
      credentialStore: InMemoryProviderCredentialStore(credentials: [
        "fixture": .apiKey(.init(key: "fixture", metadata: [:]))
      ]),
      streamingTransport: transport)
    let request = ProviderRequest(
      id: "identity", providerID: "fixture", modelID: "fixture-model",
      messages: [.user([.text("hello")])], tools: [],
      options: .init(
        maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil, responseSchema: nil,
        providerOptions: [:]))
    do {
      for try await _ in runtime.stream(request) {}
    } catch is ProviderRuntimeFailure {}
    let sent = try #require(await transport.sent)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let oracle = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Oracle/client-identity.json")),
      providerID: "fixture", operation: "test.identity")
    #expect(
      sent.value(forHTTPHeaderField: "User-Agent")
        == oracle.object("cases")?.object("non-node-runtime")?.string("User-Agent"))
  }
}

private actor IdentityCaptureTransport: ProviderHTTPStreamingTransport {
  var sent: URLRequest?
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    sent = request
    return .init(statusCode: 418, headers: [:], body: AsyncThrowingStream { $0.finish() })
  }
}
