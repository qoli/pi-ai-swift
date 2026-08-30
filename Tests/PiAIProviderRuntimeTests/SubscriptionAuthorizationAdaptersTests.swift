import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct SubscriptionAuthorizationAdaptersTests {
  @Test
  func anthropicPKCELoginValidatesStateAndStoresRotatingOAuth() async throws {
    let transport = SubscriptionQueueTransport([
      response(
        200,
        [
          "access_token": "anthropic-access",
          "refresh_token": "anthropic-refresh",
          "expires_in": 3_600,
        ])
    ])
    let store = InMemoryProviderCredentialStore()
    let adapter = AnthropicOAuthAuthorizationAdapter(
      transport: transport,
      now: { Date(timeIntervalSince1970: 2_000_000_000) }
    )
    let state = try await adapter.authorize(
      .login(providerID: "anthropic", methodID: "oauth"),
      interaction: { challenge in
        guard case .openURL(_, let url, _) = challenge,
          let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value
        else {
          Issue.record("Anthropic did not present a PKCE authorization URL")
          return .acknowledged
        }
        return .callbackURL(
          URL(string: "http://localhost:53692/callback?code=code-1&state=\(state)")!
        )
      },
      credentialStore: store
    )
    guard case .connected(let account) = state else {
      Issue.record("Anthropic OAuth did not connect")
      return
    }
    #expect(account.providerID == "anthropic")
    guard case .oauth(let credential)? = await store.read(providerID: "anthropic") else {
      Issue.record("Anthropic OAuth credential was not stored")
      return
    }
    #expect(credential.accessToken == "anthropic-access")
    #expect(credential.refreshToken == "anthropic-refresh")
    let sent = try #require(await transport.requests.first)
    #expect(sent.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
  }

  @Test
  func openRouterPKCEExchangesPermanentKeyWithoutInventingRefresh() async throws {
    let transport = SubscriptionQueueTransport([
      response(200, ["key": "openrouter-key"])
    ])
    let store = InMemoryProviderCredentialStore()
    let adapter = OpenRouterOAuthAuthorizationAdapter(transport: transport)
    _ = try await adapter.authorize(
      .login(providerID: "openrouter", methodID: "oauth"),
      interaction: { challenge in
        guard case .openURL(_, let url, let callbackScheme) = challenge else {
          Issue.record("OpenRouter did not present a PKCE authorization URL")
          return .acknowledged
        }
        #expect(url.host == "openrouter.ai")
        #expect(callbackScheme == "pi-ai-swift")
        return .callbackURL(URL(string: "pi-ai-swift://oauth/openrouter?code=code-2")!)
      },
      credentialStore: store
    )
    guard case .oauth(let credential)? = await store.read(providerID: "openrouter") else {
      Issue.record("OpenRouter OAuth credential was not stored")
      return
    }
    #expect(credential.accessToken == "openrouter-key")
    #expect(credential.refreshToken.isEmpty)
    #expect(credential.expiresAt == .distantFuture)
  }

  @Test
  func xAIDeviceFlowHandlesPendingAndRefreshTokenRotation() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let transport = SubscriptionQueueTransport([
      response(
        200,
        [
          "device_code": "xai-device",
          "user_code": "XAI-CODE",
          "verification_uri": "https://auth.x.ai/activate",
          "expires_in": 600,
          "interval": 1,
        ]),
      response(400, ["error": "authorization_pending"]),
      response(
        200,
        [
          "access_token": "xai-access",
          "refresh_token": "xai-refresh",
          "expires_in": 3_600,
        ]),
    ])
    let store = InMemoryProviderCredentialStore()
    let adapter = XAIOAuthAuthorizationAdapter(
      transport: transport,
      clock: SubscriptionFixedClock(now: now)
    )
    _ = try await adapter.authorize(
      .login(providerID: "xai", methodID: "oauth"),
      interaction: { challenge in
        guard case .deviceCode(_, let code, let url, _, _) = challenge else {
          Issue.record("xAI did not present a device code")
          return .value("")
        }
        #expect(code == "XAI-CODE")
        #expect(url.scheme == "https")
        return .acknowledged
      },
      credentialStore: store
    )
    guard case .oauth(let credential)? = await store.read(providerID: "xai") else {
      Issue.record("xAI OAuth credential was not stored")
      return
    }
    #expect(credential.accessToken == "xai-access")
    #expect(credential.refreshToken == "xai-refresh")
    #expect(await transport.requests.count == 3)
  }

  @Test
  func xAIRefreshPreservesUnrotatedRefreshToken() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let source = OAuthCredential(
      accessToken: "expired-access",
      refreshToken: "stable-refresh",
      expiresAt: now,
      metadata: [:]
    )
    let store = InMemoryProviderCredentialStore(
      credentials: ["xai": .oauth(source)]
    )
    let transport = SubscriptionQueueTransport([
      response(
        200,
        [
          "access_token": "refreshed-access",
          "expires_in": 3_600,
        ])
    ])
    let adapter = XAIOAuthAuthorizationAdapter(
      transport: transport,
      clock: SubscriptionFixedClock(now: now)
    )
    let resolved = try await adapter.resolveCredential(
      providerID: "xai",
      credentialStore: store,
      refreshCoordinator: CredentialRefreshCoordinator(
        credentialStore: store
      )
    )
    guard case .oauth(let credential) = resolved else {
      Issue.record("xAI refresh did not return OAuth credential")
      return
    }
    #expect(credential.accessToken == "refreshed-access")
    #expect(credential.refreshToken == "stable-refresh")
  }

  @Test
  func githubCopilotDeviceFlowDerivesProxyEndpointAndAccountModels() async throws {
    let transport = SubscriptionQueueTransport([
      response(
        200,
        [
          "device_code": "github-device",
          "user_code": "GH-CODE",
          "verification_uri": "https://github.com/login/device",
          "expires_in": 600,
          "interval": 1,
        ]),
      response(200, ["error": "authorization_pending"]),
      response(200, ["access_token": "github-access"]),
      response(
        200,
        [
          "token": "tid=1;proxy-ep=proxy.individual.githubcopilot.com;exp=2000000000;",
          "expires_at": 2_000_000_000,
        ]),
      response(
        200,
        [
          "data": .array([
            .object([
              "id": .string("gpt-fixture"),
              "model_picker_enabled": .bool(true),
              "policy": .object(["state": .string("enabled")]),
            ])
          ])
        ]),
    ])
    let store = InMemoryProviderCredentialStore()
    let adapter = GitHubCopilotOAuthAuthorizationAdapter(
      transport: transport,
      clock: SubscriptionFixedClock(
        now: Date(timeIntervalSince1970: 1_900_000_000)
      )
    )
    let interaction = GitHubFixtureInteraction()
    _ = try await adapter.authorize(
      .login(providerID: "github-copilot", methodID: "oauth"),
      interaction: { challenge in try await interaction.respond(challenge) },
      credentialStore: store
    )
    guard
      case .oauth(let credential)? = await store.read(
        providerID: "github-copilot"
      )
    else {
      Issue.record("GitHub Copilot OAuth credential was not stored")
      return
    }
    #expect(credential.refreshToken == "github-access")
    #expect(
      credential.metadata["baseURL"]
        == "https://api.individual.githubcopilot.com"
    )
    #expect(credential.metadata["availableModelIDs"] == "gpt-fixture")
    #expect(await transport.requests.count == 5)
  }

  @Test
  func copilotDynamicHeadersReflectInitiatorAndVision() throws {
    var request = URLRequest(url: URL(string: "https://fixture.invalid")!)
    applyGitHubCopilotHeaders(
      providerID: "github-copilot",
      messages: [
        .user([.image(.data(Data([0x01]), mimeType: "image/png"))]),
        .assistant([.text("continue")]),
      ],
      to: &request
    )
    #expect(request.value(forHTTPHeaderField: "X-Initiator") == "agent")
    #expect(request.value(forHTTPHeaderField: "Openai-Intent") == "conversation-edits")
    #expect(request.value(forHTTPHeaderField: "Copilot-Vision-Request") == "true")
  }
}

private actor SubscriptionQueueTransport: ProviderHTTPTransport {
  private var responses: [ProviderHTTPResponse]
  private(set) var requests: [URLRequest] = []

  init(_ responses: [ProviderHTTPResponse]) { self.responses = responses }

  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else {
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: "fixture response queue is empty",
        providerID: nil,
        operation: "fixture.oauth",
        causeDescription: nil
      )
    }
    return responses.removeFirst()
  }
}

private struct SubscriptionFixedClock: ProviderOAuthClock {
  let value: Date
  init(now: Date) { value = now }
  func now() -> Date { value }
  func sleep(for duration: Duration) async throws {}
}

private actor GitHubFixtureInteraction {
  private var promptSeen = false

  func respond(_ challenge: AuthorizationChallenge) throws -> AuthorizationResponse {
    switch challenge {
    case .prompt:
      guard !promptSeen else {
        throw ProviderRuntimeFailure(
          code: .authorizationFailed,
          message: "duplicate GitHub prompt",
          providerID: "github-copilot",
          operation: "fixture",
          causeDescription: nil
        )
      }
      promptSeen = true
      return .value("")
    case .deviceCode(_, let code, _, _, _):
      #expect(promptSeen)
      #expect(code == "GH-CODE")
      return .acknowledged
    default:
      Issue.record("unexpected GitHub authorization challenge")
      return .value("")
    }
  }
}

private func response(
  _ status: Int,
  _ object: [String: Any]
) -> ProviderHTTPResponse {
  ProviderHTTPResponse(
    statusCode: status,
    headers: [:],
    body: try! JSONSerialization.data(withJSONObject: object)
  )
}

private func response(
  _ status: Int,
  _ object: [String: JSONValue]
) -> ProviderHTTPResponse {
  ProviderHTTPResponse(
    statusCode: status,
    headers: [:],
    body: try! JSONEncoder().encode(JSONValue.object(object))
  )
}
