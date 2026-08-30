import Foundation

struct GitHubCopilotOAuthAuthorizationAdapter: ProviderAuthorizationAdapter {
  static let providerID = "github-copilot"
  private static let clientID = "Iv1.b507a08c87ecfe98"
  private static let headers = [
    "User-Agent": "GitHubCopilotChat/0.35.0",
    "Editor-Version": "vscode/1.107.0",
    "Editor-Plugin-Version": "copilot-chat/0.35.0",
    "Copilot-Integration-Id": "vscode-chat",
  ]

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
      let domainResponse = try await interaction(
        .prompt(
          providerID: providerID,
          id: "github-enterprise-domain",
          message: "GitHub Enterprise domain (leave empty for github.com)",
          kind: .text
        )
      )
      guard case .value(let rawDomain) = domainResponse else {
        throw failure("GitHub domain prompt did not return a value")
      }
      let enterpriseDomain = try normalizedDomain(rawDomain)
      let domain = enterpriseDomain ?? "github.com"
      let device = try await startDevice(domain: domain)
      let acknowledgement = try await interaction(
        .deviceCode(
          providerID: providerID,
          userCode: device.userCode,
          verificationURL: device.verificationURL,
          expiresAt: device.expiresAt,
          pollingInterval: .seconds(device.interval)
        )
      )
      guard acknowledgement == .acknowledged else {
        throw failure("GitHub Copilot device authorization was not acknowledged")
      }
      let githubToken = try await poll(domain: domain, device: device)
      let credential = try await exchangeCopilotToken(
        githubToken: githubToken,
        enterpriseDomain: enterpriseDomain
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
      now: clock.now(),
      refresh: { credential in
        try await exchangeCopilotToken(
          githubToken: credential.refreshToken,
          enterpriseDomain: credential.metadata["enterpriseDomain"]
        )
      }
    )
    return .oauth(refreshed)
  }

  private func startDevice(domain: String) async throws -> Device {
    var request = try oauthFormRequest(
      url: URL(string: "https://\(domain)/login/device/code")!,
      fields: ["client_id": Self.clientID, "scope": "read:user"]
    )
    request.setValue("GitHubCopilotChat/0.35.0", forHTTPHeaderField: "User-Agent")
    let body = try oauthResponseObject(
      try await transport.send(request),
      providerID: Self.providerID,
      operation: "copilot.oauth.device.start"
    )
    guard let code = body.string("device_code"), !code.isEmpty,
      let userCode = body.string("user_code"), !userCode.isEmpty,
      let verification = body.string("verification_uri"),
      let verificationURL = URL(string: verification),
      ["https", "http"].contains(verificationURL.scheme ?? ""),
      let expiresIn = body.int("expires_in"), expiresIn > 0
    else { throw failure("GitHub device authorization response is malformed") }
    let interval = body.int("interval") ?? 5
    guard interval > 0 else { throw failure("GitHub device polling interval is invalid") }
    return Device(
      code: code,
      userCode: userCode,
      verificationURL: verificationURL,
      expiresAt: clock.now().addingTimeInterval(TimeInterval(expiresIn)),
      interval: interval
    )
  }

  private func poll(domain: String, device: Device) async throws -> String {
    var interval = device.interval
    while clock.now() < device.expiresAt {
      try await clock.sleep(for: .seconds(interval))
      var request = try oauthFormRequest(
        url: URL(string: "https://\(domain)/login/oauth/access_token")!,
        fields: [
          "client_id": Self.clientID,
          "device_code": device.code,
          "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ]
      )
      request.setValue("GitHubCopilotChat/0.35.0", forHTTPHeaderField: "User-Agent")
      let response = try await transport.send(request)
      guard (200..<300).contains(response.statusCode) else {
        throw failure("GitHub device token request failed (HTTP \(response.statusCode))")
      }
      let body = try decodeJSONObject(
        response.body,
        providerID: Self.providerID,
        operation: "copilot.oauth.device.poll"
      )
      if let token = body.string("access_token"), !token.isEmpty { return token }
      switch body.string("error") {
      case "authorization_pending": continue
      case "slow_down":
        if let reported = body.int("interval") {
          guard reported > 0 else { throw failure("GitHub slow_down interval is invalid") }
          interval = reported
        } else {
          interval += 5
        }
      case let error?: throw failure("GitHub device flow failed: \(error)")
      case nil: throw failure("GitHub device token response is malformed")
      }
    }
    throw failure("GitHub device authorization timed out")
  }

  private func exchangeCopilotToken(
    githubToken: String,
    enterpriseDomain: String?
  ) async throws -> OAuthCredential {
    let domain = enterpriseDomain ?? "github.com"
    var request = URLRequest(
      url: URL(string: "https://api.\(domain)/copilot_internal/v2/token")!
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
    for (name, value) in Self.headers { request.setValue(value, forHTTPHeaderField: name) }
    let body = try oauthResponseObject(
      try await transport.send(request),
      providerID: Self.providerID,
      operation: "copilot.oauth.token"
    )
    guard let token = body.string("token"), !token.isEmpty,
      let expiresAt = body.int("expires_at"), expiresAt > 0
    else { throw failure("GitHub Copilot token response is malformed") }
    let baseURL = try copilotBaseURL(token: token, enterpriseDomain: enterpriseDomain)
    let available = try await fetchAvailableModels(
      token: token,
      baseURL: baseURL
    )
    var metadata = [
      "baseURL": baseURL.absoluteString,
      "availableModelIDs": available.joined(separator: ","),
    ]
    if let enterpriseDomain { metadata["enterpriseDomain"] = enterpriseDomain }
    return OAuthCredential(
      accessToken: token,
      refreshToken: githubToken,
      expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt) - 300),
      metadata: metadata
    )
  }

  private func fetchAvailableModels(
    token: String,
    baseURL: URL
  ) async throws -> [String] {
    var request = URLRequest(url: baseURL.appending(path: "models"))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("2026-06-01", forHTTPHeaderField: "X-GitHub-Api-Version")
    for (name, value) in Self.headers { request.setValue(value, forHTTPHeaderField: name) }
    let body = try oauthResponseObject(
      try await transport.send(request),
      providerID: Self.providerID,
      operation: "copilot.oauth.models"
    )
    guard let data = body.array("data") else {
      throw failure("GitHub Copilot models response is malformed")
    }
    return data.compactMap { item in
      guard let model = item.objectValue, let id = model.string("id"),
        model.bool("model_picker_enabled") == true,
        model.object("policy")?.string("state") != "disabled"
      else { return nil }
      return id
    }.sorted()
  }

  private func copilotBaseURL(
    token: String,
    enterpriseDomain: String?
  ) throws -> URL {
    if let range = token.range(of: #"(?:^|;)proxy-ep=([^;]+)"#, options: .regularExpression) {
      let value = String(token[range])
      guard let host = value.split(separator: "=").last, !host.isEmpty,
        let url = URL(string: "https://\(host.replacingOccurrences(of: "proxy.", with: "api."))")
      else { throw failure("GitHub Copilot token proxy endpoint is malformed") }
      return url
    }
    if let enterpriseDomain,
      let url = URL(string: "https://copilot-api.\(enterpriseDomain)")
    {
      return url
    }
    throw failure("GitHub Copilot token is missing proxy endpoint")
  }

  private func normalizedDomain(_ input: String) throws -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: value), let host = url.host, !host.isEmpty else {
      throw failure("GitHub Enterprise domain is invalid")
    }
    return host
  }

  private func require(_ providerID: String) throws {
    guard providerID == Self.providerID else { throw failure("provider mismatch") }
  }

  private func failure(_ message: String) -> ProviderRuntimeFailure {
    oauthFailure(
      .authorizationFailed,
      providerID: Self.providerID,
      operation: "copilot.oauth",
      message: message
    )
  }

  private struct Device: Sendable {
    let code: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: Int
  }
}
