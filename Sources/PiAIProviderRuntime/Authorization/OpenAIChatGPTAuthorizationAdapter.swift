import Foundation

struct OpenAIChatGPTAuthorizationAdapter: ProviderAuthorizationAdapter {
  static let providerID = "openai"
  private static let redirect = "http://127.0.0.1:1455/auth/callback"
  private static let resource = "https://api.openai.com/v1"
  private static let scope =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
  private let transport: any ProviderHTTPTransport
  private let clock: any ProviderOAuthClock
  private let deviceID: String?
  private let agentName: String

  init(
    transport: any ProviderHTTPTransport,
    clock: any ProviderOAuthClock = SystemProviderOAuthClock(),
    deviceID: String?, agentName: String = "Pi"
  ) {
    self.transport = transport
    self.clock = clock
    self.deviceID = deviceID
    self.agentName = agentName
  }

  func requestAuthorization(for credential: ProviderCredential?) throws
    -> ProviderRequestAuthorization
  {
    if case .oauth(let value) = credential {
      return .init(
        credential: .apiKey(.init(key: value.accessToken, metadata: value.metadata)), headers: [:])
    }
    return .init(credential: credential, headers: [:])
  }

  func authorize(
    _ operation: AuthorizationOperation, interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    switch operation {
    case .logout(let providerID):
      guard providerID == Self.providerID else { throw failure("provider mismatch") }
      try await credentialStore.delete(providerID: providerID)
      return .disconnected(providerID: providerID)
    case .login(let providerID, let methodID):
      guard providerID == Self.providerID, methodID == "oauth" else {
        throw failure("unsupported authorization method")
      }
      guard let deviceID,
        deviceID.range(
          of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
          options: .regularExpression) != nil
      else {
        throw failure("Sign in with ChatGPT requires a device ID (UUID) for this installation")
      }
      let pkce = try OAuthPKCE.make()
      let state = try OAuthPKCE.randomValue()
      var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
      components.queryItems = [
        .init(name: "client_id", value: "dynamic_agent_client"),
        .init(name: "agent_name_hint", value: agentName),
        .init(name: "ext_agent_host_id", value: "urn:uuid:" + deviceID.lowercased()),
        .init(name: "response_type", value: "code"),
        .init(name: "redirect_uri", value: Self.redirect),
        .init(name: "resource", value: Self.resource), .init(name: "scope", value: Self.scope),
        .init(name: "state", value: state), .init(name: "code_challenge", value: pkce.challenge),
        .init(name: "code_challenge_method", value: "S256"),
        .init(name: "nonce", value: try OAuthPKCE.randomValue()),
      ]
      let response = try await interaction(
        .openURL(providerID: providerID, url: components.url!, callbackScheme: nil))
      let callback: URLComponents
      switch response {
      case .callbackURL(let url): callback = try callbackComponents(url.absoluteString)
      case .value(let value): callback = try callbackComponents(value)
      case .acknowledged: throw failure("Paste the full callback URL from the browser")
      }
      func parameter(_ name: String) -> String? {
        callback.queryItems?.first { $0.name == name }?.value
      }
      if let error = parameter("error"), !error.isEmpty {
        throw failure("ChatGPT authorization failed: " + error)
      }
      guard let code = parameter("code"), !code.isEmpty else {
        throw failure("Missing authorization code")
      }
      guard let returnedState = parameter("state"), !returnedState.isEmpty else {
        throw failure("Missing OAuth state")
      }
      guard returnedState == state else { throw failure("OAuth state mismatch") }
      guard
        let clientID = parameter("client_id")?.trimmingCharacters(
          in: ProviderErrorText.javaScriptWhitespace), !clientID.isEmpty
      else {
        throw failure("OpenAI OAuth registration callback did not contain an issued client ID")
      }
      _ = try await interaction(
        .progress(providerID: providerID, message: "Exchanging authorization code for tokens..."))
      let body = try await requestToken([
        "grant_type": "authorization_code", "client_id": clientID, "code": code,
        "code_verifier": pkce.verifier, "redirect_uri": Self.redirect, "resource": Self.resource,
      ])
      guard let idToken = body.string("id_token"),
        !idToken.trimmingCharacters(in: ProviderErrorText.javaScriptWhitespace).isEmpty
      else {
        throw failure("OpenAI OAuth token response did not contain an ID token")
      }
      let credential = try credential(body, clientID: clientID)
      _ = try await credentialStore.modify(providerID: providerID) { _ in .oauth(credential) }
      return .connected(
        .init(
          providerID: providerID, accountID: nil, authorizationKind: .oauth,
          expiresAt: credential.expiresAt))
    }
  }

  var oauthRefresh: CredentialRefreshCoordinator.RefreshOperation? {
    { value in
      guard let clientID = value.metadata["clientID"],
        !clientID.trimmingCharacters(in: ProviderErrorText.javaScriptWhitespace).isEmpty
      else {
        throw failure(
          "Stored OpenAI OAuth credential does not contain an issued client ID; reconnect ChatGPT"
        )
      }
      return try await credential(
        requestToken([
          "grant_type": "refresh_token", "client_id": clientID,
          "refresh_token": value.refreshToken,
          "resource": Self.resource,
        ]), clientID: clientID)
    }
  }
  var oauthNow: @Sendable () -> Date { { clock.now() } }

  func resolveCredential(
    providerID: String, credentialStore: any ProviderCredentialStore,
    refreshCoordinator: CredentialRefreshCoordinator
  ) async throws -> ProviderCredential? {
    guard let stored = try await credentialStore.read(providerID: providerID) else { return nil }
    guard case .oauth(let optimistic) = stored else { return stored }
    let refreshed = try await refreshCoordinator.credential(
      providerID: providerID,
      optimisticCredential: optimistic, now: oauthNow,
      refresh: oauthRefresh!)
    return refreshed.map(ProviderCredential.oauth)
  }

  private func callbackComponents(_ input: String) throws -> URLComponents {
    guard
      let value = URLComponents(
        string: input.trimmingCharacters(in: ProviderErrorText.javaScriptWhitespace)),
      value.scheme != nil
    else {
      throw failure("Paste the full callback URL from the browser")
    }
    guard value.scheme == "http", value.host == "127.0.0.1", value.port == 1455,
      value.path == "/auth/callback"
    else {
      throw failure("The pasted callback URL must start with " + Self.redirect)
    }
    return value
  }
  private func requestToken(_ fields: [String: String]) async throws -> [String: JSONValue] {
    let response = try await transport.send(
      oauthFormRequest(
        url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!, fields: fields))
    guard (200..<300).contains(response.statusCode) else {
      let text = String(decoding: response.body, as: UTF8.self)
      throw failure(
        "OpenAI OAuth token request failed (\(response.statusCode)): "
          + (text.isEmpty
            ? HTTPURLResponse.localizedString(forStatusCode: response.statusCode) : text))
    }
    guard let value = try JSONDecoder().decode(JSONValue.self, from: response.body).objectValue
    else {
      throw failure("OpenAI OAuth token response must be an object")
    }
    return value
  }
  private func credential(_ body: [String: JSONValue], clientID: String) throws -> OAuthCredential {
    func required(_ name: String) throws -> String {
      guard let value = body.string(name),
        !value.trimmingCharacters(in: ProviderErrorText.javaScriptWhitespace).isEmpty
      else {
        throw failure("OpenAI OAuth token response has invalid " + name)
      }
      return value
    }
    let access = try required("access_token")
    let refresh = try required("refresh_token")
    let scope = try required("scope")
    let expiry: Double
    switch body["expires_in"] {
    case .integer(let value): expiry = Double(value)
    case .number(let value): expiry = value
    default: throw failure("OpenAI OAuth token response has invalid expires_in")
    }
    guard expiry.isFinite, expiry > 0 else {
      throw failure("OpenAI OAuth token response has invalid expires_in")
    }
    let scopes = scope.components(separatedBy: ProviderErrorText.javaScriptWhitespace).filter {
      !$0.isEmpty
    }
    guard scopes.contains("chatgpt.tokens.use.direct") else {
      throw failure("OpenAI OAuth grant did not include chatgpt.tokens.use.direct")
    }
    let encoded = String(decoding: try JSONEncoder().encode(scopes), as: UTF8.self)
    return .init(
      accessToken: access, refreshToken: refresh,
      expiresAt: clock.now().addingTimeInterval(expiry - 180),
      metadata: ["clientID": clientID, "scopes": encoded])
  }
  private func failure(_ message: String) -> ProviderRuntimeFailure {
    oauthFailure(
      .authorizationFailed, providerID: Self.providerID, operation: "openai.chatgpt.oauth",
      message: message)
  }
}
