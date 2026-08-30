import Foundation

struct XAIOAuthAuthorizationAdapter: ProviderAuthorizationAdapter {
  static let providerID = "xai"
  private static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
  private static let scope =
    "openid profile email offline_access grok-cli:access api:access"
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
      let device = try await requestDeviceCode()
      let response = try await interaction(
        .deviceCode(
          providerID: providerID,
          userCode: device.userCode,
          verificationURL: device.verificationURL,
          expiresAt: device.expiresAt,
          pollingInterval: .seconds(device.interval)
        )
      )
      guard response == .acknowledged else {
        throw failure("xAI device authorization was not acknowledged")
      }
      let credential = try await poll(device)
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
        let response = try await sendToken([
          "grant_type": "refresh_token",
          "client_id": Self.clientID,
          "refresh_token": credential.refreshToken,
        ])
        return try oauthCredential(
          response,
          providerID: Self.providerID,
          operation: "xai.oauth.refresh",
          now: clock.now(),
          expirySkew: 300,
          defaultLifetime: 3_600,
          previousRefreshToken: credential.refreshToken
        )
      }
    )
    return .oauth(refreshed)
  }

  private func requestDeviceCode() async throws -> Device {
    let request = try oauthFormRequest(
      url: URL(string: "https://auth.x.ai/oauth2/device/code")!,
      fields: [
        "client_id": Self.clientID,
        "scope": Self.scope,
        "referrer": "pi",
      ]
    )
    let body = try oauthResponseObject(
      try await transport.send(request),
      providerID: Self.providerID,
      operation: "xai.oauth.device.start"
    )
    guard let deviceCode = body.string("device_code"), !deviceCode.isEmpty,
      let userCode = body.string("user_code"), !userCode.isEmpty,
      let verification = body.string("verification_uri"),
      let verificationURL = URL(string: verification),
      verificationURL.scheme == "https",
      let expiresIn = body.int("expires_in"), expiresIn > 0
    else {
      throw oauthFailure(
        .invalidResponse,
        providerID: Self.providerID,
        operation: "xai.oauth.device.start",
        message: "xAI device authorization response is malformed"
      )
    }
    let completeURL: URL?
    if let value = body.string("verification_uri_complete") {
      guard let url = URL(string: value), url.scheme == "https" else {
        throw failure("xAI verification_uri_complete is untrusted")
      }
      completeURL = url
    } else {
      completeURL = nil
    }
    let interval = body.int("interval") ?? 5
    guard interval > 0 else { throw failure("xAI polling interval is invalid") }
    return Device(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationURL: completeURL ?? verificationURL,
      expiresAt: clock.now().addingTimeInterval(TimeInterval(expiresIn)),
      interval: interval
    )
  }

  private func poll(_ device: Device) async throws -> OAuthCredential {
    var interval = device.interval
    while clock.now() < device.expiresAt {
      try await clock.sleep(for: .seconds(interval))
      let response = try await sendTokenResponse([
        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        "client_id": Self.clientID,
        "device_code": device.deviceCode,
      ])
      if (200..<300).contains(response.statusCode) {
        return try oauthCredential(
          try decodeJSONObject(
            response.body,
            providerID: Self.providerID,
            operation: "xai.oauth.device.poll"
          ),
          providerID: Self.providerID,
          operation: "xai.oauth.device.poll",
          now: clock.now(),
          expirySkew: 300,
          defaultLifetime: 3_600
        )
      }
      let body = try decodeJSONObject(
        response.body,
        providerID: Self.providerID,
        operation: "xai.oauth.device.poll"
      )
      switch body.string("error") {
      case "authorization_pending": continue
      case "slow_down":
        if let reported = body.int("interval") {
          guard reported > 0 else { throw failure("xAI slow_down interval is invalid") }
          interval = reported
        } else {
          interval += 5
        }
      case "access_denied", "authorization_denied":
        throw failure("xAI device authorization was denied")
      case "expired_token":
        throw failure("xAI device authorization expired")
      default:
        throw failure("xAI device token polling failed (HTTP \(response.statusCode))")
      }
    }
    throw failure("xAI device authorization timed out")
  }

  private func sendToken(_ fields: [String: String]) async throws -> [String: JSONValue] {
    try oauthResponseObject(
      try await sendTokenResponse(fields),
      providerID: Self.providerID,
      operation: "xai.oauth.token"
    )
  }

  private func sendTokenResponse(
    _ fields: [String: String]
  ) async throws -> ProviderHTTPResponse {
    try await transport.send(
      oauthFormRequest(
        url: URL(string: "https://auth.x.ai/oauth2/token")!,
        fields: fields
      )
    )
  }

  private func require(_ providerID: String) throws {
    guard providerID == Self.providerID else { throw failure("provider mismatch") }
  }

  private func failure(_ message: String) -> ProviderRuntimeFailure {
    oauthFailure(
      .authorizationFailed,
      providerID: Self.providerID,
      operation: "xai.oauth",
      message: message
    )
  }

  private struct Device: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: Int
  }
}
