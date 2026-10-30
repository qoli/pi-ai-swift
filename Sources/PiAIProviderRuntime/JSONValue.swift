import Foundation

public enum JSONValue: Sendable, Equatable, Codable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
  case orderedObject([ObjectMember])

  public struct ObjectMember: Sendable, Equatable {
    public let key: String
    public let value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
      self.key = key
      self.value = value
    }
  }

  /// Retains object member order when it affects a provider's projection.
  public init(jsonData: Data) throws {
    self = try ProviderOrderedJSON(data: jsonData).jsonValuePreservingObjectOrder
  }

  public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
    if let left = lhs.objectValue, let right = rhs.objectValue { return left == right }
    switch (lhs, rhs) {
    case (.null, .null): return true
    case (.bool(let left), .bool(let right)): return left == right
    case (.integer(let left), .integer(let right)): return left == right
    case (.number(let left), .number(let right)): return left == right
    case (.string(let left), .string(let right)): return left == right
    case (.array(let left), .array(let right)): return left == right
    default: return false
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .integer(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .orderedObject:
      try container.encode(objectValue!)
    }
  }
}
