import Foundation

enum BedrockFailure {
  private static let javaScriptWhitespace = CharacterSet(
    charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}"
      + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}"
      + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
  private static let prefixes = [
    "InternalServerException": "Internal server error",
    "ModelStreamErrorException": "Model stream error",
    "ValidationException": "Validation error",
    "ThrottlingException": "Throttling error",
    "ServiceUnavailableException": "Service unavailable",
  ]

  static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: javaScriptWhitespace)
    return result.isEmpty || result.utf16.count > 200 ? nil : result
  }

  static func exceptionName(_ value: String?) -> String? {
    guard let value else { return nil }
    return prefixes.keys.first {
      $0 == value || $0.prefix(1).lowercased() + $0.dropFirst() == value
    } ?? value
  }

  static func responseErrorName(headers: [String: String], body: [String: JSONValue]?) -> String? {
    let header = headers.first { $0.key.lowercased() == "x-amzn-errortype" }?.value
    return (header ?? body?.string("__type") ?? body?.string("code"))?
      .split(separator: "#").last?.split(separator: ":").first.map(String.init)
  }

  static func message(_ message: String, exceptionName: String? = nil) -> String {
    let hint =
      message.range(of: "data retention mode", options: .caseInsensitive) == nil
      ? ""
      : " See https://docs.aws.amazon.com/bedrock/latest/userguide/data-retention.html for supported data retention modes."
    return exceptionName.map { "\(prefixes[$0] ?? $0): \(message)\(hint)" } ?? "\(message)\(hint)"
  }

  static func diagnostic(status: Int? = nil, errorCode: String? = nil, requestID: String? = nil)
    -> JSONValue?
  {
    var details: [String: JSONValue] = [:]
    if let status { details["status"] = .integer(Int64(status)) }
    if let errorCode, errorCode.hasSuffix("Exception"), let value = normalized(errorCode) {
      details["errorCode"] = .string(value)
    }
    if let value = normalized(requestID) { details["requestId"] = .string(value) }
    guard !details.isEmpty else { return nil }
    return .object([
      "type": .string("bedrock_response_failure"),
      "timestamp": .integer(Int64(Date().timeIntervalSince1970 * 1_000)),
      "details": .object(details),
    ])
  }
}
