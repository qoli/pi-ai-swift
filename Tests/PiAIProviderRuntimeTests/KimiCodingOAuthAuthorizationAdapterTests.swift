import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct KimiCodingOAuthAuthorizationAdapterTests {
  @Test
  func deviceFlowPreservesPendingSlowDownAndStoresCredential() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let transport = KimiOAuthFixtureTransport(responses: [
      response(
        200,
        [
          "device_code": "device",
          "user_code": "ABCD-EFGH",
          "verification_uri": "https://auth.kimi.com/device",
          "verification_uri_complete": "https://auth.kimi.com/device?code=ABCD-EFGH",
          "interval": 1,
          "expires_in": 600,
        ]),
      response(400, ["error": "authorization_pending"]),
      response(400, ["error": "slow_down", "interval": 2]),
      response(
        200,
        [
          "access_token": "access",
          "refresh_token": "refresh",
          "expires_in": 3_600,
        ]),
    ])
    let adapter = KimiCodingOAuthAuthorizationAdapter(
      transport: transport,
      oauthBaseURL: URL(string: "https://fixture.invalid")!,
      clock: FixedOAuthClock(now: now)
    )
    let store = InMemoryProviderCredentialStore()
    let state = try await adapter.authorize(
      .login(providerID: "kimi-coding", methodID: "oauth"),
      interaction: { challenge in
        guard
          case .deviceCode(
            let providerID,
            let userCode,
            let url,
            _,
            let interval
          ) = challenge
        else {
          Issue.record("expected device code challenge")
          return .value("wrong")
        }
        #expect(providerID == "kimi-coding")
        #expect(userCode == "ABCD-EFGH")
        #expect(url.absoluteString == "https://auth.kimi.com/device?code=ABCD-EFGH")
        #expect(interval == .seconds(1))
        return .acknowledged
      },
      credentialStore: store
    )
    #expect(
      state
        == .connected(
          ProviderAccount(
            providerID: "kimi-coding",
            accountID: nil,
            authorizationKind: .oauth,
            expiresAt: now.addingTimeInterval(3_600)
          )
        )
    )
    #expect(
      await store.read(providerID: "kimi-coding")
        == .oauth(
          OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: now.addingTimeInterval(3_600),
            metadata: [:]
          )
        )
    )
    #expect(await transport.requestCount() == 4)
  }

  @Test
  func refreshRotatesExpiredCredentialAndRejectsMalformedToken() async throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let expired = OAuthCredential(
      accessToken: "old-access",
      refreshToken: "old-refresh",
      expiresAt: now,
      metadata: [:]
    )
    let store = InMemoryProviderCredentialStore(
      credentials: ["kimi-coding": .oauth(expired)]
    )
    let transport = KimiOAuthFixtureTransport(responses: [
      response(
        200,
        [
          "access_token": "new-access",
          "refresh_token": "new-refresh",
          "expires_in": 600,
        ])
    ])
    let adapter = KimiCodingOAuthAuthorizationAdapter(
      transport: transport,
      oauthBaseURL: URL(string: "https://fixture.invalid")!,
      clock: FixedOAuthClock(now: now)
    )
    let resolved = try await adapter.resolveCredential(
      providerID: "kimi-coding",
      credentialStore: store
    )
    #expect(
      resolved
        == .oauth(
          OAuthCredential(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: now.addingTimeInterval(600),
            metadata: [:]
          )
        )
    )

    let malformedStore = InMemoryProviderCredentialStore(
      credentials: ["kimi-coding": .oauth(expired)]
    )
    let malformedAdapter = KimiCodingOAuthAuthorizationAdapter(
      transport: KimiOAuthFixtureTransport(responses: [
        response(200, ["access_token": "missing-fields"])
      ]),
      oauthBaseURL: URL(string: "https://fixture.invalid")!,
      clock: FixedOAuthClock(now: now)
    )
    await #expect(throws: ProviderRuntimeFailure.self) {
      _ = try await malformedAdapter.resolveCredential(
        providerID: "kimi-coding",
        credentialStore: malformedStore
      )
    }
  }
}

private struct FixedOAuthClock: ProviderOAuthClock {
  let nowValue: Date

  init(now: Date) { nowValue = now }
  func now() -> Date { nowValue }
  func sleep(for duration: Duration) async throws {}
}

private actor KimiOAuthFixtureTransport: ProviderHTTPTransport {
  private var responses: [ProviderHTTPResponse]
  private var requests: [URLRequest] = []

  init(responses: [ProviderHTTPResponse]) { self.responses = responses }

  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else {
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: "fixture response queue is empty",
        providerID: "kimi-coding",
        operation: "fixture",
        causeDescription: nil
      )
    }
    return responses.removeFirst()
  }

  func requestCount() -> Int { requests.count }
}

private func response(
  _ statusCode: Int,
  _ object: [String: Any]
) -> ProviderHTTPResponse {
  ProviderHTTPResponse(
    statusCode: statusCode,
    headers: [:],
    body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  )
}
