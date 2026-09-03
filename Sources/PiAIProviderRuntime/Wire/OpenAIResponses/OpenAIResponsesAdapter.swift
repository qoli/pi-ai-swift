import Foundation

struct OpenAIResponsesAdapter: WireProtocolAdapter {
  enum Flavor: Sendable, Equatable {
    case standard
    case azure
    case codex
  }

  let protocolID: String
  let flavor: Flavor

  init(
    protocolID: String = "openai-responses",
    flavor: Flavor = .standard
  ) {
    self.protocolID = protocolID
    self.flavor = flavor
  }

  func stream(
    _ request: ProviderRequest,
    context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport
  ) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let response = try await transport.stream(
            try makeURLRequest(request, context: context)
          )
          guard (200..<300).contains(response.statusCode) else {
            let body = try await collectErrorBody(from: response.body)
            throw failure(
              .transportFailed,
              providerID: request.providerID,
              operation: "openai-responses.response",
              message: "OpenAI Responses request failed (HTTP \(response.statusCode))",
              cause: body
            )
          }
          var decoder = ServerSentEventDecoder()
          var reducer = OpenAIResponsesReducer(
            providerID: request.providerID,
            requestedModelID: request.modelID,
            acceptsCodexTerminalAliases: flavor == .codex
          )
          for try await chunk in response.body {
            try Task.checkCancellation()
            for event in try decoder.append(chunk) {
              for normalized in try reducer.reduce(event) {
                continuation.yield(normalized)
              }
            }
          }
          for event in try decoder.finish() {
            for normalized in try reducer.reduce(event) {
              continuation.yield(normalized)
            }
          }
          try reducer.validateTerminal()
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func makeURLRequest(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> URLRequest {
    var urlRequest = URLRequest(url: try endpoint(context: context))
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (name, value) in context.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    applyGitHubCopilotHeaders(
      providerID: request.providerID,
      messages: request.messages,
      to: &urlRequest
    )
    switch (flavor, context.credential) {
    case (.azure, .apiKey(let credential)):
      urlRequest.setValue(credential.key, forHTTPHeaderField: "api-key")
    case (.codex, .oauth(let credential)):
      urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
      guard let accountID = credential.metadata["accountID"], !accountID.isEmpty else {
        throw failure(
          .invalidCredential,
          providerID: request.providerID,
          operation: "openai-responses.request.auth",
          message: "OpenAI Codex credential is missing accountID"
        )
      }
      urlRequest.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
      urlRequest.setValue("pi", forHTTPHeaderField: "originator")
      urlRequest.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
      if let sessionID = codexSessionID(request.options) {
        urlRequest.setValue(sessionID, forHTTPHeaderField: "session-id")
        urlRequest.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
      }
    case (_, .apiKey(let credential)):
      urlRequest.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
    case (_, .oauth(let credential)):
      urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    case (_, nil):
      throw failure(
        .missingCredential,
        providerID: request.providerID,
        operation: "openai-responses.request.auth",
        message: "OpenAI Responses credential is missing"
      )
    }
    urlRequest.httpBody = try encodeJSONObject(
      try makeBody(request, context: context),
      providerID: request.providerID,
      operation: "openai-responses.request.encode"
    )
    return urlRequest
  }

  private func endpoint(context: WireProtocolContext) throws -> URL {
    switch flavor {
    case .standard:
      return context.baseURL.appending(path: "responses")
    case .azure:
      var components = URLComponents(
        url: context.baseURL.appending(path: "responses"),
        resolvingAgainstBaseURL: false
      )
      let metadata = credentialMetadata(context.credential)
      components?.queryItems = [
        URLQueryItem(
          name: "api-version",
          value: metadata["apiVersion"] ?? "v1"
        )
      ]
      guard let url = components?.url else {
        throw failure(
          .invalidRequest,
          providerID: context.provider.id,
          operation: "azure-openai-responses.request.url",
          message: "Azure OpenAI Responses URL is invalid"
        )
      }
      return url
    case .codex:
      let normalized = context.baseURL.absoluteString.trimmingCharacters(
        in: CharacterSet(charactersIn: "/")
      )
      if normalized.hasSuffix("/codex/responses") {
        return context.baseURL
      }
      if normalized.hasSuffix("/codex") {
        return context.baseURL.appending(path: "responses")
      }
      return context.baseURL.appending(path: "codex/responses")
    }
  }

  private func makeBody(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: JSONValue] {
    if let effort = request.options.reasoningEffort {
      let supported = try ProviderReasoning.supportedEfforts(
        reasoning: context.model.capabilities.reasoning,
        metadata: context.modelConfiguration.metadata,
        protocolID: context.model.protocolID,
        providerID: context.model.providerID, modelID: context.model.id,
        modelName: context.model.name)
      guard supported.contains(effort) else {
        throw ProviderRuntimeFailure(
          code: .unsupportedCapability,
          message: "Model does not support the selected reasoning effort: \(effort.rawValue)",
          providerID: request.providerID, operation: "stream.validate-reasoning",
          causeDescription: nil)
      }
    }

    var body: [String: JSONValue] = [
      "model": .string(resolvedModelID(request, context: context)),
      "input": .array(try makeInput(request.messages)),
      "stream": .bool(true),
      "store": .bool(false),
    ]
    let instructions = request.messages.compactMap { message -> String? in
      guard case .system(let text) = message else { return nil }
      return text
    }
    if !instructions.isEmpty {
      body["instructions"] = .string(instructions.joined(separator: "\n\n"))
    }
    if flavor != .codex,
      let maximum = request.options.maximumOutputTokens
        ?? context.model.maximumOutputTokens
    {
      body["max_output_tokens"] = .integer(Int64(max(16, maximum)))
    }
    if let temperature = request.options.temperature {
      body["temperature"] = .number(temperature)
    }
    if let effort = request.options.reasoningEffort, context.model.capabilities.reasoning {
      let mapped = context.modelConfiguration.metadata
        .object("thinkingLevelMap")?.string(effort.rawValue)
      body["reasoning"] = .object([
        "effort": .string(mapped ?? (effort == .off ? "none" : effort.rawValue)),
        "summary": .string("auto"),
      ])
      body["include"] = .array([.string("reasoning.encrypted_content")])
    }
    if let serviceTier = request.options.serviceTier {
      body["service_tier"] = .string(serviceTier)
    }
    if let toolChoice = request.options.toolChoice {
      body["tool_choice"] = toolChoice
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map {
          .object([
            "type": .string("function"),
            "name": .string($0.name),
            "description": .string($0.description),
            "parameters": $0.inputSchema,
            "strict": .bool(true),
          ])
        }
      )
    }
    if let schema = request.options.responseSchema {
      body["text"] = .object([
        "format": .object([
          "type": .string("json_schema"),
          "name": .string("response"),
          "strict": .bool(true),
          "schema": schema,
        ])
      ])
    }
    if flavor == .codex {
      body["instructions"] = .string(
        instructions.isEmpty
          ? "You are a helpful assistant."
          : instructions.joined(separator: "\n\n")
      )
      body["text"] = .object(["verbosity": .string("low")])
      body["include"] = .array([.string("reasoning.encrypted_content")])
      body["tool_choice"] = request.options.toolChoice ?? .string("auto")
      body["parallel_tool_calls"] = .bool(true)
      if let sessionID = codexSessionID(request.options) {
        body["prompt_cache_key"] = .string(sessionID)
      }
    }
    for (key, value) in request.options.providerOptions {
      body[key] = value
    }
    return body
  }

  private func codexSessionID(
    _ options: ProviderGenerationOptions
  ) -> String? {
    guard flavor == .codex, options.cacheRetention != .none,
      let sessionID = options.sessionID,
      !sessionID.isEmpty
    else { return nil }
    return String(sessionID.prefix(64))
  }

  private func resolvedModelID(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) -> String {
    guard flavor == .azure else { return request.modelID }
    return credentialMetadata(context.credential)["deploymentName"]
      ?? request.modelID
  }

  private func credentialMetadata(
    _ credential: ProviderCredential?
  ) -> [String: String] {
    switch credential {
    case .apiKey(let credential): credential.metadata
    case .oauth(let credential): credential.metadata
    case nil: [:]
    }
  }

  private func makeInput(_ messages: [ProviderMessage]) throws -> [JSONValue] {
    try messages.compactMap { message in
      switch message {
      case .system:
        return nil
      case .user(let content):
        return .object([
          "role": .string("user"),
          "content": .array(try content.map(makeUserContent(_:))),
        ])
      case .assistant(let content):
        return .object([
          "role": .string("assistant"),
          "content": .array(
            content.compactMap { item in
              guard case .text(let text) = item else { return nil }
              return .object([
                "type": .string("output_text"), "text": .string(text),
              ])
            }
          ),
        ])
      case .toolResult(let result):
        let text = result.content.compactMap { item -> String? in
          guard case .text(let text) = item else { return nil }
          return text
        }.joined(separator: "\n")
        return .object([
          "type": .string("function_call_output"),
          "call_id": .string(result.toolCallID),
          "output": .string(text),
        ])
      }
    }
  }

  private func makeUserContent(_ content: ProviderUserContent) throws -> JSONValue {
    switch content {
    case .text(let text):
      .object(["type": .string("input_text"), "text": .string(text)])
    case .image(.data(let data, let mimeType)):
      .object([
        "type": .string("input_image"),
        "image_url": .string("data:\(mimeType);base64,\(data.base64EncodedString())"),
      ])
    case .image(.remoteURL(let url, _)):
      .object([
        "type": .string("input_image"),
        "image_url": .string(url.absoluteString),
      ])
    }
  }

  private func failure(
    _ code: ProviderRuntimeFailure.Code,
    providerID: String?,
    operation: String,
    message: String,
    cause: String? = nil
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: code,
      message: message,
      providerID: providerID,
      operation: operation,
      causeDescription: cause
    )
  }
}

private struct OpenAIResponsesReducer {
  let providerID: String
  let requestedModelID: String
  let acceptsCodexTerminalAliases: Bool
  private var started = false
  private var terminal = false
  private var tools: [String: ToolState] = [:]
  private var completedToolCall = false

  init(
    providerID: String,
    requestedModelID: String,
    acceptsCodexTerminalAliases: Bool
  ) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
    self.acceptsCodexTerminalAliases = acceptsCodexTerminalAliases
  }

  mutating func reduce(_ event: ServerSentEvent) throws -> [ProviderEvent] {
    let object = try decodeJSONObject(
      Data(event.data.utf8),
      providerID: providerID,
      operation: "openai-responses.event.decode"
    )
    guard let type = object.string("type") ?? event.event else {
      throw invalid("Responses event is missing type")
    }
    switch type {
    case "response.created", "response.in_progress":
      guard !started else { return [] }
      guard let response = object.object("response"), let id = response.string("id") else {
        throw invalid("response.created is missing response identity")
      }
      started = true
      return [
        .responseStarted(
          ProviderResponseMetadata(
            responseID: id,
            providerID: providerID,
            modelID: response.string("model") ?? requestedModelID,
            providerMetadata: [:]
          )
        )
      ]
    case "response.output_text.delta":
      guard let delta = object.string("delta") else { throw invalid("text delta is missing delta") }
      return [.textDelta(delta)]
    case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
      guard let delta = object.string("delta") else {
        throw invalid("reasoning delta is missing delta")
      }
      return [.reasoningDelta(delta)]
    case "response.output_item.added":
      guard let item = object.object("item"), item.string("type") == "function_call" else {
        return []
      }
      guard let id = item.string("id") ?? item.string("call_id"),
        let name = item.string("name")
      else { throw invalid("function call item is missing id or name") }
      tools[id] = ToolState(name: name, arguments: item.string("arguments") ?? "")
      return [.toolCallStarted(id: id, name: name)]
    case "response.function_call_arguments.delta":
      guard let id = object.string("item_id") ?? object.string("call_id"),
        let delta = object.string("delta"),
        var state = tools[id]
      else { throw invalid("function call delta has no matching item") }
      state.arguments += delta
      tools[id] = state
      return [.toolInputDelta(id: id, delta: delta)]
    case "response.output_item.done":
      guard let item = object.object("item"), let itemType = item.string("type") else {
        throw invalid("completed output item is missing type")
      }
      if itemType == "reasoning" {
        guard let encrypted = item.string("encrypted_content"), !encrypted.isEmpty else {
          return []
        }
        return [.reasoningSignatureDelta(encrypted)]
      }
      guard itemType == "function_call" else { return [] }
      guard let id = item.string("id") ?? item.string("call_id"),
        let state = tools.removeValue(forKey: id)
      else { throw invalid("completed function call has no matching item") }
      let raw = item.string("arguments") ?? state.arguments
      let arguments: JSONValue
      do {
        arguments = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
      } catch {
        throw invalid("function call arguments are malformed")
      }
      completedToolCall = true
      return [
        .toolCallCompleted(
          ProviderToolCall(id: id, name: state.name, arguments: arguments)
        )
      ]
    case "response.completed",
      "response.done"
    where type == "response.completed" || acceptsCodexTerminalAliases:
      guard let response = object.object("response") else {
        throw invalid("completed event is missing response")
      }
      terminal = true
      var events: [ProviderEvent] = []
      if let usage = response.object("usage") {
        events.append(
          .usage(
            ProviderUsage(
              inputTokens: usage.int("input_tokens"),
              outputTokens: usage.int("output_tokens"),
              reasoningTokens: usage.object("output_tokens_details")?.int("reasoning_tokens"),
              cachedInputTokens: usage.object("input_tokens_details")?.int("cached_tokens"),
              providerMetadata: usage
            )
          )
        )
      }
      events.append(.completed(completedToolCall ? .toolCalls : .stop))
      return events
    case "response.incomplete":
      terminal = true
      return [.completed(.length)]
    case "response.failed", "error":
      terminal = true
      let error = object.object("error") ?? object.object("response")?.object("error")
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: error?.string("message") ?? "OpenAI Responses stream failed",
        providerID: providerID,
        operation: "openai-responses.event.error",
        causeDescription: error?.string("code")
      )
    case "response.output_text.done", "response.content_part.added",
      "response.content_part.done",
      "response.function_call_arguments.done", "response.reasoning_summary_part.added",
      "response.reasoning_summary_part.done", "response.reasoning_summary_text.done":
      return []
    default:
      throw invalid("unsupported OpenAI Responses event: \(type)")
    }
  }

  func validateTerminal() throws {
    guard started, terminal else {
      throw invalid("OpenAI Responses stream ended without a terminal event")
    }
    guard tools.isEmpty else {
      throw invalid("OpenAI Responses stream ended with incomplete tool calls")
    }
  }

  private func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: providerID,
      operation: "openai-responses.event.reduce",
      causeDescription: nil
    )
  }

  private struct ToolState {
    let name: String
    var arguments: String
  }
}
