/// A caller-selected reasoning level. `nil` in generation options leaves the
/// provider default unchanged; `.off` explicitly requests disabled reasoning.
/// Use `ProviderModel.supportedReasoningEfforts` to build a model-specific picker.
public enum ProviderReasoningEffort: String, CaseIterable, Sendable, Hashable, Codable {
  case off
  case minimal
  case low
  case medium
  case high
  case xhigh
  case max
}

enum ProviderReasoning {
  /// Mirrors the pinned upstream getSupportedThinkingLevels contract, excluding
  /// settings for which the wire protocol cannot represent our explicit-off contract.
  static func supportedEfforts(
    reasoning: Bool,
    metadata: [String: JSONValue],
    protocolID: String = "",
    providerID: String = "",
    modelID: String = "",
    modelName: String = ""
  ) throws -> [ProviderReasoningEffort] {
    let map: [String: JSONValue]
    if let value = metadata["thinkingLevelMap"] {
      guard case .object(let object) = value else {
        throw invalidMap("thinkingLevelMap must be an object")
      }
      for (key, value) in object {
        guard ProviderReasoningEffort(rawValue: key) != nil else {
          throw invalidMap("unknown thinking level: \(key)")
        }
        switch value {
        case .null: break
        case .string(let wireValue) where !wireValue.isEmpty: break
        default: throw invalidMap("thinking level \(key) must map to a nonempty string or null")
        }
      }
      map = object
    } else {
      map = [:]
    }
    if protocolID == "openrouter-images" { return [] }
    guard reasoning else { return [.off] }
    let compat = metadata.object("compat") ?? [:]
    let format =
      compat.string("thinkingFormat") ?? (providerID == "openrouter" ? "openrouter" : "openai")
    if protocolID == "openai-completions" {
      let formats = [
        "openai", "zai", "deepseek", "qwen", "qwen-chat-template",
        "openrouter", "together", "string-thinking", "ant-ling", "chat-template", "baseten",
      ]
      guard formats.contains(format) else { return [] }
      if format == "openai", compat.bool("supportsReasoningEffort") == false { return [] }
    }
    if protocolID == "bedrock-converse-stream",
      ![modelID, modelName].contains(where: {
        $0.lowercased().contains("anthropic") || $0.lowercased().contains("claude")
      })
    {
      return []
    }
    return ProviderReasoningEffort.allCases.filter { effort in
      if map[effort.rawValue] == .null { return false }
      if protocolID == "anthropic-messages", compat.bool("forceAdaptiveThinking") != true,
        effort == .xhigh || effort == .max
      {
        return false
      }
      if ["google-generative-ai", "google-vertex"].contains(protocolID), effort != .off,
        let mapped = map[effort.rawValue]?.stringValue,
        !["minimal", "low", "medium", "high"].contains(mapped.lowercased())
      {
        return false
      }
      if effort == .off,
        [
          "openai-responses", "openai-codex-responses", "azure-openai-responses",
          "mistral-conversations",
        ].contains(protocolID),
        let mapped = map["off"]?.stringValue, mapped != "none"
      {
        return false
      }
      if protocolID == "openai-completions" {
        if ["chat-template", "baseten"].contains(format) {
          let template =
            compat.object(format == "baseten" ? "chatTemplateArgs" : "chatTemplateKwargs") ?? [:]
          if effort == .xhigh || effort == .max,
            template.values.contains(where: {
              if case .object(let variable) = $0 {
                return variable.string("$var") == "thinking.budget"
              }
              return false
            })
          {
            return false
          }
          let encodesControl = template.values.contains { value in
            guard case .object(let variable) = value else { return false }
            if effort == .off, variable.bool("omitWhenOff") == true { return false }
            switch variable.string("$var") {
            case "thinking.enabled": return true
            case "thinking.level": return effort != .off || map["off"]?.stringValue != nil
            case "thinking.budget": return effort != .off
            default: return false
            }
          }
          if !encodesControl
            && !(format == "baseten" && compat.bool("supportsReasoningEffort") != false
              && (effort != .off || map["off"]?.stringValue != nil))
          {
            return false
          }
        }
        if format == "openai", effort == .off, map["off"] == nil { return false }
        if format == "ant-ling", map[effort.rawValue] == nil { return false }
      }
      if effort == .off, protocolID == "bedrock-converse-stream" { return false }
      if effort == .off, protocolID == "mistral-conversations",
        !["mistral-small-2603", "mistral-small-latest", "mistral-medium-3.5"].contains(modelID)
      {
        return false
      }
      if effort == .off,
        ["google-generative-ai", "google-vertex"].contains(protocolID),
        modelID.lowercased().contains("gemini-3") || modelID.lowercased().contains("gemma-4")
          || modelID.lowercased().contains("gemini-2.5-pro")
          || ["gemini-flash-latest", "gemini-flash-lite-latest"].contains(modelID.lowercased())
      {
        return false
      }
      if effort == .xhigh || effort == .max { return map[effort.rawValue] != nil }
      return true
    }
  }

  private static func invalidMap(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidRequest, message: message, providerID: nil,
      operation: "catalog.reasoning", causeDescription: nil)
  }
}
