import Foundation

extension JSONValue {
  var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
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
    return try JSONEncoder().encode(JSONValue.object(object))
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
