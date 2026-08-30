import Foundation

struct AnthropicOAuthAuthorizationAdapter: ProviderAuthorizationAdapter {
  static let providerID = "anthropic"
  private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  private static let redirectURI = "http://localhost:53692/callback"
  private static let scope =
    "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

  private let transport: any ProviderHTTPTransport
  private let now: @Sendable () -> Date

  init(
    transport: any ProviderHTTPTransport,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.transport = transport
    self.now = now
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    switch operation {
    case .logout(let providerID):
      try require(providerID)
      try await credentialStore.delete(providerID: providerID)
      return .disconnected(providerID: providerID)
    case .login(let providerID, let methodID):
      try require(providerID)
      guard methodID == "oauth" else { throw failure("unsupported authorization method") }
      let pkce = try OAuthPKCE.make()
      var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
      components.queryItems = [
        URLQueryItem(name: "code", value: "true"),
        URLQueryItem(name: "client_id", value: Self.clientID),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
        URLQueryItem(name: "scope", value: Self.scope),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: pkce.state),
      ]
      guard let url = components.url else { throw failure("authorization URL is invalid") }
      let response = try await interaction(
        .openURL(providerID: providerID, url: url, callbackScheme: nil)
      )
      let code = try oauthAuthorizationCode(
        response,
        expectedState: pkce.state,
        providerID: providerID
      )
      let credential = try await exchange(
        fields: [
          "grant_type": .string("authorization_code"),
          "client_id": .string(Self.clientID),
          "code": .string(code),
          "state": .string(pkce.state),
          "redirect_uri": .string(Self.redirectURI),
          "code_verifier": .string(pkce.verifier),
        ],
        operation: "anthropic.oauth.exchange"
      )
      _ = try await credentialStore.modify(providerID: providerID) { _ in
        .oauth(credential)
      }
      return .connected(
        ProviderAccount(
          providerID: providerID,
          accountID: nil,
          authorizationKind: .oauth,
          expiresAt: credential.expiresAt
        )
      )
    }
  }

  func resolveCredential(
    providerID: String,
    credentialStore: any ProviderCredentialStore,
    refreshCoordinator: CredentialRefreshCoordinator
  ) async throws -> ProviderCredential? {
    try require(providerID)
    guard let stored = try await credentialStore.read(providerID: providerID) else {
      return nil
    }
    guard case .oauth = stored else { return stored }
    let refreshed = try await refreshCoordinator.credential(
      providerID: providerID,
      minimumValidity: 60,
      now: now(),
      refresh: { credential in
        try await exchange(
          fields: [
            "grant_type": .string("refresh_token"),
            "client_id": .string(Self.clientID),
            "refresh_token": .string(credential.refreshToken),
          ],
          operation: "anthropic.oauth.refresh"
        )
      }
    )
    return .oauth(refreshed)
  }

  private func exchange(
    fields: [String: JSONValue],
    operation: String
  ) async throws -> OAuthCredential {
    let response = try await transport.send(
      oauthJSONRequest(
        url: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        body: fields
      )
    )
    return try oauthCredential(
      oauthResponseObject(response, providerID: Self.providerID, operation: operation),
      providerID: Self.providerID,
      operation: operation,
      now: now(),
      expirySkew: 300
    )
  }

  private func require(_ providerID: String) throws {
    guard providerID == Self.providerID else { throw failure("provider mismatch") }
  }

  private func failure(_ message: String) -> ProviderRuntimeFailure {
    oauthFailure(
      .authorizationFailed,
      providerID: Self.providerID,
      operation: "anthropic.oauth",
      message: message
    )
  }
}

struct OpenRouterOAuthAuthorizationAdapter: ProviderAuthorizationAdapter {
  static let providerID = "openrouter"
  private static let callbackURL = "pi-ai-swift://oauth/openrouter"
  private let transport: any ProviderHTTPTransport

  init(transport: any ProviderHTTPTransport) {
    self.transport = transport
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    switch operation {
    case .logout(let providerID):
      try require(providerID)
      try await credentialStore.delete(providerID: providerID)
      return .disconnected(providerID: providerID)
    case .login(let providerID, let methodID):
      try require(providerID)
      guard methodID == "oauth" else { throw failure("unsupported authorization method") }
      let pkce = try OAuthPKCE.make()
      var components = URLComponents(string: "https://openrouter.ai/auth")!
      components.queryItems = [
        URLQueryItem(name: "callback_url", value: Self.callbackURL),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
      ]
      guard let url = components.url else { throw failure("authorization URL is invalid") }
      let response = try await interaction(
        .openURL(providerID: providerID, url: url, callbackScheme: "pi-ai-swift")
      )
      let code = try oauthAuthorizationCode(
        response,
        expectedState: nil,
        providerID: providerID
      )
      let tokenResponse = try await transport.send(
        oauthJSONRequest(
          url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!,
          body: [
            "code": .string(code),
            "code_verifier": .string(pkce.verifier),
          ]
        )
      )
      let body = try oauthResponseObject(
        tokenResponse,
        providerID: providerID,
        operation: "openrouter.oauth.exchange"
      )
      guard let key = body.string("key"), !key.isEmpty else {
        throw oauthFailure(
          .invalidResponse,
          providerID: providerID,
          operation: "openrouter.oauth.exchange",
          message: "OpenRouter OAuth response is missing key"
        )
      }
      let credential = OAuthCredential(
        accessToken: key,
        refreshToken: "",
        expiresAt: .distantFuture,
        metadata: [:]
      )
      _ = try await credentialStore.modify(providerID: providerID) { _ in
        .oauth(credential)
      }
      return .connected(
        ProviderAccount(
          providerID: providerID,
          accountID: nil,
          authorizationKind: .oauth,
          expiresAt: credential.expiresAt
        )
      )
    }
  }

  func resolveCredential(
    providerID: String,
    credentialStore: any ProviderCredentialStore,
    refreshCoordinator: CredentialRefreshCoordinator
  ) async throws -> ProviderCredential? {
    try require(providerID)
    guard let stored = try await credentialStore.read(providerID: providerID) else {
      return nil
    }
    guard case .oauth(let credential) = stored else { return stored }
    guard !credential.accessToken.isEmpty else {
      throw oauthFailure(
        .invalidCredential,
        providerID: providerID,
        operation: "openrouter.oauth.resolve",
        message: "OpenRouter OAuth key is empty"
      )
    }
    return stored
  }

  private func require(_ providerID: String) throws {
    guard providerID == Self.providerID else { throw failure("provider mismatch") }
  }

  private func failure(_ message: String) -> ProviderRuntimeFailure {
    oauthFailure(
      .authorizationFailed,
      providerID: Self.providerID,
      operation: "openrouter.oauth",
      message: message
    )
  }
}
