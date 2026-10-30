import Foundation

extension JSONValue {
  public var objectValue: [String: JSONValue]? {
    switch self {
    case .object(let value): return value
    case .orderedObject(let members):
      return Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    default: return nil
    }
  }

  public var objectPropertyNames: [String]? {
    switch self {
    case .object(let value): return value.keys.sorted()
    case .orderedObject(let members):
      var seen = Set<String>()
      let keys = members.map(\.key).filter { seen.insert($0).inserted }
      let indexed = keys.compactMap { key -> (UInt32, String)? in
        guard let index = UInt32(key), index != .max, String(index) == key else { return nil }
        return (index, key)
      }.sorted { $0.0 < $1.0 }
      let indexedKeys = Set(indexed.map(\.1))
      return indexed.map(\.1) + keys.filter { !indexedKeys.contains($0) }
    default: return nil
    }
  }

  var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var integerValue: Int? {
    switch self {
    case .integer(let value): Int(exactly: value)
    case .number(let value) where value.rounded() == value: Int(exactly: value)
    default: nil
    }
  }

  var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  func string(_ key: String) -> String? { self[key]?.stringValue }
  func int(_ key: String) -> Int? { self[key]?.integerValue }
  func bool(_ key: String) -> Bool? { self[key]?.boolValue }
  func object(_ key: String) -> [String: JSONValue]? { self[key]?.objectValue }
  func array(_ key: String) -> [JSONValue]? { self[key]?.arrayValue }
}

func decodeJSONObject(
  _ data: Data,
  providerID: String,
  operation: String
) throws -> [String: JSONValue] {
  do {
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .object(let object) = value else {
      throw DecodingError.typeMismatch(
        [String: JSONValue].self,
        DecodingError.Context(
          codingPath: [],
          debugDescription: "expected a JSON object"
        )
      )
    }
    return object
  } catch {
    throw ProviderRuntimeFailure(
      code: .invalidResponse,
      message: "provider response contains malformed JSON",
      providerID: providerID,
      operation: operation,
      causeDescription: String(describing: error)
    )
  }
}

func encodeJSONObject(
  _ object: [String: JSONValue],
  providerID: String,
  operation: String
) throws -> Data {
  do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(JSONValue.object(object))
  } catch {
    throw ProviderRuntimeFailure(
      code: .invalidRequest,
      message: "provider request could not be encoded",
      providerID: providerID,
      operation: operation,
      causeDescription: String(describing: error)
    )
  }
}
