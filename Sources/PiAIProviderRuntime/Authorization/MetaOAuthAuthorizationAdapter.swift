import Foundation

struct MetaOAuthAuthorizationAdapter: ProviderAuthorizationAdapter {
  static let providerID = "meta"
  private let transport: any ProviderHTTPTransport
  private let clock: any ProviderOAuthClock

  init(
    transport: any ProviderHTTPTransport, clock: any ProviderOAuthClock = SystemProviderOAuthClock()
  ) {
    self.transport = transport
    self.clock = clock
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
      let deviceResponse = try await form(
        "https://auth.meta.com/oidc/device/authorization/",
        fields: ["client_id": "1031625952748946"])
      let device = object(deviceResponse)
      guard (200..<300).contains(deviceResponse.statusCode) else {
        throw failure(
          "Meta device authorization failed with status \(deviceResponse.statusCode)"
            + detail(device))
      }
      guard let code = device.string("device_code"), !code.isEmpty,
        let userCode = device.string("user_code"), !userCode.isEmpty,
        let verification = trustedURL(device.string("verification_uri_complete"))
          ?? trustedURL(device.string("verification_uri"))
      else {
        throw failure(
          "Invalid Meta device authorization response: "
            + String(decoding: deviceResponse.body, as: UTF8.self))
      }
      let interval = positive(device["interval"])
      let lifetime = positive(device["expires_in"])
      _ = try await interaction(
        .deviceCode(
          providerID: providerID, userCode: userCode,
          verificationURL: verification,
          expiresAt: lifetime.map { clock.now().addingTimeInterval($0) },
          pollingInterval: interval.map { .seconds($0) }))
      let token = try await ProviderDeviceCodePolling.poll(
        intervalSeconds: interval,
        expiresInSeconds: lifetime, waitBeforeFirstPoll: true, clock: clock
      ) {
        let response = try await form(
          "https://auth.meta.com/oidc/device/token/",
          fields: [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": code,
            "client_id": "1031625952748946",
          ])
        let body = object(response)
        if (200..<300).contains(response.statusCode), let access = body.string("access_token"),
          !access.isEmpty
        {
          return .complete(access)
        }
        switch body.string("error") {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(intervalSeconds: positive(body["interval"]))
        case "access_denied": return .failed("Meta login was denied.")
        case "expired_token":
          return .failed("Meta device authorization expired. Please restart login.")
        default:
          return .failed(
            "Meta device token request failed with status \(response.statusCode)" + detail(body))
        }
      }
      _ = try await interaction(
        .progress(providerID: providerID, message: "Enabling Meta Model API access..."))
      let credential = try await mint(token)
      _ = try await credentialStore.modify(providerID: providerID) { _ in .oauth(credential) }
      return .connected(
        .init(
          providerID: providerID, accountID: nil, authorizationKind: .oauth,
          expiresAt: credential.expiresAt))
    }
  }

  func resolveCredential(
    providerID: String, credentialStore: any ProviderCredentialStore,
    refreshCoordinator: CredentialRefreshCoordinator
  ) async throws -> ProviderCredential? {
    guard let stored = try await credentialStore.read(providerID: providerID) else { return nil }
    guard case .oauth = stored else { return stored }
    let refreshed = try await refreshCoordinator.credential(
      providerID: providerID,
      now: { clock.now() }, refresh: { try await mint($0.refreshToken) })
    return refreshed.map(ProviderCredential.oauth)
  }

  private func mint(_ identity: String) async throws -> OAuthCredential {
    var request = try oauthJSONRequest(
      url: URL(string: "https://api.meta.ai/muse-code/key")!, body: [:])
    request.timeoutInterval = 30
    request.setValue("Bearer " + identity, forHTTPHeaderField: "Authorization")
    request.setValue("1.0.0", forHTTPHeaderField: "x-api-version")
    let response = try await transport.send(request)
    let body = object(response)
    if [401, 403].contains(response.statusCode) {
      throw failure(
        "Meta session expired (status \(response.statusCode)). Run `/login meta` to sign in again."
          + detail(body))
    }
    guard (200..<300).contains(response.statusCode) else {
      throw failure("Meta API key mint failed with status \(response.statusCode)" + detail(body))
    }
    guard let key = body.string("api_key"), !key.isEmpty else {
      throw failure(
        "Meta did not issue an API key."
          + (trustedURL(body.string("action_url")).map { " Complete setup at " + $0.absoluteString }
            ?? ""))
    }
    return .init(
      accessToken: key, refreshToken: identity, expiresAt: clock.now().addingTimeInterval(86_400),
      metadata: [:])
  }

  private func form(_ url: String, fields: [String: String]) async throws -> ProviderHTTPResponse {
    var request = try oauthFormRequest(url: URL(string: url)!, fields: fields)
    request.timeoutInterval = 30
    return try await transport.send(request)
  }
  private func object(_ response: ProviderHTTPResponse) -> [String: JSONValue] {
    (try? JSONDecoder().decode(JSONValue.self, from: response.body).objectValue) ?? [:]
  }
  private func trustedURL(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
    else { return nil }
    return url
  }
  private func positive(_ value: JSONValue?) -> Double? {
    let number: Double?
    switch value {
    case .integer(let value): number = Double(value)
    case .number(let value): number = value
    default: number = nil
    }
    return number.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
  }
  private func detail(_ body: [String: JSONValue]) -> String {
    for key in ["error_description", "detail", "message", "error"] {
      if let value = body.string(key)?.trimmingCharacters(
        in: ProviderErrorText.javaScriptWhitespace), !value.isEmpty
      {
        return ": " + value
      }
    }
    return ""
  }
  private func failure(_ message: String) -> ProviderRuntimeFailure {
    oauthFailure(
      .authorizationFailed, providerID: Self.providerID, operation: "meta.oauth", message: message)
  }
}
