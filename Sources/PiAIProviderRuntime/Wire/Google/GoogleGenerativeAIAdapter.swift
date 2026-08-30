import Foundation

struct GoogleGenerativeAIAdapter: WireProtocolAdapter {
  enum Flavor: Sendable, Equatable {
    case generativeAI
    case vertex
  }

  let protocolID: String
  let flavor: Flavor

  init(
    protocolID: String = "google-generative-ai",
    flavor: Flavor = .generativeAI
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
              operation: "google.response",
              message: "Google generation request failed (HTTP \(response.statusCode))",
              cause: body
            )
          }

          var decoder = ServerSentEventDecoder()
          var reducer = GoogleEventReducer(
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
          try Task.checkCancellation()
          for event in try decoder.finish() {
            for normalized in try reducer.reduce(event) {
              continuation.yield(normalized)
            }
          }
          for normalized in try reducer.finish() {
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
    let metadata = credentialMetadata(context.credential)
    let endpoint: URL
    switch flavor {
    case .generativeAI:
      endpoint = context.baseURL
        .appending(path: "models")
        .appending(path: "\(request.modelID):streamGenerateContent")
    case .vertex:
      let project = try requiredConfiguration(
        "project",
        aliases: ["projectID"],
        request: request,
        metadata: metadata
      )
      let location = try requiredConfiguration(
        "location",
        aliases: [],
        request: request,
        metadata: metadata
      )
      endpoint = context.baseURL
        .appending(path: "v1")
        .appending(path: "projects")
        .appending(path: project)
        .appending(path: "locations")
        .appending(path: location)
        .appending(path: "publishers")
        .appending(path: "google")
        .appending(path: "models")
        .appending(path: "\(request.modelID):streamGenerateContent")
    }

    guard
      var components = URLComponents(
        url: endpoint,
        resolvingAgainstBaseURL: false
      )
    else {
      throw failure(
        .invalidRequest,
        providerID: request.providerID,
        operation: "google.request.url",
        message: "Google generation URL is invalid"
      )
    }
    components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
    guard let url = components.url else {
      throw failure(
        .invalidRequest,
        providerID: request.providerID,
        operation: "google.request.url",
        message: "Google generation URL is invalid"
      )
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (name, value) in context.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    try applyCredential(
      context.credential,
      to: &urlRequest,
      providerID: request.providerID
    )
    urlRequest.httpBody = try encodeJSONObject(
      try makeBody(request, context: context),
      providerID: request.providerID,
      operation: "google.request.encode"
    )
    return urlRequest
  }

  private func applyCredential(
    _ credential: ProviderCredential?,
    to request: inout URLRequest,
    providerID: String
  ) throws {
    switch (flavor, credential) {
    case (_, .apiKey(let credential)) where !credential.key.isEmpty:
      request.setValue(credential.key, forHTTPHeaderField: "x-goog-api-key")
    case (.vertex, .oauth(let credential)) where !credential.accessToken.isEmpty:
      request.setValue(
        "Bearer \(credential.accessToken)",
        forHTTPHeaderField: "Authorization"
      )
    case (.generativeAI, .oauth):
      throw failure(
        .invalidCredential,
        providerID: providerID,
        operation: "google.request.auth",
        message: "Google Generative AI requires an API-key credential"
      )
    case (_, .apiKey), (.vertex, .oauth):
      throw failure(
        .invalidCredential,
        providerID: providerID,
        operation: "google.request.auth",
        message: "Google credential is empty"
      )
    case (_, nil):
      throw failure(
        .missingCredential,
        providerID: providerID,
        operation: "google.request.auth",
        message: "Google credential is missing"
      )
    }
  }

  private func makeBody(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: JSONValue] {
    var body: [String: JSONValue] = [
      "contents": .array(try makeContents(request.messages, modelID: request.modelID))
    ]
    let systems = request.messages.compactMap { message -> String? in
      guard case .system(let text) = message else { return nil }
      return text
    }
    if !systems.isEmpty {
      body["systemInstruction"] = .object([
        "parts": .array([
          .object(["text": .string(systems.joined(separator: "\n\n"))])
        ])
      ])
    }

    var generationConfig: [String: JSONValue] = [:]
    if let maximum = request.options.maximumOutputTokens
      ?? context.model.maximumOutputTokens
    {
      generationConfig["maxOutputTokens"] = .integer(Int64(maximum))
    }
    if let temperature = request.options.temperature {
      generationConfig["temperature"] = .number(temperature)
    }
    if let schema = request.options.responseSchema {
      generationConfig["responseMimeType"] = .string("application/json")
      generationConfig["responseJsonSchema"] = schema
    }
    if let effort = request.options.reasoningEffort {
      guard context.model.capabilities.reasoning else {
        throw failure(
          .unsupportedCapability,
          providerID: request.providerID,
          operation: "google.request.reasoning",
          message: "selected Google model does not support reasoning"
        )
      }
      generationConfig["thinkingConfig"] = .object(
        try thinkingConfiguration(effort: effort, modelID: request.modelID)
      )
    }
    if !generationConfig.isEmpty {
      body["generationConfig"] = .object(generationConfig)
    }

    if !request.tools.isEmpty {
      body["tools"] = .array([
        .object([
          "functionDeclarations": .array(
            request.tools.map { tool in
              .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parametersJsonSchema": tool.inputSchema,
              ])
            }
          )
        ])
      ])
      if let choice = request.options.providerOptions["toolChoice"]?.stringValue {
        guard let mode = toolChoiceMode(choice) else {
          throw failure(
            .invalidRequest,
            providerID: request.providerID,
            operation: "google.request.tool-choice",
            message: "unsupported Google tool choice: \(choice)"
          )
        }
        body["toolConfig"] = .object([
          "functionCallingConfig": .object(["mode": .string(mode)])
        ])
      }
    }
    return body
  }

  private func makeContents(
    _ messages: [ProviderMessage],
    modelID: String
  ) throws -> [JSONValue] {
    try messages.compactMap { message in
      switch message {
      case .system:
        nil
      case .user(let content):
        .object([
          "role": .string("user"),
          "parts": .array(try content.map(makeUserPart(_:))),
        ])
      case .assistant(let content):
        .object([
          "role": .string("model"),
          "parts": .array(try content.map { try makeAssistantPart($0, modelID: modelID) }),
        ])
      case .toolResult(let result):
        .object([
          "role": .string("user"),
          "parts": .array(try makeToolResultParts(result, modelID: modelID)),
        ])
      }
    }
  }

  private func makeUserPart(_ content: ProviderUserContent) throws -> JSONValue {
    switch content {
    case .text(let text):
      .object(["text": .string(text)])
    case .image(let image):
      try makeImagePart(image)
    }
  }

  private func makeAssistantPart(
    _ content: ProviderAssistantContent,
    modelID: String
  ) throws -> JSONValue {
    switch content {
    case .text(let text):
      return .object(["text": .string(text)])
    case .reasoning(let reasoning):
      var part: [String: JSONValue] = [
        "text": .string(reasoning.text),
        "thought": .bool(true),
      ]
      if let signature = reasoning.signature {
        guard Data(base64Encoded: signature) != nil else {
          throw failure(
            .invalidRequest,
            providerID: nil,
            operation: "google.request.thought-signature",
            message: "Google thought signature is not valid base64"
          )
        }
        part["thoughtSignature"] = .string(signature)
      }
      return .object(part)
    case .toolCall(let call):
      var functionCall: [String: JSONValue] = [
        "name": .string(call.name),
        "args": call.arguments,
      ]
      if requiresToolCallID(modelID) {
        functionCall["id"] = .string(normalizedToolCallID(call.id))
      }
      return .object(["functionCall": .object(functionCall)])
    }
  }

  private func makeToolResultParts(
    _ result: ProviderToolResult,
    modelID: String
  ) throws -> [JSONValue] {
    let texts = result.content.compactMap { content -> String? in
      guard case .text(let text) = content else { return nil }
      return text
    }
    let responseKey = result.isError ? "error" : "output"
    var functionResponse: [String: JSONValue] = [
      "name": .string(result.toolName),
      "response": .object([
        responseKey: .string(texts.joined(separator: "\n"))
      ]),
    ]
    if requiresToolCallID(modelID) {
      functionResponse["id"] = .string(normalizedToolCallID(result.toolCallID))
    }
    var parts: [JSONValue] = [
      .object(["functionResponse": .object(functionResponse)])
    ]
    for content in result.content {
      guard case .image(let image) = content else { continue }
      parts.append(try makeImagePart(image))
    }
    return parts
  }

  private func makeImagePart(_ image: ProviderImage) throws -> JSONValue {
    switch image {
    case .data(let data, let mimeType):
      .object([
        "inlineData": .object([
          "mimeType": .string(mimeType),
          "data": .string(data.base64EncodedString()),
        ])
      ])
    case .remoteURL:
      throw failure(
        .unsupportedCapability,
        providerID: nil,
        operation: "google.request.image",
        message: "Google generation requires image bytes instead of a remote URL"
      )
    }
  }

  private func thinkingConfiguration(
    effort: String,
    modelID: String
  ) throws -> [String: JSONValue] {
    guard ["minimal", "low", "medium", "high"].contains(effort) else {
      throw failure(
        .invalidRequest,
        providerID: nil,
        operation: "google.request.reasoning",
        message: "unsupported Google reasoning effort: \(effort)"
      )
    }
    let lower = modelID.lowercased()
    if lower.contains("gemini-3") || lower.contains("gemma-4") {
      let level: String
      if lower.contains("pro") {
        level = ["minimal", "low"].contains(effort) ? "LOW" : "HIGH"
      } else {
        level = effort.uppercased()
      }
      return [
        "includeThoughts": .bool(true),
        "thinkingLevel": .string(level),
      ]
    }

    let budgets: [String: Int]
    if lower.contains("2.5-pro") {
      budgets = ["minimal": 128, "low": 2_048, "medium": 8_192, "high": 32_768]
    } else if lower.contains("2.5-flash") {
      budgets = ["minimal": 128, "low": 2_048, "medium": 8_192, "high": 24_576]
    } else {
      budgets = ["minimal": -1, "low": -1, "medium": -1, "high": -1]
    }
    return [
      "includeThoughts": .bool(true),
      "thinkingBudget": .integer(Int64(budgets[effort]!)),
    ]
  }

  private func toolChoiceMode(_ value: String) -> String? {
    switch value {
    case "auto": "AUTO"
    case "none": "NONE"
    case "any": "ANY"
    default: nil
    }
  }

  private func requiredConfiguration(
    _ key: String,
    aliases: [String],
    request: ProviderRequest,
    metadata: [String: String]
  ) throws -> String {
    let optionKeys = [key] + aliases
    for optionKey in optionKeys {
      if let value = request.options.providerOptions[optionKey]?.stringValue,
        !value.isEmpty
      {
        return value
      }
    }
    for metadataKey in optionKeys {
      if let value = metadata[metadataKey], !value.isEmpty {
        return value
      }
    }
    throw failure(
      .invalidCredential,
      providerID: request.providerID,
      operation: "google-vertex.request.configuration",
      message: "Google Vertex credential is missing \(key) metadata"
    )
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

  private func requiresToolCallID(_ modelID: String) -> Bool {
    guard
      let match = modelID.range(
        of: #"^gemini(?:-live)?-([0-9]+)"#,
        options: .regularExpression
      )
    else { return modelID.hasPrefix("claude-") || modelID.hasPrefix("gpt-oss-") }
    let matched = String(modelID[match])
    let major = matched.split(separator: "-").last.flatMap { Int($0) }
    return (major ?? 0) >= 3
  }

  private func normalizedToolCallID(_ value: String) -> String {
    String(
      value
        .map { character in
          character.isLetter || character.isNumber || character == "_" || character == "-"
            ? character : "_"
        }
        .prefix(64)
    )
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

private struct GoogleEventReducer {
  let providerID: String
  let requestedModelID: String
  private var started = false
  private var finishReason: String?
  private var usage: ProviderUsage?
  private var sawToolCall = false
  private var toolCallIDs = Set<String>()
  private var generatedToolCallCount = 0

  init(providerID: String, requestedModelID: String) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
  }

  mutating func reduce(_ event: ServerSentEvent) throws -> [ProviderEvent] {
    guard event.data != "[DONE]" else { return [] }
    let object = try decodeJSONObject(
      Data(event.data.utf8),
      providerID: providerID,
      operation: "google.event.decode"
    )
    if let error = object.object("error") {
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: error.string("message") ?? "Google generation stream failed",
        providerID: providerID,
        operation: "google.event.error",
        causeDescription: error.string("status") ?? error.int("code").map(String.init)
      )
    }

    var normalized: [ProviderEvent] = []
    if !started {
      guard let responseID = object.string("responseId"), !responseID.isEmpty else {
        throw invalid("first Google event is missing responseId")
      }
      started = true
      normalized.append(
        .responseStarted(
          ProviderResponseMetadata(
            responseID: responseID,
            providerID: providerID,
            modelID: requestedModelID,
            providerMetadata: [:]
          )
        )
      )
    }

    if let candidate = object.array("candidates")?.first?.objectValue {
      if let content = candidate.object("content") {
        for part in content.array("parts") ?? [] {
          guard let part = part.objectValue else {
            throw invalid("Google content part is not an object")
          }
          if let signature = part.string("thoughtSignature") {
            guard !signature.isEmpty, Data(base64Encoded: signature) != nil else {
              throw invalid("Google thought signature is malformed")
            }
            normalized.append(.reasoningSignatureDelta(signature))
          }
          if let text = part.string("text") {
            normalized.append(
              part.bool("thought") == true ? .reasoningDelta(text) : .textDelta(text))
          }
          if let function = part.object("functionCall") {
            guard let name = function.string("name"), !name.isEmpty else {
              throw invalid("Google function call is missing name")
            }
            let arguments = function["args"] ?? .object([:])
            guard arguments.objectValue != nil else {
              throw invalid("Google function call arguments are not an object")
            }
            let providedID = function.string("id")
            let id: String
            if let providedID, !providedID.isEmpty, !toolCallIDs.contains(providedID) {
              id = providedID
            } else {
              generatedToolCallCount += 1
              id = "google-tool-\(generatedToolCallCount)"
            }
            toolCallIDs.insert(id)
            sawToolCall = true
            let argumentData = try JSONEncoder().encode(arguments)
            guard let argumentText = String(data: argumentData, encoding: .utf8) else {
              throw invalid("Google function call arguments are not UTF-8")
            }
            normalized.append(.toolCallStarted(id: id, name: name))
            normalized.append(.toolInputDelta(id: id, delta: argumentText))
            normalized.append(
              .toolCallCompleted(
                ProviderToolCall(id: id, name: name, arguments: arguments)
              )
            )
          }
        }
      }
      if let reason = candidate.string("finishReason") {
        finishReason = reason
      }
    }

    if let raw = object.object("usageMetadata") {
      let prompt = raw.int("promptTokenCount")
      let cached = raw.int("cachedContentTokenCount")
      let candidates = raw.int("candidatesTokenCount")
      let thoughts = raw.int("thoughtsTokenCount")
      usage = ProviderUsage(
        inputTokens: prompt.map { max(0, $0 - (cached ?? 0)) },
        outputTokens: (candidates != nil || thoughts != nil)
          ? (candidates ?? 0) + (thoughts ?? 0) : nil,
        reasoningTokens: thoughts,
        cachedInputTokens: cached,
        providerMetadata: raw
      )
    }
    return normalized
  }

  mutating func finish() throws -> [ProviderEvent] {
    guard started else { throw invalid("Google stream emitted no response") }
    guard let finishReason else {
      throw invalid("Google stream ended without a finish reason")
    }
    let reason: ProviderFinishReason
    switch finishReason {
    case "STOP": reason = sawToolCall ? .toolCalls : .stop
    case "MAX_TOKENS": reason = .length
    case "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "SAFETY", "IMAGE_SAFETY",
      "IMAGE_PROHIBITED_CONTENT", "IMAGE_RECITATION", "IMAGE_OTHER", "RECITATION",
      "FINISH_REASON_UNSPECIFIED", "OTHER", "LANGUAGE", "MALFORMED_FUNCTION_CALL",
      "UNEXPECTED_TOOL_CALL", "NO_IMAGE":
      throw invalid("Google provider stopped with: \(finishReason)")
    default:
      throw invalid("unsupported Google finish reason: \(finishReason)")
    }
    var events: [ProviderEvent] = []
    if let usage { events.append(.usage(usage)) }
    events.append(.completed(reason))
    return events
  }

  private func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: providerID,
      operation: "google.event.normalize",
      causeDescription: nil
    )
  }
}
