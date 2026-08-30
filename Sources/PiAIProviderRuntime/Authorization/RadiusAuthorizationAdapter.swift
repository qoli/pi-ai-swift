import Foundation

struct RadiusOAuthAuthorizationAdapter: ProviderAuthorizationAdapter {
  static let providerID = "radius"
  static let defaultGateway = "https://radius.pi.dev"
  private static let clientID = "pi-gateway"
  private static let scope = "gateway offline_access"
  private static let redirectURI = "http://127.0.0.1:1456/oauth/callback"

  private let transport: any ProviderHTTPTransport
  private let clock: any ProviderOAuthClock

  init(
    transport: any ProviderHTTPTransport,
    clock: any ProviderOAuthClock = SystemProviderOAuthClock()
  ) {
    self.transport = transport
    self.clock = clock
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
      let gateway = try await requestGateway(interaction)
      let method = try await requestLoginMethod(interaction)
      let credential: OAuthCredential
      switch method {
      case "device-code":
        credential = try await loginWithDeviceCode(
          gateway: gateway,
          interaction: interaction
        )
      case "browser":
        credential = try await loginWithBrowser(
          gateway: gateway,
          interaction: interaction
        )
      default:
        throw failure("unknown Radius login method: \(method)")
      }
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
      now: clock.now(),
      refresh: { credential in
        guard let rawGateway = credential.metadata["gateway"],
          let gateway = URL(string: rawGateway),
          let scheme = gateway.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          gateway.host != nil
        else {
          throw oauthFailure(
            .invalidCredential,
            providerID: Self.providerID,
            operation: "radius.oauth.refresh",
            message: "Radius OAuth credential is missing gateway metadata"
          )
        }
        return try await token(
          gateway: gateway,
          fields: [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": credential.refreshToken,
          ],
          operation: "radius.oauth.refresh"
        )
      }
    )
    return .oauth(refreshed)
  }

  private func requestGateway(
    _ interaction: @escaping AuthorizationInteraction
  ) async throws -> URL {
    let response = try await interaction(
      .prompt(
        providerID: Self.providerID,
        id: "radius-gateway",
        message: "Radius gateway URL (leave empty for radius.pi.dev)",
        kind: .text
      )
    )
    guard case .value(let input) = response else {
      throw failure("Radius gateway prompt did not return a value")
    }
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = trimmed.isEmpty ? Self.defaultGateway : trimmed
    let normalized = raw.contains("://") ? raw : "https://\(raw)"
    guard let url = URL(string: normalized),
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      url.host != nil,
      let result = URL(
        string: url.absoluteString.trimmingCharacters(
          in: CharacterSet(charactersIn: "/")
        ))
    else {
      throw failure("Radius gateway URL is invalid")
    }
    return result
  }

  private func requestLoginMethod(
    _ interaction: @escaping AuthorizationInteraction
  ) async throws -> String {
    let response = try await interaction(
      .prompt(
        providerID: Self.providerID,
        id: "radius-login-method",
        message: "Radius login method: browser or device-code",
        kind: .text
      )
    )
    guard case .value(let method) = response else {
      throw failure("Radius login method prompt did not return a value")
    }
    return method.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func loginWithDeviceCode(
    gateway: URL,
    interaction: @escaping AuthorizationInteraction
  ) async throws -> OAuthCredential {
    let response = try await transport.send(
      oauthFormRequest(
        url: gateway.appending(path: "v1/oauth/device"),
        fields: ["client_id": Self.clientID, "scope": Self.scope]
      )
    )
    let body = try oauthResponseObject(
      response,
      providerID: Self.providerID,
      operation: "radius.oauth.device.start"
    )
    guard let deviceCode = body.string("device_code"), !deviceCode.isEmpty,
      let userCode = body.string("user_code"), !userCode.isEmpty,
      let verification = body.string("verification_uri"),
      let verificationURL = URL(string: verification),
      let verificationScheme = verificationURL.scheme?.lowercased(),
      ["http", "https"].contains(verificationScheme),
      let expiresIn = body.int("expires_in"), expiresIn > 0
    else { throw failure("Radius device authorization response is malformed") }
    var interval = body.int("interval") ?? 5
    guard interval > 0 else { throw failure("Radius device polling interval is invalid") }
    let expiresAt = clock.now().addingTimeInterval(TimeInterval(expiresIn))
    let acknowledgement = try await interaction(
      .deviceCode(
        providerID: Self.providerID,
        userCode: userCode,
        verificationURL: verificationURL,
        expiresAt: expiresAt,
        pollingInterval: .seconds(interval)
      )
    )
    guard acknowledgement == .acknowledged else {
      throw failure("Radius device authorization was not acknowledged")
    }
    while clock.now() < expiresAt {
      try await clock.sleep(for: .seconds(interval))
      let tokenResponse = try await transport.send(
        oauthFormRequest(
          url: gateway.appending(path: "v1/oauth/token"),
          fields: [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": Self.clientID,
            "device_code": deviceCode,
          ]
        )
      )
      if (200..<300).contains(tokenResponse.statusCode) {
        return try tokenCredential(
          tokenResponse,
          gateway: gateway,
          operation: "radius.oauth.device.poll"
        )
      }
      let error = try decodeJSONObject(
        tokenResponse.body,
        providerID: Self.providerID,
        operation: "radius.oauth.device.poll"
      ).string("error")
      switch error {
      case "authorization_pending": continue
      case "slow_down": interval += 5
      case "expired_token": throw failure("Radius device authorization expired")
      case "access_denied": throw failure("Radius device authorization was denied")
      default:
        throw failure("Radius device token polling failed (HTTP \(tokenResponse.statusCode))")
      }
    }
    throw failure("Radius device authorization timed out")
  }

  private func loginWithBrowser(
    gateway: URL,
    interaction: @escaping AuthorizationInteraction
  ) async throws -> OAuthCredential {
    var discoveryRequest = URLRequest(url: gateway.appending(path: "v1/oauth"))
    discoveryRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    let discovery = try oauthResponseObject(
      try await transport.send(discoveryRequest),
      providerID: Self.providerID,
      operation: "radius.oauth.discovery"
    )
    guard let endpoint = discovery.string("authorizationEndpoint"),
      var components = URLComponents(string: endpoint),
      let authorizationScheme = components.scheme?.lowercased(),
      ["http", "https"].contains(authorizationScheme)
    else { throw failure("Radius OAuth discovery is malformed") }
    let pkce = try OAuthPKCE.make()
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: Self.clientID),
      URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
      URLQueryItem(name: "scope", value: Self.scope),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "handoff", value: "url"),
      URLQueryItem(name: "state", value: pkce.state),
    ]
    guard let authorizationURL = components.url else {
      throw failure("Radius authorization URL is invalid")
    }
    let callback = try await interaction(
      .openURL(
        providerID: Self.providerID,
        url: authorizationURL,
        callbackScheme: nil
      )
    )
    let code = try oauthAuthorizationCode(
      callback,
      expectedState: pkce.state,
      providerID: Self.providerID
    )
    return try await token(
      gateway: gateway,
      fields: [
        "grant_type": "authorization_code",
        "client_id": Self.clientID,
        "redirect_uri": Self.redirectURI,
        "code": code,
        "code_verifier": pkce.verifier,
      ],
      operation: "radius.oauth.exchange"
    )
  }

  private func token(
    gateway: URL,
    fields: [String: String],
    operation: String
  ) async throws -> OAuthCredential {
    let request = try oauthFormRequest(
      url: gateway.appending(path: "v1/oauth/token"),
      fields: fields
    )
    let response = try await transport.send(request)
    return try tokenCredential(
      response,
      gateway: gateway,
      operation: operation
    )
  }

  private func tokenCredential(
    _ response: ProviderHTTPResponse,
    gateway: URL,
    operation: String
  ) throws -> OAuthCredential {
    try oauthCredential(
      oauthResponseObject(
        response,
        providerID: Self.providerID,
        operation: operation
      ),
      providerID: Self.providerID,
      operation: operation,
      now: clock.now(),
      expirySkew: 60,
      metadata: ["gateway": gateway.absoluteString]
    )
  }

  private func require(_ providerID: String) throws {
    guard providerID == Self.providerID else { throw failure("provider mismatch") }
  }

  private func failure(_ message: String) -> ProviderRuntimeFailure {
    oauthFailure(
      .authorizationFailed,
      providerID: Self.providerID,
      operation: "radius.oauth",
      message: message
    )
  }
}
