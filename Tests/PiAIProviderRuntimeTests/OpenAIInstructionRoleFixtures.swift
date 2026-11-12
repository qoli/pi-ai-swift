@testable import PiAIProviderRuntime

enum OpenAIInstructionRoleFixtures {
  private static let changedFirstRoleFields: [String: String] = {
    var fields = [
      "completions.compat-reasoning-content": "messages",
      "completions.compat-thinking-as-text": "messages",
      "completions.detected-compat-openrouter-anthropic": "messages",
      "completions.detected-compat-openrouter-openai": "messages",
      "completions.detected-compat-standard": "messages",
    ]
    for effort in ["off", "minimal", "low", "medium", "high"] {
      fields["reasoning-\(effort)-request/openai-completions"] = "messages"
      fields["reasoning-\(effort)-request/openai-responses"] = "input"
      fields["reasoning-\(effort)-request/azure-openai-responses"] = "input"
    }
    return fields
  }()

  private enum Failure: Error {
    case unexpectedUpstreamRole(caseID: String)
  }

  /// Apply the authorized role change to the frozen upstream body, keeping every other field.
  static func expectedBody(_ upstream: JSONValue, for caseID: String) throws -> JSONValue {
    guard let field = changedFirstRoleFields[caseID] else { return upstream }
    guard var body = upstream.objectValue, var items = body.array(field),
      var first = items.first?.objectValue, first.string("role") == "developer"
    else {
      throw Failure.unexpectedUpstreamRole(caseID: caseID)
    }
    first["role"] = .string("system")
    items[0] = .object(first)
    body[field] = .array(items)
    return .object(body)
  }
}
