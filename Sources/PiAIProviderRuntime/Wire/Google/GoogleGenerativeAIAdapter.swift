import Foundation
import OSLog

private func rewriteGoogleConst(_ value: JSONValue, nameMap: Bool = false) -> JSONValue {
  if case .array(let values) = value { return .array(values.map { rewriteGoogleConst($0) }) }
  guard let schema = value.objectValue else { return value }
  let nameMaps: Set<String> = [
    "properties", "patternProperties", "$defs", "definitions", "dependentSchemas", "dependencies",
  ]
  let subschemas: Set<String> = [
    "additionalProperties", "unevaluatedProperties", "propertyNames", "items", "prefixItems",
    "additionalItems", "unevaluatedItems", "contains", "allOf", "anyOf", "oneOf", "not",
    "if", "then", "else", "contentSchema",
  ]
  var result: [JSONValue.ObjectMember] = []
  for key in value.objectPropertyNames ?? [] {
    let child = schema[key]!
    let rewritten: JSONValue
    if nameMap || subschemas.contains(key) {
      rewritten = rewriteGoogleConst(child)
    } else if nameMaps.contains(key) {
      rewritten = rewriteGoogleConst(child, nameMap: true)
    } else {
      rewritten = child
    }
    result.append(.init(key, rewritten))
  }
  if !nameMap, schema["enum"] == nil, let constant = schema["const"] {
    switch constant {
    case .string, .integer, .number:
      result.removeAll { $0.key == "const" }
      result.append(.init("enum", .array([constant])))
    default: break
    }
  }
  return .orderedObject(result)
}

enum GoogleToolProjection {
  private static func openAPI(_ schema: JSONValue) -> JSONValue {
    guard let object = schema.objectValue else { return schema }
    let metadata: Set<String> = [
      "$schema", "$id", "$anchor", "$dynamicAnchor", "$vocabulary", "$comment", "$defs",
      "definitions",
    ]
    return .orderedObject(
      (schema.objectPropertyNames ?? []).filter { !metadata.contains($0) }.map {
        .init($0, openAPI(object[$0]!))
      })
  }

  static func declarations(
    _ tools: [ProviderToolDefinition], supportsStrictMode: Bool, providerID: String,
    useParameters: Bool = false
  ) throws -> (tools: JSONValue?, usesStrictMode: Bool) {
    guard !tools.isEmpty else { return (nil, false) }
    var usesStrictMode = false
    let declarations = try tools.map { tool -> JSONValue in
      let resolved = try ProviderConstrainedSamplingResolver.jsonSchema(
        for: tool, supportsStrictMode: supportsStrictMode,
        providerID: providerID, operation: "google.request.tools")
      usesStrictMode = usesStrictMode || resolved.strict == true
      return .orderedObject([
        .init("name", .string(tool.name)), .init("description", .string(tool.description)),
        .init(
          useParameters ? "parameters" : "parametersJsonSchema",
          useParameters ? openAPI(resolved.schema) : rewriteGoogleConst(resolved.schema)),
      ])
    }
    return (.array([.object(["functionDeclarations": .array(declarations)])]), usesStrictMode)
  }
}

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
          let observation = ProviderWireObservation(request: request, wire: context)
          let response = try await transport.stream(
            try await observation.payload(makeURLRequest(request, context: context))
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
          continuation.yield(
            .responseStarted(
              ProviderResponseMetadata(
                responseID: nil,
                providerID: request.providerID,
                modelID: request.modelID,
                providerMetadata: [:]
              )
            )
          )
          for try await chunk in response.body {
            try Task.checkCancellation()
            for event in try decoder.append(chunk) {
              for normalized in try await reducer.reduce(event, observation: observation) {
                try await observation.toolEvent(normalized)
                continuation.yield(normalized)
              }
            }
          }
          try Task.checkCancellation()
          let pendingLineBytes = decoder.pendingLineBytes
          let flushedEvents = try decoder.finish()
          for event in flushedEvents {
            for normalized in try await reducer.reduce(event, observation: observation) {
              try await observation.toolEvent(normalized)
              continuation.yield(normalized)
            }
          }
          for normalized in try reducer.finish(
            requestID: request.id, httpStatus: response.statusCode,
            pendingLineBytes: pendingLineBytes, flushedEventCount: flushedEvents.count)
          {
            try await observation.toolEvent(normalized)
            continuation.yield(normalized)
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch let error as ProviderRuntimeFailure {
          continuation.finish(throwing: error)
        } catch {
          continuation.finish(
            throwing: ProviderRuntimeFailure(
              transportError: error, message: "Google generation transport failed",
              providerID: request.providerID, operation: "google.response.transport"))
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
      let collectionScope: Bool
      if case .apiKey = context.credential {
        collectionScope = true
      } else {
        collectionScope = context.usesVertexCollectionScope
      }
      if collectionScope {
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
      return message.systemPayload?.content
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
    if let thinking = request.options.providerOptions.object("thinking"),
      context.model.capabilities.reasoning
    {
      var config: [String: JSONValue] = [:]
      if thinking.bool("enabled") == true {
        config["includeThoughts"] = .bool(true)
        if let level = thinking["level"] {
          if let level = level.stringValue,
            ["MINIMAL", "LOW", "MEDIUM", "HIGH"].contains(level)
          {
            config["thinkingLevel"] = .string(level)
          }
        } else if let budget = thinking["budgetTokens"] {
          config["thinkingBudget"] = budget
        }
      } else {
        config = try disabledThinkingConfiguration(
          modelID: request.modelID, providerID: request.providerID,
          metadata: context.modelConfiguration.metadata)
      }
      generationConfig["thinkingConfig"] = .object(config)
    } else if let effort = request.options.reasoningEffort {
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
          providerID: request.providerID,
          metadata: context.modelConfiguration.metadata,
          customBudgets: request.options.thinkingBudgets
        ))
    }
    if !generationConfig.isEmpty {
      body["generationConfig"] = .object(generationConfig)
    }

    if !request.tools.isEmpty {
      let supportsStrictMode = supportsStrictToolSampling(request.modelID)
      let projection = try GoogleToolProjection.declarations(
        request.tools, supportsStrictMode: supportsStrictMode, providerID: request.providerID)
      body["tools"] = projection.tools
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
      } else if projection.usesStrictMode {
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
      case .system, .systemMessage:
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
        let parts = try content.compactMap { try makeAssistantPart($0, modelID: modelID) }
        guard !parts.isEmpty else { continue }
        contents.append(
          .object([
            "role": .string("model"),
            "parts": .array(parts),
          ]))
      case .assistantMessage(let assistant):
        guard let content = assistant.replayContent(for: target) else { continue }
        let parts = try content.compactMap { try makeAssistantPart($0, modelID: modelID) }
        guard !parts.isEmpty else { continue }
        contents.append(.object(["role": .string("model"), "parts": .array(parts)]))
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
    case .textUTF16(let units):
      try makeUserPart(.text(ProviderInputText.sanitizeUTF16(units)))
    case .unrecognized:
      throw ProviderInputText.unsupportedContent("google")
    case .text(let text):
      .object(["text": .string(text)])
    case .image(let image):
      try makeImagePart(image)
    }
  }

  private func makeAssistantPart(
    _ content: ProviderAssistantContent,
    modelID: String
  ) throws -> JSONValue? {
    switch content {
    case .textUTF16(let units):
      return try makeAssistantPart(.text(ProviderInputText.sanitizeUTF16(units)), modelID: modelID)
    case .unrecognized:
      return nil
    case .text(let text):
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      return .object(["text": .string(text)])
    case .signedText(let text):
      let signature = usableThoughtSignature(text.signature)
      guard !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || signature != nil
      else { return nil }
      var part: [String: JSONValue] = ["text": .string(text.text)]
      if let signature { part["thoughtSignature"] = .string(signature) }
      return .object(part)
    case .reasoning(let reasoning):
      let signature = usableThoughtSignature(reasoning.signature)
      guard
        !reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || signature != nil
      else { return nil }
      var part: [String: JSONValue] = [
        "text": .string(reasoning.text),
        "thought": .bool(true),
      ]
      if let signature {
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
      if let signature = usableThoughtSignature(call.thoughtSignature) {
        part["thoughtSignature"] = .string(signature)
      }
      return .object(part)
    }
  }

  private func usableThoughtSignature(_ signature: String?) -> String? {
    guard let signature, signature.utf16.count % 4 == 0,
      signature.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil
    else { return nil }
    return signature
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
    let text = texts.joined(separator: "\n")
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    var functionResponse: [String: JSONValue] = [
      "name": .string(result.toolName),
      "response": .object([
        responseKey: .string(hasText ? text : "")
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
    if !hasText, !images.isEmpty {
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

  static func resolveThinkingLevel(
    effort requested: ProviderReasoningEffort,
    providerID: String,
    modelID: String,
    metadata: [String: JSONValue]
  ) throws -> String {
    let mapped = metadata.object("thinkingLevelMap")?[requested.rawValue]
    let effort = (mapped?.stringValue ?? requested.rawValue).lowercased()
    guard ["minimal", "low", "medium", "high"].contains(effort) else {
      let mapping = mapped?.stringValue ?? (mapped == .null ? "null" : "undefined")
      throw ProviderRuntimeFailure(
        code: .invalidRequest,
        message:
          "Unsupported Google thinking level mapping for \(providerID)/\(modelID): \(requested.rawValue) -> \(mapping)",
        providerID: providerID, operation: "google.request.reasoning", causeDescription: nil)
    }
    return effort
  }

  private func usesThinkingLevel(_ modelID: String) -> Bool {
    let lower = modelID.lowercased()
    return isGemini3Pro(lower) || isGemini3Flash(lower) || isGemma4(lower)
      || lower.range(of: "gemini-(?:[4-9]|[1-9][0-9])", options: .regularExpression) != nil
  }

  private func disabledThinkingConfiguration(
    modelID: String,
    providerID: String,
    metadata: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    guard usesThinkingLevel(modelID) else { return ["thinkingBudget": .integer(0)] }
    let map = metadata.object("thinkingLevelMap") ?? [:]
    guard map["off"] == .null else { return ["thinkingBudget": .integer(0)] }
    let fallback = ProviderReasoningEffort.allCases.dropFirst().first { level in
      guard map[level.rawValue] != .null else { return false }
      return ![.xhigh, .max].contains(level) || map[level.rawValue] != nil
    }
    guard let fallback else { return ["thinkingBudget": .integer(0)] }
    let level = try Self.resolveThinkingLevel(
      effort: fallback, providerID: providerID, modelID: modelID, metadata: metadata)
    return ["thinkingLevel": .string(level.uppercased())]
  }

  private func thinkingConfiguration(
    effort requested: ProviderReasoningEffort,
    modelID: String,
    providerID: String,
    metadata: [String: JSONValue],
    customBudgets: [ProviderReasoningEffort: Int]?
  ) throws -> [String: JSONValue] {
    let lower = modelID.lowercased()
    if requested == .off {
      return try disabledThinkingConfiguration(
        modelID: modelID, providerID: providerID, metadata: metadata)
    }
    let effort = try Self.resolveThinkingLevel(
      effort: requested, providerID: providerID, modelID: modelID, metadata: metadata)
    if usesThinkingLevel(modelID) {
      return [
        "includeThoughts": .bool(true),
        "thinkingLevel": .string(effort.uppercased()),
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
  private static let logger = Logger(subsystem: "com.ronnie.pi-ai-swift", category: "GoogleSSE")

  let providerID: String
  let protocolID: String
  let requestedModelID: String
  let pricing: ProviderUsagePricing?
  private var responseID: String?
  private var finishReason: String?
  private var usage: ProviderUsage?
  private var sawToolCall = false
  private var toolCallIDs = Set<String>()
  private var generatedToolCallCount = 0
  private var content: [ProviderResponseContent] = []
  private var sseEventCount = 0
  private var sawDoneMarker = false
  private var lastCandidateCount = 0
  private var sawFinishReasonField = false

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

  mutating func reduce(_ event: ServerSentEvent, observation: ProviderWireObservation) async throws
    -> [ProviderEvent]
  {
    sseEventCount += 1
    guard event.data != "[DONE]" else {
      sawDoneMarker = true
      return []
    }
    let object = try decodeJSONObject(
      Data(event.data.utf8),
      providerID: providerID,
      operation: "google.event.decode"
    )
    try await observation.streamEvent(.object(object))
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
    if responseID == nil || responseID?.isEmpty == true {
      responseID = object.string("responseId")
    }

    let candidates = object.array("candidates") ?? []
    lastCandidateCount = candidates.count
    sawFinishReasonField =
      sawFinishReasonField || candidates.contains { $0.objectValue?["finishReason"] != nil }
    if let candidate = candidates.first?.objectValue {
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
            let call = ProviderToolCall(
              id: id,
              name: name,
              arguments: arguments,
              thoughtSignature: part.string("thoughtSignature").flatMap {
                $0.isEmpty ? nil : $0
              })
            self.content.append(.toolCall(call))
            let argumentData = try JSONEncoder().encode(arguments)
            guard let argumentText = String(data: argumentData, encoding: .utf8) else {
              throw invalid("Google function call arguments are not UTF-8")
            }
            normalized.append(.toolCallStarted(id: id, name: name))
            normalized.append(.toolInputDelta(id: id, delta: argumentText))
            normalized.append(.toolCallCompleted(call))
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

  mutating func finish(
    requestID: String, httpStatus: Int, pendingLineBytes: Int, flushedEventCount: Int
  ) throws -> [ProviderEvent] {
    guard let finishReason else {
      let diagnostic = """
        end=eof httpStatus=\(httpStatus) sseEvents=\(sseEventCount) \
        eofPendingLineBytes=\(pendingLineBytes) eofFlushedEvents=\(flushedEventCount) \
        doneMarkerSeen=\(sawDoneMarker) lastJSONCandidates=\(lastCandidateCount) \
        finishReasonFieldSeen=\(sawFinishReasonField) usageMetadataSeen=\(usage != nil)
        """
      let correlationID = UUID(uuidString: requestID)?.uuidString ?? "unavailable"
      Self.logger.warning(
        "event=google.sse.incomplete requestID=\(correlationID, privacy: .public) \(diagnostic, privacy: .public)"
      )
      throw ProviderRuntimeFailure(
        code: .incompleteStream,
        message: "Google stream ended without a finish reason",
        providerID: providerID,
        operation: "google.event.finish",
        causeDescription: diagnostic)
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
        message: "Provider stopped with: \(finishReason)",
        providerID: providerID,
        operation: "google.event.finish",
        causeDescription: finishReason,
        providerMetadata: ["rawStopReason": .string(finishReason)]
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
