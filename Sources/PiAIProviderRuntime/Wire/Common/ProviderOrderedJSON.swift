import Foundation

/// Retains object member order when provider JSON is carried in an opaque string.
indirect enum ProviderOrderedJSON {
  case object([(String, ProviderOrderedJSON)])
  case array([ProviderOrderedJSON])
  case scalar(JSONValue)

  init(data: Data) throws {
    _ = try JSONDecoder().decode(JSONValue.self, from: data)
    var parser = Parser(bytes: Array(data))
    self = try parser.value()
  }

  subscript(key: String) -> ProviderOrderedJSON? {
    guard case .object(let members) = self else { return nil }
    return members.first { $0.0 == key }?.1
  }

  var isTruthy: Bool {
    switch self {
    case .scalar(.null), .scalar(.bool(false)): false
    case .scalar(.string(let value)): !value.isEmpty
    case .scalar(.integer(let value)): value != 0
    case .scalar(.number(let value)): value != 0
    default: true
    }
  }

  func encodedString() throws -> String {
    switch self {
    case .object(let members):
      let indices = members.compactMap { member -> (UInt32, (String, ProviderOrderedJSON))? in
        guard let index = UInt32(member.0), index != .max, String(index) == member.0 else {
          return nil
        }
        return (index, member)
      }.sorted { $0.0 < $1.0 }
      let indexKeys = Set(indices.map { $0.1.0 })
      let ordered = indices.map(\.1) + members.filter { !indexKeys.contains($0.0) }
      return "{"
        + (try ordered.map { key, value in
          try Self.scalar(.string(key)).encodedString() + ":" + value.encodedString()
        }).joined(separator: ",") + "}"
    case .array(let values):
      return "[" + (try values.map { try $0.encodedString() }).joined(separator: ",") + "]"
    case .scalar(let value):
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
  }

  private struct Parser {
    let bytes: [UInt8]
    var index = 0

    mutating func value() throws -> ProviderOrderedJSON {
      skipWhitespace()
      if bytes[index] == 123 {
        index += 1
        skipWhitespace()
        var members: [(String, ProviderOrderedJSON)] = []
        while bytes[index] != 125 {
          let key = try JSONDecoder().decode(String.self, from: token())
          skipWhitespace()
          index += 1
          let member = try value()
          if let existing = members.firstIndex(where: { $0.0 == key }) {
            members[existing].1 = member
          } else {
            members.append((key, member))
          }
          skipWhitespace()
          if bytes[index] == 44 {
            index += 1
            skipWhitespace()
          }
        }
        index += 1
        return .object(members)
      }
      if bytes[index] == 91 {
        index += 1
        skipWhitespace()
        var values: [ProviderOrderedJSON] = []
        while bytes[index] != 93 {
          values.append(try value())
          skipWhitespace()
          if bytes[index] == 44 { index += 1 }
          skipWhitespace()
        }
        index += 1
        return .array(values)
      }
      return .scalar(try JSONDecoder().decode(JSONValue.self, from: token()))
    }

    mutating func token() -> Data {
      let start = index
      if bytes[index] == 34 {
        index += 1
        while bytes[index] != 34 {
          if bytes[index] == 92 { index += 1 }
          index += 1
        }
        index += 1
      } else {
        while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) {
          index += 1
        }
      }
      return Data(bytes[start..<index])
    }

    mutating func skipWhitespace() {
      while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
  }
}
