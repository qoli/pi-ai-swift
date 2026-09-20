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
    try request.validateSingleSystemMessage(operation: "pi-messages.request.system")
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
    var messages = try makeMessages(request.messages, context: context)
    if !systemPrompt.isEmpty || !request.tools.isEmpty {
      var system: [String: JSONValue] = [
        "role": .string("system"),
        "content": .string(systemPrompt),
        "timestamp": .integer(0),
      ]
      if !request.tools.isEmpty {
        system["toolsAdded"] = .array(request.tools.map(makeTool(_:)))
      }
      messages.insert(.object(system), at: 0)
    }
    let contextObject: [String: JSONValue] = ["messages": .array(messages)]

    var options: [String: JSONValue] = [:]
    if let temperature = request.options.temperature {
      options["temperature"] = .number(temperature)
    }
    if let maximum = request.options.maximumOutputTokens {
      options["maxTokens"] = .integer(Int64(maximum))
    }
    if let effort = request.options.reasoningEffort, effort != .off {
      options["reasoning"] = .string(effort.rawValue)
    }
    options["cacheRetention"] = .string(request.options.cacheRetention.rawValue)
    if let sessionID = request.options.sessionID {
      options["sessionId"] = .string(sessionID)
    }
    if let toolChoice = request.options.toolChoice {
      options["toolChoice"] = toolChoice
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
    try messages.compactMap { message -> JSONValue? in
      switch message {
      case .system:
        return nil
      case .user(let content):
        if content.count == 1, case .text(let text) = content[0] {
          return .object([
            "role": .string("user"),
            "content": .string(text),
            "timestamp": .integer(0),
          ])
        }
        return .object([
          "role": .string("user"),
          "content": .array(try content.map(makeUserContent(_:))),
          "timestamp": .integer(0),
        ])
      case .userMessage(let user):
        if user.content.count == 1, case .text(let text) = user.content[0] {
          return .object([
            "role": .string("user"),
            "content": .string(text),
            "timestamp": .integer(user.timestampMilliseconds),
          ])
        }
        return .object([
          "role": .string("user"),
          "content": .array(try user.content.map(makeUserContent(_:))),
          "timestamp": .integer(user.timestampMilliseconds),
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
      case .assistantMessage(let assistant):
        let source = assistant.source
        var object: [String: JSONValue] = [
          "role": .string("assistant"),
          "content": .array(assistant.content.map(makeAssistantContent(_:))),
          "api": .string(source.api),
          "provider": .string(source.providerID),
          "model": .string(source.modelID),
          "usage": makeUsage(assistant.usage),
          "stopReason": .string(assistant.stopReason.rawValue),
          "timestamp": .integer(assistant.timestampMilliseconds),
        ]
        if let responseID = assistant.responseID { object["responseId"] = .string(responseID) }
        if let responseModelID = assistant.responseModelID {
          object["responseModel"] = .string(responseModelID)
        }
        if let rawStopReason = assistant.rawStopReason {
          object["rawStopReason"] = .string(rawStopReason)
        }
        return .object(object)
      case .toolResult(let result):
        let object: [String: JSONValue] = [
          "role": .string("toolResult"),
          "toolCallId": .string(result.toolCallID),
          "toolName": .string(result.toolName),
          "content": .array(try result.content.map(makeToolResultContent(_:))),
          "isError": .bool(result.isError),
          "timestamp": .integer(result.timestampMilliseconds ?? 0),
        ]
        return .object(object)
      }
    }
  }

  private func makeTool(_ tool: ProviderToolDefinition) -> JSONValue {
    var object: [String: JSONValue] = [
      "name": .string(tool.name),
      "description": .string(tool.description),
      "parameters": tool.inputSchema,
    ]
    if let constrainedSampling = tool.constrainedSampling {
      switch constrainedSampling {
      case .jsonSchema(let strict):
        object["constrainedSampling"] = .object([
          "type": .string("json_schema"),
          "strict": .string(strict.rawValue),
        ])
      case .grammar(let variants):
        object["constrainedSampling"] = .object([
          "type": .string("grammar"),
          "variants": .object(variants.mapValues(JSONValue.string)),
        ])
      }
    }
    return .object(object)
  }

  private func makeUserContent(_ content: ProviderUserContent) throws -> JSONValue {
    switch content {
    case .text(let text):
      return .object(["type": .string("text"), "text": .string(text)])
    case .image(let image):
      return try makeImage(image)
    }
  }

  private func makeAssistantContent(_ content: ProviderAssistantContent)
    -> JSONValue
  {
    switch content {
    case .text(let text):
      return .object(["type": .string("text"), "text": .string(text)])
    case .signedText(let text):
      var object: [String: JSONValue] = [
        "type": .string("text"),
        "text": .string(text.text),
      ]
      if let signature = text.signature { object["textSignature"] = .string(signature) }
      return .object(object)
    case .reasoning(let reasoning):
      var object: [String: JSONValue] = [
        "type": .string("thinking"),
        "thinking": .string(reasoning.text),
      ]
      if let signature = reasoning.signature { object["thinkingSignature"] = .string(signature) }
      if let redacted = reasoning.isRedacted { object["redacted"] = .bool(redacted) }
      return .object(object)
    case .toolCall(let call):
      var object: [String: JSONValue] = [
        "type": .string("toolCall"),
        "id": .string(call.id),
        "name": .string(call.name),
        "arguments": call.arguments,
      ]
      if let signature = call.thoughtSignature { object["thoughtSignature"] = .string(signature) }
      if let namespace = call.namespace { object["namespace"] = .string(namespace) }
      return .object(object)
    }
  }

  private func makeUsage(_ usage: ProviderUsage) -> JSONValue {
    .object([
      "input": usage.inputTokens.map { .integer(Int64($0)) } ?? .null,
      "output": usage.outputTokens.map { .integer(Int64($0)) } ?? .null,
      "reasoning": usage.reasoningTokens.map { .integer(Int64($0)) } ?? .null,
      "cacheRead": usage.cachedInputTokens.map { .integer(Int64($0)) } ?? .null,
      "cacheWrite": usage.cacheWriteTokens.map { .integer(Int64($0)) } ?? .null,
      "totalTokens": usage.totalTokens.map { .integer(Int64($0)) } ?? .null,
      "cost": .object([
        "input": .integer(0),
        "output": .integer(0),
        "cacheRead": .integer(0),
        "cacheWrite": .integer(0),
        "total": .integer(0),
      ]),
    ])
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
  let timestampMilliseconds: Int64
  private(set) var isTerminal = false
  private var started = false
  private var toolStates: [Int: ToolState] = [:]
  private var textStates: [Int: String] = [:]
  private var reasoningStates: [Int: String] = [:]
  private var completedContent: [Int: ProviderResponseContent] = [:]

  init(providerID: String, requestedModelID: String, requestID: String) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
    self.requestID = requestID
    self.timestampMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
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
            responseID: nil,
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
      completedContent[index] = .text(
        ProviderTextContent(text: content, signature: object.string("contentSignature")))
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
      var events: [ProviderEvent] = suffix.isEmpty ? [] : [.reasoningDelta(suffix)]
      let signature = object.string("contentSignature")
      completedContent[index] = .reasoning(
        ProviderReasoningContent(
          text: content,
          signature: signature,
          isRedacted: object.bool("redacted"),
          providerMetadata: [:]
        ))
      if let signature, !signature.isEmpty {
        events.append(.reasoningSignatureDelta(signature))
      }
      return events
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
      let completed = ProviderToolCall(
        id: id,
        name: name,
        arguments: arguments,
        thoughtSignature: call.string("thoughtSignature"),
        namespace: call.string("namespace")
      )
      completedContent[index] = .toolCall(completed)
      return [
        .toolCallCompleted(completed)
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
      let normalizedUsage = try makeUsage(usage)
      let finishReason = try mapFinishReason(reason)
      let snapshot = ProviderResponseSnapshot(
        responseID: object.string("responseId"),
        providerID: providerID,
        protocolID: "pi-messages",
        modelID: requestedModelID,
        responseModelID: object.string("responseModel"),
        content: completedContent.keys.sorted().compactMap { completedContent[$0] },
        usage: normalizedUsage,
        finishReason: finishReason,
        rawFinishReason: object.string("rawStopReason"),
        timestampMilliseconds: timestampMilliseconds
      )
      return [.usage(normalizedUsage), .responseSnapshot(snapshot), .completed(finishReason)]
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

  private func makeUsage(_ usage: [String: JSONValue]) throws -> ProviderUsage {
    guard let rawCost = usage.object("cost") else {
      throw invalid("pi-messages usage is missing cost")
    }
    return ProviderUsage(
      inputTokens: usage.int("input"),
      outputTokens: usage.int("output"),
      reasoningTokens: usage.int("reasoning"),
      cachedInputTokens: usage.int("cacheRead"),
      cacheWriteTokens: usage.int("cacheWrite"),
      totalTokens: usage.int("totalTokens"),
      providerMetadata: usage,
      cost: try ProviderUsagePricing.directCost(
        rawCost,
        providerID: providerID,
        operation: "pi-messages.event.usage-cost",
        failureCode: .invalidResponse)
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
