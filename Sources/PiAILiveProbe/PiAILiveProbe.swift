import Foundation
import PiAIProviderRuntime

@main
struct PiAILiveProbe {
  static func main() async {
    do {
      let configuration = try LiveConfiguration.environment()
      let store = InMemoryProviderCredentialStore(
        credentials: [configuration.providerID: configuration.credential]
      )
      let runtime = try BuiltinProviderRuntime(credentialStore: store)
      let catalog = try await runtime.catalog()
      guard
        let provider = catalog.providers.first(where: {
          $0.id == configuration.providerID
        }),
        provider.models.contains(where: { $0.id == configuration.modelID })
      else {
        throw LiveProbeFailure("configured provider or model is absent from the catalog")
      }

      let text = try await runText(
        runtime: runtime,
        configuration: configuration
      )
      let tool = try await runTool(
        runtime: runtime,
        configuration: configuration
      )

      print("PI_AI_LIVE_PROBE_SUCCEEDED")
      print("provider=\(configuration.providerID)")
      print("model=\(configuration.modelID)")
      print("text_response_started=\(text.responseStarted)")
      print("text_delta_count=\(text.textDeltaCount)")
      print("text_usage_present=\(text.usagePresent)")
      print("text_completed=\(text.completed)")
      print("tool_response_started=\(tool.responseStarted)")
      print("tool_call_completed=\(tool.toolCallCompleted)")
      print("tool_arguments_valid=\(tool.argumentsValid)")
      print("tool_usage_present=\(tool.usagePresent)")
      print("tool_completed=\(tool.completed)")
    } catch let error as ProviderRuntimeFailure {
      print("PI_AI_LIVE_PROBE_FAILED")
      print("code=\(error.code.rawValue)")
      print("operation=\(error.operation ?? "unknown")")
      print("message=\(error.message)")
      if let summary = SafeProviderError.summary(error.causeDescription) {
        print("provider_error=\(summary)")
      }
      Foundation.exit(EXIT_FAILURE)
    } catch let error as LiveProbeFailure {
      print("PI_AI_LIVE_PROBE_FAILED")
      print("code=probe_validation_failed")
      print("message=\(error.message)")
      Foundation.exit(EXIT_FAILURE)
    } catch {
      print("PI_AI_LIVE_PROBE_FAILED")
      print("code=unexpected")
      print("error_type=\(String(reflecting: type(of: error)))")
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func runText(
    runtime: BuiltinProviderRuntime,
    configuration: LiveConfiguration
  ) async throws -> TextEvidence {
    let request = ProviderRequest(
      id: UUID().uuidString,
      providerID: configuration.providerID,
      modelID: configuration.modelID,
      messages: [
        .system("Answer directly and briefly."),
        .user([.text("Reply with a short greeting.")]),
      ],
      tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 64,
        temperature: configuration.providerID == "openai-codex" ? nil : 0,
        reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: [:]
      )
    )
    var evidence = TextEvidence()
    for try await event in runtime.stream(request) {
      switch event {
      case .responseStarted: evidence.responseStarted = true
      case .textDelta(let delta) where !delta.isEmpty:
        evidence.textDeltaCount += 1
      case .usage: evidence.usagePresent = true
      case .completed: evidence.completed = true
      default: break
      }
    }
    guard evidence.responseStarted, evidence.textDeltaCount > 0, evidence.completed else {
      throw LiveProbeFailure("text stream did not produce a complete response")
    }
    return evidence
  }

  private static func runTool(
    runtime: BuiltinProviderRuntime,
    configuration: LiveConfiguration
  ) async throws -> ToolEvidence {
    let toolChoice: JSONValue
    let providerOptions: [String: JSONValue]
    if configuration.providerID == "kimi-coding" {
      toolChoice = .null
      providerOptions = [
        "tool_choice": .object([
          "type": .string("auto")
        ])
      ]
    } else {
      toolChoice = .object([
        "type": .string("function"),
        "name": .string("echo"),
      ])
      providerOptions = [:]
    }
    let request = ProviderRequest(
      id: UUID().uuidString,
      providerID: configuration.providerID,
      modelID: configuration.modelID,
      messages: [
        .system("Use the required tool exactly once."),
        .user([.text("Call echo with value live-ok.")]),
      ],
      tools: [
        ProviderToolDefinition(
          name: "echo",
          description: "Echo a required test value",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
              "value": .object(["type": .string("string")])
            ]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false),
          ])
        )
      ],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 128,
        temperature: configuration.providerID == "openai-codex" ? nil : 0,
        reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: providerOptions,
        toolChoice: toolChoice == .null ? nil : toolChoice
      )
    )
    var evidence = ToolEvidence()
    for try await event in runtime.stream(request) {
      switch event {
      case .responseStarted: evidence.responseStarted = true
      case .toolCallCompleted(let call):
        evidence.toolCallCompleted = call.name == "echo"
        if case .object(let arguments) = call.arguments {
          evidence.argumentsValid = arguments["value"] == .string("live-ok")
        }
      case .usage: evidence.usagePresent = true
      case .completed: evidence.completed = true
      default: break
      }
    }
    guard evidence.responseStarted, evidence.toolCallCompleted,
      evidence.argumentsValid, evidence.completed
    else {
      throw LiveProbeFailure("tool stream did not produce the required call")
    }
    return evidence
  }
}

private struct LiveConfiguration {
  let providerID: String
  let modelID: String
  let credential: ProviderCredential

  static func environment() throws -> LiveConfiguration {
    let environment = ProcessInfo.processInfo.environment
    guard let providerID = environment["PI_AI_LIVE_PROVIDER"] else {
      throw LiveProbeFailure("PI_AI_LIVE_PROVIDER is required")
    }
    switch providerID {
    case "kimi-coding":
      guard let key = environment["PI_AI_LIVE_API_KEY"], !key.isEmpty else {
        throw LiveProbeFailure("PI_AI_LIVE_API_KEY is required")
      }
      return LiveConfiguration(
        providerID: providerID,
        modelID: environment["PI_AI_LIVE_MODEL"] ?? "k3-256k",
        credential: .apiKey(APIKeyCredential(key: key, metadata: [:]))
      )
    case "openai-codex":
      guard
        let access = environment["PI_AI_LIVE_OAUTH_ACCESS_TOKEN"],
        !access.isEmpty,
        let refresh = environment["PI_AI_LIVE_OAUTH_REFRESH_TOKEN"],
        !refresh.isEmpty,
        let accountID = environment["PI_AI_LIVE_OAUTH_ACCOUNT_ID"],
        !accountID.isEmpty,
        let milliseconds = environment["PI_AI_LIVE_OAUTH_EXPIRES_MS"].flatMap(Double.init)
      else {
        throw LiveProbeFailure("complete OpenAI OAuth environment is required")
      }
      return LiveConfiguration(
        providerID: providerID,
        modelID: environment["PI_AI_LIVE_MODEL"] ?? "gpt-5.4-mini",
        credential: .oauth(
          OAuthCredential(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date(timeIntervalSince1970: milliseconds / 1_000),
            metadata: ["accountID": accountID]
          ))
      )
    default:
      throw LiveProbeFailure("unsupported live provider")
    }
  }
}

private struct TextEvidence {
  var responseStarted = false
  var textDeltaCount = 0
  var usagePresent = false
  var completed = false
}

private struct ToolEvidence {
  var responseStarted = false
  var toolCallCompleted = false
  var argumentsValid = false
  var usagePresent = false
  var completed = false
}

private struct LiveProbeFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

private enum SafeProviderError {
  static func summary(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let candidate =
      raw.split(separator: "\n")
      .first(where: { $0.hasPrefix("data:") })
      .map { String($0.dropFirst("data:".count)) }
      ?? raw
    guard let data = candidate.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else { return "unstructured_response" }
    let error = object["error"] as? [String: Any] ?? object
    let fields = ["type", "code", "message", "error", "detail"]
      .compactMap { key -> String? in
        guard let value = error[key] as? String else { return nil }
        return "\(key)=\(redact(value))"
      }
    return fields.isEmpty ? nil : fields.joined(separator: ";")
  }

  private static func redact(_ value: String) -> String {
    let limited = String(value.prefix(300))
    return limited.replacingOccurrences(
      of: #"(?:sk-[A-Za-z0-9_-]{8,}|Bearer\s+[A-Za-z0-9._-]{8,})"#,
      with: "[redacted]",
      options: .regularExpression
    )
  }
}
