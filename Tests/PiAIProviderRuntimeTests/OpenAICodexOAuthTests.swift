import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct OpenAICodexOAuthTests {
  @Test
  func deviceAuthorizationAcceptsNumericInterval() async throws {
    let transport = QueueTransport([
      deviceAuthorizationResponse(interval: 5)
    ])
    let client = makeClient(transport)

    let authorization = try await client.startDeviceAuthorization()

    #expect(authorization.userCode == "ABCD-1234")
    #expect(authorization.pollingInterval == .seconds(5))
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/api/accounts/deviceauth/usercode")
    #expect(request.httpMethod == "POST")
  }

  @Test
  func deviceAuthorizationAcceptsStringInterval() async throws {
    let transport = QueueTransport([
      deviceAuthorizationResponse(interval: "5")
    ])
    let client = makeClient(transport)

    let authorization = try await client.startDeviceAuthorization()

    #expect(authorization.pollingInterval == .seconds(5))
  }

  @Test
  func unavailableDeviceAuthorizationFailsWithoutBrowserFallback() async {
    let transport = QueueTransport([
      .init(statusCode: 404, headers: [:], body: Data())
    ])
    let client = makeClient(transport)

    do {
      _ = try await client.startDeviceAuthorization()
      Issue.record("404 device authorization produced a valid session")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .unsupportedCapability)
      #expect(error.operation == "oauth.device.start")
    } catch {
      Issue.record("unexpected error type: \(error)")
    }
  }

  @Test
  func pollingPreservesPendingSlowDownAndAuthorizedStates() async throws {
    let transport = QueueTransport([
      .init(statusCode: 403, headers: [:], body: Data()),
      .init(
        statusCode: 429,
        headers: [:],
        body: Data(#"{"error":{"code":"slow_down"}}"#.utf8)
      ),
      .init(
        statusCode: 200,
        headers: [:],
        body: Data(
          #"{"authorization_code":"code-1","code_verifier":"verifier-1"}"#
            .utf8
        )
      ),
    ])
    let client = makeClient(transport)
    let authorization = makeAuthorization()

    #expect(try await client.pollDeviceAuthorization(authorization) == .pending)
    #expect(try await client.pollDeviceAuthorization(authorization) == .slowDown)
    #expect(
      try await client.pollDeviceAuthorization(authorization)
        == .authorized(code: "code-1", verifier: "verifier-1")
    )
  }

  @Test
  func tokenExchangeRequiresChatGPTAccountClaim() async {
    let transport = QueueTransport([
      .init(
        statusCode: 200,
        headers: [:],
        body: tokenResponse(accessToken: jwt(payload: [:]))
      )
    ])
    let client = makeClient(transport)

    do {
      _ = try await client.exchangeAuthorizationCode(
        code: "code-1",
        verifier: "verifier-1"
      )
      Issue.record("token without account claim produced a credential")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .invalidCredential)
      #expect(error.operation == "oauth.token.validate")
    } catch {
      Issue.record("unexpected error type: \(error)")
    }
  }

  @Test
  func tokenExchangeReturnsCredentialWithoutPersistingTokens() async throws {
    let accessToken = jwt(payload: [
      "https://api.openai.com/auth": [
        "chatgpt_account_id": "account-1"
      ]
    ])
    let transport = QueueTransport([
      .init(
        statusCode: 200,
        headers: [:],
        body: tokenResponse(accessToken: accessToken)
      )
    ])
    let client = makeClient(transport)

    let credential = try await client.exchangeAuthorizationCode(
      code: "code-1",
      verifier: "verifier-1"
    )

    #expect(credential.accessToken == accessToken)
    #expect(credential.refreshToken == "refresh-1")
    #expect(credential.metadata["accountID"] == "account-1")
    let request = try #require(await transport.requests.first)
    let data = try #require(request.httpBody)
    let body = try #require(String(data: data, encoding: .utf8))
    #expect(body.contains("grant_type=authorization_code"))
    #expect(body.contains("code_verifier=verifier-1"))
    #expect(
      body.contains(
        "redirect_uri=https://auth.openai.com/deviceauth/callback"
      ))
  }
}

private actor QueueTransport: ProviderHTTPTransport {
  private var responses: [ProviderHTTPResponse]
  private(set) var requests: [URLRequest] = []

  init(_ responses: [ProviderHTTPResponse]) {
    self.responses = responses
  }

  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else {
      throw QueueTransportError.missingResponse
    }
    return responses.removeFirst()
  }
}

private enum QueueTransportError: Error {
  case missingResponse
}

private func makeClient(_ transport: QueueTransport) -> OpenAICodexOAuthClient {
  OpenAICodexOAuthClient(
    transport: transport,
    authBaseURL: URL(string: "https://auth.openai.com")!
  )
}

private func makeAuthorization() -> OpenAICodexDeviceAuthorization {
  OpenAICodexDeviceAuthorization(
    deviceAuthorizationID: "device-1",
    userCode: "ABCD-1234",
    verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
    pollingInterval: .seconds(5),
    expiresAt: Date().addingTimeInterval(900)
  )
}

private func deviceAuthorizationResponse(interval: Any) -> ProviderHTTPResponse {
  let body = try! JSONSerialization.data(withJSONObject: [
    "device_auth_id": "device-1",
    "user_code": "ABCD-1234",
    "interval": interval,
  ])
  return .init(statusCode: 200, headers: [:], body: body)
}

private func jwt(payload: [String: Any]) -> String {
  let header = try! JSONSerialization.data(withJSONObject: ["alg": "none"])
  let payload = try! JSONSerialization.data(withJSONObject: payload)
  return [header, payload, Data("signature".utf8)]
    .map(base64URLEncode)
    .joined(separator: ".")
}

private func base64URLEncode(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private func tokenResponse(accessToken: String) -> Data {
  try! JSONSerialization.data(withJSONObject: [
    "access_token": accessToken,
    "refresh_token": "refresh-1",
    "expires_in": 3_600,
  ])
}
