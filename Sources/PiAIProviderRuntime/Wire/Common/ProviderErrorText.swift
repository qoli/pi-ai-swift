import Foundation

enum ProviderErrorText {
  static let maximumBodyCharacters = 4_000
  static let javaScriptWhitespace = CharacterSet(
    charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}"
      + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}"
      + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")

  struct Normalized: Sendable, Encodable {
    let status: JSONValue?
    let body: String?
    let message: String
    let messageCarriesBody: Bool
  }

  enum BodyCandidate: Sendable {
    case text(String)
    case plainObject(serialized: String, isEmpty: Bool, isReadable: Bool)
    case other
  }

  static func normalize(
    isError: Bool, message: String, serializedValue: String?, stringValue: String,
    statusCandidates: [JSONValue], body: BodyCandidate, error: BodyCandidate,
    responseBody: BodyCandidate
  ) -> Normalized {
    guard isError else {
      return .init(
        status: nil, body: nil, message: serializedValue ?? stringValue,
        messageCarriesBody: false)
    }
    let status = statusCandidates.first {
      switch $0 {
      case .integer, .number: return true
      default: return false
      }
    }
    let selected: String?
    if case .text(let value) = body {
      selected = value
    } else if case .plainObject(let value, false, _) = error {
      selected = value
    } else if case .text(let value) = responseBody {
      selected = value
    } else if case .plainObject(let value, false, false) = responseBody {
      selected = value
    } else {
      selected = nil
    }
    let trimmed = selected?.trimmingCharacters(in: javaScriptWhitespace)
    let excerpt = trimmed.flatMap {
      $0.isEmpty ? nil : truncate($0, maximumCharacters: maximumBodyCharacters)
    }
    return .init(
      status: status, body: excerpt, message: message,
      messageCarriesBody: excerpt.map { message.contains($0) } ?? true)
  }

  static func format(_ value: Normalized, prefix: String? = nil) -> String {
    let status = value.status.flatMap { try? ProviderOrderedJSON.scalar($0).encodedString() }
    if !value.messageCarriesBody, let status, let body = value.body {
      return prefix.map { "\($0) (\(status)): \(body)" } ?? "\(status): \(body)"
    }
    if let prefix, let status { return "\(prefix) (\(status)): \(value.message)" }
    return value.message
  }

  static func truncate(_ text: String, maximumCharacters: Int) -> String {
    let length = text.utf16.count
    guard length > maximumCharacters else { return text }
    let end = maximumCharacters < 0 ? max(0, length + maximumCharacters) : maximumCharacters
    return String(decoding: text.utf16.prefix(end), as: UTF16.self)
      + "... [truncated \(length - maximumCharacters) chars]"
  }

  static func format(
    status: Int?, body: String?, message: String, messageCarriesBody: Bool, prefix: String? = nil
  ) -> String {
    format(
      .init(
        status: status.map { .integer(Int64($0)) }, body: body,
        message: message, messageCarriesBody: messageCarriesBody), prefix: prefix)
  }

  static func http(status: Int, body: String?, emptyMessage: String) -> String {
    guard let raw = body?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return emptyMessage
    }
    let compact = (try? ProviderOrderedJSON(data: Data(raw.utf8)).encodedString()) ?? raw
    return format(
      status: status, body: truncate(compact, maximumCharacters: maximumBodyCharacters),
      message: emptyMessage, messageCarriesBody: false)
  }

  static func openAIStreamError(_ data: Data) throws -> (message: String, code: String?) {
    let parsed = try ProviderOrderedJSON(data: data)
    let error = parsed["error"].flatMap { $0.isNullish ? nil : $0 } ?? parsed
    let message: String
    if let detail = error["message"], detail.isTruthy {
      message = try detail.stringValue ?? detail.encodedString()
    } else if error.isTruthy {
      message = try error.encodedString()
    } else {
      message = "(no status code or body)"
    }
    return (message, error["code"]?.stringValue)
  }
}
