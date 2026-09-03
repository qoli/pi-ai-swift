import Foundation

struct OpenAICompletionsAdapter: WireProtocolAdapter {
  let protocolID = "openai-completions"

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
              operation: "openai-completions.response",
              message: "OpenAI Completions request failed (HTTP \(response.statusCode))",
              cause: body
            )
          }
          var decoder = ServerSentEventDecoder()
          var reducer = OpenAICompletionsReducer(
            providerID: request.providerID,
            requestedModelID: request.modelID
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
          for event in try reducer.finish() {
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func applyReasoning(
    _ effort: ProviderReasoningEffort,
    metadata: [String: JSONValue],
    compat: [String: JSONValue],
    body: inout [String: JSONValue],
    providerID: String
  ) throws {
    let enabled = effort != .off
    let mapped = metadata.object("thinkingLevelMap")?.string(effort.rawValue)
    let wireEffort = mapped ?? (enabled ? effort.rawValue : "none")
    let supportsEffort = compat.bool("supportsReasoningEffort") != false
    // These provider defaults are the pinned upstream compatibility resolution.
    let format =
      compat.string("thinkingFormat") ?? (providerID == "openrouter" ? "openrouter" : "openai")
    switch format {
    case "zai":
      body["thinking"] = .object(
        enabled
          ? ["type": .string("enabled"), "clear_thinking": .bool(false)]
          : ["type": .string("disabled")])
      if enabled && supportsEffort { body["reasoning_effort"] = .string(wireEffort) }
    case "deepseek":
      body["thinking"] = .object(["type": .string(enabled ? "enabled" : "disabled")])
      if enabled && supportsEffort { body["reasoning_effort"] = .string(wireEffort) }
    case "qwen":
      body["enable_thinking"] = .bool(enabled)
      if enabled && supportsEffort { body["reasoning_effort"] = .string(wireEffort) }
    case "qwen-chat-template":
      body["chat_template_kwargs"] = .object([
        "enable_thinking": .bool(enabled), "preserve_thinking": .bool(true),
      ])
    case "chat-template", "baseten":
      let key = format == "baseten" ? "chatTemplateArgs" : "chatTemplateKwargs"
      let field = format == "baseten" ? "chat_template_args" : "chat_template_kwargs"
      var values: [String: JSONValue] = [:]
      for (name, value) in compat.object(key) ?? [:] {
        guard case .object(let variable) = value else {
          values[name] = value
          continue
        }
        if !enabled && variable.bool("omitWhenOff") == true { continue }
        switch variable.string("$var") {
        case "thinking.enabled": values[name] = .bool(enabled)
        case "thinking.level":
          if enabled || mapped != nil { values[name] = .string(wireEffort) }
        case "thinking.budget":
          if enabled {
            let budgets: [ProviderReasoningEffort: Int] = [
              .minimal: 1_024, .low: 2_048, .medium: 8_192, .high: 16_384,
            ]
            guard let budget = budgets[effort] else {
              throw failure(
                .unsupportedCapability, providerID: providerID,
                operation: "openai-completions.request.reasoning",
                message: "reasoning budget requires a supported budget level")
            }
            guard let ceiling = body.int("max_tokens") ?? body.int("max_completion_tokens") else {
              throw failure(
                .invalidRequest, providerID: providerID,
                operation: "openai-completions.request.reasoning",
                message: "reasoning budget requires an output limit")
            }
            let clamped = min(budget, max(0, ceiling - 1_024))
            guard clamped > 0 else {
              throw failure(
                .invalidRequest, providerID: providerID,
                operation: "openai-completions.request.reasoning",
                message: "output limit leaves no room for reasoning")
            }
            values[name] = .integer(Int64(clamped))
          }
        default:
          throw failure(
            .unsupportedCapability, providerID: providerID,
            operation: "openai-completions.request.reasoning",
            message: "unknown reasoning template variable")
        }
      }
      guard !values.isEmpty || (format == "baseten" && supportsEffort && (enabled || mapped != nil))
      else {
        throw failure(
          .unsupportedCapability, providerID: providerID,
          operation: "openai-completions.request.reasoning",
          message: "reasoning template has no encodable control")
      }
      if !values.isEmpty { body[field] = .object(values) }
      if format == "baseten", supportsEffort, enabled || mapped != nil {
        body["reasoning_effort"] = .string(wireEffort)
      }
    case "openrouter":
      body["reasoning"] = .object(["effort": .string(wireEffort)])
    case "together":
      body["reasoning"] = .object(["enabled": .bool(enabled)])
      if enabled && supportsEffort { body["reasoning_effort"] = .string(wireEffort) }
    case "string-thinking":
      body["thinking"] = .string(wireEffort)
    case "ant-ling":
      guard let mapped else {
        throw failure(
          .unsupportedCapability, providerID: providerID,
          operation: "openai-completions.request.reasoning",
          message: "reasoning effort requires a model mapping")
      }
      body["reasoning"] = .object(["effort": .string(mapped)])
    case "openai":
      guard supportsEffort else {
        throw failure(
          .unsupportedCapability, providerID: providerID,
          operation: "openai-completions.request.reasoning",
          message: "model does not encode reasoning effort")
      }
      if !enabled && mapped == nil {
        throw failure(
          .unsupportedCapability, providerID: providerID,
          operation: "openai-completions.request.reasoning",
          message: "model has no explicit reasoning-off mapping")
      }
      body["reasoning_effort"] = .string(wireEffort)
    default:
      throw failure(
        .unsupportedCapability, providerID: providerID,
        operation: "openai-completions.request.reasoning",
        message: "unsupported reasoning format: \(format)")
    }
  }

  private func makeURLRequest(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> URLRequest {
    let endpoint = context.baseURL.appending(path: "chat/completions")
    var urlRequest = URLRequest(url: endpoint)
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
    switch context.credential {
    case .apiKey(let credential):
      urlRequest.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
    case .oauth(let credential):
      urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    case nil:
      throw failure(
        .missingCredential,
        providerID: request.providerID,
        operation: "openai-completions.request.auth",
        message: "OpenAI Completions credential is missing"
      )
    }
    urlRequest.httpBody = try encodeJSONObject(
      try makeBody(request, context: context),
      providerID: request.providerID,
      operation: "openai-completions.request.encode"
    )
    return urlRequest
  }

  private func makeBody(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: JSONValue] {
    let metadata = context.modelConfiguration.metadata
    let compat = metadata.object("compat") ?? [:]
    var body: [String: JSONValue] = [
      "model": .string(request.modelID),
      "messages": .array(try makeMessages(request.messages)),
      "stream": .bool(true),
      "stream_options": .object(["include_usage": .bool(true)]),
    ]
    if compat.bool("supportsStore") != false {
      body["store"] = .bool(false)
    }
    if let maximum = request.options.maximumOutputTokens
      ?? context.model.maximumOutputTokens
    {
      let field = compat.string("maxTokensField") ?? "max_completion_tokens"
      body[field] = .integer(Int64(maximum))
    }
    if let temperature = request.options.temperature {
      body["temperature"] = .number(temperature)
    }
    if let effort = request.options.reasoningEffort, context.model.capabilities.reasoning {
      try applyReasoning(
        effort, metadata: metadata, compat: compat, body: &body, providerID: request.providerID)
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map {
          .object([
            "type": .string("function"),
            "function": .object([
              "name": .string($0.name),
              "description": .string($0.description),
              "parameters": $0.inputSchema,
            ]),
          ])
        }
      )
    }
    if let schema = request.options.responseSchema {
      body["response_format"] = .object([
        "type": .string("json_schema"),
        "json_schema": .object([
          "name": .string("response"),
          "strict": .bool(true),
          "schema": schema,
        ]),
      ])
    }
    for (key, value) in request.options.providerOptions {
      body[key] = value
    }
    return body
  }

  private func makeMessages(_ messages: [ProviderMessage]) throws -> [JSONValue] {
    try messages.map { message in
      switch message {
      case .system(let text):
        return .object(["role": .string("system"), "content": .string(text)])
      case .user(let content):
        return .object([
          "role": .string("user"),
          "content": .array(try content.map(makeUserContent(_:))),
        ])
      case .assistant(let content):
        var object: [String: JSONValue] = ["role": .string("assistant")]
        let texts = content.compactMap { item -> String? in
          guard case .text(let text) = item else { return nil }
          return text
        }
        object["content"] = texts.isEmpty ? .null : .string(texts.joined())
        let reasoning = content.compactMap { item -> ProviderReasoningContent? in
          guard case .reasoning(let value) = item else { return nil }
          return value
        }
        if let first = reasoning.first {
          object["reasoning_content"] = .string(first.text)
        }
        let calls = content.compactMap { item -> ProviderToolCall? in
          guard case .toolCall(let call) = item else { return nil }
          return call
        }
        if !calls.isEmpty {
          object["tool_calls"] = .array(
            try calls.map {
              .object([
                "id": .string($0.id),
                "type": .string("function"),
                "function": .object([
                  "name": .string($0.name),
                  "arguments": .string(try jsonString($0.arguments)),
                ]),
              ])
            }
          )
        }
        return .object(object)
      case .toolResult(let result):
        let text = result.content.compactMap { content -> String? in
          guard case .text(let value) = content else { return nil }
          return value
        }.joined(separator: "\n")
        return .object([
          "role": .string("tool"),
          "tool_call_id": .string(result.toolCallID),
          "content": .string(text),
        ])
      }
    }
  }

  private func makeUserContent(_ content: ProviderUserContent) throws -> JSONValue {
    switch content {
    case .text(let text):
      .object(["type": .string("text"), "text": .string(text)])
    case .image(.data(let data, let mimeType)):
      .object([
        "type": .string("image_url"),
        "image_url": .object([
          "url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")
        ]),
      ])
    case .image(.remoteURL(let url, _)):
      .object([
        "type": .string("image_url"),
        "image_url": .object(["url": .string(url.absoluteString)]),
      ])
    }
  }

  private func jsonString(_ value: JSONValue) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw failure(
        .invalidRequest,
        providerID: nil,
        operation: "openai-completions.request.tool-call",
        message: "tool call arguments are not valid UTF-8 JSON"
      )
    }
    return string
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

private struct OpenAICompletionsReducer {
  let providerID: String
  let requestedModelID: String
  private var started = false
  private var terminal = false
  private var finishReason: ProviderFinishReason?
  private var toolCalls: [Int: ToolCallState] = [:]

  init(providerID: String, requestedModelID: String) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
  }

  mutating func reduce(_ event: ServerSentEvent) throws -> [ProviderEvent] {
    if event.data == "[DONE]" {
      terminal = true
      return []
    }
    let object = try decodeJSONObject(
      Data(event.data.utf8),
      providerID: providerID,
      operation: "openai-completions.event.decode"
    )
    var events: [ProviderEvent] = []
    if !started {
      guard let responseID = object.string("id") else {
        throw invalid("completion chunk is missing response id")
      }
      started = true
      events.append(
        .responseStarted(
          ProviderResponseMetadata(
            responseID: responseID,
            providerID: providerID,
            modelID: object.string("model") ?? requestedModelID,
            providerMetadata: [:]
          )
        )
      )
    }
    if let usage = object.object("usage") {
      events.append(
        .usage(
          ProviderUsage(
            inputTokens: usage.int("prompt_tokens"),
            outputTokens: usage.int("completion_tokens"),
            reasoningTokens: usage.object("completion_tokens_details")?.int("reasoning_tokens"),
            cachedInputTokens: usage.object("prompt_tokens_details")?.int("cached_tokens"),
            providerMetadata: usage
          )
        )
      )
    }
    for choiceValue in object.array("choices") ?? [] {
      guard let choice = choiceValue.objectValue else {
        throw invalid("completion choice is not an object")
      }
      if let reason = choice.string("finish_reason") {
        finishReason = try mapFinishReason(reason)
      }
      guard let delta = choice.object("delta") else { continue }
      if let text = delta.string("content"), !text.isEmpty {
        events.append(.textDelta(text))
      }
      for key in ["reasoning_content", "reasoning", "reasoning_text"] {
        if let text = delta.string(key), !text.isEmpty {
          events.append(.reasoningDelta(text))
        }
      }
      for toolValue in delta.array("tool_calls") ?? [] {
        guard let tool = toolValue.objectValue, let index = tool.int("index") else {
          throw invalid("tool call delta is malformed")
        }
        var state = toolCalls[index] ?? ToolCallState()
        if let id = tool.string("id") { state.id = id }
        if let function = tool.object("function") {
          if let name = function.string("name") { state.name = name }
          if let arguments = function.string("arguments") {
            state.arguments += arguments
            if let id = state.id, let name = state.name, !state.started {
              state.started = true
              events.append(.toolCallStarted(id: id, name: name))
            }
            if let id = state.id {
              events.append(.toolInputDelta(id: id, delta: arguments))
            }
          }
        }
        toolCalls[index] = state
      }
    }
    return events
  }

  mutating func finish() throws -> [ProviderEvent] {
    guard started, terminal else {
      throw invalid("OpenAI Completions stream ended without [DONE]")
    }
    var events: [ProviderEvent] = []
    for index in toolCalls.keys.sorted() {
      guard let state = toolCalls[index], let id = state.id, let name = state.name else {
        throw invalid("tool call ended without id or name")
      }
      let arguments: JSONValue
      do {
        arguments = try JSONDecoder().decode(
          JSONValue.self,
          from: Data(state.arguments.utf8)
        )
      } catch {
        throw invalid("tool call arguments are malformed")
      }
      events.append(
        .toolCallCompleted(
          ProviderToolCall(id: id, name: name, arguments: arguments)
        )
      )
    }
    guard let finishReason else {
      throw invalid("OpenAI Completions stream ended without a finish reason")
    }
    events.append(.completed(finishReason))
    return events
  }

  private func mapFinishReason(_ value: String) throws -> ProviderFinishReason {
    switch value {
    case "length": .length
    case "tool_calls", "function_call": .toolCalls
    case "content_filter": .contentFilter
    case "stop": .stop
    default: throw invalid("unsupported OpenAI finish reason: \(value)")
    }
  }

  private func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: providerID,
      operation: "openai-completions.event.reduce",
      causeDescription: nil
    )
  }

  private struct ToolCallState {
    var id: String?
    var name: String?
    var arguments = ""
    var started = false
  }
}
