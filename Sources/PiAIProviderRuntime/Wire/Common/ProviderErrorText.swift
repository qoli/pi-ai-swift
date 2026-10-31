import Foundation

enum ProviderErrorText {
  static let maximumBodyCharacters = 4_000

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
    guard !messageCarriesBody, let status, let body else {
      if let prefix, let status { return "\(prefix) (\(status)): \(message)" }
      return message
    }
    if let prefix { return "\(prefix) (\(status)): \(body)" }
    return "\(status): \(body)"
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
}
