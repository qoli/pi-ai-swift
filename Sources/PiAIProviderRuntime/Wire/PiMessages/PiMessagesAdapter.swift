import Foundation

struct PiMessagesAdapter: WireProtocolAdapter {
  let protocolID = "pi-messages"

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
              operation: "pi-messages.response",
              message: "pi-messages request failed (HTTP \(response.statusCode))",
              cause: body
            )
          }

          var decoder = ServerSentEventDecoder()
          var reducer = PiMessagesEventReducer(
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
              if reducer.isTerminal {
                continuation.finish()
                return
              }
            }
          }
          for event in try decoder.finish() {
            for normalized in try reducer.reduce(event) {
              continuation.yield(normalized)
            }
            if reducer.isTerminal {
              continuation.finish()
              return
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
    var components = URLComponents(
      url: context.baseURL.appending(path: "messages"),
      resolvingAgainstBaseURL: false
    )
    if request.options.providerOptions["debug"]?.boolValue == true {
      components?.queryItems = [URLQueryItem(name: "debug", value: "1")]
    }
    guard let endpoint = components?.url else {
      throw failure(
        .invalidRequest,
        providerID: request.providerID,
        operation: "pi-messages.request.url",
        message: "pi-messages endpoint is invalid"
      )
    }

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
    case .oauth(let credential):
      urlRequest.setValue(
        "Bearer \(credential.accessToken)",
        forHTTPHeaderField: "Authorization"
      )
    case nil:
      throw failure(
        .missingCredential,
        providerID: request.providerID,
        operation: "pi-messages.request.auth",
        message: "pi-messages credential is missing"
      )
    }
    urlRequest.httpBody = try encodeJSONObject(
      try makeBody(request, context: context),
      providerID: request.providerID,
      operation: "pi-messages.request.encode"
    )
    return urlRequest
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

    if request.options.responseSchema != nil {
      throw failure(
        .unsupportedCapability,
        providerID: request.providerID,
        operation: "pi-messages.request.structured-output",
        message: "pi-messages structured output is not in the pinned upstream contract"
      )
    }
    let systemPrompt = request.messages.compactMap { message -> String? in
      guard case .system(let text) = message else { return nil }
      return text
    }.joined(separator: "\n\n")
    var contextObject: [String: JSONValue] = [
      "messages": .array(try makeMessages(request.messages, context: context))
    ]
    if !systemPrompt.isEmpty {
      contextObject["systemPrompt"] = .string(systemPrompt)
    }
    if !request.tools.isEmpty {
      contextObject["tools"] = .array(
        request.tools.map {
          .object([
            "name": .string($0.name),
            "description": .string($0.description),
            "parameters": $0.inputSchema,
          ])
        })
    }

    var options: [String: JSONValue] = [:]
    if let temperature = request.options.temperature {
      options["temperature"] = .number(temperature)
    }
    if let maximum = request.options.maximumOutputTokens {
      options["maxTokens"] = .integer(Int64(maximum))
    }
    if let effort = request.options.reasoningEffort {
      options["reasoning"] = .string(effort.rawValue)
    }
    for (key, value) in request.options.providerOptions where key != "debug" {
      options[key] = value
    }
    return [
      "model": .string(request.modelID),
      "context": .object(contextObject),
      "options": .object(options),
    ]
  }

  private func makeMessages(
    _ messages: [ProviderMessage],
    context: WireProtocolContext
  ) throws -> [JSONValue] {
    try messages.compactMap { message in
      switch message {
      case .system:
        return nil
      case .user(let content):
        return .object([
          "role": .string("user"),
          "content": .array(try content.map(makeUserContent(_:))),
          "timestamp": .integer(0),
        ])
      case .assistant(let content):
        return .object([
          "role": .string("assistant"),
          "content": .array(content.map(makeAssistantContent(_:))),
          "api": .string(protocolID),
          "provider": .string(context.provider.id),
          "model": .string(context.model.id),
          "usage": emptyUsage(),
          "stopReason": .string("stop"),
          "timestamp": .integer(0),
        ])
      case .toolResult(let result):
        return .object([
          "role": .string("toolResult"),
          "toolCallId": .string(result.toolCallID),
          "toolName": .string(result.toolName),
          "content": .array(try result.content.map(makeToolResultContent(_:))),
          "isError": .bool(result.isError),
          "timestamp": .integer(0),
        ])
      }
    }
  }

  private func makeUserContent(_ content: ProviderUserContent) throws -> JSONValue {
    switch content {
    case .text(let text):
      .object(["type": .string("text"), "text": .string(text)])
    case .image(let image):
      try makeImage(image)
    }
  }

  private func makeAssistantContent(_ content: ProviderAssistantContent)
    -> JSONValue
  {
    switch content {
    case .text(let text):
      .object(["type": .string("text"), "text": .string(text)])
    case .reasoning(let reasoning):
      .object([
        "type": .string("thinking"),
        "thinking": .string(reasoning.text),
        "thinkingSignature": reasoning.signature.map(JSONValue.string) ?? .null,
      ])
    case .toolCall(let call):
      .object([
        "type": .string("toolCall"),
        "id": .string(call.id),
        "name": .string(call.name),
        "arguments": call.arguments,
      ])
    }
  }

  private func makeToolResultContent(_ content: ProviderToolResultContent) throws
    -> JSONValue
  {
    switch content {
    case .text(let text):
      .object(["type": .string("text"), "text": .string(text)])
    case .image(let image):
      try makeImage(image)
    }
  }

  private func makeImage(_ image: ProviderImage) throws -> JSONValue {
    switch image {
    case .data(let data, let mimeType):
      return .object([
        "type": .string("image"),
        "data": .string(data.base64EncodedString()),
        "mimeType": .string(mimeType),
      ])
    case .remoteURL:
      throw failure(
        .unsupportedCapability,
        providerID: nil,
        operation: "pi-messages.request.image",
        message: "pi-messages requires inline image bytes"
      )
    }
  }

  private func emptyUsage() -> JSONValue {
    .object([
      "input": .integer(0),
      "output": .integer(0),
      "cacheRead": .integer(0),
      "cacheWrite": .integer(0),
      "totalTokens": .integer(0),
      "cost": .object([
        "input": .number(0),
        "output": .number(0),
        "cacheRead": .number(0),
        "cacheWrite": .number(0),
        "total": .number(0),
      ]),
    ])
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

private struct PiMessagesEventReducer {
  let providerID: String
  let requestedModelID: String
  let requestID: String
  private(set) var isTerminal = false
  private var started = false
  private var toolStates: [Int: ToolState] = [:]
  private var textStates: [Int: String] = [:]
  private var reasoningStates: [Int: String] = [:]

  init(providerID: String, requestedModelID: String, requestID: String) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
    self.requestID = requestID
  }

  mutating func reduce(_ event: ServerSentEvent) throws -> [ProviderEvent] {
    if event.data == "[DONE]" { return [] }
    guard !isTerminal else {
      throw invalid("pi-messages emitted data after its terminal event")
    }
    let object = try decodeJSONObject(
      Data(event.data.utf8),
      providerID: providerID,
      operation: "pi-messages.event.decode"
    )
    guard let type = object.string("type") else {
      throw invalid("pi-messages event is missing type")
    }
    switch type {
    case "start":
      guard !started else { throw invalid("pi-messages emitted duplicate start") }
      started = true
      return [
        .responseStarted(
          ProviderResponseMetadata(
            responseID: requestID,
            providerID: providerID,
            modelID: requestedModelID,
            providerMetadata: [:]
          )
        )
      ]
    case "text_start":
      try requireStarted(type)
      guard let index = object.int("contentIndex"), textStates[index] == nil else {
        throw invalid("pi-messages text start is malformed")
      }
      textStates[index] = ""
      return []
    case "text_delta":
      try requireStarted(type)
      guard let index = object.int("contentIndex"),
        let delta = object.string("delta"), var text = textStates[index]
      else {
        throw invalid("pi-messages text delta has no matching start")
      }
      text += delta
      textStates[index] = text
      return [.textDelta(delta)]
    case "text_end":
      try requireStarted(type)
      guard let index = object.int("contentIndex"),
        let content = object.string("content"),
        let streamed = textStates.removeValue(forKey: index),
        content.hasPrefix(streamed)
      else { throw invalid("pi-messages text end is malformed") }
      let suffix = String(content.dropFirst(streamed.count))
      return suffix.isEmpty ? [] : [.textDelta(suffix)]
    case "thinking_start":
      try requireStarted(type)
      guard let index = object.int("contentIndex"),
        reasoningStates[index] == nil
      else { throw invalid("pi-messages thinking start is malformed") }
      reasoningStates[index] = ""
      return []
    case "thinking_delta":
      try requireStarted(type)
      guard let index = object.int("contentIndex"),
        let delta = object.string("delta"),
        var reasoning = reasoningStates[index]
      else {
        throw invalid("pi-messages thinking delta has no matching start")
      }
      reasoning += delta
      reasoningStates[index] = reasoning
      return [.reasoningDelta(delta)]
    case "thinking_end":
      try requireStarted(type)
      guard let index = object.int("contentIndex"),
        let content = object.string("content"),
        let streamed = reasoningStates.removeValue(forKey: index),
        content.hasPrefix(streamed)
      else { throw invalid("pi-messages thinking end is malformed") }
      let suffix = String(content.dropFirst(streamed.count))
      return suffix.isEmpty ? [] : [.reasoningDelta(suffix)]
    case "toolcall_start":
      try requireStarted(type)
      guard let index = object.int("contentIndex"),
        let id = object.string("id"),
        let name = object.string("toolName"),
        toolStates[index] == nil
      else { throw invalid("pi-messages tool-call start is malformed") }
      toolStates[index] = ToolState(id: id, name: name, arguments: "")
      return [.toolCallStarted(id: id, name: name)]
    case "toolcall_delta":
      try requireStarted(type)
      guard let index = object.int("contentIndex"),
        let delta = object.string("delta"), var tool = toolStates[index]
      else { throw invalid("pi-messages tool-call delta has no matching start") }
      tool.arguments += delta
      toolStates[index] = tool
      return [.toolInputDelta(id: tool.id, delta: delta)]
    case "toolcall_end":
      try requireStarted(type)
      guard let index = object.int("contentIndex"),
        let state = toolStates.removeValue(forKey: index),
        let call = object.object("toolCall"),
        let id = call.string("id"), let name = call.string("name"),
        id == state.id, name == state.name,
        let arguments = call["arguments"]
      else { throw invalid("pi-messages tool-call end is malformed") }
      guard case .object = arguments else {
        throw invalid("pi-messages tool-call arguments are not an object")
      }
      if !state.arguments.isEmpty {
        let assembled: JSONValue
        do {
          assembled = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(state.arguments.utf8)
          )
        } catch {
          throw invalid("pi-messages partial tool arguments are malformed")
        }
        guard assembled == arguments else {
          throw invalid("pi-messages final tool arguments differ from streamed input")
        }
      }
      return [
        .toolCallCompleted(
          ProviderToolCall(id: id, name: name, arguments: arguments)
        )
      ]
    case "done":
      try requireStarted(type)
      guard toolStates.isEmpty, textStates.isEmpty, reasoningStates.isEmpty else {
        throw invalid("pi-messages completed with unfinished content blocks")
      }
      guard let reason = object.string("reason"),
        let usage = object.object("usage")
      else { throw invalid("pi-messages done event is malformed") }
      isTerminal = true
      return [usageEvent(usage), .completed(try mapFinishReason(reason))]
    case "error":
      try requireStarted(type)
      isTerminal = true
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: object.string("errorMessage")
          ?? "pi-messages stream returned an error",
        providerID: providerID,
        operation: "pi-messages.event.error",
        causeDescription: object.string("reason")
      )
    default:
      throw invalid("unsupported pi-messages event: \(type)")
    }
  }

  func validateTerminal() throws {
    guard isTerminal else {
      throw invalid("pi-messages stream ended without a terminal event")
    }
  }

  private func usageEvent(_ usage: [String: JSONValue]) -> ProviderEvent {
    .usage(
      ProviderUsage(
        inputTokens: usage.int("input"),
        outputTokens: usage.int("output"),
        reasoningTokens: usage.int("reasoning"),
        cachedInputTokens: usage.int("cacheRead"),
        providerMetadata: usage["totalTokens"].map {
          ["totalTokens": $0]
        } ?? [:]
      )
    )
  }

  private func mapFinishReason(_ value: String) throws -> ProviderFinishReason {
    switch value {
    case "stop": .stop
    case "length": .length
    case "toolUse": .toolCalls
    default: throw invalid("unsupported pi-messages finish reason: \(value)")
    }
  }

  private func requireStarted(_ type: String) throws {
    guard started else {
      throw invalid("pi-messages \(type) arrived before start")
    }
  }

  private func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: providerID,
      operation: "pi-messages.event.reduce",
      causeDescription: nil
    )
  }

  private struct ToolState {
    let id: String
    let name: String
    var arguments: String
  }
}
