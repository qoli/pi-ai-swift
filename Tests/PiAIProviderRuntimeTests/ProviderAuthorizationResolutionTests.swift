import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite struct ProviderAuthorizationResolutionTests {
  @Test func explicitRequestKeyUsesThePublicSeamWithoutReadingStoredOAuth() async throws {
    let expected = try sourceCases().first {
      $0.objectValue!.string("id") == "explicit-api-key-wins-oauth"
    }!.objectValue!
    let key = expected.object("result")!.object("auth")!.string("apiKey")!
    let stored = ProviderCredential.oauth(
      .init(
        accessToken: "fixture-stored", refreshToken: "fixture-refresh",
        expiresAt: .distantFuture, metadata: [:]))
    let store = ResolutionCountingStore(credentials: ["anthropic": stored])
    let transport = ResolutionFixtureTransport()
    let runtime = try BuiltinProviderRuntime(credentialStore: store, streamingTransport: transport)
    let model = try #require(
      try await runtime.catalog().providers.first { $0.id == "anthropic" }?.models.first)
    await store.resetReads()
    let connection = ProviderConnectionOptions(authentication: .init(apiKey: key))
    let decoded = try JSONDecoder().decode(
      ProviderConnectionOptions.self, from: JSONEncoder().encode(connection))
    let request = ProviderRequest(
      id: "fixture", providerID: "anthropic", modelID: model.id,
      messages: [.user([.text("fixture")])], tools: [],
      options: .init(
        maximumOutputTokens: 32,
        temperature: nil, reasoningEffort: nil, responseSchema: nil, providerOptions: [:]),
      connectionOptions: decoded)
    for try await _ in runtime.stream(request) {}
    #expect(await transport.request?.value(forHTTPHeaderField: "x-api-key") == key)
    #expect(
      await store.readCount("anthropic")
        == expected.array("calls")!.filter { $0 == .string("read") }.count)
    #expect(try await store.read(providerID: "anthropic") == stored)
  }

  @Test func requestEnvironmentOverlaysTheHostThroughThePublicSeam() async throws {
    let expected = try sourceCases().first {
      $0.objectValue!.string("id") == "explicit-environment-overlays-context"
    }!.objectValue!
    let key = expected.object("result")!.object("auth")!.string("apiKey")!
    let transport = ResolutionFixtureTransport()
    let store = InMemoryProviderCredentialStore()
    let runtime = try BuiltinProviderRuntime(
      credentialStore: store, streamingTransport: transport,
      authorizationConfiguration: .init(
        authenticationContext: .init(
          environment: { $0 == "ANTHROPIC_API_KEY" ? "ambient-key" : nil },
          fileExists: { _ in false })))
    let model = try #require(
      try await runtime.catalog().providers.first { $0.id == "anthropic" }?.models.first)
    let request = ProviderRequest(
      id: "fixture", providerID: "anthropic", modelID: model.id,
      messages: [.user([.text("fixture")])], tools: [],
      options: .init(
        maximumOutputTokens: 32,
        temperature: nil, reasoningEffort: nil, responseSchema: nil, providerOptions: [:]),
      connectionOptions: .init(authentication: .init(environment: ["ANTHROPIC_API_KEY": key])))
    for try await _ in runtime.stream(request) {}
    #expect(await transport.request?.value(forHTTPHeaderField: "x-api-key") == key)
    #expect(try await store.read(providerID: "anthropic") == nil)
  }

  @Test func resolverMatchesPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func cases(_ folder: String) throws -> [JSONValue] {
      try JSONValue(
        jsonData: Data(
          contentsOf:
            root.appending(path: "Fixtures/Differential/\(folder)/auth-resolution.json"))
      ).objectValue!.array("cases")!
    }
    let inputs = try cases("Cases")
    let expected = try cases("Oracle")
    #expect(inputs.count == expected.count)
    for (input, oracle) in zip(inputs, expected) {
      #expect(
        try await AuthResolutionFixtures.replay(input.objectValue!) == oracle,
        Comment(rawValue: input.objectValue!.string("id")!))
    }
  }

  @Test func builtinOAuthUsesTheSourceReadCount() async throws {
    let store = ResolutionCountingStore(credentials: [
      "anthropic": .oauth(
        .init(
          accessToken: "fixture-access", refreshToken: "fixture-refresh",
          expiresAt: Date().addingTimeInterval(3_600), metadata: [:]))
    ])
    let runtime = try BuiltinProviderRuntime(
      credentialStore: store,
      streamingTransport: ResolutionFixtureTransport())
    let catalog = try await runtime.catalog()
    let model = try #require(
      catalog.providers.first { $0.id == "anthropic" }?.models.first { $0.capabilities.textInput })
    await store.resetReads()
    let request = ProviderRequest(
      id: "fixture", providerID: "anthropic", modelID: model.id,
      messages: [.user([.text("fixture")])], tools: [],
      options: .init(
        maximumOutputTokens: 32, temperature: nil, reasoningEffort: nil,
        responseSchema: nil, providerOptions: [:]))
    for try await _ in runtime.stream(request) {}
    let oracle = try sourceCases().first { $0.objectValue!.string("id") == "valid-oauth" }!
      .objectValue!
    let expected = oracle.array("calls")!.filter { $0 == .string("read") }.count
    #expect(await store.readCount("anthropic") == expected)
  }

  @Test func catalogRequiresAHandlerForTheStoredCredentialKind() async throws {
    let oracle = try sourceCases().first {
      $0.objectValue!.string("id") == "stored-oauth-without-handler"
    }!.objectValue!
    #expect(oracle["result"] == .null)
    let store = ResolutionCountingStore(credentials: [
      "mistral": .oauth(
        .init(
          accessToken: "fixture-access", refreshToken: "fixture-refresh",
          expiresAt: Date().addingTimeInterval(3_600), metadata: [:]))
    ])
    let runtime = try BuiltinProviderRuntime(
      credentialStore: store,
      authorizationConfiguration: .init(
        authenticationContext: .init(
          environment: { _ in nil }, fileExists: { _ in false })))
    let provider = try #require(try await runtime.catalog().providers.first { $0.id == "mistral" })
    #expect(provider.availability?.configured == false)
  }

  private func sourceCases() throws -> [JSONValue] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    return try JSONValue(
      jsonData: Data(
        contentsOf:
          root.appending(path: "Fixtures/Differential/Oracle/auth-resolution.json"))
    ).objectValue!.array("cases")!
  }
}

private actor ResolutionCountingStore: ProviderCredentialStore {
  let memory: InMemoryProviderCredentialStore
  private var reads: [String: Int] = [:]
  init(credentials: [String: ProviderCredential]) { memory = .init(credentials: credentials) }
  func read(providerID: String) async throws -> ProviderCredential? {
    reads[providerID, default: 0] += 1
    return try await memory.read(providerID: providerID)
  }
  func list() async throws -> [ProviderCredentialInfo] { try await memory.list() }
  func modify(
    providerID: String,
    _ transform: @escaping @Sendable (ProviderCredential?) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    try await memory.modify(providerID: providerID, transform)
  }
  func delete(providerID: String) async throws { try await memory.delete(providerID: providerID) }
  func resetReads() { reads = [:] }
  func readCount(_ id: String) -> Int { reads[id, default: 0] }
}

private actor ResolutionFixtureTransport: ProviderHTTPStreamingTransport {
  private(set) var request: URLRequest?
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    self.request = request
    let payloads = [
      #"{"type":"message_start","message":{"id":"fixture","model":"fixture","usage":{"input_tokens":1,"output_tokens":0}}}"#,
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
      #"{"type":"message_stop"}"#,
    ]
    let frames = try payloads.map { value in
      let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
      return "event: \(object["type"] as! String)\ndata: \(value)\n\n"
    }
    return .init(
      statusCode: 200, headers: [:],
      body: AsyncThrowingStream {
        $0.yield(Data(frames.joined().utf8))
        $0.finish()
      })
  }
}
