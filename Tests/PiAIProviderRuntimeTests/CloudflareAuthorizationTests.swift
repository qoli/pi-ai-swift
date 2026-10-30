import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct CloudflareAuthorizationTests {
  @Test
  func loginAndCancellationMatchPinnedSource() async throws {
    let fixture = try cloudflareJSON("Cases")
    let oracle = try cloudflareJSON("Oracle")
    for spec in try #require(fixture.array("logins")) {
      let item = try #require(spec.objectValue)
      let id = try #require(item.string("id"))
      let provider = try #require(item.string("providerID"))
      let expected = try #require(oracle.object("logins")?.object(id))
      let original = ProviderCredential.apiKey(.init(key: "fixture-original", metadata: [:]))
      let store = InMemoryProviderCredentialStore(credentials: [provider: original])
      let runtime = try BuiltinProviderRuntime(credentialStore: store)
      let interaction = CloudflareFixtureInteraction(
        answers: try #require(item.array("answers")).compactMap(\.stringValue),
        stopAt: item.int("stopAt"))
      do {
        _ = try await runtime.authorize(.login(providerID: provider, methodID: "api-key")) {
          try await interaction.respond($0)
        }
        #expect(expected.bool("cancelled") == false, Comment(rawValue: id))
      } catch is CancellationError {
        #expect(expected.bool("cancelled") == true, Comment(rawValue: id))
      }
      #expect(await interaction.prompts == expected.array("prompts"), Comment(rawValue: id))
      let stored = try await store.read(providerID: provider)
      if expected.bool("cancelled") == true {
        #expect(stored == original, Comment(rawValue: id))
      } else {
        guard case .apiKey(let credential) = stored else {
          Issue.record("missing Cloudflare credential")
          continue
        }
        #expect(credential.key == expected.object("credential")?.string("key"))
        #expect(
          credential.metadata
            == expected.object("credential")?.object("env")?.compactMapValues(\.stringValue))
      }
    }
  }

  @Test
  func credentialResolutionMatchesPinnedSource() async throws {
    let fixture = try cloudflareJSON("Cases")
    let oracle = try cloudflareJSON("Oracle")
    for spec in try #require(fixture.array("resolutions")) {
      let item = try #require(spec.objectValue)
      let id = try #require(item.string("id"))
      let provider = try #require(item.string("providerID"))
      let raw = try #require(item.object("credential"))
      let stored = ProviderCredential.apiKey(
        .init(
          key: try #require(raw.string("key")),
          metadata: raw.object("env")?.compactMapValues(\.stringValue) ?? [:]))
      let store = InMemoryProviderCredentialStore(credentials: [provider: stored])
      let adapter = CloudflareAuthorizationAdapter(
        providerID: provider, methodID: "api-key")
      let observed = try await adapter.resolveCredential(
        providerID: provider, credentialStore: store,
        refreshCoordinator: CredentialRefreshCoordinator(credentialStore: store))
      let configured = oracle.object("resolutions")?[id] != .null
      #expect((observed != nil) == configured, Comment(rawValue: id))
    }
  }

  @Test(arguments: ["openai-completions", "openai-responses", "anthropic-messages"])
  func gatewayRequestUsesResolvedHeaderAuthentication(_ api: String) async throws {
    let oracle = try cloudflareJSON("Oracle")
    let resolved = try #require(
      oracle.object("resolutions")?.object("cloudflare-ai-gateway.complete"))
    let expected = try #require(resolved.object("auth")?.object("headers"))
    let providerID = "cloudflare-ai-gateway"
    let model = ProviderModel(
      id: "fixture-chat", providerID: providerID, name: "fixture", protocolID: api,
      capabilities: .init(
        textInput: true, imageInput: false, toolCalling: false, reasoning: false,
        structuredOutput: false, imageGeneration: false),
      contextWindow: 1000, maximumOutputTokens: 100)
    let provider = ProviderDefinition(
      descriptor: .init(
        id: providerID, name: providerID, authorizationMethods: [], models: [model]),
      baseURL: "https://fixture.invalid/{CLOUDFLARE_ACCOUNT_ID}/{CLOUDFLARE_GATEWAY_ID}",
      headers: [:],
      modelConfigurations: [
        .init(modelID: model.id, outputModality: .text): .init(
          protocolID: api, baseURL: nil, headers: [:], metadata: fixtureMetadataWithCost())
      ],
      credentialRequirement: .required,
      authorization: CloudflareAuthorizationAdapter(
        providerID: providerID, methodID: "api-key"))
    let recorder = CloudflareRequestRecorder()
    let runtime = try ProviderRuntimeKernel(
      catalogRevision: "fixture", providers: [provider],
      wireProtocols: StandardWireProtocols.make(),
      credentialStore: InMemoryProviderCredentialStore(credentials: [
        providerID: .apiKey(
          .init(
            key: "fixture-cf-key",
            metadata: [
              "CLOUDFLARE_ACCOUNT_ID": "fixture-account",
              "CLOUDFLARE_GATEWAY_ID": "fixture-gateway",
            ]))
      ]), transport: recorder)
    let request = ProviderRequest(
      id: "fixture", providerID: providerID, modelID: model.id,
      messages: [.user([.text("hello")])], tools: [],
      options: .init(
        maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
        responseSchema: nil, providerOptions: [:], cacheRetention: .none))
    do {
      for try await _ in runtime.stream(request) {}
    } catch {
      // The fixture transport stops after request capture.
    }
    let sent = try #require(await recorder.sent)
    #expect(sent.url?.path.hasPrefix("/fixture-account/fixture-gateway/") == true)
    for (name, value) in expected {
      #expect(sent.value(forHTTPHeaderField: name) == value.stringValue)
    }
  }
}

private func cloudflareJSON(_ folder: String) throws -> [String: JSONValue] {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  return try #require(
    JSONDecoder().decode(
      JSONValue.self,
      from: Data(
        contentsOf: root.appending(path: "Fixtures/Differential/\(folder)/cloudflare-auth.json"))
    ).objectValue)
}

private actor CloudflareFixtureInteraction {
  let answers: [String]
  let stopAt: Int?
  var prompts: [JSONValue] = []
  init(answers: [String], stopAt: Int?) {
    self.answers = answers
    self.stopAt = stopAt
  }
  func respond(_ challenge: AuthorizationChallenge) throws -> AuthorizationResponse {
    guard case .prompt(_, _, let message, let kind) = challenge else { throw CancellationError() }
    let index = prompts.count
    prompts.append(.object(["type": .string(kind.rawValue), "message": .string(message)]))
    if index == stopAt { throw CancellationError() }
    return .value(answers[index])
  }
}
private struct CloudflareCaptureComplete: Error {}
private actor CloudflareRequestRecorder: ProviderHTTPStreamingTransport {
  var sent: URLRequest?
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    sent = request
    throw CloudflareCaptureComplete()
  }
}
