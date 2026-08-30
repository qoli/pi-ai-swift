import Foundation

struct BedrockConverseStreamAdapter: WireProtocolAdapter {
  let protocolID = "bedrock-converse-stream"
  private let signingDate: Date?

  init(signingDate: Date? = nil) {
    self.signingDate = signingDate
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
              request,
              "bedrock.response",
              "Bedrock ConverseStream request failed (HTTP \(response.statusCode))",
              cause: body
            )
          }
          let responseID = try requireResponseID(response.headers, request: request)
          var decoder = AWSEventStreamDecoder()
          var reducer = BedrockEventReducer(
            providerID: request.providerID,
            requestedModelID: request.modelID,
            responseID: responseID
          )
          for try await chunk in response.body {
            try Task.checkCancellation()
            for message in try decoder.append(chunk) {
              for event in try reducer.reduce(message) {
                continuation.yield(event)
              }
            }
          }
          for message in try decoder.finish() {
            for event in try reducer.reduce(message) {
              continuation.yield(event)
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

  private func makeURLRequest(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> URLRequest {
    let endpoint = try endpointURL(baseURL: context.baseURL, modelID: request.modelID)
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue(
      "application/vnd.amazon.eventstream",
      forHTTPHeaderField: "Accept"
    )
    urlRequest.setValue("application/json", forHTTPHeaderField: "x-amzn-bedrock-accept")
    for (name, value) in context.headers where !isReservedHeader(name) {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    urlRequest.httpBody = try encodeJSONObject(
      try makeBody(request, context: context),
      providerID: request.providerID,
      operation: "bedrock.request.encode"
    )
    switch context.credential {
    case .apiKey(let credential):
      guard !credential.key.isEmpty else {
        throw failure(
          .invalidCredential,
          request,
          "bedrock.request.auth",
          "Bedrock credential secret is empty"
        )
      }
      switch credential.metadata["authentication"] ?? "bearer" {
      case "bearer":
        urlRequest.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
      case "sigv4":
        guard let accessKeyID = credential.metadata["accessKeyID"],
          !accessKeyID.isEmpty
        else {
          throw failure(
            .invalidCredential,
            request,
            "bedrock.request.auth",
            "Bedrock SigV4 credential is missing accessKeyID metadata"
          )
        }
        try AWSSignatureV4.sign(
          &urlRequest,
          credential: AWSSignatureV4Credential(
            accessKeyID: accessKeyID,
            secretAccessKey: credential.key,
            sessionToken: credential.metadata["sessionToken"]
          ),
          region: try resolvedRegion(
            request: request,
            endpoint: endpoint,
            metadata: credential.metadata
          ),
          service: "bedrock",
          date: signingDate ?? Date()
        )
      case let method:
        throw failure(
          .unsupportedCapability,
          request,
          "bedrock.request.auth",
          "unsupported Bedrock authentication method: \(method)"
        )
      }
    case .oauth:
      throw failure(
        .unsupportedCapability,
        request,
        "bedrock.request.auth",
        "Bedrock OAuth credentials are unsupported"
      )
    case nil:
      throw failure(
        .missingCredential,
        request,
        "bedrock.request.auth",
        "Bedrock credential is missing"
      )
    }
    return urlRequest
  }

  private func resolvedRegion(
    request: ProviderRequest,
    endpoint: URL,
    metadata: [String: String]
  ) throws -> String {
    if let region = metadata["region"], !region.isEmpty { return region }
    let arnParts = request.modelID.split(
      separator: ":",
      omittingEmptySubsequences: false
    )
    if arnParts.count > 3, arnParts[0] == "arn", arnParts[1] == "aws",
      !arnParts[3].isEmpty
    {
      return String(arnParts[3])
    }
    if let host = endpoint.host {
      let parts = host.split(separator: ".")
      if parts.count >= 4, parts[0] == "bedrock-runtime", !parts[1].isEmpty {
        return String(parts[1])
      }
    }
    throw failure(
      .invalidCredential,
      request,
      "bedrock.request.region",
      "Bedrock SigV4 requires explicit region metadata for this endpoint"
    )
  }

  private func makeBody(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: JSONValue] {
    let supportedOptions: Set<String> = [
      "additionalModelRequestFields", "interleavedThinking", "requestMetadata",
      "thinkingBudgets", "thinkingDisplay", "toolChoice",
    ]
    let unknown = Set(request.options.providerOptions.keys).subtracting(supportedOptions)
    guard unknown.isEmpty else {
      throw failure(
        .unsupportedCapability,
        request,
        "bedrock.request.options",
        "unsupported Bedrock provider options: \(unknown.sorted().joined(separator: ", "))"
      )
    }
    var body: [String: JSONValue] = [
      "messages": .array(try messages(request.messages))
    ]
    let systems = request.messages.compactMap { message -> JSONValue? in
      guard case .system(let text) = message else { return nil }
      return .object(["text": .string(nonBlank(text))])
    }
    if !systems.isEmpty { body["system"] = .array(systems) }

    var inference: [String: JSONValue] = [:]
    if let maximum = request.options.maximumOutputTokens ?? context.model.maximumOutputTokens {
      inference["maxTokens"] = .integer(Int64(maximum))
    }
    if let temperature = request.options.temperature {
      inference["temperature"] = .number(temperature)
    }
    if !inference.isEmpty { body["inferenceConfig"] = .object(inference) }

    if !request.tools.isEmpty {
      var toolConfiguration: [String: JSONValue] = [
        "tools": .array(
          request.tools.map { tool in
            .object([
              "toolSpec": .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": .object(["json": tool.inputSchema]),
              ])
            ])
          }
        )
      ]
      if let choice = request.options.providerOptions["toolChoice"] {
        toolConfiguration["toolChoice"] = choice
      }
      body["toolConfig"] = .object(toolConfiguration)
    } else if request.options.providerOptions["toolChoice"] != nil {
      throw failure(
        .invalidRequest,
        request,
        "bedrock.request.tool-choice",
        "Bedrock toolChoice requires at least one tool"
      )
    }
    var additionalFields = try reasoningFields(request, context: context)
    if let fields = request.options.providerOptions["additionalModelRequestFields"] {
      guard case .object(let custom) = fields else {
        throw failure(
          .invalidRequest,
          request,
          "bedrock.request.additional-fields",
          "Bedrock additionalModelRequestFields must be an object"
        )
      }
      for (key, value) in custom {
        guard additionalFields[key] == nil else {
          throw failure(
            .invalidRequest,
            request,
            "bedrock.request.additional-fields",
            "Bedrock additionalModelRequestFields conflicts with reasoning field: \(key)"
          )
        }
        additionalFields[key] = value
      }
    }
    if !additionalFields.isEmpty {
      body["additionalModelRequestFields"] = .object(additionalFields)
    }
    if let metadata = request.options.providerOptions["requestMetadata"] {
      body["requestMetadata"] = metadata
    }
    if request.options.responseSchema != nil {
      throw failure(
        .unsupportedCapability,
        request,
        "bedrock.request.schema",
        "Bedrock structured response schemas are not implemented"
      )
    }
    return body
  }

  private func reasoningFields(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: JSONValue] {
    guard let requested = request.options.reasoningEffort else { return [:] }
    guard context.model.capabilities.reasoning else {
      throw failure(
        .unsupportedCapability,
        request,
        "bedrock.request.reasoning",
        "Bedrock model does not support reasoning"
      )
    }
    let candidates = [context.model.id, context.model.name].flatMap { value in
      let lower = value.lowercased()
      return [
        lower, lower.replacingOccurrences(of: #"[\s_.:]+"#, with: "-", options: .regularExpression),
      ]
    }
    guard candidates.contains(where: { $0.contains("anthropic") || $0.contains("claude") })
    else {
      return [:]
    }
    let adaptive = candidates.contains { value in
      ["opus-4-6", "opus-4-7", "opus-4-8", "opus-5", "sonnet-4-6", "sonnet-5", "fable-5"]
        .contains { value.contains($0) }
    }
    let display =
      request.options.providerOptions["thinkingDisplay"]?.stringValue
      ?? "summarized"
    if adaptive {
      return [
        "thinking": .object([
          "type": .string("adaptive"),
          "display": .string(display),
        ]),
        "output_config": .object([
          "effort": .string(
            try reasoningEffort(
              requested,
              candidates: candidates,
              context: context,
              request: request
            )
          )
        ]),
      ]
    }

    let defaults = [
      "minimal": 1_024,
      "low": 2_048,
      "medium": 8_192,
      "high": 16_384,
      "xhigh": 16_384,
      "max": 16_384,
    ]
    guard var budget = defaults[requested] else {
      throw failure(
        .invalidRequest,
        request,
        "bedrock.request.reasoning",
        "unsupported Bedrock reasoning effort: \(requested)"
      )
    }
    if case .object(let custom)? = request.options.providerOptions["thinkingBudgets"],
      let configured = custom[requested]?.integerValue
    {
      guard configured > 0 else {
        throw failure(
          .invalidRequest,
          request,
          "bedrock.request.reasoning",
          "Bedrock reasoning budget must be positive"
        )
      }
      budget = configured
    }
    let outputLimit =
      request.options.maximumOutputTokens
      ?? context.model.maximumOutputTokens ?? budget + 1_024
    budget = min(budget, max(0, outputLimit - 1_024))
    guard budget > 0 else {
      throw failure(
        .invalidRequest,
        request,
        "bedrock.request.reasoning",
        "Bedrock output limit leaves no room for reasoning"
      )
    }
    var result: [String: JSONValue] = [
      "thinking": .object([
        "type": .string("enabled"),
        "budget_tokens": .integer(Int64(budget)),
        "display": .string(display),
      ])
    ]
    if request.options.providerOptions["interleavedThinking"]?.boolValue != false {
      result["anthropic_beta"] = .array([
        .string("interleaved-thinking-2025-05-14")
      ])
    }
    return result
  }

  private func reasoningEffort(
    _ requested: String,
    candidates: [String],
    context: WireProtocolContext,
    request: ProviderRequest
  ) throws -> String {
    if let mapped = context.modelConfiguration.metadata
      .object("thinkingLevelMap")?.string(requested)
    {
      return mapped
    }
    let supportsXHigh = candidates.contains { value in
      ["opus-4-7", "opus-4-8", "opus-5", "sonnet-5", "fable-5"]
        .contains { value.contains($0) }
    }
    if requested == "xhigh", supportsXHigh { return "xhigh" }
    switch requested {
    case "minimal", "low": return "low"
    case "medium": return "medium"
    case "high": return "high"
    case "xhigh", "max": return "high"
    default:
      throw failure(
        .invalidRequest,
        request,
        "bedrock.request.reasoning",
        "unsupported Bedrock reasoning effort: \(requested)"
      )
    }
  }

  private func messages(_ messages: [ProviderMessage]) throws -> [JSONValue] {
    try messages.compactMap { message in
      switch message {
      case .system:
        return nil
      case .user(let content):
        return .object([
          "role": .string("user"),
          "content": .array(try content.map(userContent)),
        ])
      case .assistant(let content):
        let values = content.compactMap(assistantContent)
        guard !values.isEmpty else { return nil }
        return .object(["role": .string("assistant"), "content": .array(values)])
      case .toolResult(let result):
        return .object([
          "role": .string("user"),
          "content": .array([
            .object([
              "toolResult": .object([
                "toolUseId": .string(normalizeToolID(result.toolCallID)),
                "status": .string(result.isError ? "error" : "success"),
                "content": .array(try result.content.map(toolResultContent)),
              ])
            ])
          ]),
        ])
      }
    }
  }

  private func userContent(_ content: ProviderUserContent) throws -> JSONValue {
    switch content {
    case .text(let text):
      .object(["text": .string(nonBlank(text))])
    case .image(.data(let data, let mimeType)):
      try image(data: data, mimeType: mimeType)
    case .image(.remoteURL):
      throw ProviderRuntimeFailure(
        code: .unsupportedCapability,
        message: "Bedrock requires inline image bytes",
        providerID: "amazon-bedrock",
        operation: "bedrock.request.image",
        causeDescription: nil
      )
    }
  }

  private func assistantContent(_ content: ProviderAssistantContent) -> JSONValue? {
    switch content {
    case .text(let text):
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return .object(["text": .string(text)])
    case .reasoning(let reasoning):
      var value: [String: JSONValue] = ["text": .string(reasoning.text)]
      if let signature = reasoning.signature { value["signature"] = .string(signature) }
      return .object(["reasoningContent": .object(["reasoningText": .object(value)])])
    case .toolCall(let call):
      return .object([
        "toolUse": .object([
          "toolUseId": .string(normalizeToolID(call.id)),
          "name": .string(call.name),
          "input": sanitizeDocument(call.arguments),
        ])
      ])
    }
  }

  private func toolResultContent(_ content: ProviderToolResultContent) throws -> JSONValue {
    switch content {
    case .text(let text): .object(["text": .string(nonBlank(text))])
    case .image(.data(let data, let mimeType)): try image(data: data, mimeType: mimeType)
    case .image(.remoteURL):
      throw ProviderRuntimeFailure(
        code: .unsupportedCapability,
        message: "Bedrock requires inline image bytes",
        providerID: "amazon-bedrock",
        operation: "bedrock.request.tool-image",
        causeDescription: nil
      )
    }
  }

  private func image(data: Data, mimeType: String) throws -> JSONValue {
    let format: String
    switch mimeType.lowercased() {
    case "image/png": format = "png"
    case "image/jpeg", "image/jpg": format = "jpeg"
    case "image/gif": format = "gif"
    case "image/webp": format = "webp"
    default:
      throw ProviderRuntimeFailure(
        code: .unsupportedCapability,
        message: "unsupported Bedrock image MIME type: \(mimeType)",
        providerID: "amazon-bedrock",
        operation: "bedrock.request.image",
        causeDescription: nil
      )
    }
    return .object([
      "image": .object([
        "format": .string(format),
        "source": .object(["bytes": .string(data.base64EncodedString())]),
      ])
    ])
  }

  private func sanitizeDocument(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object):
      return .object(
        object.reduce(into: [:]) { result, item in
          guard !item.key.isEmpty else { return }
          result[item.key] = sanitizeDocument(item.value)
        }
      )
    case .array(let values): return .array(values.map(sanitizeDocument))
    default: return value
    }
  }

  private func nonBlank(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "<empty>" : text
  }

  private func normalizeToolID(_ value: String) -> String {
    let valid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    let sanitized = value.unicodeScalars.map { valid.contains($0) ? Character(String($0)) : "_" }
    return String(sanitized.prefix(64))
  }

  private func isReservedHeader(_ name: String) -> Bool {
    let value = name.lowercased()
    return value == "authorization" || value == "host" || value.hasPrefix("x-amz-")
  }

  private func endpointURL(baseURL: URL, modelID: String) throws -> URL {
    let unreserved = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: "-._~")
    )
    guard
      let encodedModelID = modelID.addingPercentEncoding(
        withAllowedCharacters: unreserved
      ),
      let endpoint = URL(
        string:
          baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          + "/model/\(encodedModelID)/converse-stream"
      )
    else {
      throw ProviderRuntimeFailure(
        code: .invalidRequest,
        message: "Bedrock model identifier cannot be encoded into the endpoint",
        providerID: "amazon-bedrock",
        operation: "bedrock.request.url",
        causeDescription: nil
      )
    }
    return endpoint
  }

  private func requireResponseID(
    _ headers: [String: String],
    request: ProviderRequest
  ) throws -> String {
    guard
      let value = headers.first(where: { $0.key.lowercased() == "x-amzn-requestid" })?.value,
      !value.isEmpty
    else {
      throw failure(
        .invalidResponse,
        request,
        "bedrock.response.identity",
        "Bedrock response is missing x-amzn-requestid"
      )
    }
    return value
  }

  private func failure(
    _ code: ProviderRuntimeFailure.Code,
    _ request: ProviderRequest,
    _ operation: String,
    _ message: String,
    cause: String? = nil
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: code,
      message: message,
      providerID: request.providerID,
      operation: operation,
      causeDescription: cause
    )
  }
}

private struct BedrockEventReducer {
  let providerID: String
  let requestedModelID: String
  let responseID: String
  private var started = false
  private var stopReason: ProviderFinishReason?
  private var completed = false
  private var tools: [Int: ToolState] = [:]

  init(providerID: String, requestedModelID: String, responseID: String) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
    self.responseID = responseID
  }

  mutating func reduce(_ message: AWSEventStreamMessage) throws -> [ProviderEvent] {
    let messageType = message.headers[":message-type"] ?? "event"
    let eventType = message.headers[":event-type"] ?? message.headers[":exception-type"]
    let object = try decodeJSONObject(
      message.payload,
      providerID: providerID,
      operation: "bedrock.event.decode"
    )
    if messageType == "exception" || eventType?.hasSuffix("Exception") == true {
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: object.string("message")
          ?? "Bedrock stream returned \(eventType ?? "an exception")",
        providerID: providerID,
        operation: "bedrock.event.error",
        causeDescription: eventType
      )
    }
    guard messageType == "event", let eventType else {
      throw invalid("Bedrock event is missing a supported message type")
    }
    switch eventType {
    case "messageStart":
      guard object.string("role") == "assistant", !started else {
        throw invalid("Bedrock messageStart is invalid")
      }
      started = true
      return [
        .responseStarted(
          ProviderResponseMetadata(
            responseID: responseID,
            providerID: providerID,
            modelID: requestedModelID,
            providerMetadata: [:]
          )
        )
      ]
    case "contentBlockStart":
      guard let index = object.int("contentBlockIndex") else {
        throw invalid("Bedrock contentBlockStart is missing an index")
      }
      guard let tool = object.object("start")?.object("toolUse") else { return [] }
      guard let id = tool.string("toolUseId"), let name = tool.string("name") else {
        throw invalid("Bedrock tool start is missing identity")
      }
      tools[index] = ToolState(id: id, name: name, input: "")
      return [.toolCallStarted(id: id, name: name)]
    case "contentBlockDelta":
      guard let index = object.int("contentBlockIndex"), let delta = object.object("delta") else {
        throw invalid("Bedrock contentBlockDelta is malformed")
      }
      if let text = delta.string("text") { return [.textDelta(text)] }
      if let reasoning = delta.object("reasoningContent")?.string("text") {
        return [.reasoningDelta(reasoning)]
      }
      if let reasoningContent = delta.object("reasoningContent"),
        let signature = reasoningContent.string("signature"), !signature.isEmpty
      {
        return [.reasoningSignatureDelta(signature)]
      }
      if let reasoningContent = delta.object("reasoningContent"),
        let redacted = reasoningContent.string("redactedContent"),
        !redacted.isEmpty
      {
        guard Data(base64Encoded: redacted) != nil else {
          throw invalid("Bedrock redacted reasoning content is malformed")
        }
        return [.reasoningSignatureDelta(redacted)]
      }
      if let input = delta.object("toolUse")?.string("input") {
        guard var tool = tools[index] else {
          throw invalid("Bedrock tool delta has no matching tool start")
        }
        tool.input += input
        tools[index] = tool
        return [.toolInputDelta(id: tool.id, delta: input)]
      }
      throw invalid("Bedrock content delta has no supported content")
    case "contentBlockStop":
      guard let index = object.int("contentBlockIndex") else {
        throw invalid("Bedrock contentBlockStop is missing an index")
      }
      guard let tool = tools.removeValue(forKey: index) else { return [] }
      let arguments: JSONValue
      if tool.input.isEmpty {
        arguments = .object([:])
      } else {
        do {
          arguments = try JSONDecoder().decode(JSONValue.self, from: Data(tool.input.utf8))
        } catch {
          throw invalid("Bedrock tool input is malformed JSON")
        }
      }
      return [
        .toolCallCompleted(
          ProviderToolCall(id: tool.id, name: tool.name, arguments: arguments)
        )
      ]
    case "messageStop":
      guard let reason = object.string("stopReason") else {
        throw invalid("Bedrock messageStop is missing stopReason")
      }
      stopReason = try mapStopReason(reason)
      return []
    case "metadata":
      guard let reason = stopReason else {
        throw invalid("Bedrock metadata arrived before messageStop")
      }
      guard !completed else { throw invalid("Bedrock emitted duplicate metadata") }
      completed = true
      var events: [ProviderEvent] = []
      if let usage = object.object("usage") {
        events.append(
          .usage(
            ProviderUsage(
              inputTokens: usage.int("inputTokens"),
              outputTokens: usage.int("outputTokens"),
              reasoningTokens: nil,
              cachedInputTokens: usage.int("cacheReadInputTokens"),
              providerMetadata: usage
            )
          )
        )
      }
      events.append(.completed(reason))
      return events
    default:
      throw invalid("unsupported Bedrock event: \(eventType)")
    }
  }

  mutating func finish() throws -> [ProviderEvent] {
    guard started, let reason = stopReason else {
      throw invalid("Bedrock stream ended without messageStart and messageStop")
    }
    guard tools.isEmpty else { throw invalid("Bedrock stream ended with incomplete tool calls") }
    if completed { return [] }
    completed = true
    return [.completed(reason)]
  }

  private func mapStopReason(_ value: String) throws -> ProviderFinishReason {
    switch value {
    case "end_turn", "stop_sequence": return .stop
    case "max_tokens", "model_context_window_exceeded": return .length
    case "tool_use": return .toolCalls
    default: throw invalid("unsupported Bedrock stop reason: \(value)")
    }
  }

  private func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: providerID,
      operation: "bedrock.event.reduce",
      causeDescription: nil
    )
  }

  private struct ToolState {
    let id: String
    let name: String
    var input: String
  }
}
