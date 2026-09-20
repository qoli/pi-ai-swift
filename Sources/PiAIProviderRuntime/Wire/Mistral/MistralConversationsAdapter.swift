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
            requestID: request.id,
            pricing: try ProviderUsagePricing.parse(
              metadata: context.modelConfiguration.metadata,
              providerID: request.providerID,
              operation: "mistral.usage.pricing")
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
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let error as ProviderRuntimeFailure {
          continuation.finish(throwing: error)
        } catch {
          continuation.finish(
            throwing: failure(
              .transportFailed,
              providerID: request.providerID,
              operation: "mistral.response.transport",
              message: "Mistral Conversations transport failed",
              cause: String(describing: error)
            ))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func makeURLRequest(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> URLRequest {
    try request.validateSingleSystemMessage(operation: "mistral.request.system")
    let endpoint = context.baseURL.appending(path: "v1/chat/completions")
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (name, value) in context.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    if request.options.cacheRetention != .none,
      let sessionID = request.options.sessionID, !sessionID.isEmpty,
      urlRequest.value(forHTTPHeaderField: "x-affinity") == nil
    {
      urlRequest.setValue(sessionID, forHTTPHeaderField: "x-affinity")
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
      "model": .string(request.modelID),
      "stream": .bool(true),
      "messages": .array(
        try makeMessages(request.messages.insertingMissingToolResults(), context: context)),
    ]
    if let maximum = request.options.maximumOutputTokens
      ?? context.model.maximumOutputTokens
    {
      body["max_tokens"] = .integer(Int64(maximum))
    }
    if let temperature = request.options.temperature {
      body["temperature"] = .number(temperature)
    }
    if request.options.cacheRetention != .none,
      let sessionID = request.options.sessionID, !sessionID.isEmpty
    {
      body["prompt_cache_key"] = .string(sessionID)
    }
    if let effort = request.options.reasoningEffort,
      effort != .off,
      context.model.capabilities.reasoning
    {
      if Self.usesReasoningEffort(modelID: context.model.id) {
        body["reasoning_effort"] = .string(
          mappedReasoningEffort(effort, context: context)
        )
      } else {
        body["prompt_mode"] = .string("reasoning")
      }
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        try request.tools.map {
          try makeToolDefinition($0, providerID: request.providerID)
        })
    }
    if let toolChoice = request.options.toolChoice {
      body["tool_choice"] = toolChoice
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
    let target = ProviderMessageSource(
      api: protocolID, providerID: context.provider.id, modelID: context.model.id)
    var normalizedToolIDs: [String: String] = [:]
    return try messages.compactMap { message in
      switch message {
      case .system(let text):
        return .object(["role": .string("system"), "content": .string(text)])
      case .user(let content):
        if content.count == 1, case .text(let text) = content[0] {
          return .object([
            "role": .string("user"),
            "content": .string(text),
          ])
        }
        let supportedContent =
          context.model.capabilities.imageInput
          ? content
          : content.filter { if case .text = $0 { true } else { false } }
        if supportedContent.isEmpty,
          content.contains(where: { if case .image = $0 { true } else { false } })
        {
          return .object([
            "role": .string("user"),
            "content": .array([
              .object([
                "type": .string("text"),
                "text": .string("(image omitted: model does not support images)"),
              ])
            ]),
          ])
        }
        return .object([
          "role": .string("user"),
          "content": .array(
            try supportedContent.map { try makeUserContent($0, context: context) }
          ),
        ])
      case .userMessage(let user):
        return try makeMessages([.user(user.content)], context: context)[0]
      case .assistant(let content):
        var parts: [JSONValue] = []
        var calls: [JSONValue] = []
        for item in content {
          switch item {
          case .text(let text):
            parts.append(.object(["type": .string("text"), "text": .string(text)]))
          case .signedText(let text):
            parts.append(.object(["type": .string("text"), "text": .string(text.text)]))
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
      case .assistantMessage(let assistant):
        guard let content = assistant.replayContent(for: target) else { return nil }
        let normalizedContent = content.map { item -> ProviderAssistantContent in
          guard case .toolCall(let call) = item, assistant.source != target else { return item }
          let normalizedID = normalizedMistralToolID(call.id)
          normalizedToolIDs[call.id] = normalizedID
          return .toolCall(
            ProviderToolCall(
              id: normalizedID,
              name: call.name,
              arguments: call.arguments,
              thoughtSignature: call.thoughtSignature,
              namespace: call.namespace,
              providerMetadata: call.providerMetadata
            ))
        }
        return try makeMessages([.assistant(normalizedContent)], context: context)[0]
      case .toolResult(let result):
        let text = result.content.compactMap { item -> String? in
          guard case .text(let text) = item else { return nil }
          return text
        }.joined(separator: "\n")
        let hasImages = result.content.contains { if case .image = $0 { true } else { false } }
        var parts: [JSONValue] = [
          .object([
            "type": .string("text"),
            "text": .string(
              toolResultText(
                text,
                hasImages: hasImages,
                supportsImages: context.model.capabilities.imageInput,
                isError: result.isError
              )),
          ])
        ]
        for item in result.content {
          guard case .image(let image) = item else { continue }
          guard context.model.capabilities.imageInput else { continue }
          parts.append(try makeImage(image))
        }
        return .object([
          "role": .string("tool"),
          "tool_call_id": .string(normalizedToolIDs[result.toolCallID] ?? result.toolCallID),
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

  private func makeToolDefinition(
    _ tool: ProviderToolDefinition,
    providerID: String
  ) throws -> JSONValue {
    let constrained = try ProviderConstrainedSamplingResolver.jsonSchema(
      for: tool,
      supportsStrictMode: true,
      providerID: providerID,
      operation: "mistral.request.tool-schema"
    )
    return .object([
      "type": .string("function"),
      "function": .object([
        "name": .string(tool.name),
        "description": .string(tool.description),
        "parameters": constrained.schema,
        "strict": .bool(constrained.strict ?? false),
      ]),
    ])
  }

  private func mappedReasoningEffort(
    _ effort: ProviderReasoningEffort,
    context: WireProtocolContext
  ) -> String {
    if case .object(let map)? = context.modelConfiguration.metadata[
      "thinkingLevelMap"
    ], case .string(let mapped)? = map[effort.rawValue] {
      return mapped
    }
    return effort == .off ? "none" : "high"
  }

  private func toolResultText(
    _ text: String,
    hasImages: Bool,
    supportsImages: Bool,
    isError: Bool
  ) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = isError ? "[tool error] " : ""
    if !trimmed.isEmpty {
      let suffix =
        hasImages && !supportsImages
        ? "\n(tool image omitted: model does not support images)" : ""
      return "\(prefix)\(trimmed)\(suffix)"
    }
    if hasImages {
      if supportsImages {
        return isError ? "[tool error] (see attached image)" : "(see attached image)"
      }
      return isError
        ? "[tool error] (image omitted: model does not support images)"
        : "(image omitted: model does not support images)"
    }
    return isError ? "[tool error] (no tool output)" : "(no tool output)"
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

  private func normalizedMistralToolID(_ value: String) -> String {
    let normalized = value.filter { $0.isLetter || $0.isNumber }
    if normalized.count == 9 { return normalized }
    let seed = normalized.isEmpty ? value : normalized
    return String(mistralShortHash(seed).filter { $0.isLetter || $0.isNumber }.prefix(9))
  }

  private func mistralShortHash(_ value: String) -> String {
    var h1 = UInt32(0xdead_beef)
    var h2 = UInt32(0x41c6_ce57)
    for codeUnit in value.utf16 {
      h1 = (h1 ^ UInt32(codeUnit)) &* 2_654_435_761
      h2 = (h2 ^ UInt32(codeUnit)) &* 1_597_334_677
    }
    h1 = ((h1 ^ (h1 >> 16)) &* 2_246_822_507) ^ ((h2 ^ (h2 >> 13)) &* 3_266_489_909)
    h2 = ((h2 ^ (h2 >> 16)) &* 2_246_822_507) ^ ((h1 ^ (h1 >> 13)) &* 3_266_489_909)
    return String(h2, radix: 36) + String(h1, radix: 36)
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

  private static func usesReasoningEffort(modelID: String) -> Bool {
    modelID == "mistral-small-2603"
      || modelID == "mistral-small-latest"
      || modelID.hasPrefix("mistral-medium-")
      || modelID == "zai-glm-5-2"
  }
}

private struct MistralEventReducer {
  let providerID: String
  let requestedModelID: String
  let requestID: String
  let pricing: ProviderUsagePricing?
  private var started = false
  private var responseID: String?
  private var responseModelID: String?
  private var finishReason: ProviderFinishReason?
  private var rawFinishReason: String?
  private var toolStates: [String: ToolState] = [:]
  private var toolOrder: [String] = []
  private var usage: ProviderUsage?
  private var content: [ProviderResponseContent] = []

  init(
    providerID: String,
    requestedModelID: String,
    requestID: String,
    pricing: ProviderUsagePricing?
  ) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
    self.requestID = requestID
    self.pricing = pricing
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
      responseID = object.string("id")
      responseModelID = object.string("model")
      normalized.append(
        .responseStarted(
          ProviderResponseMetadata(
            responseID: nil,
            providerID: providerID,
            modelID: requestedModelID,
            providerMetadata: [:]
          )
        ))
    }
    if let usage = object.object("usage") {
      guard let pricing else {
        throw ProviderRuntimeFailure(
          code: .upstreamDrift, message: "model cost rates are missing",
          providerID: providerID, operation: "mistral.usage.pricing",
          causeDescription: nil)
      }
      let prompt = usage.int("prompt_tokens") ?? 0
      let cached = min(prompt, max(0, cachedTokens(usage)))
      let output = usage.int("completion_tokens") ?? 0
      let input = max(0, prompt - cached)
      self.usage = ProviderUsage(
        inputTokens: input,
        outputTokens: output,
        reasoningTokens: usage.object("completion_tokens_details")?.int(
          "reasoning_tokens"
        ),
        cachedInputTokens: cached,
        cacheWriteTokens: 0,
        totalTokens: usage.int("total_tokens") ?? max(0, prompt - cached) + output + cached,
        providerMetadata: usage,
        cost: pricing.cost(input: input, output: output, cacheRead: cached, cacheWrite: 0)
      )
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
        rawFinishReason = reason
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
      let call = ProviderToolCall(id: tool.id, name: tool.name, arguments: arguments)
      content.append(.toolCall(call))
      events.append(.toolCallCompleted(call))
    }
    let terminalUsage =
      usage
      ?? ProviderUsage(
        inputTokens: 0,
        outputTokens: 0,
        reasoningTokens: nil,
        cachedInputTokens: 0,
        cacheWriteTokens: 0,
        totalTokens: 0,
        providerMetadata: [:],
        cost: pricing?.cost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
      )
    events.append(.usage(terminalUsage))
    events.append(
      .responseSnapshot(
        ProviderResponseSnapshot(
          responseID: responseID,
          providerID: providerID,
          protocolID: "mistral-conversations",
          modelID: requestedModelID,
          responseModelID: responseModelID == requestedModelID ? nil : responseModelID,
          content: content,
          usage: terminalUsage,
          finishReason: finishReason,
          rawFinishReason: rawFinishReason,
          timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )))
    events.append(.completed(finishReason))
    return events
  }

  private mutating func reduceContent(_ content: JSONValue) throws
    -> [ProviderEvent]
  {
    switch content {
    case .string(let text):
      if !text.isEmpty {
        self.content.append(.text(ProviderTextContent(text: text, signature: nil)))
      }
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
            self.content.append(.text(ProviderTextContent(text: text, signature: nil)))
            events.append(.textDelta(text))
          }
        case "thinking":
          guard let thinking = item.array("thinking") else {
            throw invalid("Mistral thinking block is malformed")
          }
          for part in thinking {
            guard let text = part.objectValue?.string("text") else { continue }
            if !text.isEmpty {
              self.content.append(
                .reasoning(
                  ProviderReasoningContent(text: text, signature: nil, providerMetadata: [:])))
              events.append(.reasoningDelta(text))
            }
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
      let resolvedID = (id == nil || id == "null") ? derivedToolCallID(index: index!) : id!
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

  private func cachedTokens(_ usage: [String: JSONValue]) -> Int {
    usage.object("prompt_tokens_details")?.int("cached_tokens")
      ?? usage.object("promptTokenDetails")?.int("cachedTokens")
      ?? usage.int("num_cached_tokens")
      ?? 0
  }

  private func derivedToolCallID(index: Int) -> String {
    let value = "toolcall:\(index)"
    let normalized = value.filter { $0.isLetter || $0.isNumber }
    if normalized.count == 9 { return normalized }
    let seed = normalized.isEmpty ? value : normalized
    return String(mistralShortHash(seed).filter { $0.isLetter || $0.isNumber }.prefix(9))
  }

  private func mistralShortHash(_ value: String) -> String {
    var h1 = UInt32(0xdead_beef)
    var h2 = UInt32(0x41c6_ce57)
    for codeUnit in value.utf16 {
      h1 = (h1 ^ UInt32(codeUnit)) &* 2_654_435_761
      h2 = (h2 ^ UInt32(codeUnit)) &* 1_597_334_677
    }
    h1 = ((h1 ^ (h1 >> 16)) &* 2_246_822_507) ^ ((h2 ^ (h2 >> 13)) &* 3_266_489_909)
    h2 = ((h2 ^ (h2 >> 16)) &* 2_246_822_507) ^ ((h1 ^ (h1 >> 13)) &* 3_266_489_909)
    return String(h2, radix: 36) + String(h1, radix: 36)
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
