import Foundation

@testable import PiAIProviderRuntime

enum OAuthResolutionFixtures {
  static func replay(_ spec: [String: JSONValue]) async throws -> JSONValue {
    let now = Date(timeIntervalSince1970: Double(spec.int("now")!) / 1_000)
    let source = OAuthCredential(
      accessToken: "old-access", refreshToken: "old-refresh",
      expiresAt: now.addingTimeInterval(Double(spec.int("expiresOffsetMilliseconds")!) / 1_000),
      metadata: [:])
    let provider = spec.string("provider") ?? "fixture"
    let store = InMemoryProviderCredentialStore(credentials: [provider: .oauth(source)])
    let coordinator = CredentialRefreshCoordinator(credentialStore: store)
    let recorder = OAuthResolutionRecorder()
    let result: OAuthCredential
    if provider == "anthropic" {
      let adapter = AnthropicOAuthAuthorizationAdapter(
        transport: OAuthResolutionTransport(recorder: recorder, spec: spec), now: { now })
      guard
        case .oauth(let credential) = try await adapter.resolveCredential(
          providerID: provider, credentialStore: store, refreshCoordinator: coordinator)
      else { throw CancellationError() }
      result = credential
    } else {
      result = try await coordinator.credential(providerID: provider, now: now) { _ in
        await recorder.refreshed()
        return OAuthCredential(
          accessToken: spec.string("refreshedAccess")!,
          refreshToken: spec.string("refreshedRefresh")!,
          expiresAt: now.addingTimeInterval(
            Double(spec.int("refreshedExpiresOffsetMilliseconds")!) / 1_000), metadata: [:])
      }
    }
    guard case .oauth(let stored) = try await store.read(providerID: provider) else {
      throw CancellationError()
    }
    return .object([
      "id": spec["id"]!, "refreshCount": .integer(Int64(await recorder.count)),
      "result": .object([
        "auth": .object(["apiKey": .string(result.accessToken)]), "source": .string("OAuth"),
      ]),
      "stored": .object([
        "type": .string("oauth"), "access": .string(stored.accessToken),
        "refresh": .string(stored.refreshToken),
        "expires": .integer(Int64((stored.expiresAt.timeIntervalSince1970 * 1_000).rounded())),
      ]),
    ])
  }
}

private actor OAuthResolutionRecorder {
  var count = 0
  func refreshed() { count += 1 }
}

private struct OAuthResolutionTransport: ProviderHTTPTransport {
  let recorder: OAuthResolutionRecorder
  let spec: [String: JSONValue]
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    await recorder.refreshed()
    return .init(
      statusCode: 200, headers: [:],
      body: try JSONEncoder().encode(
        JSONValue.object([
          "access_token": spec["refreshedAccess"]!, "refresh_token": spec["refreshedRefresh"]!,
          "expires_in": .integer(3_600),
        ])))
  }
}
