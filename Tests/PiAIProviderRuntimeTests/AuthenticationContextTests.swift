import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite struct AuthenticationContextTests {
  @Test func catalogWithoutContextDoesNotReadCredentials() async throws {
    let store = ContextCredentialStore()
    let runtime = try runtime(store: store, transport: ContextTransport())
    let catalog = try await runtime.catalog()
    #expect(catalog.providers.first?.availability == nil)
    #expect(await store.reads == 0)
  }

  @Test func ambientAuthenticationIsUsedWithoutPersistingIt() async throws {
    let store = ContextCredentialStore()
    let transport = ContextTransport()
    let context = ProviderAuthenticationContext(
      environment: { name in
        name == "OPENAI_API_KEY" ? "synthetic-environment-key" : nil
      },
      fileExists: { _ in
        Issue.record("API-key resolution read a file")
        return false
      })
    let runtime = try runtime(store: store, transport: transport, context: context)
    let availability = try #require(try await runtime.catalog().providers.first?.availability)
    #expect(availability.configured)
    #expect(availability.source == "OPENAI_API_KEY")
    for try await _ in runtime.stream(request("ambient")) {}
    #expect(
      await transport.requests.first?.value(forHTTPHeaderField: "Authorization")
        == "Bearer synthetic-environment-key")
    #expect(await store.value == nil)
  }

  @Test func customAPIKeyProviderDoesNotAcceptAStoredOAuthCredential() async throws {
    let store = ContextCredentialStore(
      .oauth(
        .init(
          accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
          expiresAt: .distantPast, metadata: [:])))
    let context = ProviderAuthenticationContext(
      environment: { _ in
        Issue.record("Stored OAuth availability read the environment")
        return nil
      },
      fileExists: { _ in
        Issue.record("Stored OAuth availability read a file")
        return false
      })
    let runtime = try runtime(
      store: store, transport: ContextTransport(), context: context,
      models: [model(), model(api: "openai-decisions")])
    let availability = try #require(try await runtime.catalog().providers.first?.availability)
    #expect(!availability.configured)
    #expect(availability.models.isEmpty)
    #expect(await store.modifications == 0)
  }

  @Test func transportOverrideIsPerRequestAndFailureDoesNotUseTheDefaultTransport() async throws {
    let original = ContextTransport()
    let replacement = ContextTransport(fails: true)
    let resolverCalls = ContextCalls()
    let runtime = try runtime(
      store: ContextCredentialStore(.apiKey(.init(key: "synthetic-key", metadata: [:]))),
      transport: original,
      resolver: { request in
        await resolverCalls.append(request.id)
        return request.id == "override" ? replacement : nil
      })
    do {
      for try await _ in runtime.stream(request("override")) {}
      Issue.record("The overridden transport failure was not propagated")
    } catch {}
    for try await _ in runtime.stream(request("inherit")) {}
    #expect(await original.requests.count == 1)
    #expect(await replacement.requests.count == 1)
    #expect(await resolverCalls.values == ["override", "inherit"])
  }

  @Test(arguments: ["google-generative-ai", "google-vertex"])
  func googleRejectsAnExplicitRequestTransportBeforeSending(api: String) async throws {
    let original = ContextTransport()
    let replacement = ContextTransport()
    let runtime = try runtime(
      store: ContextCredentialStore(), transport: original,
      models: [model(api: api)], resolver: { _ in replacement })
    do {
      for try await _ in runtime.stream(request("google")) {}
      Issue.record("Google accepted a per-request transport override")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .unsupportedCapability)
      #expect(failure.operation == "stream.resolve-transport")
    }
    #expect(await original.requests.isEmpty)
    #expect(await replacement.requests.isEmpty)
  }

  private func runtime(
    store: ContextCredentialStore, transport: ContextTransport,
    context: ProviderAuthenticationContext? = nil, models: [CustomProviderModel]? = nil,
    resolver: ProviderRequestTransportResolver? = nil
  ) throws -> CustomProviderRuntime {
    try CustomProviderRuntime(
      providers: [
        .init(
          id: "openai", baseURL: URL(string: "https://fixture.invalid/v1")!,
          api: "openai-completions", models: models ?? [model()])
      ], credentialStore: store,
      streamingTransport: transport, authenticationContext: context,
      requestTransportResolver: resolver)
  }

  private func model(api: String = "openai-completions") -> CustomProviderModel {
    .init(
      id: "same", api: api,
      capabilities: .init(
        textInput: true, imageInput: false, toolCalling: false, reasoning: false,
        structuredOutput: false, imageGeneration: false, classification: api == "openai-decisions"),
      metadata: fixtureMetadataWithCost([:]))
  }

  private func request(_ id: String) -> ProviderRequest {
    .init(
      id: id, providerID: "openai", modelID: "same", messages: [.user([.text("fixture")])],
      tools: [],
      options: .init(
        maximumOutputTokens: 8, temperature: nil, reasoningEffort: nil, responseSchema: nil,
        providerOptions: [:]))
  }
}

private actor ContextCalls {
  var values: [String] = []
  func append(_ value: String) { values.append(value) }
}

private actor ContextCredentialStore: ProviderCredentialStore {
  var value: ProviderCredential?
  var reads = 0
  var modifications = 0
  init(_ value: ProviderCredential? = nil) { self.value = value }
  func read(providerID: String) -> ProviderCredential? {
    reads += 1
    return value
  }
  func list() -> [ProviderCredentialInfo] { [] }
  func modify(
    providerID: String,
    _ transform: @escaping @Sendable (ProviderCredential?) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    modifications += 1
    value = try await transform(value)
    return value
  }
  func delete(providerID: String) { value = nil }
}

private actor ContextTransport: ProviderHTTPStreamingTransport {
  var requests: [URLRequest] = []
  let fails: Bool
  init(fails: Bool = false) { self.fails = fails }
  func stream(_ request: URLRequest) -> ProviderHTTPStreamingResponse {
    requests.append(request)
    let data = Data(
      (fails
        ? "synthetic failure"
        : "data: {\"id\":\"fixture\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
        .utf8)
    return .init(
      statusCode: fails ? 400 : 200, headers: [:],
      body: .init {
        $0.yield(data)
        $0.finish()
      })
  }
}
