import Foundation

public struct OpenAICodexDeviceAuthorization: Sendable, Equatable {
  public let userCode: String
  public let verificationURL: URL
  public let pollingInterval: Duration
  public let expiresAt: Date

  let deviceAuthorizationID: String

  init(
    deviceAuthorizationID: String,
    userCode: String,
    verificationURL: URL,
    pollingInterval: Duration,
    expiresAt: Date
  ) {
    self.deviceAuthorizationID = deviceAuthorizationID
    self.userCode = userCode
    self.verificationURL = verificationURL
    self.pollingInterval = pollingInterval
    self.expiresAt = expiresAt
  }
}

public struct OpenAICodexOAuthClient: Sendable {
  public static let providerID = "openai-codex"

  private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  private static let deviceAuthorizationLifetime: TimeInterval = 15 * 60
  private static let slowDownIncrementSeconds = 5

  private let transport: any ProviderHTTPTransport
  private let authBaseURL: URL

  public init(
    transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
  ) {
    self.transport = transport
    self.authBaseURL = URL(string: "https://auth.openai.com")!
  }

  init(transport: any ProviderHTTPTransport, authBaseURL: URL) {
    self.transport = transport
    self.authBaseURL = authBaseURL
  }

  public func login(
    interaction: @escaping AuthorizationInteraction
  ) async throws -> OAuthCredential {
    let authorization = try await startDeviceAuthorization()
    let response = try await interaction(
      .deviceCode(
        providerID: Self.providerID,
        userCode: authorization.userCode,
        verificationURL: authorization.verificationURL,
        expiresAt: authorization.expiresAt,
        pollingInterval: authorization.pollingInterval
      )
    )
    guard response == .acknowledged else {
      throw failure(
        .authorizationFailed,
        operation: "oauth.device.interaction",
        message: "OpenAI Codex device authorization was not acknowledged"
      )
    }
    return try await waitForCredential(authorization)
  }

  public func startDeviceAuthorization() async throws
    -> OpenAICodexDeviceAuthorization
  {
    let endpoint = authBaseURL.appending(
      path: "api/accounts/deviceauth/usercode"
    )
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      DeviceAuthorizationRequest(clientID: Self.clientID)
    )

    let response = try await send(request, operation: "oauth.device.start")
    if response.statusCode == 404 {
      throw failure(
        .unsupportedCapability,
        operation: "oauth.device.start",
        message: "OpenAI Codex device-code login is not enabled for this account or workspace"
      )
    }
    guard (200..<300).contains(response.statusCode) else {
      throw httpFailure(
        response,
        operation: "oauth.device.start",
        message: "OpenAI Codex device-code request failed"
      )
    }

    let payload: DeviceAuthorizationResponse = try decode(
      response.body,
      operation: "oauth.device.start"
    )
    guard !payload.deviceAuthorizationID.isEmpty, !payload.userCode.isEmpty else {
      throw failure(
        .invalidResponse,
        operation: "oauth.device.start",
        message: "OpenAI Codex device-code response contains empty required fields"
      )
    }
    guard payload.interval.isFinite, payload.interval >= 0 else {
      throw failure(
        .invalidResponse,
        operation: "oauth.device.start",
        message: "OpenAI Codex device-code response contains an invalid polling interval"
      )
    }

    return OpenAICodexDeviceAuthorization(
      deviceAuthorizationID: payload.deviceAuthorizationID,
      userCode: payload.userCode,
      verificationURL: authBaseURL.appending(path: "codex/device"),
      pollingInterval: .seconds(max(1, payload.interval)),
      expiresAt: Date().addingTimeInterval(Self.deviceAuthorizationLifetime)
    )
  }

  public func waitForCredential(
    _ authorization: OpenAICodexDeviceAuthorization
  ) async throws -> OAuthCredential {
    var interval = authorization.pollingInterval

    while Date() < authorization.expiresAt {
      try Task.checkCancellation()
      switch try await pollDeviceAuthorization(authorization) {
      case .pending:
        break
      case .slowDown:
        interval += .seconds(Self.slowDownIncrementSeconds)
      case .authorized(let code, let verifier):
        return try await exchangeAuthorizationCode(
          code: code,
          verifier: verifier
        )
      }

      let remaining = authorization.expiresAt.timeIntervalSinceNow
      guard remaining > 0 else { break }
      let sleepSeconds = min(interval.timeInterval, remaining)
      try await Task.sleep(for: .seconds(sleepSeconds))
    }

    throw failure(
      .authorizationFailed,
      operation: "oauth.device.poll",
      message: "OpenAI Codex device authorization timed out"
    )
  }

  public func refresh(
    _ credential: OAuthCredential
  ) async throws -> OAuthCredential {
    let endpoint = authBaseURL.appending(path: "oauth/token")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    var components = URLComponents()
    components.queryItems = [
      URLQueryItem(name: "grant_type", value: "refresh_token"),
      URLQueryItem(name: "refresh_token", value: credential.refreshToken),
      URLQueryItem(name: "client_id", value: Self.clientID),
    ]
    guard let form = components.percentEncodedQuery else {
      throw failure(
        .invalidRequest,
        operation: "oauth.token.refresh",
        message: "OpenAI Codex token refresh form could not be encoded"
      )
    }
    request.httpBody = Data(form.utf8)
    let response = try await send(request, operation: "oauth.token.refresh")
    guard (200..<300).contains(response.statusCode) else {
      throw httpFailure(
        response,
        operation: "oauth.token.refresh",
        message: "OpenAI Codex token refresh failed"
      )
    }
    let token: TokenResponse = try decode(
      response.body,
      operation: "oauth.token.refresh"
    )
    guard !token.accessToken.isEmpty, !token.refreshToken.isEmpty,
      token.expiresIn > 0
    else {
      throw failure(
        .invalidResponse,
        operation: "oauth.token.refresh",
        message: "OpenAI Codex refresh response contains invalid required fields"
      )
    }
    let accountID = try extractAccountID(from: token.accessToken)
    return OAuthCredential(
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
      metadata: ["accountID": accountID]
    )
  }

  func pollDeviceAuthorization(
    _ authorization: OpenAICodexDeviceAuthorization
  ) async throws -> DevicePollResult {
    let endpoint = authBaseURL.appending(path: "api/accounts/deviceauth/token")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      DeviceTokenRequest(
        deviceAuthorizationID: authorization.deviceAuthorizationID,
        userCode: authorization.userCode
      )
    )

    let response = try await send(request, operation: "oauth.device.poll")
    if response.statusCode == 403 || response.statusCode == 404 {
      return .pending
    }
    if (200..<300).contains(response.statusCode) {
      let payload: DeviceTokenResponse = try decode(
        response.body,
        operation: "oauth.device.poll"
      )
      guard !payload.authorizationCode.isEmpty, !payload.codeVerifier.isEmpty
      else {
        throw failure(
          .invalidResponse,
          operation: "oauth.device.poll",
          message: "OpenAI Codex device token response contains empty required fields"
        )
      }
      return .authorized(
        code: payload.authorizationCode,
        verifier: payload.codeVerifier
      )
    }

    let error = try? JSONDecoder().decode(
      OAuthErrorEnvelope.self,
      from: response.body
    )
    switch error?.code {
    case "deviceauth_authorization_pending":
      return .pending
    case "slow_down":
      return .slowDown
    default:
      throw httpFailure(
        response,
        operation: "oauth.device.poll",
        message: "OpenAI Codex device authorization polling failed"
      )
    }
  }

  func exchangeAuthorizationCode(
    code: String,
    verifier: String
  ) async throws -> OAuthCredential {
    let endpoint = authBaseURL.appending(path: "oauth/token")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded",
      forHTTPHeaderField: "Content-Type"
    )
    var components = URLComponents()
    components.queryItems = [
      URLQueryItem(name: "grant_type", value: "authorization_code"),
      URLQueryItem(name: "client_id", value: Self.clientID),
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "code_verifier", value: verifier),
      URLQueryItem(
        name: "redirect_uri",
        value: authBaseURL.appending(path: "deviceauth/callback").absoluteString
      ),
    ]
    guard let form = components.percentEncodedQuery else {
      throw failure(
        .invalidRequest,
        operation: "oauth.token.exchange",
        message: "OpenAI Codex token exchange form could not be encoded"
      )
    }
    request.httpBody = Data(form.utf8)

    let response = try await send(request, operation: "oauth.token.exchange")
    guard (200..<300).contains(response.statusCode) else {
      throw httpFailure(
        response,
        operation: "oauth.token.exchange",
        message: "OpenAI Codex token exchange failed"
      )
    }
    let token: TokenResponse = try decode(
      response.body,
      operation: "oauth.token.exchange"
    )
    guard !token.accessToken.isEmpty, !token.refreshToken.isEmpty,
      token.expiresIn > 0
    else {
      throw failure(
        .invalidResponse,
        operation: "oauth.token.exchange",
        message: "OpenAI Codex token response contains invalid required fields"
      )
    }
    let accountID = try extractAccountID(from: token.accessToken)
    return OAuthCredential(
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)),
      metadata: ["accountID": accountID]
    )
  }

  private func send(
    _ request: URLRequest,
    operation: String
  ) async throws -> ProviderHTTPResponse {
    do {
      return try await transport.send(request)
    } catch let error as ProviderRuntimeFailure {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw failure(
        .transportFailed,
        operation: operation,
        message: "OpenAI Codex authorization transport failed",
        cause: error
      )
    }
  }

  private func decode<T: Decodable>(
    _ data: Data,
    operation: String
  ) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw failure(
        .invalidResponse,
        operation: operation,
        message: "OpenAI Codex authorization response is malformed",
        cause: error
      )
    }
  }

  private func extractAccountID(from accessToken: String) throws -> String {
    let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else {
      throw failure(
        .invalidCredential,
        operation: "oauth.token.validate",
        message: "OpenAI Codex access token is not a JWT"
      )
    }
    var encoded = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - encoded.count % 4) % 4
    encoded.append(String(repeating: "=", count: padding))
    guard let data = Data(base64Encoded: encoded),
      let object = try? JSONSerialization.jsonObject(with: data),
      let payload = object as? [String: Any],
      let auth = payload["https://api.openai.com/auth"]
        as? [String: Any],
      let accountID = auth["chatgpt_account_id"] as? String,
      !accountID.isEmpty
    else {
      throw failure(
        .invalidCredential,
        operation: "oauth.token.validate",
        message: "OpenAI Codex access token is missing chatgpt_account_id"
      )
    }
    return accountID
  }

  private func httpFailure(
    _ response: ProviderHTTPResponse,
    operation: String,
    message: String
  ) -> ProviderRuntimeFailure {
    let body = String(data: response.body, encoding: .utf8)
    let description = body.flatMap { $0.isEmpty ? nil : String($0.prefix(1_024)) }
    return failure(
      .authorizationFailed,
      operation: operation,
      message: "\(message) (HTTP \(response.statusCode))",
      causeDescription: description
    )
  }

  private func failure(
    _ code: ProviderRuntimeFailure.Code,
    operation: String,
    message: String,
    cause: (any Error)? = nil,
    causeDescription: String? = nil
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: code,
      message: message,
      providerID: Self.providerID,
      operation: operation,
      causeDescription: causeDescription ?? cause.map(String.init(describing:))
    )
  }
}

enum DevicePollResult: Equatable {
  case pending
  case slowDown
  case authorized(code: String, verifier: String)
}

private struct DeviceAuthorizationRequest: Encodable {
  let clientID: String

  enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
  }
}

private struct DeviceAuthorizationResponse: Decodable {
  let deviceAuthorizationID: String
  let userCode: String
  let interval: TimeInterval

  enum CodingKeys: String, CodingKey {
    case deviceAuthorizationID = "device_auth_id"
    case userCode = "user_code"
    case interval
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceAuthorizationID = try container.decode(
      String.self,
      forKey: .deviceAuthorizationID
    )
    userCode = try container.decode(String.self, forKey: .userCode)
    if let value = try? container.decode(TimeInterval.self, forKey: .interval) {
      interval = value
    } else {
      let value = try container.decode(String.self, forKey: .interval)
      guard let parsed = TimeInterval(value) else {
        throw DecodingError.dataCorruptedError(
          forKey: .interval,
          in: container,
          debugDescription: "interval must be a finite number or numeric string"
        )
      }
      interval = parsed
    }
  }
}

private struct DeviceTokenRequest: Encodable {
  let deviceAuthorizationID: String
  let userCode: String

  enum CodingKeys: String, CodingKey {
    case deviceAuthorizationID = "device_auth_id"
    case userCode = "user_code"
  }
}

private struct DeviceTokenResponse: Decodable {
  let authorizationCode: String
  let codeVerifier: String

  enum CodingKeys: String, CodingKey {
    case authorizationCode = "authorization_code"
    case codeVerifier = "code_verifier"
  }
}

private struct TokenResponse: Decodable {
  let accessToken: String
  let refreshToken: String
  let expiresIn: Int

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
  }
}

private struct OAuthErrorEnvelope: Decodable {
  let error: OAuthErrorValue?

  var code: String? {
    switch error {
    case .string(let code): code
    case .object(let object): object.code
    case nil: nil
    }
  }
}

private enum OAuthErrorValue: Decodable {
  case string(String)
  case object(OAuthErrorObject)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      self = .object(try container.decode(OAuthErrorObject.self))
    }
  }
}

private struct OAuthErrorObject: Decodable {
  let code: String?
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let components = self.components
    return TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1e18
  }
}
