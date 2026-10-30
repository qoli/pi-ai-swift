import Foundation

extension ProviderToolCall {
  /// Mirrors upstream parseToolCallArguments, keeping final validation separate
  /// from a partial preview and retaining the original input for tool validation.
  static func parsing(
    id: String, name: String, input: String, thoughtSignature: String? = nil,
    namespace: String? = nil
  ) -> ProviderToolCall {
    func call(_ value: JSONValue, error: String? = nil) -> ProviderToolCall {
      ProviderToolCall(
        id: id, name: name, arguments: value, thoughtSignature: thoughtSignature,
        namespace: namespace, argumentsError: error)
    }
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return call(.object([:]))
    }
    func decode(_ text: String) throws -> JSONValue {
      try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
    do {
      let value: JSONValue
      do { value = try decode(input) } catch {
        let repaired = repairToolArgumentString(input)
        guard repaired != input else { throw error }
        value = try decode(repaired)
      }
      guard case .object = value else {
        return call(
          .object([:]),
          error: "Tool arguments must be a JSON object\n\nReceived arguments:\n\(input)")
      }
      return call(value)
    } catch {
      return call(
        .object([:]), error: "\(error.localizedDescription)\n\nReceived arguments:\n\(input)")
    }
  }
}

/// The pinned repairJson only escapes controls and invalid escapes inside JSON
/// strings. It never closes incomplete JSON or accepts a parsed prefix.
private func repairToolArgumentString(_ input: String) -> String {
  let bytes = Array(input.utf8)
  var result: [UInt8] = []
  var inString = false
  var index = 0
  let escapes: Set<UInt8> = [34, 92, 47, 98, 102, 110, 114, 116]
  func hex(_ value: UInt8) -> Bool {
    (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
  }
  while index < bytes.count {
    let byte = bytes[index]
    if !inString {
      result.append(byte)
      if byte == 34 { inString = true }
    } else if byte == 34 {
      result.append(byte)
      inString = false
    } else if byte == 92 {
      if index + 5 < bytes.count, bytes[index + 1] == 117,
        bytes[(index + 2)...(index + 5)].allSatisfy(hex)
      {
        result.append(contentsOf: bytes[index...(index + 5)])
        index += 5
      } else if index + 1 < bytes.count, escapes.contains(bytes[index + 1]) {
        result.append(contentsOf: bytes[index...(index + 1)])
        index += 1
      } else {
        result.append(contentsOf: [92, 92])
      }
    } else if byte < 32 {
      result.append(contentsOf: String(format: "\\u%04x", byte).utf8)
    } else {
      result.append(byte)
    }
    index += 1
  }
  return String(decoding: result, as: UTF8.self)
}
