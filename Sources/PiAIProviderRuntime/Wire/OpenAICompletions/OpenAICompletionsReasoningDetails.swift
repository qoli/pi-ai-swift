import Foundation

enum OpenAICompletionsReasoningDetails {
  static func valid(_ value: JSONValue) -> Bool {
    guard case .object(let object) = value, let type = object.string("type") else { return false }
    if let id = object["id"], id != .null, id.stringValue == nil { return false }
    if object["format"] != nil, object.string("format") == nil { return false }
    if let index = object["index"] {
      switch index {
      case .integer, .number: break
      default: return false
      }
    }
    switch type {
    case "reasoning.summary": return object.string("summary") != nil
    case "reasoning.encrypted": return object.string("data") != nil
    case "reasoning.text":
      guard object.string("text") != nil else { return false }
      if let signature = object["signature"], signature != .null, signature.stringValue == nil {
        return false
      }
      return true
    default: return false
    }
  }

  static func parse(_ signature: String?) -> [JSONValue]? {
    guard let signature,
      let value = try? JSONDecoder().decode(JSONValue.self, from: Data(signature.utf8)),
      case .array(let values) = value, !values.isEmpty, values.allSatisfy(valid)
    else { return nil }
    return values
  }

  static func legacy(_ signature: String?) -> JSONValue? {
    guard let signature,
      let value = try? JSONDecoder().decode(JSONValue.self, from: Data(signature.utf8)),
      valid(value), let object = value.objectValue,
      object.string("type") == "reasoning.encrypted",
      object.string("id")?.isEmpty == false, object.string("data")?.isEmpty == false
    else { return nil }
    return value
  }

  static func append(_ detail: ProviderOrderedJSON, to details: inout [ProviderOrderedJSON]) {
    guard var last = details.last, let type = detail["type"]?.stringValue,
      last["type"]?.stringValue == type, ["reasoning.text", "reasoning.summary"].contains(type)
    else {
      details.append(detail)
      return
    }
    let key = type == "reasoning.text" ? "text" : "summary"
    last.set(
      .scalar(.string((last[key]?.stringValue ?? "") + (detail[key]?.stringValue ?? ""))), for: key)
    if key == "text", last["signature"]?.isTruthy != true {
      last.set(detail["signature"] ?? .undefined, for: "signature")
    }
    if last["id"]?.isNullish != false { last.set(detail["id"] ?? .undefined, for: "id") }
    if last["format"]?.isTruthy != true { last.set(detail["format"] ?? .undefined, for: "format") }
    if last["index"]?.isNullish != false { last.set(detail["index"] ?? .undefined, for: "index") }
    details[details.count - 1] = last
  }
}
