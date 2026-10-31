import CryptoKit
import Foundation
import Security

struct OAuthPKCE: Sendable, Equatable {
  let verifier: String
  let challenge: String
  let state: String

  static func make() throws -> OAuthPKCE {
    let verifier = try randomValue()
    let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    return OAuthPKCE(
      verifier: verifier, challenge: challenge, state: UUID().uuidString.lowercased())
  }

  static func randomValue() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw oauthFailure(
        .authorizationFailed,
        providerID: nil,
        operation: "oauth.pkce",
        message: "Secure PKCE randomness is unavailable"
      )
    }
    return base64URL(Data(bytes))
  }
}

func oauthFormRequest(
  url: URL,
  fields: [String: String]
) throws -> URLRequest {
  func encode(_ value: String) -> String {
    value.utf8.map { byte in
      switch byte {
      case 65...90, 97...122, 48...57, 42, 45, 46, 95: String(UnicodeScalar(byte))
      case 32: "+"
      default: String(format: "%%%02X", byte)
      }
    }.joined()
  }
  let encoded = fields.sorted { $0.key < $1.key }.map { encode($0.key) + "=" + encode($0.value) }
    .joined(separator: "&")
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Accept")
  request.setValue(
    "application/x-www-form-urlencoded",
    forHTTPHeaderField: "Content-Type"
  )
  request.httpBody = Data(encoded.utf8)
  return request
}

func oauthJSONRequest(
  url: URL,
  body: [String: JSONValue]
) throws -> URLRequest {
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Accept")
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.httpBody = try encodeJSONObject(
    body,
    providerID: "oauth",
    operation: "oauth.json.encode"
  )
  return request
}

func oauthResponseObject(
  _ response: ProviderHTTPResponse,
  providerID: String,
  operation: String
) throws -> [String: JSONValue] {
  guard (200..<300).contains(response.statusCode) else {
    throw oauthFailure(
      .authorizationFailed,
      providerID: providerID,
      operation: operation,
      message: "OAuth request failed (HTTP \(response.statusCode))"
    )
  }
  return try decodeJSONObject(
    response.body,
    providerID: providerID,
    operation: operation
  )
}

func oauthAuthorizationCode(
  _ response: AuthorizationResponse,
  expectedState: String?,
  providerID: String,
  requireState: Bool = true
) throws -> String {
  let code: String?
  let state: String?
  switch response {
  case .callbackURL(let url):
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    code = components?.queryItems?.first { $0.name == "code" }?.value
    state = components?.queryItems?.first { $0.name == "state" }?.value
  case .value(let raw):
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: value), url.scheme != nil {
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      code = components?.queryItems?.first { $0.name == "code" }?.value
      state = components?.queryItems?.first { $0.name == "state" }?.value
    } else if value.contains("#") {
      let values = value.split(separator: "#", maxSplits: 1).map(String.init)
      code = values.first
      state = values.count == 2 ? values[1] : nil
    } else if value.contains("code=") {
      let components = URLComponents(string: "?" + value)
      code = components?.queryItems?.first { $0.name == "code" }?.value
      state = components?.queryItems?.first { $0.name == "state" }?.value
    } else {
      code = value
      state = nil
    }
  case .acknowledged:
    code = nil
    state = nil
  }
  guard let code, !code.isEmpty else {
    throw oauthFailure(
      .authorizationFailed,
      providerID: providerID,
      operation: "oauth.callback",
      message: "OAuth callback is missing authorization code"
    )
  }
  if let expectedState, requireState || state != nil {
    guard state == expectedState else {
      throw oauthFailure(
        .authorizationFailed,
        providerID: providerID,
        operation: "oauth.callback",
        message: "OAuth callback state mismatch"
      )
    }
  }
  return code
}

func oauthCredential(
  _ body: [String: JSONValue],
  providerID: String,
  operation: String,
  now: Date,
  expirySkew: TimeInterval,
  defaultLifetime: Int? = nil,
  previousRefreshToken: String? = nil,
  metadata: [String: String] = [:]
) throws -> OAuthCredential {
  guard let access = body.string("access_token"), !access.isEmpty else {
    throw oauthFailure(
      .invalidResponse,
      providerID: providerID,
      operation: operation,
      message: "OAuth token response is missing access_token"
    )
  }
  let refresh = body.string("refresh_token") ?? previousRefreshToken
  guard let refresh, !refresh.isEmpty else {
    throw oauthFailure(
      .invalidResponse,
      providerID: providerID,
      operation: operation,
      message: "OAuth token response is missing refresh_token"
    )
  }
  let expiresIn: Int
  if let reported = body.int("expires_in") {
    expiresIn = reported
  } else if let defaultLifetime {
    expiresIn = defaultLifetime
  } else {
    throw oauthFailure(
      .invalidResponse,
      providerID: providerID,
      operation: operation,
      message: "OAuth token response is missing expires_in"
    )
  }
  guard expiresIn > 0, TimeInterval(expiresIn) > expirySkew else {
    throw oauthFailure(
      .invalidResponse,
      providerID: providerID,
      operation: operation,
      message: "OAuth token response has invalid expires_in"
    )
  }
  return OAuthCredential(
    accessToken: access,
    refreshToken: refresh,
    expiresAt: now.addingTimeInterval(TimeInterval(expiresIn) - expirySkew),
    metadata: metadata
  )
}

func oauthFailure(
  _ code: ProviderRuntimeFailure.Code,
  providerID: String?,
  operation: String,
  message: String
) -> ProviderRuntimeFailure {
  ProviderRuntimeFailure(
    code: code,
    message: message,
    providerID: providerID,
    operation: operation,
    causeDescription: nil
  )
}

private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}
