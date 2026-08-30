import Foundation

struct MistralConversationsAdapter: WireProtocolAdapter {
  let protocolID = "mistral-conversations"

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
              operation: "mistral.response",
              message: "Mistral Conversations request failed (HTTP \(response.statusCode))",
              cause: body
            )
          }

          var decoder = ServerSentEventDecoder()
          var reducer = MistralEventReducer(
            providerID: request.providerID,
            requestedModelID: request.modelID,
            requestID: request.id
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
          for normalized in try reducer.finalize() {
            continuation.yield(normalized)
          }
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
    let endpoint = context.baseURL.appending(path: "v1/chat/completions")
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (name, value) in context.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    switch context.credential {
    case .apiKey(let credential):
      urlRequest.setValue(
        "Bearer \(credential.key)",
        forHTTPHeaderField: "Authorization"
      )
    case .oauth:
      throw failure(
        .invalidCredential,
        providerID: request.providerID,
        operation: "mistral.request.auth",
        message: "Mistral Conversations requires an API-key credential"
      )
    case nil:
      throw failure(
        .missingCredential,
        providerID: request.providerID,
        operation: "mistral.request.auth",
        message: "Mistral Conversations credential is missing"
      )
    }
    urlRequest.httpBody = try encodeJSONObject(
      try makeBody(request, context: context),
      providerID: request.providerID,
      operation: "mistral.request.encode"
    )
    return urlRequest
  }

  private func makeBody(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: JSONValue] {
    var body: [String: JSONValue] = [
      "model": .string(request.modelID),
      "stream": .bool(true),
      "messages": .array(try makeMessages(request.messages, context: context)),
    ]
    if let maximum = request.options.maximumOutputTokens
      ?? context.model.maximumOutputTokens
    {
      body["max_tokens"] = .integer(Int64(maximum))
    }
    if let temperature = request.options.temperature {
      body["temperature"] = .number(temperature)
    }
    if let effort = request.options.reasoningEffort,
      context.model.capabilities.reasoning
    {
      if Self.reasoningEffortModels.contains(context.model.id) {
        body["reasoning_effort"] = .string(
          mappedReasoningEffort(effort, context: context)
        )
      } else if effort != "off" && effort != "none" {
        body["prompt_mode"] = .string("reasoning")
      }
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(request.tools.map(makeToolDefinition(_:)))
    }
    if request.options.responseSchema != nil {
      throw failure(
        .unsupportedCapability,
        providerID: request.providerID,
        operation: "mistral.request.structured-output",
        message: "Mistral Conversations structured output is not in the pinned upstream contract"
      )
    }
    for (key, value) in request.options.providerOptions {
      body[key] = value
    }
    return body
  }

  private func makeMessages(
    _ messages: [ProviderMessage],
    context: WireProtocolContext
  ) throws -> [JSONValue] {
    try messages.map { message in
      switch message {
      case .system(let text):
        return .object(["role": .string("system"), "content": .string(text)])
      case .user(let content):
        return .object([
          "role": .string("user"),
          "content": .array(
            try content.map { try makeUserContent($0, context: context) }
          ),
        ])
      case .assistant(let content):
        var parts: [JSONValue] = []
        var calls: [JSONValue] = []
        for item in content {
          switch item {
          case .text(let text):
            parts.append(.object(["type": .string("text"), "text": .string(text)]))
          case .reasoning(let reasoning):
            parts.append(
              .object([
                "type": .string("thinking"),
                "thinking": .array([
                  .object(["type": .string("text"), "text": .string(reasoning.text)])
                ]),
              ]))
          case .toolCall(let call):
            calls.append(
              .object([
                "id": .string(call.id),
                "type": .string("function"),
                "function": .object([
                  "name": .string(call.name),
                  "arguments": .string(try encodeJSONString(call.arguments)),
                ]),
                "index": .integer(0),
              ]))
          }
        }
        var result: [String: JSONValue] = [
          "role": .string("assistant"), "prefix": .bool(false),
        ]
        if !parts.isEmpty { result["content"] = .array(parts) }
        if !calls.isEmpty { result["tool_calls"] = .array(calls) }
        return .object(result)
      case .toolResult(let result):
        let text = result.content.compactMap { item -> String? in
          guard case .text(let text) = item else { return nil }
          return text
        }.joined(separator: "\n")
        var parts: [JSONValue] = [
          .object([
            "type": .string("text"),
            "text": .string(toolResultText(text, isError: result.isError)),
          ])
        ]
        for item in result.content {
          guard case .image(let image) = item else { continue }
          guard context.model.capabilities.imageInput else {
            throw failure(
              .unsupportedCapability,
              providerID: context.provider.id,
              operation: "mistral.request.tool-result-image",
              message: "Mistral model does not accept tool-result images"
            )
          }
          parts.append(try makeImage(image))
        }
        return .object([
          "role": .string("tool"),
          "tool_call_id": .string(result.toolCallID),
          "name": .string(result.toolName),
          "content": .array(parts),
        ])
      }
    }
  }

  private func makeUserContent(
    _ content: ProviderUserContent,
    context: WireProtocolContext
  ) throws -> JSONValue {
    switch content {
    case .text(let text):
      return .object(["type": .string("text"), "text": .string(text)])
    case .image(let image):
      if !context.model.capabilities.imageInput {
        throw failure(
          .unsupportedCapability,
          providerID: context.provider.id,
          operation: "mistral.request.image",
          message: "Mistral model does not accept image input"
        )
      }
      return try makeImage(image)
    }
  }

  private func makeImage(_ image: ProviderImage) throws -> JSONValue {
    let url: String
    switch image {
    case .data(let data, let mimeType):
      url = "data:\(mimeType);base64,\(data.base64EncodedString())"
    case .remoteURL:
      throw failure(
        .unsupportedCapability,
        providerID: nil,
        operation: "mistral.request.image",
        message: "Mistral Conversations requires inline image bytes"
      )
    }
    return .object(["type": .string("image_url"), "image_url": .string(url)])
  }

  private func makeToolDefinition(_ tool: ProviderToolDefinition) -> JSONValue {
    .object([
      "type": .string("function"),
      "function": .object([
        "name": .string(tool.name),
        "description": .string(tool.description),
        "parameters": tool.inputSchema,
        "strict": .bool(true),
      ]),
    ])
  }

  private func mappedReasoningEffort(
    _ effort: String,
    context: WireProtocolContext
  ) -> String {
    if case .object(let map)? = context.modelConfiguration.metadata[
      "thinkingLevelMap"
    ], case .string(let mapped)? = map[effort] {
      return mapped
    }
    return "high"
  }

  private func toolResultText(_ text: String, isError: Bool) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return isError ? "[tool error] (no tool output)" : "(no tool output)"
    }
    return isError ? "[tool error] \(trimmed)" : trimmed
  }

  private func encodeJSONString(_ value: JSONValue) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw failure(
        .invalidRequest,
        providerID: nil,
        operation: "mistral.request.tool-call",
        message: "Mistral tool arguments are not UTF-8"
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

  private static let reasoningEffortModels: Set<String> = [
    "mistral-small-2603", "mistral-small-latest", "mistral-medium-3.5",
  ]
}

private struct MistralEventReducer {
  let providerID: String
  let requestedModelID: String
  let requestID: String
  private var started = false
  private var responseID: String?
  private var finishReason: ProviderFinishReason?
  private var toolStates: [String: ToolState] = [:]
  private var toolOrder: [String] = []

  init(providerID: String, requestedModelID: String, requestID: String) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
    self.requestID = requestID
  }

  mutating func reduce(_ event: ServerSentEvent) throws -> [ProviderEvent] {
    if event.data == "[DONE]" {
      return []
    }
    let object = try decodeJSONObject(
      Data(event.data.utf8),
      providerID: providerID,
      operation: "mistral.event.decode"
    )
    if let error = object.object("error") {
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: error.string("message") ?? "Mistral stream returned an error",
        providerID: providerID,
        operation: "mistral.event.error",
        causeDescription: error.string("code")
      )
    }

    var normalized: [ProviderEvent] = []
    if !started {
      started = true
      responseID = object.string("id") ?? requestID
      normalized.append(
        .responseStarted(
          ProviderResponseMetadata(
            responseID: responseID!,
            providerID: providerID,
            modelID: object.string("model") ?? requestedModelID,
            providerMetadata: [:]
          )
        ))
    }
    if let usage = object.object("usage") {
      let prompt = usage.int("prompt_tokens")
      let cached = cachedTokens(usage)
      normalized.append(
        .usage(
          ProviderUsage(
            inputTokens: prompt.map { max(0, $0 - (cached ?? 0)) },
            outputTokens: usage.int("completion_tokens"),
            reasoningTokens: usage.object("completion_tokens_details")?.int(
              "reasoning_tokens"
            ),
            cachedInputTokens: cached,
            providerMetadata: usage["total_tokens"].map {
              ["totalTokens": $0]
            } ?? [:]
          )
        ))
    }

    guard let choices = object.array("choices") else {
      if object["usage"] != nil { return normalized }
      throw invalid("Mistral event is missing choices")
    }
    for choiceValue in choices {
      guard let choice = choiceValue.objectValue else {
        throw invalid("Mistral choice is not an object")
      }
      if let reason = choice.string("finish_reason") {
        finishReason = try mapFinishReason(reason)
      }
      guard let delta = choice.object("delta") else { continue }
      if let content = delta["content"] {
        normalized.append(contentsOf: try reduceContent(content))
      }
      if let calls = delta.array("tool_calls") {
        for call in calls {
          guard let call = call.objectValue else {
            throw invalid("Mistral tool call is not an object")
          }
          normalized.append(contentsOf: try reduceToolCall(call))
        }
      }
    }
    return normalized
  }

  mutating func finalize() throws -> [ProviderEvent] {
    guard started else { throw invalid("Mistral stream produced no events") }
    guard let finishReason else {
      throw invalid("Mistral stream ended without a finish reason")
    }
    var events: [ProviderEvent] = []
    for key in toolOrder {
      guard let tool = toolStates[key] else { continue }
      let arguments: JSONValue
      if tool.arguments.isEmpty {
        arguments = .object([:])
      } else {
        do {
          arguments = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(tool.arguments.utf8)
          )
        } catch {
          throw invalid("Mistral tool arguments are malformed")
        }
      }
      events.append(
        .toolCallCompleted(
          ProviderToolCall(id: tool.id, name: tool.name, arguments: arguments)
        ))
    }
    events.append(.completed(finishReason))
    return events
  }

  private mutating func reduceContent(_ content: JSONValue) throws
    -> [ProviderEvent]
  {
    switch content {
    case .string(let text):
      return text.isEmpty ? [] : [.textDelta(text)]
    case .array(let items):
      var events: [ProviderEvent] = []
      for item in items {
        guard let item = item.objectValue, let type = item.string("type") else {
          throw invalid("Mistral content block is malformed")
        }
        switch type {
        case "text":
          if let text = item.string("text"), !text.isEmpty {
            events.append(.textDelta(text))
          }
        case "thinking":
          guard let thinking = item.array("thinking") else {
            throw invalid("Mistral thinking block is malformed")
          }
          for part in thinking {
            guard let text = part.objectValue?.string("text") else { continue }
            if !text.isEmpty { events.append(.reasoningDelta(text)) }
          }
        default:
          throw invalid("unsupported Mistral content block: \(type)")
        }
      }
      return events
    case .null:
      return []
    default:
      throw invalid("Mistral content has an unsupported shape")
    }
  }

  private mutating func reduceToolCall(_ call: [String: JSONValue]) throws
    -> [ProviderEvent]
  {
    let index = call.int("index")
    let id = call.string("id")
    guard index != nil || id != nil else {
      throw invalid("Mistral tool call is missing index and id")
    }
    let key = index.map { "index:\($0)" } ?? "id:\(id!)"
    guard let function = call.object("function") else {
      throw invalid("Mistral tool call is missing function")
    }
    let name = function.string("name")
    let delta: String
    switch function["arguments"] {
    case .string(let value): delta = value
    case .object, .array:
      guard let value = function["arguments"],
        let encoded = try? JSONEncoder().encode(value),
        let string = String(data: encoded, encoding: .utf8)
      else { throw invalid("Mistral tool arguments cannot be encoded") }
      delta = string
    case nil, .null: delta = ""
    default: throw invalid("Mistral tool arguments have an unsupported shape")
    }

    var events: [ProviderEvent] = []
    if var state = toolStates[key] {
      if let id, id != "null", id != state.id {
        throw invalid("Mistral tool call identity changed during streaming")
      }
      if let name, !name.isEmpty, name != state.name {
        throw invalid("Mistral tool name changed during streaming")
      }
      state.arguments += delta
      toolStates[key] = state
      if !delta.isEmpty {
        events.append(.toolInputDelta(id: state.id, delta: delta))
      }
    } else {
      guard let name, !name.isEmpty else {
        throw invalid("Mistral tool call start is missing name")
      }
      let resolvedID = (id == nil || id == "null") ? "mistral-\(index!)" : id!
      toolStates[key] = ToolState(
        id: resolvedID,
        name: name,
        arguments: delta
      )
      toolOrder.append(key)
      events.append(.toolCallStarted(id: resolvedID, name: name))
      if !delta.isEmpty {
        events.append(.toolInputDelta(id: resolvedID, delta: delta))
      }
    }
    return events
  }

  private func cachedTokens(_ usage: [String: JSONValue]) -> Int? {
    usage.object("prompt_tokens_details")?.int("cached_tokens")
      ?? usage.object("promptTokenDetails")?.int("cachedTokens")
      ?? usage.int("num_cached_tokens")
  }

  private func mapFinishReason(_ value: String) throws -> ProviderFinishReason {
    switch value {
    case "stop": .stop
    case "length", "model_length": .length
    case "tool_calls": .toolCalls
    case "error":
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: "Mistral provider stopped with an error",
        providerID: providerID,
        operation: "mistral.event.finish",
        causeDescription: value
      )
    default: throw invalid("unsupported Mistral finish reason: \(value)")
    }
  }

  private func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: providerID,
      operation: "mistral.event.reduce",
      causeDescription: nil
    )
  }

  private struct ToolState {
    let id: String
    let name: String
    var arguments: String
  }
}
