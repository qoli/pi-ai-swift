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
            responseID: responseID,
            pricing: try ProviderUsagePricing.parse(
              metadata: context.modelConfiguration.metadata,
              providerID: request.providerID,
              operation: "bedrock.usage.pricing")
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
    try request.validateSingleSystemMessage(operation: "bedrock.request.system")
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

    let supportedOptions: Set<String> = [
      "additionalModelRequestFields", "interleavedThinking", "requestMetadata",
      "forcePromptCaching", "thinkingDisplay",
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
    let cacheControl = bedrockCachePoint(request, context: context)
    var body: [String: JSONValue] = [
      "messages": .array(
        try messages(
          request.messages.insertingMissingToolResults(),
          context: context,
          cachePoint: cacheControl
        ))
    ]
    var systems = request.messages.compactMap { message -> JSONValue? in
      guard case .system(let text) = message else { return nil }
      return .object(["text": .string(nonBlank(text))])
    }
    if let cacheControl, !systems.isEmpty { systems.append(cacheControl) }
    if !systems.isEmpty { body["system"] = .array(systems) }

    var inference: [String: JSONValue] = [:]
    if let maximum = try effectiveMaximumOutputTokens(request, context: context) {
      inference["maxTokens"] = .integer(Int64(maximum))
    }
    if let temperature = request.options.temperature {
      inference["temperature"] = .number(temperature)
    }
    if !inference.isEmpty { body["inferenceConfig"] = .object(inference) }

    if !request.tools.isEmpty, request.options.toolChoice?.stringValue != "none" {
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
      if let choice = request.options.toolChoice {
        switch choice {
        case .string("auto"):
          toolConfiguration["toolChoice"] = .object(["auto": .object([:])])
        case .string("any"):
          toolConfiguration["toolChoice"] = .object(["any": .object([:])])
        case .string("none"):
          break
        case .object(let value) where value.string("type") == "tool":
          guard let name = value.string("name"), !name.isEmpty else {
            throw failure(
              .invalidRequest, request, "bedrock.request.tool-choice",
              "Bedrock named tool choice requires a non-empty name")
          }
          toolConfiguration["toolChoice"] = .object(["tool": .object(["name": .string(name)])])
        default:
          throw failure(
            .invalidRequest,
            request,
            "bedrock.request.tool-choice",
            "unsupported Bedrock tool choice"
          )
        }
      }
      body["toolConfig"] = .object(toolConfiguration)
    } else if request.tools.isEmpty, request.options.toolChoice != nil {
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
      if requested == .off { return [:] }
      throw failure(
        .unsupportedCapability,
        request,
        "bedrock.request.reasoning",
        "Bedrock model does not support reasoning"
      )
    }
    guard requested != .off else { return [:] }
    let candidates = [context.model.id, context.model.name].flatMap { value in
      let lower = value.lowercased()
      return [
        lower, lower.replacingOccurrences(of: #"[\s_.:]+"#, with: "-", options: .regularExpression),
      ]
    }
    guard
      ProviderBedrockModel.isAnthropicClaude(
        id: context.model.id,
        name: context.model.name
      )
    else {
      // The pinned upstream forwards the reasoning option for non-Claude Bedrock
      // models but does not encode provider-specific request fields for it.
      return [:]
    }
    let adaptive = candidates.contains { value in
      ["opus-4-6", "opus-4-7", "opus-4-8", "opus-5", "sonnet-4-6", "sonnet-5", "fable-5"]
        .contains { value.contains($0) }
    }
    let display = request.options.providerOptions["thinkingDisplay"]?.stringValue ?? "summarized"
    let omitDisplay = isGovCloudTarget(request: request, context: context)
    if adaptive {
      var thinking: [String: JSONValue] = ["type": .string("adaptive")]
      if !omitDisplay { thinking["display"] = .string(display) }
      return [
        "thinking": .object(thinking),
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
    guard var budget = defaults[requested.rawValue] else {
      throw failure(
        .invalidRequest,
        request,
        "bedrock.request.reasoning",
        "unsupported Bedrock reasoning effort: \(requested)"
      )
    }
    let customLevel: ProviderReasoningEffort =
      requested == .xhigh || requested == .max ? .high : requested
    if let configured = request.options.thinkingBudgets?[customLevel] {
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
    let outputLimit = try effectiveMaximumOutputTokens(request, context: context) ?? budget + 1_024
    budget = min(budget, max(0, outputLimit - 1_024))
    guard budget > 0 else {
      throw failure(
        .invalidRequest,
        request,
        "bedrock.request.reasoning",
        "Bedrock output limit leaves no room for reasoning"
      )
    }
    var thinking: [String: JSONValue] = [
      "type": .string("enabled"), "budget_tokens": .integer(Int64(budget)),
    ]
    if !omitDisplay { thinking["display"] = .string(display) }
    var result: [String: JSONValue] = ["thinking": .object(thinking)]
    if request.options.providerOptions["interleavedThinking"]?.boolValue != false {
      result["anthropic_beta"] = .array([
        .string("interleaved-thinking-2025-05-14")
      ])
    }
    return result
  }

  private func reasoningEffort(
    _ requested: ProviderReasoningEffort,
    candidates: [String],
    context: WireProtocolContext,
    request: ProviderRequest
  ) throws -> String {
    if let mapped = context.modelConfiguration.metadata
      .object("thinkingLevelMap")?.string(requested.rawValue)
    {
      return mapped
    }
    let supportsXHigh = candidates.contains { value in
      ["opus-4-7", "opus-4-8", "opus-5", "sonnet-5", "fable-5"]
        .contains { value.contains($0) }
    }
    if requested == .xhigh, supportsXHigh { return "xhigh" }
    switch requested {
    case .minimal, .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    case .xhigh, .max: return "high"
    default:
      throw failure(
        .invalidRequest,
        request,
        "bedrock.request.reasoning",
        "unsupported Bedrock reasoning effort: \(requested)"
      )
    }
  }

  private func messages(
    _ messages: [ProviderMessage],
    context: WireProtocolContext,
    cachePoint: JSONValue?
  ) throws -> [JSONValue] {
    let target = ProviderMessageSource(
      api: protocolID, providerID: context.provider.id, modelID: context.model.id)
    let supportsSignature = bedrockSupportsThinkingSignature(context.model)
    var result: [JSONValue] = try messages.compactMap { message -> JSONValue? in
      switch message {
      case .system:
        return nil
      case .user(let content):
        return .object([
          "role": .string("user"),
          "content": .array(try content.map(userContent)),
        ])
      case .userMessage(let user):
        return .object([
          "role": .string("user"),
          "content": .array(try user.content.map(userContent)),
        ])
      case .assistant(let content):
        let values = content.compactMap {
          assistantContent($0, supportsSignature: supportsSignature)
        }
        guard !values.isEmpty else { return nil }
        return .object(["role": .string("assistant"), "content": .array(values)])
      case .assistantMessage(let assistant):
        guard let content = assistant.replayContent(for: target) else { return nil }
        let values = content.compactMap {
          assistantContent($0, supportsSignature: supportsSignature)
        }
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
    result = groupingConsecutiveToolResults(result)
    if let cachePoint, let index = result.indices.last,
      result[index].objectValue?.string("role") == "user",
      case .object(var message) = result[index], case .array(var content)? = message["content"]
    {
      content.append(cachePoint)
      message["content"] = .array(content)
      result[index] = .object(message)
    }
    return result
  }

  private func groupingConsecutiveToolResults(_ messages: [JSONValue]) -> [JSONValue] {
    var grouped: [JSONValue] = []
    for value in messages {
      guard case .object(let message) = value,
        message.string("role") == "user",
        case .array(let content)? = message["content"],
        content.allSatisfy({ $0.objectValue?["toolResult"] != nil }),
        let last = grouped.indices.last,
        case .object(var previous) = grouped[last],
        previous.string("role") == "user",
        case .array(let previousContent)? = previous["content"],
        previousContent.allSatisfy({ $0.objectValue?["toolResult"] != nil })
      else {
        grouped.append(value)
        continue
      }
      previous["content"] = .array(previousContent + content)
      grouped[last] = .object(previous)
    }
    return grouped
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

  private func assistantContent(
    _ content: ProviderAssistantContent,
    supportsSignature: Bool
  ) -> JSONValue? {
    switch content {
    case .text(let text):
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return .object(["text": .string(text)])
    case .signedText(let text):
      guard !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return .object(["text": .string(text.text)])
    case .reasoning(let reasoning):
      if reasoning.isRedacted == true {
        guard let signature = reasoning.signature,
          let bytes = Data(base64Encoded: signature), !bytes.isEmpty
        else { return nil }
        return .object([
          "reasoningContent": .object(["redactedContent": .string(bytes.base64EncodedString())])
        ])
      }
      if supportsSignature {
        guard let signature = reasoning.signature,
          !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .object(["text": .string(reasoning.text)]) }
        return .object([
          "reasoningContent": .object([
            "reasoningText": .object([
              "text": .string(reasoning.text), "signature": .string(signature),
            ])
          ])
        ])
      }
      return .object([
        "reasoningContent": .object([
          "reasoningText": .object(["text": .string(reasoning.text)])
        ])
      ])
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

  private func bedrockSupportsThinkingSignature(_ model: ProviderModel) -> Bool {
    ProviderBedrockModel.isAnthropicClaude(id: model.id, name: model.name)
  }

  private func effectiveMaximumOutputTokens(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> Int? {
    guard let requested = request.options.maximumOutputTokens ?? context.model.maximumOutputTokens
    else {
      return nil
    }
    guard let effort = request.options.reasoningEffort, effort != .off,
      ProviderBedrockModel.isAnthropicClaude(id: context.model.id, name: context.model.name)
    else { return requested }
    let candidates = [context.model.id, context.model.name].map {
      $0.lowercased().replacingOccurrences(
        of: #"[\s_.:]+"#, with: "-", options: .regularExpression)
    }
    let adaptive = candidates.contains { value in
      ["opus-4-6", "opus-4-7", "opus-4-8", "opus-5", "sonnet-4-6", "sonnet-5", "fable-5"]
        .contains { value.contains($0) }
    }
    guard !adaptive else { return requested }
    let level: ProviderReasoningEffort = effort == .xhigh || effort == .max ? .high : effort
    let defaults: [ProviderReasoningEffort: Int] = [
      .minimal: 1_024, .low: 2_048, .medium: 8_192, .high: 16_384,
    ]
    guard let budget = request.options.thinkingBudgets?[level] ?? defaults[level] else {
      return requested
    }
    return min(requested + budget, context.model.maximumOutputTokens ?? requested + budget)
  }

  private func bedrockCachePoint(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) -> JSONValue? {
    guard request.options.cacheRetention != .none,
      supportsPromptCaching(context: context)
    else { return nil }
    var point: [String: JSONValue] = ["type": .string("default")]
    if request.options.cacheRetention == .long { point["ttl"] = .string("1h") }
    return .object(["cachePoint": .object(point)])
  }

  private func supportsPromptCaching(context: WireProtocolContext) -> Bool {
    if context.modelConfiguration.metadata.bool("forcePromptCaching") == true { return true }
    let candidates = [context.model.id, context.model.name].map {
      $0.lowercased().replacingOccurrences(
        of: #"[\s_.:]+"#, with: "-", options: .regularExpression)
    }
    guard candidates.contains(where: { $0.contains("claude") }) else { return false }
    return candidates.contains { value in
      value.contains("fable-5") || value.contains("opus-5") || value.contains("sonnet-5")
        || value.contains("-4-") || value.contains("claude-3-7-sonnet")
        || value.contains("claude-3-5-haiku")
    }
  }

  private func isGovCloudTarget(
    request: ProviderRequest,
    context: WireProtocolContext
  ) -> Bool {
    if case .apiKey(let credential) = context.credential,
      credential.metadata["region"]?.lowercased().hasPrefix("us-gov-") == true
    {
      return true
    }
    let modelID = request.modelID.lowercased()
    return modelID.hasPrefix("us-gov.") || modelID.hasPrefix("arn:aws-us-gov:")
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
  let pricing: ProviderUsagePricing?
  private var started = false
  private var stopReason: ProviderFinishReason?
  private var rawStopReason: String?
  private var completed = false
  private var tools: [Int: ToolState] = [:]
  private var completedTools: [Int: ProviderToolCall] = [:]
  private var textBlocks: [Int: String] = [:]
  private var reasoningBlocks: [Int: ReasoningState] = [:]
  private var usage = ProviderUsage(
    inputTokens: 0,
    outputTokens: 0,
    reasoningTokens: nil,
    cachedInputTokens: 0,
    cacheWriteTokens: 0,
    totalTokens: 0,
    providerMetadata: [:]
  )

  init(
    providerID: String,
    requestedModelID: String,
    responseID: String,
    pricing: ProviderUsagePricing?
  ) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
    self.responseID = responseID
    self.pricing = pricing
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
      if let text = delta.string("text") {
        textBlocks[index, default: ""] += text
        return [.textDelta(text)]
      }
      if let reasoning = delta.object("reasoningContent")?.string("text") {
        var state = reasoningBlocks[index] ?? ReasoningState()
        state.text += reasoning
        reasoningBlocks[index] = state
        return [.reasoningDelta(reasoning)]
      }
      if let reasoningContent = delta.object("reasoningContent"),
        let signature = reasoningContent.string("signature"), !signature.isEmpty
      {
        var state = reasoningBlocks[index] ?? ReasoningState()
        if !state.isRedacted { state.signature += signature }
        reasoningBlocks[index] = state
        return [.reasoningSignatureDelta(signature)]
      }
      if let reasoningContent = delta.object("reasoningContent"),
        let redacted = reasoningContent.string("redactedContent"),
        !redacted.isEmpty
      {
        guard let bytes = Data(base64Encoded: redacted) else {
          throw invalid("Bedrock redacted reasoning content is malformed")
        }
        var state = reasoningBlocks[index] ?? ReasoningState()
        let first = !state.isRedacted
        if first {
          state.isRedacted = true
          state.signature = ""
          state.text += "[Reasoning redacted]"
        }
        state.redactedBytes.append(bytes)
        reasoningBlocks[index] = state
        return first ? [.reasoningDelta("[Reasoning redacted]")] : []
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
      if let reasoning = reasoningBlocks[index], reasoning.isRedacted,
        !reasoning.redactedBytes.isEmpty
      {
        return [.reasoningSignatureDelta(reasoning.redactedBytes.base64EncodedString())]
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
      let call = ProviderToolCall(id: tool.id, name: tool.name, arguments: arguments)
      completedTools[index] = call
      return [.toolCallCompleted(call)]
    case "messageStop":
      guard let reason = object.string("stopReason") else {
        throw invalid("Bedrock messageStop is missing stopReason")
      }
      rawStopReason = reason
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
        guard let pricing else {
          throw ProviderRuntimeFailure(
            code: .upstreamDrift, message: "model cost rates are missing",
            providerID: providerID, operation: "bedrock.usage.pricing",
            causeDescription: nil)
        }
        let input = usage.int("inputTokens") ?? 0
        let output = usage.int("outputTokens") ?? 0
        let cacheRead = usage.int("cacheReadInputTokens") ?? 0
        let cacheWrite = usage.int("cacheWriteInputTokens") ?? 0
        self.usage = ProviderUsage(
          inputTokens: input,
          outputTokens: output,
          reasoningTokens: nil,
          cachedInputTokens: cacheRead,
          cacheWriteTokens: cacheWrite,
          totalTokens: usage.int("totalTokens")
            ?? input + output,
          providerMetadata: usage,
          cost: pricing.cost(
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
        )
        events.append(.usage(self.usage))
      }
      events.append(responseSnapshot(reason))
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
    return [.usage(usage), responseSnapshot(reason), .completed(reason)]
  }

  private func responseSnapshot(_ reason: ProviderFinishReason) -> ProviderEvent {
    let indices = Set(textBlocks.keys)
      .union(reasoningBlocks.keys)
      .union(completedTools.keys)
      .sorted()
    let content = indices.compactMap { index -> ProviderResponseContent? in
      if let reasoning = reasoningBlocks[index] {
        let signature =
          reasoning.isRedacted
          ? reasoning.redactedBytes.base64EncodedString()
          : reasoning.signature
        return .reasoning(
          ProviderReasoningContent(
            text: reasoning.text,
            signature: signature.isEmpty ? nil : signature,
            isRedacted: reasoning.isRedacted ? true : nil,
            providerMetadata: [:]
          ))
      }
      if let text = textBlocks[index] {
        return .text(ProviderTextContent(text: text, signature: nil))
      }
      if let tool = completedTools[index] { return .toolCall(tool) }
      return nil
    }
    return .responseSnapshot(
      ProviderResponseSnapshot(
        responseID: nil,
        providerID: providerID,
        protocolID: "bedrock-converse-stream",
        modelID: requestedModelID,
        responseModelID: nil,
        content: content,
        usage: usage,
        finishReason: reason,
        rawFinishReason: rawStopReason,
        timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
        providerMetadata: ["transportRequestID": .string(responseID)]
      ))
  }

  private func mapStopReason(_ value: String) throws -> ProviderFinishReason {
    switch value {
    case "end_turn", "stop_sequence": return .stop
    case "max_tokens", "model_context_window_exceeded": return .length
    case "tool_use": return .toolCalls
    default:
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: "Provider stopped with: \(value)",
        providerID: providerID,
        operation: "bedrock.event.error",
        causeDescription: value
      )
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

  private struct ReasoningState {
    var text = ""
    var signature = ""
    var isRedacted = false
    var redactedBytes = Data()
  }
}
