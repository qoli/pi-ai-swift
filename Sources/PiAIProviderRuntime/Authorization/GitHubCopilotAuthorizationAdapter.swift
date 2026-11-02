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

  func requestAuthorization(for credential: ProviderCredential?) throws
    -> ProviderRequestAuthorization
  {
    guard case .oauth(let value) = credential else {
      return .init(credential: credential, headers: [:])
    }
    return .init(
      credential: .apiKey(.init(key: value.accessToken, metadata: value.metadata)), headers: [:])
  }

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
        enterpriseDomain: enterpriseDomain,
        loginInteraction: interaction
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
      now: { clock.now() },
      refresh: { credential in
        try await exchangeCopilotToken(
          githubToken: credential.refreshToken,
          enterpriseDomain: credential.metadata["enterpriseDomain"]
        )
      }
    )
    return refreshed.map(ProviderCredential.oauth)
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
      let expiresIn = body.int("expires_in"), expiresIn > 0
    else { throw failure("GitHub device authorization response is malformed") }
    guard ["https", "http"].contains(verificationURL.scheme ?? "") else {
      throw failure("Untrusted verification_uri in device code response")
    }
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
    try await ProviderDeviceCodePolling.poll(
      intervalSeconds: Double(device.interval),
      expiresInSeconds: device.expiresAt.timeIntervalSince(clock.now()),
      waitBeforeFirstPoll: true, clock: clock
    ) {
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
      if let token = body.string("access_token"), !token.isEmpty { return .complete(token) }
      switch body.string("error") {
      case "authorization_pending": return .pending
      case "slow_down": return .slowDown(intervalSeconds: body.int("interval").map(Double.init))
      case let error?: throw failure("GitHub device flow failed: \(error)")
      case nil: throw failure("GitHub device token response is malformed")
      }
    }
  }

  private func exchangeCopilotToken(
    githubToken: String,
    enterpriseDomain: String?,
    loginInteraction: AuthorizationInteraction? = nil
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
    let models = try await fetchAvailableModels(
      token: token,
      baseURL: baseURL,
      maximumRetries: loginInteraction == nil ? 0 : 2
    )
    var available = models.available
    if let loginInteraction, !models.policy.isEmpty {
      _ = try await loginInteraction(
        .progress(providerID: Self.providerID, message: "Enabling models..."))
      for modelID in models.policy {
        var request = URLRequest(url: baseURL.appending(path: "models/\(modelID)/policy"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (name, value) in Self.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("chat-policy", forHTTPHeaderField: "openai-intent")
        request.setValue("chat-policy", forHTTPHeaderField: "x-interaction-type")
        request.httpBody = Data(#"{"state":"enabled"}"#.utf8)
        do {
          let response = try await rateLimited(request, maximumRetries: 2)
          if response.statusCode == 429 { break }
          if (200..<300).contains(response.statusCode) { available.append(modelID) }
        } catch {
          try Task.checkCancellation()
        }
      }
      var seen = Set<String>()
      available = available.filter { seen.insert($0).inserted }
    }
    var metadata = [
      "baseURL": baseURL.absoluteString,
      "availableModelIDs": available.joined(separator: ","),
      "availableModelIDsJSON": String(decoding: try JSONEncoder().encode(available), as: UTF8.self),
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
    baseURL: URL,
    maximumRetries: Int
  ) async throws -> (available: [String], policy: [String]) {
    var request = URLRequest(url: baseURL.appending(path: "models"))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("2026-06-01", forHTTPHeaderField: "X-GitHub-Api-Version")
    for (name, value) in Self.headers { request.setValue(value, forHTTPHeaderField: name) }
    let body = try oauthResponseObject(
      try await rateLimited(request, maximumRetries: maximumRetries),
      providerID: Self.providerID,
      operation: "copilot.oauth.models"
    )
    guard let data = body.array("data") else {
      throw failure("GitHub Copilot models response is malformed")
    }
    let candidates = data.compactMap { item -> [String: JSONValue]? in
      guard let model = item.objectValue, model.string("id") != nil,
        model.object("capabilities")?.object("supports")?.bool("tool_calls") != false
      else { return nil }
      return model
    }
    let picker = candidates.filter {
      $0.bool("model_picker_enabled") == true && $0.object("policy")?.string("state") != "disabled"
    }.compactMap { $0.string("id") }
    let policyFallback =
      picker.isEmpty && baseURL.absoluteString == "https://api.individual.githubcopilot.com"
    let available =
      policyFallback
      ? candidates.filter { $0.object("policy")?.string("state") == "enabled" }.compactMap {
        $0.string("id")
      } : picker
    let unconfigured = candidates.filter {
      $0.object("policy")?.string("state") == "unconfigured"
        && ($0.bool("model_picker_enabled") == true || policyFallback)
    }
    let known =
      unconfigured.isEmpty
      ? Set<String>()
      : Set(
        try BuiltinProviderRegistry.load().providers.first { $0.id == Self.providerID }?.models.map(
          \.id) ?? [])
    return (available, unconfigured.compactMap { $0.string("id") }.filter { known.contains($0) })
  }

  private func rateLimited(_ original: URLRequest, maximumRetries: Int) async throws
    -> ProviderHTTPResponse
  {
    let deadline = maximumRetries > 0 ? clock.now().addingTimeInterval(5) : nil
    for retry in 0...maximumRetries {
      try Task.checkCancellation()
      var request = original
      request.timeoutInterval = min(5, deadline?.timeIntervalSince(clock.now()) ?? 5)
      let response = try await transport.send(request)
      if response.statusCode != 429 || retry == maximumRetries { return response }
      var delay = 500 * pow(2, Double(retry))
      if let text = response.headers.first(where: { $0.key.lowercased() == "retry-after" })?.value,
        !text.isEmpty
      {
        if let seconds = ProviderRequestRetry.parseFloat(text) {
          delay = seconds * 1_000
        } else {
          let format = DateFormatter()
          format.locale = Locale(identifier: "en_US_POSIX")
          format.timeZone = TimeZone(secondsFromGMT: 0)
          format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
          guard let date = format.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
            return response
          }
          delay = date.timeIntervalSince(clock.now()) * 1_000
        }
        if !delay.isFinite { return response }
      }
      delay = max(0, delay)
      if let deadline, delay >= deadline.timeIntervalSince(clock.now()) * 1_000 { return response }
      try await clock.sleep(for: .milliseconds(delay))
    }
    throw failure("GitHub Copilot rate-limit retry exhausted")
  }

  func copilotBaseURL(
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
    return URL(string: "https://api.individual.githubcopilot.com")!
  }

  func normalizedDomain(_ input: String) throws -> String? {
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
