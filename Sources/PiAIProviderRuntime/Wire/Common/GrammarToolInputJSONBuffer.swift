import Foundation

struct GrammarToolInputJSONBuffer: Sendable {
  let property: String
  private(set) var input = ""
  private var started = false
  private var closed = false
  private var unsent = ""

  init(property: String, initialInput: String) throws {
    self.property = property
    unsent = try appendToBuffer(initialInput) ?? ""
  }

  mutating func append(_ delta: String) throws -> String? {
    try send(appendToBuffer(delta))
  }

  mutating func close(_ finalInput: String?) throws -> String? {
    if closed {
      if finalInput == nil || finalInput == input { return try send(nil) }
      throw GrammarToolInputJSONError.changedAfterClose(property)
    }
    if let finalInput, !finalInput.utf8.starts(with: input.utf8) {
      throw GrammarToolInputJSONError.nonMonotonic(property)
    }
    let rest =
      finalInput.map { String(decoding: $0.utf8.dropFirst(input.utf8.count), as: UTF8.self) } ?? ""
    if let finalInput { input = finalInput }
    closed = true
    return try send(start() + Self.fragment(rest) + "\"}")
  }

  private mutating func appendToBuffer(_ delta: String) throws -> String? {
    guard !closed else { throw GrammarToolInputJSONError.changedAfterClose(property) }
    guard !delta.isEmpty else { return nil }
    input += delta
    return try start() + Self.fragment(delta)
  }

  private mutating func start() throws -> String {
    guard !started else { return "" }
    started = true
    return try "{" + Self.quote(property) + ":\""
  }

  private mutating func send(_ delta: String?) throws -> String? {
    guard !unsent.isEmpty else { return delta }
    let result = unsent + (delta ?? "")
    unsent = ""
    return result
  }

  private static func fragment(_ value: String) throws -> String {
    String(try quote(value).dropFirst().dropLast())
  }

  private static func quote(_ value: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}

enum GrammarToolInputJSONError: Error, CustomStringConvertible {
  case changedAfterClose(String)
  case nonMonotonic(String)

  var description: String {
    switch self {
    case .changedAfterClose(let property):
      "grammar tool input for property \"\(property)\" changed after it was closed"
    case .nonMonotonic(let property):
      "grammar tool input for property \"\(property)\" changed non-monotonically"
    }
  }
}
