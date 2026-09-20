import Foundation

enum GoogleVertexConfiguration {
  static func resolveBaseURLTemplate(
    _ template: String,
    protocolID: String,
    credential: ProviderCredential?
  ) -> String {
    guard protocolID == "google-vertex", case .apiKey = credential,
      template.contains("{location}")
    else { return template }
    return "https://aiplatform.googleapis.com"
  }
}

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
            protocolID: protocolID,
            requestedModelID: request.modelID,
            pricing: try ProviderUsagePricing.parse(
              metadata: context.modelConfiguration.metadata,
              providerID: request.providerID,
              operation: "google.usage.pricing")
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
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let error as ProviderRuntimeFailure {
          continuation.finish(throwing: error)
        } catch {
          continuation.finish(
            throwing: failure(
              .transportFailed,
              providerID: request.providerID,
              operation: "google.response.transport",
              message: "Google generation transport failed",
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
    try request.validateSingleSystemMessage(operation: "google.request.system")
    let metadata = credentialMetadata(context.credential)
    let endpoint: URL
    switch flavor {
    case .generativeAI:
      endpoint = context.baseURL
        .appending(path: "models")
        .appending(path: "\(request.modelID):streamGenerateContent")
    case .vertex:
      let base = vertexAPIBaseURL(context.baseURL)
      if case .apiKey = context.credential {
        endpoint =
          base
          .appending(path: "publishers")
          .appending(path: "google")
          .appending(path: "models")
          .appending(path: "\(request.modelID):streamGenerateContent")
      } else {
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
        endpoint =
          base
          .appending(path: "projects")
          .appending(path: project)
          .appending(path: "locations")
          .appending(path: location)
          .appending(path: "publishers")
          .appending(path: "google")
          .appending(path: "models")
          .appending(path: "\(request.modelID):streamGenerateContent")
      }
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
    ProviderSessionHeaders.applyOpenCode(request: request, to: &urlRequest)
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
      "contents": .array(
        try makeContents(request.messages.insertingMissingToolResults(), context: context))
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
        try thinkingConfiguration(
          effort: effort,
          modelID: request.modelID,
          metadata: context.modelConfiguration.metadata,
          customBudgets: request.options.thinkingBudgets
        ))
    }
    if !generationConfig.isEmpty {
      body["generationConfig"] = .object(generationConfig)
    }

    if !request.tools.isEmpty {
      let supportsStrictMode = supportsStrictToolSampling(request.modelID)
      var usesStrictMode = false
      body["tools"] = .array([
        .object([
          "functionDeclarations": .array(
            try request.tools.map { tool in
              let resolved = try ProviderConstrainedSamplingResolver.jsonSchema(
                for: tool,
                supportsStrictMode: supportsStrictMode,
                providerID: request.providerID,
                operation: "google.request.tools"
              )
              usesStrictMode = usesStrictMode || resolved.strict == true
              return .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parametersJsonSchema": resolved.schema,
              ])
            }
          )
        ])
      ])
      if let choice = request.options.toolChoice {
        guard let stringChoice = choice.stringValue,
          let mode = toolChoiceMode(stringChoice)
        else {
          throw failure(
            .invalidRequest,
            providerID: request.providerID,
            operation: "google.request.tool-choice",
            message: "unsupported Google tool choice"
          )
        }
        body["toolConfig"] = .object([
          "functionCallingConfig": .object(["mode": .string(mode)])
        ])
      } else if usesStrictMode {
        body["toolConfig"] = .object([
          "functionCallingConfig": .object(["mode": .string("VALIDATED")])
        ])
      }
    }
    return body
  }

  private func makeContents(
    _ messages: [ProviderMessage],
    context: WireProtocolContext
  ) throws -> [JSONValue] {
    let modelID = context.model.id
    let target = ProviderMessageSource(
      api: protocolID, providerID: context.provider.id, modelID: modelID)
    var contents: [JSONValue] = []
    for message in messages {
      switch message {
      case .system:
        continue
      case .user(let content):
        contents.append(
          .object([
            "role": .string("user"),
            "parts": .array(try content.map(makeUserPart(_:))),
          ]))
      case .userMessage(let user):
        contents.append(
          .object([
            "role": .string("user"),
            "parts": .array(try user.content.map(makeUserPart(_:))),
          ]))
      case .assistant(let content):
        let parts = try content.map { try makeAssistantPart($0, modelID: modelID) }
        guard !parts.isEmpty else { continue }
        contents.append(
          .object([
            "role": .string("model"),
            "parts": .array(parts),
          ]))
      case .assistantMessage(let assistant):
        guard let content = assistant.replayContent(for: target) else { continue }
        contents.append(
          .object([
            "role": .string("model"),
            "parts": .array(
              try content.map { try makeAssistantPart($0, modelID: modelID) }
            ),
          ]))
      case .toolResult(let result):
        let resultParts = try makeToolResultParts(
          result,
          modelID: modelID,
          acceptsImages: context.model.capabilities.imageInput
        )
        if case .object(var previous)? = contents.last,
          previous.string("role") == "user",
          case .array(var previousParts)? = previous["parts"],
          previousParts.contains(where: { $0.objectValue?["functionResponse"] != nil })
        {
          previousParts.append(contentsOf: resultParts)
          previous["parts"] = .array(previousParts)
          contents[contents.count - 1] = .object(previous)
        } else {
          contents.append(
            .object([
              "role": .string("user"),
              "parts": .array(resultParts),
            ]))
        }
        let images = result.content.compactMap { content -> ProviderImage? in
          guard case .image(let image) = content else { return nil }
          return image
        }
        if context.model.capabilities.imageInput, !images.isEmpty,
          !supportsMultimodalFunctionResponse(modelID)
        {
          contents.append(
            .object([
              "role": .string("user"),
              "parts": .array(
                [.object(["text": .string("Tool result image:")])]
                  + (try images.map(makeImagePart(_:)))
              ),
            ]))
        }
      }
    }
    return contents
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
    case .signedText(let text):
      var part: [String: JSONValue] = ["text": .string(text.text)]
      if let signature = text.signature { part["thoughtSignature"] = .string(signature) }
      return .object(part)
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
      var part: [String: JSONValue] = ["functionCall": .object(functionCall)]
      if let signature = call.thoughtSignature { part["thoughtSignature"] = .string(signature) }
      return .object(part)
    }
  }

  private func makeToolResultParts(
    _ result: ProviderToolResult,
    modelID: String,
    acceptsImages: Bool
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
    let images =
      acceptsImages
      ? result.content.compactMap { content -> ProviderImage? in
        guard case .image(let image) = content else { return nil }
        return image
      } : []
    if texts.isEmpty, !images.isEmpty {
      functionResponse["response"] = .object([
        responseKey: .string("(see attached image)")
      ])
    }
    if !images.isEmpty, supportsMultimodalFunctionResponse(modelID) {
      functionResponse["parts"] = .array(try images.map(makeImagePart(_:)))
    }
    return [.object(["functionResponse": .object(functionResponse)])]
  }

  private func supportsMultimodalFunctionResponse(_ modelID: String) -> Bool {
    let lower = modelID.lowercased()
    guard
      let match = lower.range(
        of: #"^gemini(?:-live)?-(\d+)"#,
        options: .regularExpression
      )
    else { return true }
    let matched = String(lower[match])
    let digits = matched.reversed().prefix { $0.isNumber }.reversed()
    return (Int(String(digits)) ?? 0) >= 3
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
    effort requested: ProviderReasoningEffort,
    modelID: String,
    metadata: [String: JSONValue],
    customBudgets: [ProviderReasoningEffort: Int]?
  ) throws -> [String: JSONValue] {
    let lower = modelID.lowercased()
    if requested == .off {
      let map = metadata.object("thinkingLevelMap") ?? [:]
      guard map["off"] == .null else { return ["thinkingBudget": .integer(0)] }
      for fallback in ProviderReasoningEffort.allCases.dropFirst() {
        guard map[fallback.rawValue] != .null else { continue }
        let level = map.string(fallback.rawValue) ?? fallback.rawValue
        if ["minimal", "low", "medium", "high"].contains(level.lowercased()) {
          return ["thinkingLevel": .string(level.uppercased())]
        }
      }
      return ["thinkingBudget": .integer(0)]
    }
    let effort =
      (metadata.object("thinkingLevelMap")?.string(requested.rawValue) ?? requested.rawValue)
      .lowercased()
    guard ["minimal", "low", "medium", "high"].contains(effort) else {
      throw failure(
        .invalidRequest,
        providerID: nil,
        operation: "google.request.reasoning",
        message: "unsupported Google reasoning effort: \(effort)"
      )
    }
    if isGemini3Pro(lower) || isGemini3Flash(lower)
      || (flavor == .generativeAI && isGemma4(lower))
    {
      let level: String
      if isGemini3Pro(lower) {
        level = ["minimal", "low"].contains(effort) ? "LOW" : "HIGH"
      } else if isGemma4(lower) {
        level = ["minimal", "low"].contains(effort) ? "MINIMAL" : "HIGH"
      } else {
        level = effort.uppercased()
      }
      return [
        "includeThoughts": .bool(true),
        "thinkingLevel": .string(level),
      ]
    }

    if let customBudget = customBudgets?[ProviderReasoningEffort(rawValue: effort)!] {
      return [
        "includeThoughts": .bool(true),
        "thinkingBudget": .integer(Int64(customBudget)),
      ]
    }
    let budgets: [String: Int]
    if lower.contains("2.5-pro") {
      budgets = ["minimal": 128, "low": 2_048, "medium": 8_192, "high": 32_768]
    } else if flavor == .generativeAI, lower.contains("2.5-flash-lite") {
      budgets = ["minimal": 512, "low": 2_048, "medium": 8_192, "high": 24_576]
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

  private func supportsStrictToolSampling(_ modelID: String) -> Bool {
    guard let major = geminiMajorVersion(modelID) else { return false }
    return major >= 3
  }

  private func geminiMajorVersion(_ modelID: String) -> Int? {
    guard
      let match = modelID.lowercased().range(
        of: #"^gemini(?:-live)?-([0-9]+)"#,
        options: .regularExpression
      )
    else { return nil }
    return String(modelID.lowercased()[match]).split(separator: "-").last.flatMap {
      Int(String($0))
    }
  }

  private func isGemini3Pro(_ modelID: String) -> Bool {
    modelID.range(of: #"gemini-3(?:\.[0-9]+)?-pro"#, options: .regularExpression) != nil
  }

  private func isGemini3Flash(_ modelID: String) -> Bool {
    modelID.range(of: #"gemini-3(?:\.[0-9]+)?-flash"#, options: .regularExpression) != nil
      || modelID == "gemini-flash-latest" || modelID == "gemini-flash-lite-latest"
  }

  private func isGemma4(_ modelID: String) -> Bool {
    modelID.range(of: #"gemma-?4"#, options: .regularExpression) != nil
  }

  private func vertexAPIBaseURL(_ baseURL: URL) -> URL {
    let pathComponents = baseURL.pathComponents.filter { $0 != "/" }
    if pathComponents.contains(where: {
      $0.range(of: #"^v[0-9]+(?:beta[0-9]*)?$"#, options: .regularExpression) != nil
    }) {
      return baseURL
    }
    return baseURL.appending(path: "v1")
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
    guard let major = geminiMajorVersion(modelID) else {
      return modelID.hasPrefix("claude-") || modelID.hasPrefix("gpt-oss-")
    }
    return major >= 3
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
  let protocolID: String
  let requestedModelID: String
  let pricing: ProviderUsagePricing?
  private var started = false
  private var responseID: String?
  private var finishReason: String?
  private var usage: ProviderUsage?
  private var sawToolCall = false
  private var toolCallIDs = Set<String>()
  private var generatedToolCallCount = 0
  private var content: [ProviderResponseContent] = []

  init(
    providerID: String,
    protocolID: String,
    requestedModelID: String,
    pricing: ProviderUsagePricing?
  ) {
    self.providerID = providerID
    self.protocolID = protocolID
    self.requestedModelID = requestedModelID
    self.pricing = pricing
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
      self.responseID = responseID
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
          if let text = part.string("text") {
            let signature = part.string("thoughtSignature").flatMap { $0.isEmpty ? nil : $0 }
            appendText(
              text,
              thinking: part.bool("thought") == true,
              signature: signature
            )
            normalized.append(
              part.bool("thought") == true ? .reasoningDelta(text) : .textDelta(text))
          }
          if let signature = part.string("thoughtSignature"), !signature.isEmpty {
            normalized.append(.reasoningSignatureDelta(signature))
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
            self.content.append(
              .toolCall(
                ProviderToolCall(
                  id: id,
                  name: name,
                  arguments: arguments,
                  thoughtSignature: part.string("thoughtSignature").flatMap {
                    $0.isEmpty ? nil : $0
                  }
                )))
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
      guard let pricing else {
        throw ProviderRuntimeFailure(
          code: .upstreamDrift, message: "model cost rates are missing",
          providerID: providerID, operation: "google.usage.pricing",
          causeDescription: nil)
      }
      let prompt = raw.int("promptTokenCount") ?? 0
      let cached = raw.int("cachedContentTokenCount") ?? 0
      let candidates = raw.int("candidatesTokenCount") ?? 0
      let thoughts = raw.int("thoughtsTokenCount") ?? 0
      let input = max(0, prompt - cached)
      let output = candidates + thoughts
      usage = ProviderUsage(
        inputTokens: input,
        outputTokens: output,
        reasoningTokens: thoughts,
        cachedInputTokens: cached,
        cacheWriteTokens: 0,
        totalTokens: raw.int("totalTokenCount") ?? 0,
        providerMetadata: raw,
        cost: pricing.cost(input: input, output: output, cacheRead: cached, cacheWrite: 0)
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
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: "Google provider stopped with: \(finishReason)",
        providerID: providerID,
        operation: "google.event.finish",
        causeDescription: finishReason
      )
    default:
      throw invalid("unsupported Google finish reason: \(finishReason)")
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
    var events: [ProviderEvent] = [.usage(terminalUsage)]
    events.append(
      .responseSnapshot(
        ProviderResponseSnapshot(
          responseID: responseID,
          providerID: providerID,
          protocolID: protocolID,
          modelID: requestedModelID,
          responseModelID: nil,
          content: content,
          usage: terminalUsage,
          finishReason: reason,
          rawFinishReason: finishReason,
          timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )))
    events.append(.completed(reason))
    return events
  }

  private mutating func appendText(
    _ text: String,
    thinking: Bool,
    signature: String?
  ) {
    if let last = content.indices.last {
      switch (content[last], thinking) {
      case (.reasoning(let current), true):
        content[last] = .reasoning(
          ProviderReasoningContent(
            text: current.text + text,
            signature: signature ?? current.signature,
            providerMetadata: current.providerMetadata
          ))
        return
      case (.text(let current), false):
        content[last] = .text(
          ProviderTextContent(
            text: current.text + text,
            signature: signature ?? current.signature,
            providerMetadata: current.providerMetadata
          ))
        return
      default:
        break
      }
    }
    if thinking {
      content.append(
        .reasoning(
          ProviderReasoningContent(text: text, signature: signature, providerMetadata: [:])))
    } else {
      content.append(.text(ProviderTextContent(text: text, signature: signature)))
    }
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
