import Foundation

struct AnthropicOAuthAuthorizationAdapter: ProviderAuthorizationAdapter {
  static let providerID = "anthropic"
  private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  private static let scope =
    "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

  private let transport: any ProviderHTTPTransport
  private let now: @Sendable () -> Date
  private let callbackURL: URL

  init(
    transport: any ProviderHTTPTransport,
    now: @escaping @Sendable () -> Date = Date.init,
    callbackURL: URL = URL(string: "http://localhost:53692/callback")!
  ) {
    self.transport = transport
    self.now = now
    self.callbackURL = callbackURL
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
      guard ["oauth", "oauth-browser", "oauth-copy-code"].contains(methodID) else {
        throw failure("unsupported authorization method")
      }
      let method =
        try await methodID == "oauth"
        ? ProviderOAuthLoginChoice.select(providerID: providerID, interaction: interaction)
        : methodID == "oauth-copy-code" ? "copy_code" : "browser"
      let redirectURI =
        method == "copy_code"
        ? "https://platform.claude.com/oauth/code/callback" : callbackURL.absoluteString
      let pkce = try OAuthPKCE.make()
      var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
      components.queryItems = [
        URLQueryItem(name: "code", value: "true"),
        URLQueryItem(name: "client_id", value: Self.clientID),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: redirectURI),
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
        providerID: providerID, requireState: false
      )
      let credential = try await exchange(
        fields: [
          "grant_type": .string("authorization_code"),
          "client_id": .string(Self.clientID),
          "code": .string(code),
          "state": .string(pkce.state),
          "redirect_uri": .string(redirectURI),
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
      minimumValidity: 300,
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
  private let callbackURL: URL
  private let transport: any ProviderHTTPTransport

  init(
    transport: any ProviderHTTPTransport,
    callbackURL: URL = URL(string: "pi-ai-swift://oauth/openrouter")!
  ) {
    self.transport = transport
    self.callbackURL = callbackURL
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
      try Task.checkCancellation()
      let pkce = try OAuthPKCE.make()
      var components = URLComponents(string: "https://openrouter.ai/auth")!
      components.queryItems = [
        URLQueryItem(name: "callback_url", value: callbackURL.absoluteString),
        URLQueryItem(name: "code_challenge", value: pkce.challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
      ]
      guard let url = components.url else { throw failure("authorization URL is invalid") }
      let response = try await interaction(
        .openURL(
          providerID: providerID, url: url,
          callbackScheme: ["http", "https"].contains(callbackURL.scheme ?? "")
            ? nil : callbackURL.scheme)
      )
      let code: String
      do {
        code = try oauthAuthorizationCode(response, expectedState: nil, providerID: providerID)
      } catch { throw failure("Missing authorization code") }
      let tokenResponse = try await transport.send(
        oauthJSONRequest(
          url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!,
          body: [
            "code": .string(code),
            "code_verifier": .string(pkce.verifier),
            "code_challenge_method": .string("S256"),
          ]
        )
      )
      let parsed = try? decodeJSONObject(
        tokenResponse.body, providerID: providerID, operation: "openrouter.oauth.exchange")
      if !(200..<300).contains(tokenResponse.statusCode) {
        let detail =
          parsed?.string("error_description") ?? parsed?.string("message")
          ?? parsed?.string("error") ?? parsed?.object("error")?.string("message")
        throw failure(
          "OpenRouter OAuth key exchange failed (HTTP \(tokenResponse.statusCode))"
            + (detail.map { ": " + $0 } ?? ""))
      }
      guard let body = parsed else { throw failure("OpenRouter OAuth returned invalid JSON") }
      guard let key = body.string("key"), !key.isEmpty else {
        throw oauthFailure(
          .invalidResponse,
          providerID: providerID,
          operation: "openrouter.oauth.exchange",
          message: "OpenRouter OAuth response carries no \"key\""
        )
      }
      let credential = OAuthCredential(
        accessToken: key,
        refreshToken: "",
        expiresAt: .distantFuture,
        metadata: ["expirationMilliseconds": "9007199254740991"]
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
