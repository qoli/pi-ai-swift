import Foundation

@testable import PiAIProviderRuntime

@main
struct SwiftConformanceProbe {
  static func main() async throws {
    let interactive = CommandLine.arguments.contains("--stream")
    let data =
      interactive
      ? Data((readLine() ?? "").utf8) : FileHandle.standardInput.readDataToEndOfFile()
    do {
      try await execute(data, interactive: interactive)
    } catch let error as ProviderRuntimeFailure {
      if interactive {
        try ProbeChannel().write("finished", project(error))
        return
      }
      FileHandle.standardOutput.write(
        try JSONEncoder().encode(
          ProbeOutput(request: nil, pending: false, events: [], failure: project(error))))
    } catch ProbeError.unrepresentable(let capability) {
      let failure: [String: JSONValue] = [
        "code": .string("unsupportedCapability"), "operation": .string("conformance.input"),
        "message": .string(
          "Swift ProviderRequest cannot preserve this upstream fixture: " + capability),
        "unrepresentedCapability": .string(capability),
      ]
      if interactive {
        try ProbeChannel().write("finished", failure)
      } else {
        FileHandle.standardOutput.write(
          try JSONEncoder().encode(
            ProbeOutput(request: nil, pending: false, events: [], failure: failure)))
      }
    }
  }

  private static func execute(_ data: Data, interactive: Bool) async throws {
    let envelope = try JSONDecoder().decode([String: JSONValue].self, from: data)
    if envelope.string("operation") == "catalog" {
      let registry = try BuiltinProviderRegistry.load()
      var catalog: [String: [String: JSONValue]] = [:]
      for provider in registry.providers {
        for model in provider.models {
          let route = ProviderModelRoute(modelID: model.id, outputModality: .text)
          guard let config = provider.modelConfigurations[route] else { continue }
          var raw = config.metadata
          raw["id"] = .string(model.id)
          raw["name"] = .string(model.name)
          raw["provider"] = .string(provider.id)
          raw["api"] = .string(model.protocolID)
          if let base = config.baseURL ?? provider.baseURL { raw["baseUrl"] = .string(base) }
          catalog[provider.id + "/" + model.id] = raw
        }
      }
      FileHandle.standardOutput.write(try JSONEncoder().encode(catalog))
      return
    }
    let input = try JSONDecoder().decode(ProbeInput.self, from: data)
    let model = input.model
    let api = try model.required("api")
    let provider = try model.required("provider")
    let modelID = try model.required("id")
    let options = input.options
    if envelope.string("operation") == "google-thinking-level" {
      let rawEffort = try options.required("reasoningEffort")
      guard let effort = ProviderReasoningEffort(rawValue: rawEffort) else {
        throw ProbeError.unrepresentable("unknown-reasoning-level")
      }
      let resolved = try GoogleGenerativeAIAdapter.resolveThinkingLevel(
        effort: effort, providerID: provider, modelID: modelID, metadata: model)
      FileHandle.standardOutput.write(try JSONEncoder().encode(resolved))
      return
    }
    let providerModel = ProviderModel(
      id: modelID, providerID: provider, name: model.string("name") ?? modelID,
      protocolID: api,
      capabilities: .init(
        textInput: true, imageInput: model.array("input")?.contains(.string("image")) == true,
        toolCalling: true, reasoning: model.bool("reasoning") == true,
        structuredOutput: true, imageGeneration: false),
      contextWindow: model.int("contextWindow"), maximumOutputTokens: model.int("maxTokens"),
      supportedReasoningEfforts: try ProviderReasoning.supportedEfforts(
        reasoning: model.bool("reasoning") == true, metadata: model,
        protocolID: api, providerID: provider, modelID: modelID,
        modelName: model.string("name") ?? modelID))
    if envelope.string("operation") == "reasoning-levels" {
      FileHandle.standardOutput.write(
        try JSONEncoder().encode(providerModel.supportedReasoningEfforts))
      return
    }
    var messages: [ProviderMessage] = []
    if let system = input.context.systemPrompt, !system.isEmpty { messages.append(.system(system)) }
    messages += try input.context.messages.map(message)
    let tools = try input.context.tools.map { tool in
      ProviderToolDefinition(
        name: try tool.required("name"), description: tool.string("description") ?? "",
        inputSchema: tool["parameters"] ?? .object([:]),
        constrainedSampling: try sampling(tool.object("constrainedSampling")))
    }
    let usesRawMistralOptions = api == "mistral-conversations" && input.generationMode != .simple
    let usesRawAnthropicOptions = api == "anthropic-messages" && input.generationMode != .simple
    let usesRawBedrockOptions = api == "bedrock-converse-stream" && input.generationMode != .simple
    let usesRawCompletionsOptions = api == "openai-completions" && input.generationMode != .simple
    let effort =
      usesRawMistralOptions || usesRawAnthropicOptions || usesRawBedrockOptions
        || usesRawCompletionsOptions
      ? nil
      : (options.string("reasoningEffort") ?? options.string("reasoning")
        ?? (options.bool("thinkingEnabled") == false ? "off" : nil))
    let mappedOptions: Set<String> = [
      "apiKey", "headers", "signal", "fetch", "client", "maxRetries", "maxRetryDelayMs", "timeout",
      "timeoutMs", "websocketConnectTimeoutMs", "identity", "telemetry", "transport", "project",
      "location",
      "maxTokens", "temperature", "reasoningEffort", "reasoning", "thinkingEnabled",
      "thinkingBudgetTokens", "reasoningSummary", "responseSchema", "sessionId", "cacheRetention",
      "serviceTier", "toolChoice", "thinkingBudgets", "textVerbosity", "env",
      "azureBaseUrl", "azureResourceName", "azureApiVersion", "azureDeploymentName", "region",
    ]
    var providerOptions = options.filter { !mappedOptions.contains($0.key) }
    if api == "mistral-conversations" {
      for key in ["headers", "timeoutMs"] {
        if let value = options[key] { providerOptions[key] = value }
      }
      if usesRawMistralOptions {
        providerOptions["reasoningEffort"] = options["reasoningEffort"] ?? .null
      }
    }
    if usesRawAnthropicOptions {
      for key in ["thinkingEnabled", "thinkingBudgetTokens", "effort"] {
        providerOptions[key] = options[key] ?? .null
      }
    }
    if usesRawBedrockOptions { providerOptions["reasoning"] = options["reasoning"] ?? .null }
    if usesRawCompletionsOptions {
      providerOptions["reasoningEffort"] = options["reasoningEffort"] ?? .null
    }
    let request = ProviderRequest(
      id: "upstream-conformance", providerID: provider, modelID: modelID,
      messages: messages, tools: tools,
      options: .init(
        maximumOutputTokens: options.int("maxTokens"),
        temperature: options["temperature"].flatMap(number),
        reasoningEffort: effort.flatMap(ProviderReasoningEffort.init(rawValue:)),
        reasoningSummary: options.string("reasoningSummary"),
        responseSchema: options["responseSchema"], providerOptions: providerOptions,
        sessionID: options.string("sessionId"),
        cacheRetention: options.string("cacheRetention").flatMap(
          ProviderCacheRetention.init(rawValue:)) ?? .short,
        serviceTier: options.string("serviceTier"), toolChoice: options["toolChoice"],
        thinkingBudgets: options.object("thinkingBudgets").map {
          Dictionary(
            uniqueKeysWithValues: $0.compactMap { key, value -> (ProviderReasoningEffort, Int)? in
              guard let effort = ProviderReasoningEffort(rawValue: key),
                case .integer(let budget) = value
              else { return nil }
              return (effort, Int(budget))
            })
        },
        textVerbosity: options.string("textVerbosity")),
      connectionOptions: .init(
        azureOpenAIResponses: api == "azure-openai-responses"
          ? .init(
            azureBaseURL: options.string("azureBaseUrl"),
            azureResourceName: options.string("azureResourceName"),
            azureAPIVersion: options.string("azureApiVersion"),
            azureDeploymentName: options.string("azureDeploymentName"),
            environment: input.environment) : nil))
    let headers = (options.object("headers") ?? [:]).compactMapValues(\.stringValue)
    let credential: ProviderCredential?
    if api == "google-vertex", input.credential.key == nil {
      credential = .oauth(
        .init(
          accessToken: "test", refreshToken: "test", expiresAt: .distantFuture,
          metadata: [
            "projectID": options.string("project") ?? input.environment["GOOGLE_CLOUD_PROJECT"]
              ?? "",
            "location": options.string("location") ?? input.environment["GOOGLE_CLOUD_LOCATION"]
              ?? "",
          ]))
    } else if let key = input.credential.key {
      credential = .apiKey(.init(key: key, metadata: input.credential.metadata))
    } else {
      credential = nil
    }
    let responses = input.responses ?? []
    let fixtureTransport = ProbeTransport(responses: responses, aborted: input.aborted == true)
    let channel = ProbeChannel()
    let liveTransport = InteractiveProbeTransport(channel: channel)
    let transport: any ProviderHTTPStreamingTransport =
      interactive ? liveTransport : fixtureTransport
    let authorization: any ProviderAuthorizationAdapter
    if input.requestSource == "provider",
      CloudflareAuthorizationAdapter.providerIDs.contains(provider),
      options.string("apiKey")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
      options.object("headers")?.string("cf-aig-authorization") == nil
    {
      authorization = CloudflareAuthorizationAdapter(providerID: provider, methodID: "api-key")
    } else {
      authorization = FixtureAuthorization()
    }
    let runtime = try ProviderRuntimeKernel(
      catalogRevision: "upstream-conformance",
      providers: [
        .init(
          descriptor: .init(
            id: provider, name: provider, authorizationMethods: [], models: [providerModel]),
          baseURL: model.string("baseUrl"),
          headers: (model.object("headers") ?? [:]).compactMapValues(\.stringValue),
          modelConfigurations: [
            .init(modelID: modelID, outputModality: .text): .init(
              protocolID: api, baseURL: nil, headers: headers, metadata: model)
          ],
          credentialRequirement: credential == nil ? .none : .required,
          endpointPolicy: .httpOrHTTPS,
          authorization: authorization)
      ],
      wireProtocols: StandardWireProtocols.make(),
      credentialStore: InMemoryProviderCredentialStore(
        credentials: credential.map { [provider: $0] } ?? [:]),
      transport: transport)
    let execution = Task {
      var events: [ProviderEvent] = []
      var failure: [String: JSONValue]?
      do {
        for try await event in runtime.stream(request) {
          if interactive {
            try channel.write("event", event)
          } else {
            events.append(event)
          }
        }
        if interactive && Task.isCancelled { failure = ["code": .string("cancelled")] }
      } catch is CancellationError {
        if interactive || input.aborted == true { failure = ["code": .string("cancelled")] }
      } catch let error as ProviderRuntimeFailure {
        failure = project(error)
      } catch {
        failure = [
          "code": .string("transportFailed"), "message": .string(String(describing: error)),
        ]
      }
      return (events, failure)
    }
    if interactive {
      Task.detached {
        while let line = readLine() {
          do {
            let frame = try JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8))
            if frame.string("kind") == "cancel" { execution.cancel() }
            try await liveTransport.receive(frame)
          } catch {
            await liveTransport.fail(error)
          }
        }
        await liveTransport.fail(ProbeError.unsupported("fixture transport closed"))
      }
    }
    let (events, failure) = await execution.value
    if interactive {
      try channel.write("finished", failure)
      return
    }
    let requests = await fixtureTransport.requests
    let captured = requests.last
    let output = ProbeOutput(
      request: try captured.map {
        .init(
          url: $0.url!.absoluteString, headers: $0.allHTTPHeaderFields ?? [:],
          body: try JSONDecoder().decode(JSONValue.self, from: $0.httpBody ?? Data("null".utf8)))
      }, pending: requests.count > responses.count && input.aborted != true, events: events,
      failure: failure)
    FileHandle.standardOutput.write(try JSONEncoder().encode(output))
  }

  private static func project(_ error: ProviderRuntimeFailure) -> [String: JSONValue] {
    var result: [String: JSONValue] = [
      "code": .string(error.code.rawValue), "message": .string(error.message),
      "operation": error.operation.map(JSONValue.string) ?? .null,
      "cause": error.causeDescription.map(JSONValue.string) ?? .null,
    ]
    if let metadata = error.providerMetadata { result["providerMetadata"] = .object(metadata) }
    return result
  }

  private static func message(_ raw: [String: JSONValue]) throws -> ProviderMessage {
    switch try raw.required("role") {
    case "user":
      let content = try userContent(raw["content"])
      if let timestamp = raw.int("timestamp") {
        return .userMessage(.init(content: content, timestampMilliseconds: Int64(timestamp)))
      }
      return .user(content)
    case "assistant":
      let content = try (raw.array("content") ?? []).map { value -> ProviderAssistantContent in
        guard let block = value.objectValue else { throw ProbeError.unsupported("assistant block") }
        switch try block.required("type") {
        case "text":
          return .signedText(
            .init(text: block.string("text") ?? "", signature: block.string("textSignature")))
        case "thinking":
          return .reasoning(
            .init(
              text: block.string("thinking") ?? "", signature: block.string("thinkingSignature"),
              isRedacted: block.bool("redacted"), providerMetadata: [:]))
        case "toolCall":
          return .toolCall(
            .init(
              id: try block.required("id"), name: try block.required("name"),
              arguments: block["arguments"] ?? .object([:]),
              thoughtSignature: block.string("thoughtSignature"),
              namespace: block.string("namespace"), argumentsError: block.string("argumentsError")))
        default: throw ProbeError.unsupported("assistant content")
        }
      }
      let usage = raw.object("usage") ?? [:]
      let cost = try usage["cost"].map {
        try JSONDecoder().decode(ProviderUsageCost.self, from: JSONEncoder().encode($0))
      }
      var metadata: [String: JSONValue] = [:]
      for key in ["providerThinkingLevel", "providerServiceTier", "phase"] {
        metadata[key] = raw[key]
      }
      return .assistantMessage(
        .init(
          content: content,
          source: .init(
            api: try raw.required("api"), providerID: try raw.required("provider"),
            modelID: try raw.required("model")),
          responseID: raw.string("responseId"), responseModelID: raw.string("responseModel"),
          usage: .init(
            inputTokens: usage.int("input"), outputTokens: usage.int("output"),
            reasoningTokens: usage.int("reasoning"),
            cachedInputTokens: usage.int("cacheRead"),
            cacheWriteTokens: usage.int("cacheWrite"), totalTokens: usage.int("totalTokens"),
            providerMetadata: [:], cost: cost),
          stopReason: ProviderAssistantStopReason(rawValue: raw.string("stopReason") ?? "stop")!,
          rawStopReason: raw.string("rawStopReason"),
          timestampMilliseconds: Int64(raw.int("timestamp") ?? 0),
          providerMetadata: metadata))
    case "toolResult":
      return .toolResult(
        .init(
          toolCallID: try raw.required("toolCallId"), toolName: try raw.required("toolName"),
          content: try userContent(raw["content"]).map {
            switch $0 {
            case .text(let text): return .text(text)
            case .image(let image): return .image(image)
            }
          }, isError: raw.bool("isError") ?? false,
          timestampMilliseconds: raw.int("timestamp").map(Int64.init)))
    default: throw ProbeError.unsupported("message role")
    }
  }

  private static func userContent(_ raw: JSONValue?) throws -> [ProviderUserContent] {
    if let text = raw?.stringValue { return [.text(text)] }
    guard case .array(let values) = raw else { return [] }
    return try values.map { value in
      guard let block = value.objectValue else { throw ProbeError.unsupported("user block") }
      switch try block.required("type") {
      case "text": return .text(block.string("text") ?? "")
      case "image":
        let encoded = try block.required("data")
        let padding = (4 - encoded.utf8.count % 4) % 4
        guard let data = Data(base64Encoded: encoded + String(repeating: "=", count: padding))
        else {
          throw ProbeError.unrepresentable("opaque-base64-image")
        }
        return .image(.data(data, mimeType: try block.required("mimeType")))
      default: throw ProbeError.unsupported("user content")
      }
    }
  }

  private static func sampling(_ raw: [String: JSONValue]?) throws -> ProviderConstrainedSampling? {
    guard let raw else { return nil }
    switch try raw.required("type") {
    case "json_schema":
      return .jsonSchema(strict: ProviderStrictPreference(rawValue: try raw.required("strict"))!)
    case "grammar":
      return .grammar(variants: (raw.object("variants") ?? [:]).compactMapValues(\.stringValue))
    default: throw ProbeError.unsupported("constrained sampling")
    }
  }

  private static func number(_ value: JSONValue) -> Double? {
    switch value {
    case .integer(let value): return Double(value)
    case .number(let value): return value
    default: return nil
    }
  }
}

private enum ProbeGenerationMode: String, Decodable {
  case raw
  case simple
}

private struct ProbeInput: Decodable {
  let model: [String: JSONValue]
  let requestSource: String?
  let generationMode: ProbeGenerationMode?
  let context: Context
  let options: [String: JSONValue]
  let credential: Credential
  let environment: [String: String]
  let responses: [Response]?
  let aborted: Bool?
  struct Context: Decodable {
    let systemPrompt: String?
    let messages: [[String: JSONValue]]
    let tools: [[String: JSONValue]]
  }
  struct Credential: Decodable {
    let key: String?
    let metadata: [String: String]
  }
  struct Response: Decodable, Sendable {
    let status: Int
    let headers: [String: String]
    let chunks: [String]
  }
}

private struct ProbeOutput: Encodable {
  let request: Request?
  let pending: Bool
  let events: [ProviderEvent]
  let failure: [String: JSONValue]?
  struct Request: Encodable {
    let url: String
    let headers: [String: String]
    let body: JSONValue
  }
}

private final class ProbeChannel: @unchecked Sendable {
  private let lock = NSLock()

  private struct Frame<Payload: Encodable>: Encodable {
    let kind: String
    let payload: Payload
  }

  func write<T: Encodable>(_ kind: String, _ payload: T) throws {
    var data = try JSONEncoder().encode(Frame(kind: kind, payload: payload))
    data.append(10)
    lock.withLock { FileHandle.standardOutput.write(data) }
  }
}

private actor InteractiveProbeTransport: ProviderHTTPStreamingTransport {
  let channel: ProbeChannel
  private var response: CheckedContinuation<ProviderHTTPStreamingResponse, any Error>?
  private var body: AsyncThrowingStream<Data, any Error>.Continuation?

  init(channel: ProbeChannel) { self.channel = channel }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    let captured = ProbeOutput.Request(
      url: request.url!.absoluteString, headers: request.allHTTPHeaderFields ?? [:],
      body: try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data("null".utf8)))
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        response = continuation
        do { try channel.write("request", captured) } catch { fail(error) }
      }
    } onCancel: {
      Task { await self.cancelRequest() }
    }
  }

  private func cancelRequest() {
    guard response != nil else { return }
    do { try channel.write("cancelRequest", [String: JSONValue]()) } catch {
      fail(error)
      return
    }
    fail(CancellationError())
  }

  func receive(_ frame: [String: JSONValue]) throws {
    switch frame.string("kind") {
    case "response":
      let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
      body = continuation
      response?.resume(
        returning: .init(
          statusCode: frame.int("status")!,
          headers: (frame.object("headers") ?? [:]).compactMapValues(\.stringValue),
          body: stream))
      response = nil
    case "chunk":
      guard let value = frame.string("data"), let data = Data(base64Encoded: value) else {
        throw ProbeError.unsupported("fixture chunk")
      }
      body?.yield(data)
    case "end":
      body?.finish()
      body = nil
    case "cancel": fail(CancellationError())
    case "failure":
      fail(
        ProviderRuntimeFailure(
          code: .transportFailed, message: frame.string("message") ?? "fixture transport failed",
          providerID: nil, operation: "conformance.transport", causeDescription: nil))
    default: throw ProbeError.unsupported("fixture frame")
    }
  }

  func fail(_ error: any Error) {
    response?.resume(throwing: error)
    response = nil
    body?.finish(throwing: error)
    body = nil
  }
}

private actor ProbeTransport: ProviderHTTPStreamingTransport {
  let responses: [ProbeInput.Response]
  let aborted: Bool
  var requests: [URLRequest] = []
  init(responses: [ProbeInput.Response], aborted: Bool) {
    self.responses = responses
    self.aborted = aborted
  }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    requests.append(request)
    if aborted && requests.count >= responses.count {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    guard requests.count <= responses.count else { throw CancellationError() }
    let response = responses[requests.count - 1]
    return .init(
      statusCode: response.status, headers: response.headers,
      body: AsyncThrowingStream { continuation in
        for chunk in response.chunks {
          guard let data = Data(base64Encoded: chunk) else {
            continuation.finish(throwing: ProbeError.unsupported("response chunk"))
            return
          }
          continuation.yield(data)
        }
        continuation.finish()
      })
  }
}

private enum ProbeError: Error {
  case unsupported(String)
  case unrepresentable(String)
}

private struct FixtureAuthorization: ProviderAuthorizationAdapter {
  func authorize(
    _ operation: AuthorizationOperation, interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    throw ProbeError.unsupported("authorization lifecycle fixture")
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func required(_ key: String) throws -> String {
    guard let value = string(key) else { throw ProbeError.unsupported(key) }
    return value
  }
}
