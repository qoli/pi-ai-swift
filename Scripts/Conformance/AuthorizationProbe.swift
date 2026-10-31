import Foundation

@testable import PiAIProviderRuntime

enum AuthorizationConformanceProbe {
  static func run(_ input: [String: JSONValue]) async throws {
    let rpc = AuthorizationProbeRPC()
    let clock = AuthorizationProbeClock(milliseconds: input.int("now")!, rpc: rpc)
    let provider = input.string("provider")!
    let action = input.string("action")!
    let transport = AuthorizationProbeTransport(rpc: rpc, clock: clock)
    let execution = Task {
      do {
        let adapter: any ProviderAuthorizationAdapter
        switch provider {
        case "anthropic":
          adapter = AnthropicOAuthAuthorizationAdapter(
            transport: transport, now: { clock.now() },
            callbackURL: URL(
              string: input.string("callbackURL") ?? "http://localhost:53692/callback")!)
        case "openrouter":
          adapter = OpenRouterOAuthAuthorizationAdapter(
            transport: transport,
            callbackURL: URL(
              string: input.string("callbackURL") ?? "pi-ai-swift://oauth/openrouter")!)
        case "github-copilot":
          adapter = GitHubCopilotOAuthAuthorizationAdapter(transport: transport, clock: clock)
        case "kimi-coding":
          adapter = KimiCodingOAuthAuthorizationAdapter(
            transport: transport,
            oauthBaseURL: URL(string: input.string("oauthHost") ?? "https://auth.kimi.com")!,
            clock: clock)
        case "openai-codex":
          adapter = OpenAICodexAuthorizationAdapter(
            transport: transport, clock: clock, agentName: input.string("agentName") ?? "pi")
        case "xai": adapter = XAIOAuthAuthorizationAdapter(transport: transport, clock: clock)
        case "radius": adapter = RadiusOAuthAuthorizationAdapter(transport: transport, clock: clock)
        default:
          try rpc.write(
            "authFinished",
            [
              "failure": .object([
                "code": .string("unsupportedCapability"),
                "message": .string("Native OAuth is not implemented for " + provider),
                "capability": .string("oauth-" + provider),
              ])
            ])
          return
        }
        try rpc.write(
          "authStarted", ["operation": .string("authorization." + provider + "." + action)])
        var stored: ProviderCredential?
        if let raw = input.object("credential") {
          var metadata = (raw.object("metadata") ?? [:]).compactMapValues(\.stringValue)
          for key in ["gateway", "baseURL", "enterpriseDomain"] {
            if let value = input.string(key) ?? raw.string(key) { metadata[key] = value }
          }
          if let accountID = raw.string("accountId") { metadata["accountID"] = accountID }
          if let enterprise = raw.string("enterpriseUrl"), provider == "github-copilot" {
            metadata["enterpriseDomain"] = try GitHubCopilotOAuthAuthorizationAdapter(
              transport: transport
            ).normalizedDomain(enterprise)
            metadata["enterpriseUrl"] = enterprise
          }
          if provider == "openrouter", let expires = raw.int("expires") {
            metadata["expirationMilliseconds"] = String(expires)
          }
          stored = .oauth(
            .init(
              accessToken: raw.string("access") ?? "", refreshToken: raw.string("refresh") ?? "",
              expiresAt: action == "refresh" && provider != "openrouter"
                ? .distantPast
                : Date(
                  timeIntervalSince1970: Double(raw.int("expires") ?? 0) / 1_000),
              metadata: metadata))
        }
        let store = InMemoryProviderCredentialStore(
          credentials: stored.map { [provider: $0] } ?? [:])
        if action == "toAuth" {
          let projected = try adapter.requestAuthorization(for: stored)
          var auth: [String: JSONValue] = [:]
          switch projected.credential {
          case .oauth(let value): auth["apiKey"] = .string(value.accessToken)
          case .apiKey(let value): auth["apiKey"] = .string(value.key)
          case nil: break
          }
          if !projected.headers.isEmpty {
            auth["headers"] = .object(
              projected.headers.compactMapValues { $0 }.mapValues(JSONValue.string))
          }
          if provider == "github-copilot", case .oauth(let value) = stored {
            auth["baseUrl"] = .string(
              try GitHubCopilotOAuthAuthorizationAdapter(transport: transport).copilotBaseURL(
                token: value.accessToken, enterpriseDomain: value.metadata["enterpriseDomain"]
              ).absoluteString)
          }
          try rpc.write("authFinished", ["auth": .object(auth)])
          return
        }
        if action == "login" {
          _ = try await adapter.authorize(
            .login(
              providerID: provider,
              methodID: input.string("method") == "browser" && provider == "openai-codex"
                ? "oauth-browser"
                : input.string("method") == "copy_code" && provider == "anthropic"
                  ? "oauth-copy-code" : "oauth"),
            interaction: { challenge in
              var payload: [String: JSONValue] = [:]
              switch challenge {
              case .openURL(_, let url, _):
                payload = ["type": .string("url"), "url": .string(url.absoluteString)]
              case .deviceCode(_, let userCode, let url, let expiry, let interval):
                payload = [
                  "type": .string("device"), "userCode": .string(userCode),
                  "verificationUri": .string(url.absoluteString),
                ]
                if let expiry {
                  payload["expiresInSeconds"] = .number(expiry.timeIntervalSince(clock.now()))
                }
                if let interval {
                  payload["intervalSeconds"] = .number(milliseconds(interval) / 1_000)
                }
              case .prompt(_, let id, let message, let kind):
                payload = [
                  "type": .string("prompt"), "id": .string(id),
                  "message": .string(message), "kind": .string(kind.rawValue),
                ]
              case .progress(_, let message):
                payload = ["type": .string("progress"), "message": .string(message)]
              }
              let reply = try await rpc.exchange("authInteraction", payload)
              if let value = reply.objectValue?.string("value") { return .value(value) }
              return .acknowledged
            }, credentialStore: store)
        } else if action == "refresh" {
          if provider == "openai-codex", case .oauth(let credential) = stored {
            let refreshed = try await OpenAICodexOAuthClient(transport: transport, clock: clock)
              .refresh(credential)
            _ = try await store.modify(providerID: provider) { _ in .oauth(refreshed) }
          } else {
            let resolved = try await adapter.resolveCredential(
              providerID: provider, credentialStore: store,
              refreshCoordinator: CredentialRefreshCoordinator(credentialStore: store))
            _ = try await store.modify(providerID: provider) { _ in resolved }
          }
        } else {
          throw AuthorizationProbeError("Unsupported authorization probe action: " + action)
        }
        guard case .oauth(let credential) = await store.read(providerID: provider) else {
          throw AuthorizationProbeError("Native authorization produced no OAuth credential")
        }
        try rpc.write(
          "authFinished",
          [
            "credential": .object([
              "type": .string("oauth"), "access": .string(credential.accessToken),
              "refresh": .string(credential.refreshToken),
              "expires": .integer(
                credential.metadata["expirationMilliseconds"].flatMap(Int64.init)
                  ?? Int64(credential.expiresAt.timeIntervalSince1970 * 1_000)),
              "metadata": .object(credential.metadata.mapValues(JSONValue.string)),
            ])
          ])
      } catch {
        var failure: [String: JSONValue] = ["message": .string(error.localizedDescription)]
        if let error = error as? ProviderRuntimeFailure {
          failure["message"] = .string(error.message)
          failure["code"] = .string(error.code.rawValue)
          failure["cause"] = error.causeDescription.map(JSONValue.string)
        } else if error is CancellationError {
          failure["code"] = .string("cancelled")
        }
        try? rpc.write("authFinished", ["failure": .object(failure)])
      }
    }
    Task.detached {
      while let line = readLine() {
        do {
          let frame = try JSONValue(jsonData: Data(line.utf8)).objectValue ?? [:]
          if frame.string("kind") == "cancel" {
            execution.cancel()
            await rpc.fail(CancellationError())
          } else {
            await rpc.receive(frame)
          }
        } catch { await rpc.fail(error) }
      }
      await rpc.fail(AuthorizationProbeError("Authorization fixture channel closed"))
    }
    await execution.value
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
  }

  private final class AuthorizationProbeClock: ProviderOAuthClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private let rpc: AuthorizationProbeRPC
    init(milliseconds: Int, rpc: AuthorizationProbeRPC) {
      date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
      self.rpc = rpc
    }
    func now() -> Date { lock.withLock { date } }
    func update(_ raw: [String: JSONValue]) {
      if let value = raw.int("now") {
        lock.withLock { date = Date(timeIntervalSince1970: Double(value) / 1_000) }
      }
    }
    func sleep(for duration: Duration) async throws {
      let reply = try await rpc.exchange(
        "authSleep", ["milliseconds": .number(milliseconds(duration))])
      update(reply.objectValue ?? [:])
    }
  }

  private struct AuthorizationProbeTransport: ProviderHTTPTransport {
    let rpc: AuthorizationProbeRPC
    let clock: AuthorizationProbeClock
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
      let reply =
        try await rpc.exchange(
          "authRequest",
          [
            "url": .string(request.url!.absoluteString),
            "method": .string(request.httpMethod ?? "GET"),
            "headers": .object((request.allHTTPHeaderFields ?? [:]).mapValues(JSONValue.string)),
            "body": request.httpBody.map { .string($0.base64EncodedString()) } ?? .null,
          ]
        ).objectValue ?? [:]
      clock.update(reply)
      return .init(
        statusCode: reply.int("status")!,
        headers: (reply.object("headers") ?? [:]).compactMapValues(\.stringValue),
        body: Data(base64Encoded: reply.string("body")!)!)
    }
  }

  private actor AuthorizationProbeRPC {
    private var pending: CheckedContinuation<JSONValue, any Error>?
    nonisolated func write(_ kind: String, _ payload: [String: JSONValue]) throws {
      var data = try JSONEncoder().encode(
        JSONValue.object([
          "kind": .string(kind), "payload": .object(payload),
        ]))
      data.append(10)
      FileHandle.standardOutput.write(data)
    }
    func exchange(_ kind: String, _ payload: [String: JSONValue]) async throws -> JSONValue {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          pending = continuation
          do { try write(kind, payload) } catch { fail(error) }
        }
      } onCancel: {
        Task { await self.fail(CancellationError()) }
      }
    }
    func receive(_ frame: [String: JSONValue]) {
      if let message = frame.string("error") {
        fail(AuthorizationProbeError(message))
      } else {
        pending?.resume(returning: frame["value"] ?? .null)
        pending = nil
      }
    }
    func fail(_ error: any Error) {
      pending?.resume(throwing: error)
      pending = nil
    }
  }

  private struct AuthorizationProbeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
