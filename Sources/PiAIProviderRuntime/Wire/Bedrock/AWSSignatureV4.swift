import CryptoKit
import Foundation

struct AWSSignatureV4Credential: Sendable, Equatable {
  let accessKeyID: String
  let secretAccessKey: String
  let sessionToken: String?
}

enum AWSSignatureV4 {
  static func sign(
    _ request: inout URLRequest,
    credential: AWSSignatureV4Credential,
    region: String,
    service: String,
    date: Date
  ) throws {
    guard let url = request.url, let host = url.host, !host.isEmpty,
      !credential.accessKeyID.isEmpty, !credential.secretAccessKey.isEmpty,
      !region.isEmpty, !service.isEmpty
    else {
      throw failure("AWS SigV4 signing configuration is incomplete")
    }
    guard request.httpMethod == "POST", let body = request.httpBody else {
      throw failure("AWS SigV4 requires a POST request with an encoded body")
    }

    let amzDate = format(date, pattern: "yyyyMMdd'T'HHmmss'Z'")
    let dateStamp = format(date, pattern: "yyyyMMdd")
    let payloadHash = sha256Hex(body)
    request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
    request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
    if let sessionToken = credential.sessionToken, !sessionToken.isEmpty {
      request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token")
    }
    request.setValue(canonicalHost(url), forHTTPHeaderField: "Host")

    let headers = canonicalHeaders(request)
    let signedHeaderNames = headers.map(\.name).joined(separator: ";")
    let canonicalHeaderBlock = headers.map { "\($0.name):\($0.value)\n" }.joined()
    let canonicalRequest = [
      "POST",
      canonicalURI(url),
      try canonicalQuery(url),
      canonicalHeaderBlock,
      signedHeaderNames,
      payloadHash,
    ].joined(separator: "\n")
    let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      amzDate,
      scope,
      sha256Hex(Data(canonicalRequest.utf8)),
    ].joined(separator: "\n")
    let signingKey = signatureKey(
      secret: credential.secretAccessKey,
      dateStamp: dateStamp,
      region: region,
      service: service
    )
    let signature = hmacHex(key: signingKey, data: Data(stringToSign.utf8))
    request.setValue(
      "AWS4-HMAC-SHA256 Credential=\(credential.accessKeyID)/\(scope), SignedHeaders=\(signedHeaderNames), Signature=\(signature)",
      forHTTPHeaderField: "Authorization"
    )
  }

  private static func canonicalHeaders(
    _ request: URLRequest
  ) -> [(name: String, value: String)] {
    (request.allHTTPHeaderFields ?? [:]).map { entry in
      let normalized: (name: String, value: String) = (
        entry.key.lowercased(),
        entry.value.split(whereSeparator: { $0.isWhitespace })
          .joined(separator: " ")
      )
      return normalized
    }.sorted { lhs, rhs in lhs.name < rhs.name }
  }

  private static func canonicalURI(_ url: URL) -> String {
    let path =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .percentEncodedPath ?? url.path
    return path.isEmpty ? "/" : path
  }

  private static func canonicalQuery(_ url: URL) throws -> String {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let items = components.queryItems, !items.isEmpty
    else { return "" }
    let encodedItems: [(name: String, value: String)] = try items.map { item in
      let name = try percentEncode(item.name)
      let value = try percentEncode(item.value ?? "")
      return (name: name, value: value)
    }
    return encodedItems.sorted { lhs, rhs in
      lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
    }.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
  }

  private static func canonicalHost(_ url: URL) -> String {
    guard let host = url.host else { return "" }
    guard let port = url.port else { return host }
    let defaultPort =
      (url.scheme == "https" && port == 443)
      || (url.scheme == "http" && port == 80)
    return defaultPort ? host : "\(host):\(port)"
  }

  private static func percentEncode(_ value: String) throws -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw failure("AWS SigV4 query parameter cannot be percent encoded")
    }
    return encoded
  }

  private static func signatureKey(
    secret: String,
    dateStamp: String,
    region: String,
    service: String
  ) -> Data {
    let dateKey = hmac(
      key: Data("AWS4\(secret)".utf8),
      data: Data(dateStamp.utf8)
    )
    let regionKey = hmac(key: dateKey, data: Data(region.utf8))
    let serviceKey = hmac(key: regionKey, data: Data(service.utf8))
    return hmac(key: serviceKey, data: Data("aws4_request".utf8))
  }

  private static func hmac(key: Data, data: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
  }

  private static func hmacHex(key: Data, data: Data) -> String {
    hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func format(_ date: Date, pattern: String) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = pattern
    return formatter.string(from: date)
  }

  private static func failure(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidCredential,
      message: message,
      providerID: "amazon-bedrock",
      operation: "bedrock.request.sigv4",
      causeDescription: nil
    )
  }
}
