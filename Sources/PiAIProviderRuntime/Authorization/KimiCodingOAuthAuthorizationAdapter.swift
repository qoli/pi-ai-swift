import Foundation

protocol ProviderOAuthClock: Sendable {
  func now() -> Date
  func sleep(for duration: Duration) async throws
}

struct SystemProviderOAuthClock: ProviderOAuthClock {
  func now() -> Date { Date() }
  func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

struct KimiCodingOAuthAuthorizationAdapter: ProviderAuthorizationAdapter {
  static let providerID = "kimi-coding"
  private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

  private let transport: any ProviderHTTPTransport
  private let oauthBaseURL: URL
  private let clock: any ProviderOAuthClock

  init(
    transport: any ProviderHTTPTransport,
    oauthBaseURL: URL = URL(string: "https://auth.kimi.com")!,
    clock: any ProviderOAuthClock = SystemProviderOAuthClock()
  ) {
    self.transport = transport
    self.oauthBaseURL = oauthBaseURL
    self.clock = clock
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    switch operation {
    case .logout(let providerID):
      try requireProvider(providerID)
      try await credentialStore.delete(providerID: providerID)
      return .disconnected(providerID: providerID)
    case .login(let providerID, let methodID):
      try requireProvider(providerID)
      guard methodID == "oauth" else {
        throw failure(.authorizationFailed, "unsupported Kimi authorization method")
      }
      let device = try await startDeviceAuthorization()
      let response = try await interaction(
        .deviceCode(
          providerID: providerID,
          userCode: device.userCode,
          verificationURL: device.verificationURL,
          expiresAt: device.expiresAt,
          pollingInterval: device.pollingInterval
        )
      )
      guard response == .acknowledged else {
        throw failure(.authorizationFailed, "Kimi device authorization was not acknowledged")
      }
      let credential = try await pollForCredential(device)
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
    credentialStore: any ProviderCredentialStore
  ) async throws -> ProviderCredential? {
    try requireProvider(providerID)
    guard
      let stored = try await credentialStore.read(providerID: Self.providerID)
    else { return nil }
    guard case .oauth(let credential) = stored else { return stored }
    guard credential.expiresAt.timeIntervalSince(clock.now()) <= 60 else {
      return stored
    }
    let refreshed = try await refresh(credential)
    return try await credentialStore.modify(providerID: Self.providerID) { current in
      guard current == stored else { return current }
      return .oauth(refreshed)
    }
  }

  private func startDeviceAuthorization() async throws -> DeviceAuthorization {
    let response = try await sendForm(
      path: "api/oauth/device_authorization",
      fields: ["client_id": Self.clientID],
      operation: "kimi.oauth.device.start"
    )
    guard (200..<300).contains(response.statusCode) else {
      throw httpFailure(response, operation: "kimi.oauth.device.start")
    }
    let body = try decode(response.body, operation: "kimi.oauth.device.start")
    guard let deviceCode = body.string("device_code"), !deviceCode.isEmpty,
      let userCode = body.string("user_code"), !userCode.isEmpty,
      let verification = body.string("verification_uri_complete"),
      let verificationURL = URL(string: verification),
      verificationURL.scheme == "https",
      let interval = body.int("interval"), interval > 0,
      let expiresIn = body.int("expires_in"), expiresIn > 0
    else {
      throw failure(.invalidResponse, "Kimi device authorization response is malformed")
    }
    return DeviceAuthorization(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationURL: verificationURL,
      pollingInterval: .seconds(interval),
      expiresAt: clock.now().addingTimeInterval(TimeInterval(expiresIn))
    )
  }

  private func pollForCredential(
    _ device: DeviceAuthorization
  ) async throws -> OAuthCredential {
    var interval = device.pollingInterval
    while clock.now() < device.expiresAt {
      try await clock.sleep(for: interval)
      try Task.checkCancellation()
      let response = try await sendForm(
        path: "api/oauth/token",
        fields: [
          "client_id": Self.clientID,
          "device_code": device.deviceCode,
          "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ],
        operation: "kimi.oauth.device.poll"
      )
      let body = try decode(response.body, operation: "kimi.oauth.device.poll")
      if (200..<300).contains(response.statusCode) {
        return try makeCredential(from: body, operation: "device.poll")
      }
      switch body.string("error") {
      case "authorization_pending": continue
      case "slow_down":
        guard let explicit = body.int("interval"), explicit > 0 else {
          throw failure(.invalidResponse, "Kimi slow_down response is missing interval")
        }
        interval = .seconds(explicit)
      case "access_denied":
        throw failure(.authorizationFailed, "Kimi device authorization was denied")
      case "expired_token":
        throw failure(.authorizationFailed, "Kimi device authorization expired")
      default:
        throw httpFailure(response, operation: "kimi.oauth.device.poll")
      }
    }
    throw failure(.authorizationFailed, "Kimi device authorization timed out")
  }

  private func refresh(_ credential: OAuthCredential) async throws -> OAuthCredential {
    let response = try await sendForm(
      path: "api/oauth/token",
      fields: [
        "client_id": Self.clientID,
        "grant_type": "refresh_token",
        "refresh_token": credential.refreshToken,
      ],
      operation: "kimi.oauth.refresh"
    )
    guard (200..<300).contains(response.statusCode) else {
      throw httpFailure(response, operation: "kimi.oauth.refresh")
    }
    return try makeCredential(
      from: decode(response.body, operation: "kimi.oauth.refresh"),
      operation: "refresh"
    )
  }

  private func makeCredential(
    from body: [String: JSONValue],
    operation: String
  ) throws -> OAuthCredential {
    guard let access = body.string("access_token"), !access.isEmpty,
      let refresh = body.string("refresh_token"), !refresh.isEmpty,
      let expiresIn = body.int("expires_in"), expiresIn > 0
    else {
      throw failure(.invalidResponse, "Kimi token \(operation) response is malformed")
    }
    return OAuthCredential(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: clock.now().addingTimeInterval(TimeInterval(expiresIn)),
      metadata: [:]
    )
  }

  private func sendForm(
    path: String,
    fields: [String: String],
    operation: String
  ) async throws -> ProviderHTTPResponse {
    var request = URLRequest(url: oauthBaseURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    var components = URLComponents()
    components.queryItems = fields.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    guard let form = components.percentEncodedQuery else {
      throw failure(.invalidRequest, "Kimi OAuth form could not be encoded")
    }
    request.httpBody = Data(form.utf8)
    do {
      return try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ProviderRuntimeFailure {
      throw error
    } catch {
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: "Kimi OAuth transport failed",
        providerID: Self.providerID,
        operation: operation,
        causeDescription: String(describing: error)
      )
    }
  }

  private func decode(
    _ data: Data,
    operation: String
  ) throws -> [String: JSONValue] {
    try decodeJSONObject(
      data,
      providerID: Self.providerID,
      operation: operation
    )
  }

  private func httpFailure(
    _ response: ProviderHTTPResponse,
    operation: String
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .authorizationFailed,
      message: "Kimi OAuth request failed (HTTP \(response.statusCode))",
      providerID: Self.providerID,
      operation: operation,
      causeDescription: String(data: response.body.prefix(1_024), encoding: .utf8)
    )
  }

  private func requireProvider(_ providerID: String) throws {
    guard providerID == Self.providerID else {
      throw failure(.authorizationFailed, "authorization provider mismatch")
    }
  }

  private func failure(
    _ code: ProviderRuntimeFailure.Code,
    _ message: String
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: code,
      message: message,
      providerID: Self.providerID,
      operation: "kimi.oauth",
      causeDescription: nil
    )
  }

  private struct DeviceAuthorization {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let pollingInterval: Duration
    let expiresAt: Date
  }
}
