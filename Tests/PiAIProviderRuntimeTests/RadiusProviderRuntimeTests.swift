import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct RadiusProviderRuntimeTests {
  @Test
  func deviceOAuthStoresGatewayAndHandlesPendingPolling() async throws {
    let transport = RadiusBufferedFixtureTransport([
      radiusResponse(
        200,
        [
          "device_code": "radius-device",
          "user_code": "RADIUS-CODE",
          "verification_uri": "https://radius.example/activate",
          "expires_in": 600,
          "interval": 1,
        ]
      ),
      radiusResponse(400, ["error": "authorization_pending"]),
      radiusResponse(
        200,
        [
          "access_token": "radius-access",
          "refresh_token": "radius-refresh",
          "expires_in": 3_600,
        ]
      ),
    ])
    let store = InMemoryProviderCredentialStore()
    let adapter = RadiusOAuthAuthorizationAdapter(
      transport: transport,
      clock: RadiusFixedClock(now: Date(timeIntervalSince1970: 2_000_000_000))
    )
    let interaction = RadiusDeviceInteraction()

    _ = try await adapter.authorize(
      .login(providerID: "radius", methodID: "oauth"),
      interaction: { challenge in try await interaction.respond(challenge) },
      credentialStore: store
    )

    guard case .oauth(let credential)? = await store.read(providerID: "radius") else {
      Issue.record("Radius OAuth credential was not stored")
      return
    }
    #expect(credential.accessToken == "radius-access")
    #expect(credential.refreshToken == "radius-refresh")
    #expect(credential.metadata["gateway"] == "https://radius.example")
    #expect(await transport.requests.count == 3)
  }

  @Test
  func expiredOAuthRefreshesBeforeDynamicCatalogRequest() async throws {
    let now = Date()
    let store = InMemoryProviderCredentialStore(
      credentials: [
        "radius": .oauth(
          OAuthCredential(
            accessToken: "expired-access",
            refreshToken: "radius-refresh",
            expiresAt: now.addingTimeInterval(-60),
            metadata: ["gateway": "https://radius.example"]
          ))
      ]
    )
    let buffered = RadiusBufferedFixtureTransport([
      radiusResponse(
        200,
        [
          "access_token": "refreshed-access",
          "refresh_token": "rotated-refresh",
          "expires_in": 3_600,
        ]
      ),
      ProviderHTTPResponse(
        statusCode: 200,
        headers: [:],
        body: radiusConfigData()
      ),
    ])
    let runtime = try BuiltinProviderRuntime(
      credentialStore: store,
      streamingTransport: RadiusStreamingFixtureTransport(),
      authorizationTransport: buffered
    )

    _ = try await runtime.catalog()

    let requests = await buffered.requests
    #expect(requests.count == 2)
    #expect(requests[0].url?.path == "/v1/oauth/token")
    #expect(requests[1].url?.path == "/v1/config")
    #expect(
      requests[1].value(forHTTPHeaderField: "Authorization")
        == "Bearer refreshed-access"
    )
    guard case .oauth(let refreshed)? = await store.read(providerID: "radius") else {
      Issue.record("Radius refreshed credential was not persisted")
      return
    }
    #expect(refreshed.refreshToken == "rotated-refresh")
    #expect(refreshed.metadata["gateway"] == "https://radius.example")
  }

  @Test
  func dynamicCatalogRoutesStreamAndReloadsPersistedModelsOffline() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "pi-ai-radius-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistenceURL = directory.appending(path: "catalog.json")
    let credentialStore = InMemoryProviderCredentialStore(
      credentials: [
        "radius": .apiKey(
          APIKeyCredential(
            key: "radius-fixture-key",
            metadata: ["gateway": "https://radius.example"]
          ))
      ]
    )
    let buffered = RadiusBufferedFixtureTransport([
      ProviderHTTPResponse(
        statusCode: 200,
        headers: ["ETag": #""radius-v1""#],
        body: radiusConfigData()
      ),
      ProviderHTTPResponse(
        statusCode: 200,
        headers: [:],
        body: radiusConfigData()
      ),
    ])
    let streaming = RadiusStreamingFixtureTransport()
    let runtime = try BuiltinProviderRuntime(
      credentialStore: credentialStore,
      streamingTransport: streaming,
      authorizationTransport: buffered,
      radiusCatalogPersistenceURL: persistenceURL
    )

    let catalog = try await runtime.catalog()
    let radius = try #require(catalog.providers.first { $0.id == "radius" })
    let model = try #require(radius.models.first { $0.id == "radius-model" })
    #expect(model.protocolID == "pi-messages")
    #expect(model.capabilities.imageInput)
    #expect(model.capabilities.reasoning)

    var events: [ProviderEvent] = []
    for try await event in runtime.stream(radiusRequest(modelID: model.id)) {
      events.append(event)
    }
    #expect(events.contains(.textDelta("hello")))
    #expect(events.last == .completed(.stop))
    let sent = try #require(await streaming.request)
    #expect(sent.url?.absoluteString == "https://api.radius.example/v1/messages")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer radius-fixture-key")

    let offline = try BuiltinProviderRuntime(
      credentialStore: InMemoryProviderCredentialStore(),
      streamingTransport: RadiusStreamingFixtureTransport(),
      authorizationTransport: RadiusRejectingBufferedTransport(),
      radiusCatalogPersistenceURL: persistenceURL
    )
    let offlineRadius = try #require(
      try await offline.catalog().providers.first { $0.id == "radius" }
    )
    #expect(offlineRadius.models.map(\.id) == ["radius-model"])
  }

  @Test
  func invalidNetworkRefreshFailsWithoutServingPersistedModels() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "pi-ai-radius-invalid-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistenceURL = directory.appending(path: "catalog.json")
    let credentialStore = InMemoryProviderCredentialStore(
      credentials: [
        "radius": .apiKey(
          APIKeyCredential(
            key: "radius-fixture-key",
            metadata: ["gateway": "https://radius.example"]
          ))
      ]
    )
    let initial = try BuiltinProviderRuntime(
      credentialStore: credentialStore,
      streamingTransport: RadiusStreamingFixtureTransport(),
      authorizationTransport: RadiusBufferedFixtureTransport([
        ProviderHTTPResponse(statusCode: 200, headers: [:], body: radiusConfigData())
      ]),
      radiusCatalogPersistenceURL: persistenceURL
    )
    _ = try await initial.catalog()

    let invalid = try BuiltinProviderRuntime(
      credentialStore: credentialStore,
      streamingTransport: RadiusStreamingFixtureTransport(),
      authorizationTransport: RadiusBufferedFixtureTransport([
        ProviderHTTPResponse(
          statusCode: 200,
          headers: [:],
          body: Data(#"{"baseUrl":false,"models":[]}"#.utf8)
        )
      ]),
      radiusCatalogPersistenceURL: persistenceURL
    )
    do {
      _ = try await invalid.catalog()
      Issue.record("invalid Radius refresh unexpectedly served a stale catalog")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .invalidResponse)
      #expect(error.operation == "catalog.radius.decode")
    }
  }
}

private actor RadiusDeviceInteraction {
  private var promptCount = 0

  func respond(_ challenge: AuthorizationChallenge) throws -> AuthorizationResponse {
    switch challenge {
    case .prompt(_, let id, _, _):
      promptCount += 1
      switch id {
      case "radius-gateway": return .value("https://radius.example/")
      case "radius-login-method": return .value("device-code")
      default: throw radiusFixtureFailure("unexpected Radius prompt")
      }
    case .deviceCode(_, let code, let url, _, _):
      #expect(promptCount == 2)
      #expect(code == "RADIUS-CODE")
      #expect(url.absoluteString == "https://radius.example/activate")
      return .acknowledged
    default:
      throw radiusFixtureFailure("unexpected Radius interaction")
    }
  }
}

private struct RadiusFixedClock: ProviderOAuthClock {
  let value: Date
  init(now: Date) { value = now }
  func now() -> Date { value }
  func sleep(for duration: Duration) async throws {}
}

private actor RadiusBufferedFixtureTransport: ProviderHTTPTransport {
  private var responses: [ProviderHTTPResponse]
  private(set) var requests: [URLRequest] = []

  init(_ responses: [ProviderHTTPResponse]) { self.responses = responses }

  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw radiusFixtureFailure("response queue is empty") }
    return responses.removeFirst()
  }
}

private struct RadiusRejectingBufferedTransport: ProviderHTTPTransport {
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    throw radiusFixtureFailure("offline catalog attempted network access")
  }
}

private actor RadiusStreamingFixtureTransport: ProviderHTTPStreamingTransport {
  private(set) var request: URLRequest?

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    self.request = request
    let data = Data(
      ("data: {\"type\":\"start\"}\n\n"
        + "data: {\"type\":\"text_start\",\"contentIndex\":0}\n\n"
        + "data: {\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"hello\"}\n\n"
        + "data: {\"type\":\"text_end\",\"contentIndex\":0,\"content\":\"hello\"}\n\n"
        + "data: {\"type\":\"done\",\"reason\":\"stop\",\"usage\":{\"input\":1,\"output\":1,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":2}}\n\n")
        .utf8
    )
    return ProviderHTTPStreamingResponse(
      statusCode: 200,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.yield(data)
        continuation.finish()
      }
    )
  }
}

private func radiusRequest(modelID: String) -> ProviderRequest {
  ProviderRequest(
    id: "radius-request",
    providerID: "radius",
    modelID: modelID,
    messages: [.user([.text("hello")])],
    tools: [],
    options: ProviderGenerationOptions(
      maximumOutputTokens: nil,
      temperature: nil,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: [:]
    )
  )
}

private func radiusConfigData() -> Data {
  Data(
    #"{"baseUrl":"https://api.radius.example/v1","models":[{"id":"radius-model","name":"Radius Model","reasoning":true,"thinkingLevelMap":{"high":"high"},"input":["text","image"],"cost":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0},"contextWindow":131072,"maxTokens":8192}]}"#
      .utf8
  )
}

private func radiusResponse(
  _ statusCode: Int,
  _ object: [String: Any]
) -> ProviderHTTPResponse {
  ProviderHTTPResponse(
    statusCode: statusCode,
    headers: [:],
    body: try! JSONSerialization.data(withJSONObject: object)
  )
}

private func radiusFixtureFailure(_ message: String) -> ProviderRuntimeFailure {
  ProviderRuntimeFailure(
    code: .transportFailed,
    message: message,
    providerID: "radius",
    operation: "fixture.radius",
    causeDescription: nil
  )
}
