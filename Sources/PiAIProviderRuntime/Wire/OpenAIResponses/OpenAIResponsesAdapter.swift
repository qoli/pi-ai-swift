import Foundation

struct ResolvedAzureOpenAIResponsesConfiguration: Sendable, Equatable {
  let baseURL: String
  let apiVersion: String
  let deploymentName: String

  static func resolve(
    request: ProviderRequest,
    modelBaseURL: String?
  ) throws -> ResolvedAzureOpenAIResponsesConfiguration {
    let options = request.connectionOptions.azureOpenAIResponses
    let environment = options?.environment ?? [:]
    let apiVersion = firstNonempty([
      options?.azureAPIVersion,
      environment["AZURE_OPENAI_API_VERSION"],
      "v1",
    ])!
    let explicitBaseURL = options?.azureBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
    let environmentBaseURL =
      environment["AZURE_OPENAI_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    var resolvedBaseURL = firstNonempty([explicitBaseURL, environmentBaseURL])
    let resourceName = firstNonempty([
      options?.azureResourceName,
      environment["AZURE_OPENAI_RESOURCE_NAME"],
    ])
    if resolvedBaseURL == nil, let resourceName {
      resolvedBaseURL = "https://\(resourceName).openai.azure.com/openai/v1"
    }
    if resolvedBaseURL == nil {
      resolvedBaseURL = firstNonempty([modelBaseURL])
    }
    guard let resolvedBaseURL else {
      throw failure(
        .invalidRequest,
        providerID: request.providerID,
        operation: "azure-openai-responses.request.configuration",
        message:
          "Azure OpenAI base URL is required. Set AZURE_OPENAI_BASE_URL or AZURE_OPENAI_RESOURCE_NAME, or pass azureBaseUrl, azureResourceName, or model.baseUrl."
      )
    }

    let deploymentName =
      firstNonempty([options?.azureDeploymentName])
      ?? firstNonempty([
        deploymentMap(environment["AZURE_OPENAI_DEPLOYMENT_NAME_MAP"])[request.modelID]
      ])
      ?? request.modelID
    return ResolvedAzureOpenAIResponsesConfiguration(
      baseURL: try normalizeBaseURL(resolvedBaseURL, providerID: request.providerID),
      apiVersion: apiVersion,
      deploymentName: deploymentName
    )
  }

  private static func firstNonempty(_ values: [String?]) -> String? {
    values.lazy.compactMap { value in
      guard let value, !value.isEmpty else { return nil }
      return value
    }.first
  }

  private static func deploymentMap(_ value: String?) -> [String: String] {
    guard let value, !value.isEmpty else { return [:] }
    var result: [String: String] = [:]
    for rawEntry in value.split(separator: ",", omittingEmptySubsequences: false) {
      let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !entry.isEmpty else { continue }
      let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
      result[String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)] =
        String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return result
  }

  private static func normalizeBaseURL(
    _ baseURL: String,
    providerID: String
  ) throws -> String {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: trimmed),
      components.scheme != nil, components.host != nil
    else {
      throw failure(
        .invalidRequest,
        providerID: providerID,
        operation: "azure-openai-responses.request.configuration",
        message: "Invalid Azure OpenAI base URL: \(baseURL)"
      )
    }
    let host = components.host?.lowercased() ?? ""
    let isAzureHost =
      host.hasSuffix(".openai.azure.com")
      || host.hasSuffix(".cognitiveservices.azure.com")
      || host.hasSuffix(".ai.azure.com")
    let normalizedPath = components.path.trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
    if isAzureHost,
      normalizedPath.isEmpty || normalizedPath == "openai"
        || normalizedPath == "openai/v1/responses"
    {
      components.path = "/openai/v1"
      components.query = nil
    }
    guard let normalized = components.url?.absoluteString else {
      throw failure(
        .invalidRequest,
        providerID: providerID,
        operation: "azure-openai-responses.request.configuration",
        message: "Invalid Azure OpenAI base URL: \(baseURL)"
      )
    }
    return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private static func failure(
    _ code: ProviderRuntimeFailure.Code,
    providerID: String?,
    operation: String,
    message: String
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: code, message: message, providerID: providerID, operation: operation,
      causeDescription: nil)
  }
}

struct OpenAIResponsesAdapter: WireProtocolAdapter {
  enum Flavor: Sendable, Equatable {
    case standard
    case azure
    case codex
  }

  let protocolID: String
  let flavor: Flavor

  init(
    protocolID: String = "openai-responses",
    flavor: Flavor = .standard
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
              operation: "openai-responses.response",
              message: "OpenAI Responses request failed (HTTP \(response.statusCode))",
              cause: body
            )
          }
          var decoder = ServerSentEventDecoder()
          var reducer = OpenAIResponsesReducer(
            providerID: request.providerID,
            protocolID: protocolID,
            requestedModelID: request.modelID,
            acceptsCodexTerminalAliases: flavor == .codex,
            grammarInputProperties: try grammarInputProperties(request, context: context),
            pricing: try ProviderUsagePricing.parse(
              metadata: context.modelConfiguration.metadata,
              providerID: request.providerID,
              operation: "openai-responses.usage.pricing"),
            requestedServiceTier: request.options.serviceTier,
            flavor: flavor
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
    try request.validateSingleSystemMessage(operation: "openai-responses.request.system")
    var urlRequest = URLRequest(url: try endpoint(request, context: context))
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (name, value) in context.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let compat = context.modelConfiguration.metadata.object("compat") ?? [:]
    if flavor == .standard {
      ProviderSessionHeaders.applyOpenAIResponsesAffinity(
        request: request, context: context, compat: compat, to: &urlRequest)
    }
    ProviderSessionHeaders.applyOpenCode(request: request, to: &urlRequest)
    applyGitHubCopilotHeaders(
      providerID: request.providerID,
      messages: request.messages,
      to: &urlRequest
    )
    switch (flavor, context.credential) {
    case (.azure, .apiKey(let credential)):
      urlRequest.setValue(credential.key, forHTTPHeaderField: "api-key")
    case (.codex, .oauth(let credential)):
      urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
      guard let accountID = credential.metadata["accountID"], !accountID.isEmpty else {
        throw failure(
          .invalidCredential,
          providerID: request.providerID,
          operation: "openai-responses.request.auth",
          message: "OpenAI Codex credential is missing accountID"
        )
      }
      urlRequest.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
      urlRequest.setValue("pi", forHTTPHeaderField: "originator")
      urlRequest.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
      if let sessionID = codexSessionID(request.options) {
        urlRequest.setValue(sessionID, forHTTPHeaderField: "session-id")
        urlRequest.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
      }
    case (_, .apiKey(let credential)):
      urlRequest.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
    case (_, .oauth(let credential)):
      urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    case (_, nil):
      throw failure(
        .missingCredential,
        providerID: request.providerID,
        operation: "openai-responses.request.auth",
        message: "OpenAI Responses credential is missing"
      )
    }
    urlRequest.httpBody = try encodeJSONObject(
      try makeBody(request, context: context),
      providerID: request.providerID,
      operation: "openai-responses.request.encode"
    )
    return urlRequest
  }

  private func grammarInputProperties(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: String] {
    let supports =
      context.modelConfiguration.metadata.object("compat")?
      .bool("supportsOpenAIGrammarTools") == true
    var result: [String: String] = [:]
    for tool in request.tools {
      if let grammar = try ProviderConstrainedSamplingResolver.grammar(
        for: tool, supportsGrammarTools: supports, providerID: request.providerID,
        operation: "openai-responses.request.grammar-tool"
      ) {
        result[tool.name] = grammar.inputProperty
      }
    }
    return result
  }

  private func endpoint(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> URL {
    switch flavor {
    case .standard:
      return context.baseURL.appending(path: "responses")
    case .azure:
      let configuration = try ResolvedAzureOpenAIResponsesConfiguration.resolve(
        request: request,
        modelBaseURL: context.baseURL.absoluteString
      )
      guard let baseURL = URL(string: configuration.baseURL) else {
        throw failure(
          .invalidRequest,
          providerID: request.providerID,
          operation: "azure-openai-responses.request.configuration",
          message: "Invalid Azure OpenAI base URL: \(configuration.baseURL)"
        )
      }
      var components = URLComponents(
        url: baseURL.appending(path: "responses"),
        resolvingAgainstBaseURL: false
      )
      components?.queryItems = [
        URLQueryItem(
          name: "api-version",
          value: configuration.apiVersion
        )
      ]
      guard let url = components?.url else {
        throw failure(
          .invalidRequest,
          providerID: context.provider.id,
          operation: "azure-openai-responses.request.url",
          message: "Azure OpenAI Responses URL is invalid"
        )
      }
      return url
    case .codex:
      let normalized = context.baseURL.absoluteString.trimmingCharacters(
        in: CharacterSet(charactersIn: "/")
      )
      if normalized.hasSuffix("/codex/responses") {
        return context.baseURL
      }
      if normalized.hasSuffix("/codex") {
        return context.baseURL.appending(path: "responses")
      }
      return context.baseURL.appending(path: "codex/responses")
    }
  }

  private func makeBody(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: JSONValue] {
    if flavor == .azure {
      guard request.options.serviceTier == nil else {
        throw failure(
          .unsupportedCapability,
          providerID: request.providerID,
          operation: "azure-openai-responses.request.service-tier",
          message: "The pinned Azure OpenAI Responses request contract has no service tier option"
        )
      }
      let misplacedConnectionKeys = Set([
        "azureApiVersion", "azureBaseUrl", "azureBaseURL", "azureDeploymentName",
        "azureResourceName", "env", "environment",
      ]).intersection(request.options.providerOptions.keys)
      guard misplacedConnectionKeys.isEmpty else {
        throw failure(
          .invalidRequest,
          providerID: request.providerID,
          operation: "azure-openai-responses.request.configuration",
          message:
            "Azure OpenAI connection configuration must use ProviderRequest.connectionOptions: \(misplacedConnectionKeys.sorted().joined(separator: ", "))"
        )
      }
    }
    let compat = context.modelConfiguration.metadata.object("compat") ?? [:]
    let supportsStrictMode: Bool = {
      if let configured = compat.bool("supportsStrictMode") { return configured }
      return flavor != .standard
    }()
    let supportsGrammarTools = compat.bool("supportsOpenAIGrammarTools") == true
    let deferredToolsMode: String? =
      compat.bool("supportsAdditionalTools") == true
      ? "additional-tools"
      : (compat.bool("supportsToolSearch") == true ? "tool-search" : nil)
    let toolPlacement = responseToolPlacement(
      tools: request.tools,
      messages: request.messages,
      enabled: deferredToolsMode != nil
    )
    var grammarTools: [String: ProviderConstrainedSamplingResolver.Grammar] = [:]
    for tool in request.tools {
      if let grammar = try ProviderConstrainedSamplingResolver.grammar(
        for: tool,
        supportsGrammarTools: supportsGrammarTools,
        providerID: request.providerID,
        operation: "openai-responses.request.grammar-tool"
      ) {
        grammarTools[tool.name] = grammar
      }
    }
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
      "model": .string(try resolvedModelID(request, context: context)),
      "input": .array(
        try makeInput(
          request.messages.insertingMissingToolResults(),
          includeSystem: flavor != .codex,
          context: context,
          grammarTools: grammarTools,
          deferredTools: toolPlacement.deferred,
          deferredToolsMode: deferredToolsMode,
          supportsStrictMode: supportsStrictMode
        )),
      "stream": .bool(true),
      "store": .bool(false),
    ]
    let instructions = request.messages.compactMap { message -> String? in
      guard case .system(let text) = message else { return nil }
      return text
    }
    if flavor == .codex, !instructions.isEmpty {
      body["instructions"] = .string(instructions.joined(separator: "\n\n"))
    }
    if flavor != .codex, compat.bool("supportsMaxOutputTokens") != false,
      let maximum = request.options.maximumOutputTokens
        ?? context.model.maximumOutputTokens
    {
      body["max_output_tokens"] = .integer(Int64(max(16, maximum)))
    }
    if let temperature = request.options.temperature {
      body["temperature"] = .number(temperature)
    }
    let cacheRetention: ProviderCacheRetention =
      flavor == .standard && request.options.environment?["PI_CACHE_RETENTION"] == "long"
      ? .long : request.options.cacheRetention
    if flavor != .codex, cacheRetention != .none,
      let sessionID = request.options.sessionID, !sessionID.isEmpty
    {
      body["prompt_cache_key"] = .string(String(sessionID.prefix(64)))
    }
    if flavor == .standard, cacheRetention == .long,
      compat.bool("supportsLongCacheRetention") != false
    {
      body["prompt_cache_retention"] = .string("24h")
    }
    if flavor == .standard, cacheRetention == .none,
      compat.bool("supportsExplicitPromptCacheMode") == true
    {
      body["prompt_cache_options"] = .object(["mode": .string("explicit")])
    }
    if request.options.reasoningEffort != nil || request.options.reasoningSummary != nil,
      context.model.capabilities.reasoning
    {
      let effort = request.options.reasoningEffort ?? .medium
      let levelMap = context.modelConfiguration.metadata.object("thinkingLevelMap") ?? [:]
      let mapped = levelMap.string(effort.rawValue)
      if effort == .off {
        if levelMap["off"] != .null {
          body["reasoning"] = .object([
            "effort": .string(mapped ?? "none")
          ])
        }
      } else {
        body["reasoning"] = .object([
          "effort": .string(mapped ?? effort.rawValue),
          "summary": .string(request.options.reasoningSummary ?? "auto"),
        ])
        body["include"] = .array([.string("reasoning.encrypted_content")])
      }
    } else if context.model.capabilities.reasoning,
      context.modelConfiguration.metadata.object("thinkingLevelMap")?["off"] != .null,
      request.providerID != "github-copilot"
    {
      let off =
        context.modelConfiguration.metadata.object("thinkingLevelMap")?.string("off")
        ?? "none"
      body["reasoning"] = .object(["effort": .string(off)])
    }
    if flavor == .standard, request.providerID == "xai", context.model.capabilities.reasoning {
      body["include"] = .array([.string("reasoning.encrypted_content")])
    }
    if let serviceTier = request.options.serviceTier {
      body["service_tier"] = .string(serviceTier)
    }
    if flavor == .codex, let toolChoice = request.options.toolChoice {
      guard let value = toolChoice.stringValue,
        ["auto", "none", "required"].contains(value)
      else {
        throw failure(
          .invalidRequest,
          providerID: request.providerID,
          operation: "openai-codex-responses.request.tool-choice",
          message: "Codex tool choice must be auto, none, or required"
        )
      }
    }
    if let toolChoice = request.options.toolChoice {
      body["tool_choice"] = toolChoice
    }
    if !toolPlacement.immediate.isEmpty {
      body["tools"] = .array(
        try toolPlacement.immediate.map { definition in
          try responseTool(
            definition,
            grammarTools: grammarTools,
            supportsStrictMode: supportsStrictMode,
            providerID: request.providerID,
            deferLoading: false
          )
        }
      )
    }
    if flavor == .azure, let sessionID = request.options.sessionID, !sessionID.isEmpty {
      body["prompt_cache_key"] = .string(String(sessionID.prefix(64)))
    }
    if let schema = request.options.responseSchema {
      body["text"] = .object([
        "format": .object([
          "type": .string("json_schema"),
          "name": .string("response"),
          "strict": .bool(true),
          "schema": schema,
        ])
      ])
    }
    if flavor == .codex {
      body["instructions"] = .string(
        instructions.isEmpty
          ? "You are a helpful assistant."
          : instructions.joined(separator: "\n\n")
      )
      body["text"] = .object(["verbosity": .string(request.options.textVerbosity ?? "low")])
      body["include"] = .array([.string("reasoning.encrypted_content")])
      body["tool_choice"] = request.options.toolChoice ?? .string("auto")
      body["parallel_tool_calls"] = .bool(true)
      if let sessionID = codexSessionID(request.options) {
        body["prompt_cache_key"] = .string(sessionID)
      }
    }
    for (key, value) in request.options.providerOptions {
      body[key] = value
    }
    return body
  }

  private func codexSessionID(
    _ options: ProviderGenerationOptions
  ) -> String? {
    guard flavor == .codex, options.cacheRetention != .none,
      let sessionID = options.sessionID,
      !sessionID.isEmpty
    else { return nil }
    return String(sessionID.prefix(64))
  }

  private func resolvedModelID(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> String {
    guard flavor == .azure else { return request.modelID }
    return try ResolvedAzureOpenAIResponsesConfiguration.resolve(
      request: request,
      modelBaseURL: context.baseURL.absoluteString
    ).deploymentName
  }

  private func makeInput(
    _ messages: [ProviderMessage],
    includeSystem: Bool,
    context: WireProtocolContext,
    grammarTools: [String: ProviderConstrainedSamplingResolver.Grammar],
    deferredTools: [String: ProviderToolDefinition],
    deferredToolsMode: String?,
    supportsStrictMode: Bool
  ) throws -> [JSONValue] {
    let target = ProviderMessageSource(
      api: protocolID, providerID: context.provider.id, modelID: context.model.id)
    var result: [JSONValue] = []
    var replayMessageIndex = 0
    var normalizedToolIDs: [String: String] = [:]
    var loadedToolNames = Set<String>()
    for message in messages {
      let messageIndex = replayMessageIndex
      switch message {
      case .system(let text):
        if includeSystem {
          let supportsDeveloper =
            context.modelConfiguration.metadata.object("compat")?
            .bool("supportsDeveloperRole") != false
          let role =
            context.model.capabilities.reasoning && supportsDeveloper ? "developer" : "system"
          result.append(.object(["role": .string(role), "content": .string(text)]))
        }
        continue
      case .user(let content):
        result.append(
          .object([
            "role": .string("user"),
            "content": .array(try content.map(makeUserContent(_:))),
          ]))
      case .userMessage(let user):
        result.append(
          .object([
            "role": .string("user"),
            "content": .array(try user.content.map(makeUserContent(_:))),
          ]))
      case .assistant(let content):
        result.append(
          .object([
            "role": .string("assistant"),
            "content": .array(
              content.compactMap { item in
                guard case .text(let text) = item else { return nil }
                return .object([
                  "type": .string("output_text"), "text": .string(text),
                ])
              }
            ),
          ]))
      case .assistantMessage(let assistant):
        guard let content = assistant.replayContent(for: target) else { continue }
        var textIndex = 0
        for item in content {
          switch item {
          case .reasoning(let reasoning):
            guard let signature = reasoning.signature else { continue }
            guard let data = signature.data(using: .utf8) else {
              throw failure(
                .invalidRequest, providerID: context.provider.id,
                operation: "openai-responses.request.reasoning-replay",
                message: "Responses reasoning signature is not valid UTF-8 JSON")
            }
            do {
              result.append(try JSONDecoder().decode(JSONValue.self, from: data))
            } catch {
              throw failure(
                .invalidRequest, providerID: context.provider.id,
                operation: "openai-responses.request.reasoning-replay",
                message: "Responses reasoning signature is malformed",
                cause: String(describing: error))
            }
          case .text(let text):
            result.append(
              responseMessageInput(
                text: text,
                signature: nil,
                fallbackID: textIndex == 0
                  ? "msg_pi_\(messageIndex)" : "msg_pi_\(messageIndex)_\(textIndex)"
              ))
            textIndex += 1
          case .signedText(let text):
            result.append(
              responseMessageInput(
                text: text.text,
                signature: text.signature,
                fallbackID: textIndex == 0
                  ? "msg_pi_\(messageIndex)" : "msg_pi_\(messageIndex)_\(textIndex)"
              ))
            textIndex += 1
          case .toolCall(let call):
            let normalizedID = normalizedResponsesToolID(
              call.id,
              source: assistant.source,
              target: target
            )
            normalizedToolIDs[call.id] = normalizedID
            let ids = normalizedID.split(separator: "|", maxSplits: 1).map(String.init)
            let sameProviderAndAPI =
              assistant.source.providerID == target.providerID
              && assistant.source.api == target.api
            let differentModel = sameProviderAndAPI && assistant.source.modelID != target.modelID
            var itemID = ids.count == 2 ? ids[1] : nil
            if differentModel && itemID?.hasPrefix("fc_") == true {
              itemID = nil
            }
            var object: [String: JSONValue]
            if let grammar = grammarTools[call.name] {
              guard case .object(let arguments) = call.arguments,
                let input = arguments.string(grammar.inputProperty)
              else {
                throw failure(
                  .invalidRequest,
                  providerID: context.provider.id,
                  operation: "openai-responses.request.grammar-tool-call",
                  message:
                    "Grammar tool call \"\(call.name)\" requires argument \"\(grammar.inputProperty)\" to be a string."
                )
              }
              object = [
                "type": .string("custom_tool_call"),
                "call_id": .string(ids[0]),
                "name": .string(call.name),
                "input": .string(input),
              ]
            } else {
              object = [
                "type": .string("function_call"),
                "call_id": .string(ids[0]),
                "name": .string(call.name),
                "arguments": .string(try responseJSONString(call.arguments)),
              ]
            }
            if let itemID { object["id"] = .string(itemID) }
            if assistant.source == target || deferredTools[call.name] != nil,
              let namespace = call.namespace
            {
              object["namespace"] = .string(namespace)
            }
            result.append(.object(object))
          }
        }
      case .toolResult(let toolResult):
        let normalizedID = normalizedToolIDs[toolResult.toolCallID] ?? toolResult.toolCallID
        let callID =
          normalizedID.split(separator: "|", maxSplits: 1).first.map(String.init)
          ?? toolResult.toolCallID
        result.append(
          .object([
            "type": .string(
              grammarTools[toolResult.toolName] == nil
                ? "function_call_output" : "custom_tool_call_output"),
            "call_id": .string(callID),
            "output": try makeToolResultOutput(toolResult, context: context),
          ]))
        let loaded = (toolResult.addedToolNames ?? []).compactMap {
          name -> ProviderToolDefinition? in
          guard !loadedToolNames.contains(name), let tool = deferredTools[name] else { return nil }
          loadedToolNames.insert(name)
          return tool
        }
        if !loaded.isEmpty, deferredToolsMode == "additional-tools" {
          result.append(
            .object([
              "type": .string("additional_tools"),
              "role": .string("developer"),
              "tools": .array(
                try loaded.map {
                  try responseTool(
                    $0, grammarTools: grammarTools, supportsStrictMode: supportsStrictMode,
                    providerID: context.provider.id, deferLoading: false)
                }),
            ]))
        } else if !loaded.isEmpty, deferredToolsMode == "tool-search" {
          let names = loaded.map(\.name)
          let searchCallID =
            "pi_tool_load_\(responsesShortHash("\(toolResult.toolCallID):\(names.joined(separator: ","))"))"
          result.append(
            .object([
              "type": .string("tool_search_call"),
              "call_id": .string(searchCallID),
              "execution": .string("client"),
              "status": .string("completed"),
              "arguments": .object([
                "query": .string(names.joined(separator: " ")),
                "limit": .integer(Int64(names.count)),
              ]),
            ]))
          result.append(
            .object([
              "type": .string("tool_search_output"),
              "call_id": .string(searchCallID),
              "execution": .string("client"),
              "status": .string("completed"),
              "tools": .array(
                try loaded.map {
                  try responseTool(
                    $0, grammarTools: grammarTools, supportsStrictMode: supportsStrictMode,
                    providerID: context.provider.id, deferLoading: true)
                }),
            ]))
        }
      }
      replayMessageIndex += 1
    }
    return result
  }

  private func responseToolPlacement(
    tools: [ProviderToolDefinition],
    messages: [ProviderMessage],
    enabled: Bool
  ) -> (immediate: [ProviderToolDefinition], deferred: [String: ProviderToolDefinition]) {
    guard enabled else { return (tools, [:]) }
    var usedNames = Set<String>()
    var deferredNames = Set<String>()
    for message in messages {
      switch message {
      case .assistant(let content):
        usedNames.formUnion(
          content.compactMap { item in
            guard case .toolCall(let call) = item else { return nil }
            return call.name
          })
      case .assistantMessage(let assistant):
        usedNames.formUnion(
          assistant.content.compactMap { item in
            guard case .toolCall(let call) = item else { return nil }
            return call.name
          })
      case .toolResult(let result):
        for name in result.addedToolNames ?? [] where !usedNames.contains(name) {
          deferredNames.insert(name)
        }
      default: break
      }
    }
    var deferred: [String: ProviderToolDefinition] = [:]
    var immediate: [ProviderToolDefinition] = []
    for tool in tools {
      if deferredNames.contains(tool.name) {
        deferred[tool.name] = tool
      } else {
        immediate.append(tool)
      }
    }
    return (immediate, deferred)
  }

  private func responseTool(
    _ definition: ProviderToolDefinition,
    grammarTools: [String: ProviderConstrainedSamplingResolver.Grammar],
    supportsStrictMode: Bool,
    providerID: String,
    deferLoading: Bool
  ) throws -> JSONValue {
    if let grammar = grammarTools[definition.name] {
      var tool: [String: JSONValue] = [
        "type": .string("custom"),
        "name": .string(definition.name),
        "description": .string(definition.description),
        "format": .object([
          "type": .string("grammar"),
          "syntax": .string(grammar.syntax),
          "definition": .string(grammar.definition),
        ]),
      ]
      if deferLoading { tool["defer_loading"] = .bool(true) }
      return .object(tool)
    }
    let constrained = try ProviderConstrainedSamplingResolver.jsonSchema(
      for: definition,
      supportsStrictMode: supportsStrictMode,
      providerID: providerID,
      operation: "openai-responses.request.tool-schema"
    )
    var tool: [String: JSONValue] = [
      "type": .string("function"),
      "name": .string(definition.name),
      "description": .string(definition.description),
      "parameters": constrained.schema,
    ]
    if deferLoading { tool["defer_loading"] = .bool(true) }
    if let strict = constrained.strict {
      tool["strict"] = .bool(strict)
    } else if flavor == .azure {
      tool["strict"] = .bool(false)
    } else if flavor == .codex {
      tool["strict"] = .null
    }
    return .object(tool)
  }

  private func responseMessageInput(
    text: String,
    signature: String?,
    fallbackID: String
  ) -> JSONValue {
    var id = fallbackID
    var phase: String?
    if let signature,
      let data = signature.data(using: .utf8),
      let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
      let object = parsed.objectValue,
      object.int("v") == 1,
      let parsedID = object.string("id")
    {
      id = parsedID
      phase = object.string("phase")
    }
    if id.count > 64 {
      id = "msg_\(responsesShortHash(id))"
    }
    var object: [String: JSONValue] = [
      "type": .string("message"),
      "role": .string("assistant"),
      "content": .array([
        .object([
          "type": .string("output_text"),
          "text": .string(text),
          "annotations": .array([]),
        ])
      ]),
      "status": .string("completed"),
      "id": .string(id),
    ]
    if let phase { object["phase"] = .string(phase) }
    return .object(object)
  }

  private func responseJSONString(_ value: JSONValue) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let result = String(data: data, encoding: .utf8) else {
      throw failure(
        .invalidRequest,
        providerID: nil,
        operation: "openai-responses.request.tool-call",
        message: "tool call arguments are not valid UTF-8 JSON"
      )
    }
    return result
  }

  private func normalizedResponsesToolID(
    _ id: String,
    source: ProviderMessageSource,
    target: ProviderMessageSource
  ) -> String {
    guard source != target else { return id }
    let allowedProviders: Set<String>
    switch flavor {
    case .azure:
      allowedProviders = ["openai", "openai-codex", "opencode", "azure-openai-responses"]
    case .standard, .codex:
      allowedProviders = ["openai", "openai-codex", "opencode"]
    }
    guard allowedProviders.contains(target.providerID), id.contains("|") else {
      return normalizedResponsesIDPart(id)
    }
    let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
    let callID = normalizedResponsesIDPart(parts[0])
    var itemID = "fc_\(responsesShortHash(parts[1]))"
    if itemID.count > 64 { itemID = String(itemID.prefix(64)) }
    return "\(callID)|\(itemID)"
  }

  private func normalizedResponsesIDPart(_ value: String) -> String {
    let sanitized = value.map { character in
      character.isLetter || character.isNumber || character == "_" || character == "-"
        ? character : "_"
    }
    return String(sanitized.prefix(64)).replacingOccurrences(
      of: #"_+$"#,
      with: "",
      options: .regularExpression
    )
  }

  private func responsesShortHash(_ value: String) -> String {
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

  private func makeUserContent(_ content: ProviderUserContent) throws -> JSONValue {
    switch content {
    case .text(let text):
      .object(["type": .string("input_text"), "text": .string(text)])
    case .image(.data(let data, let mimeType)):
      .object([
        "type": .string("input_image"),
        "detail": .string("auto"),
        "image_url": .string("data:\(mimeType);base64,\(data.base64EncodedString())"),
      ])
    case .image(.remoteURL(let url, _)):
      .object([
        "type": .string("input_image"),
        "detail": .string("auto"),
        "image_url": .string(url.absoluteString),
      ])
    }
  }

  private func makeToolResultOutput(
    _ result: ProviderToolResult,
    context: WireProtocolContext
  ) throws -> JSONValue {
    let text = result.content.compactMap { item -> String? in
      guard case .text(let text) = item else { return nil }
      return text
    }.joined(separator: "\n")
    let images = result.content.compactMap { item -> ProviderImage? in
      guard case .image(let image) = item else { return nil }
      return image
    }
    guard !images.isEmpty, context.model.capabilities.imageInput else {
      if !text.isEmpty { return .string(text) }
      return .string(images.isEmpty ? "(no tool output)" : "(see attached image)")
    }
    var output: [JSONValue] = []
    if !text.isEmpty {
      output.append(.object(["type": .string("input_text"), "text": .string(text)]))
    }
    for image in images {
      switch image {
      case .data(let data, let mimeType):
        output.append(
          .object([
            "type": .string("input_image"),
            "detail": .string("auto"),
            "image_url": .string("data:\(mimeType);base64,\(data.base64EncodedString())"),
          ]))
      case .remoteURL:
        throw failure(
          .unsupportedCapability,
          providerID: context.provider.id,
          operation: "openai-responses.request.tool-result-image",
          message: "OpenAI Responses tool-result images require inline bytes"
        )
      }
    }
    return .array(output)
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

private struct OpenAIResponsesReducer {
  let providerID: String
  let protocolID: String
  let requestedModelID: String
  let acceptsCodexTerminalAliases: Bool
  let grammarInputProperties: [String: String]
  let pricing: ProviderUsagePricing?
  let requestedServiceTier: String?
  let flavor: OpenAIResponsesAdapter.Flavor
  private var started = false
  private var terminal = false
  private var responseID: String?
  private var tools: [String: ToolState] = [:]
  private var toolIDsByItemID: [String: String] = [:]
  private var completedToolCall = false
  private var textByIndex: [Int: ProviderTextContent] = [:]
  private var reasoningByIndex: [Int: ProviderReasoningContent] = [:]
  private var reasoningIndexByID: [String: Int] = [:]
  private var toolsByIndex: [Int: ProviderToolCall] = [:]
  private var usage: ProviderUsage?

  init(
    providerID: String,
    protocolID: String,
    requestedModelID: String,
    acceptsCodexTerminalAliases: Bool,
    grammarInputProperties: [String: String],
    pricing: ProviderUsagePricing?,
    requestedServiceTier: String?,
    flavor: OpenAIResponsesAdapter.Flavor
  ) {
    self.providerID = providerID
    self.protocolID = protocolID
    self.requestedModelID = requestedModelID
    self.acceptsCodexTerminalAliases = acceptsCodexTerminalAliases
    self.grammarInputProperties = grammarInputProperties
    self.pricing = pricing
    self.requestedServiceTier = requestedServiceTier
    self.flavor = flavor
  }

  mutating func reduce(_ event: ServerSentEvent) throws -> [ProviderEvent] {
    if event.data == "[DONE]" { return [] }
    let object = try decodeJSONObject(
      Data(event.data.utf8),
      providerID: providerID,
      operation: "openai-responses.event.decode"
    )
    guard let type = object.string("type") ?? event.event else {
      throw invalid("Responses event is missing type")
    }
    switch type {
    case "response.created", "response.in_progress":
      guard !started else { return [] }
      guard let response = object.object("response"), let id = response.string("id") else {
        throw invalid("response.created is missing response identity")
      }
      started = true
      responseID = id
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
    case "response.output_text.delta":
      guard let delta = object.string("delta") else { throw invalid("text delta is missing delta") }
      let index = object.int("output_index") ?? 0
      let previous = textByIndex[index]?.text ?? ""
      textByIndex[index] = ProviderTextContent(
        text: previous + delta, signature: textByIndex[index]?.signature)
      return [.textDelta(delta)]
    case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
      guard let delta = object.string("delta") else {
        throw invalid("reasoning delta is missing delta")
      }
      let index = object.int("output_index") ?? 0
      let previous = reasoningByIndex[index]?.text ?? ""
      reasoningByIndex[index] = ProviderReasoningContent(
        text: previous + delta,
        signature: reasoningByIndex[index]?.signature,
        providerMetadata: [:]
      )
      return [.reasoningDelta(delta)]
    case "response.reasoning_summary_part.done":
      let index = object.int("output_index") ?? 0
      guard let current = reasoningByIndex[index] else { return [] }
      reasoningByIndex[index] = ProviderReasoningContent(
        text: current.text + "\n\n", signature: current.signature,
        isRedacted: current.isRedacted, providerMetadata: current.providerMetadata)
      return [.reasoningDelta("\n\n")]
    case "response.output_item.added":
      guard let item = object.object("item"),
        ["function_call", "custom_tool_call"].contains(item.string("type") ?? "")
      else {
        return []
      }
      guard let id = responseToolID(item),
        let name = item.string("name")
      else { throw invalid("function call item is missing id or name") }
      if let itemID = item.string("id") { toolIDsByItemID[itemID] = id }
      let customProperty =
        item.string("type") == "custom_tool_call"
        ? (grammarInputProperties[name] ?? "input") : nil
      tools[id] = ToolState(
        name: name,
        arguments: item.string("arguments") ?? item.string("input") ?? "",
        customInputProperty: customProperty)
      return [.toolCallStarted(id: id, name: name)]
    case "response.function_call_arguments.delta":
      guard let rawID = object.string("item_id") ?? object.string("call_id"),
        let id = toolIDsByItemID[rawID] ?? (tools[rawID] == nil ? nil : rawID),
        let delta = object.string("delta"),
        var state = tools[id]
      else { throw invalid("function call delta has no matching item") }
      state.arguments += delta
      tools[id] = state
      return [.toolInputDelta(id: id, delta: delta)]
    case "response.custom_tool_call_input.delta":
      guard let rawID = object.string("item_id") ?? object.string("call_id"),
        let id = toolIDsByItemID[rawID] ?? (tools[rawID] == nil ? nil : rawID),
        let delta = object.string("delta"),
        var state = tools[id], state.customInputProperty != nil
      else { throw invalid("custom tool call delta has no matching item") }
      state.arguments += delta
      tools[id] = state
      return [.toolInputDelta(id: id, delta: delta)]
    case "response.custom_tool_call_input.done":
      guard let rawID = object.string("item_id") ?? object.string("call_id"),
        let id = toolIDsByItemID[rawID] ?? (tools[rawID] == nil ? nil : rawID),
        let input = object.string("input"), var state = tools[id], state.customInputProperty != nil
      else { throw invalid("custom tool call completion has no matching item") }
      state.arguments = input
      tools[id] = state
      return []
    case "response.output_item.done":
      guard let item = object.object("item"), let itemType = item.string("type") else {
        throw invalid("completed output item is missing type")
      }
      if itemType == "reasoning" {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(item)),
          let signature = String(data: data, encoding: .utf8)
        else { throw invalid("reasoning item cannot be encoded") }
        let index = object.int("output_index") ?? 0
        let summary = (item.array("summary") ?? []).compactMap { $0.objectValue?.string("text") }
          .joined(separator: "\n\n")
        let content = (item.array("content") ?? []).compactMap { $0.objectValue?.string("text") }
          .joined(separator: "\n\n")
        reasoningByIndex[index] = ProviderReasoningContent(
          text: !summary.isEmpty
            ? summary : (!content.isEmpty ? content : reasoningByIndex[index]?.text ?? ""),
          signature: signature,
          providerMetadata: [:]
        )
        if let id = item.string("id") { reasoningIndexByID[id] = index }
        return [.reasoningSignatureDelta(signature)]
      }
      if itemType == "message" {
        let index = object.int("output_index") ?? 0
        let text = (item.array("content") ?? []).compactMap { part -> String? in
          guard let part = part.objectValue else { return nil }
          return part.string("text") ?? part.string("refusal")
        }.joined()
        guard let id = item.string("id"), !id.isEmpty else {
          throw invalid("completed message item is missing id")
        }
        var signature = #"{"v":1,"id":"\#(id)""#
        if let phase = item.string("phase") {
          signature += #", "phase":"\#(phase)""#.replacingOccurrences(of: ", ", with: ",")
        }
        signature += "}"
        textByIndex[index] = ProviderTextContent(
          text: text.isEmpty ? textByIndex[index]?.text ?? "" : text,
          signature: signature
        )
        return []
      }
      guard ["function_call", "custom_tool_call"].contains(itemType) else { return [] }
      guard let id = responseToolID(item),
        let state = tools.removeValue(forKey: id)
      else { throw invalid("completed function call has no matching item") }
      let arguments: JSONValue
      if let property = state.customInputProperty {
        arguments = .object([property: .string(item.string("input") ?? state.arguments)])
      } else {
        let raw = item.string("arguments") ?? state.arguments
        do {
          arguments = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        } catch {
          throw invalid("function call arguments are malformed")
        }
      }
      completedToolCall = true
      let call = ProviderToolCall(
        id: id,
        name: state.name,
        arguments: arguments,
        namespace: item.string("namespace")
      )
      toolsByIndex[object.int("output_index") ?? toolsByIndex.count] = call
      return [
        .toolCallCompleted(call)
      ]
    case "response.completed",
      "response.done"
    where type == "response.completed" || acceptsCodexTerminalAliases:
      guard let response = object.object("response") else {
        throw invalid("completed event is missing response")
      }
      terminal = true
      try backfillReasoningSignatures(from: response)
      var events: [ProviderEvent] = []
      if let usage = response.object("usage") {
        self.usage = try pricedUsage(
          usage, responseServiceTier: response.string("service_tier"))
        events.append(.usage(self.usage!))
      }
      if let id = response.string("id"), !id.isEmpty { responseID = id }
      guard response.string("status") == nil || response.string("status") == "completed" else {
        throw ProviderRuntimeFailure(
          code: .transportFailed,
          message: "OpenAI response has unsupported terminal status: \(response.string("status")!)",
          providerID: providerID,
          operation: "openai-responses.event.completed",
          causeDescription: response.string("status"))
      }
      let reason: ProviderFinishReason = completedToolCall ? .toolCalls : .stop
      events.append(responseSnapshot(reason, rawFinishReason: response.string("status")))
      events.append(.completed(reason))
      return events
    case "response.incomplete":
      guard let response = object.object("response") else {
        throw invalid("incomplete event is missing response")
      }
      let rawReason = response.object("incomplete_details")?.string("reason")
      guard rawReason == "max_output_tokens" else {
        terminal = true
        throw ProviderRuntimeFailure(
          code: .transportFailed,
          message: rawReason.map { "OpenAI response incomplete: \($0)" }
            ?? "OpenAI response incomplete without a provider reason",
          providerID: providerID,
          operation: "openai-responses.event.incomplete",
          causeDescription: rawReason
        )
      }
      terminal = true
      if let id = response.string("id"), !id.isEmpty { responseID = id }
      var events: [ProviderEvent] = []
      if let usage = response.object("usage") {
        self.usage = try pricedUsage(
          usage, responseServiceTier: response.string("service_tier"))
        events.append(.usage(self.usage!))
      }
      let raw = "incomplete.\(rawReason!)"
      events.append(responseSnapshot(.length, rawFinishReason: raw))
      events.append(.completed(.length))
      return events
    case "response.failed", "error":
      terminal = true
      let error = object.object("error") ?? object.object("response")?.object("error")
      let details = object.object("response")?.object("incomplete_details")?.string("reason")
      let topLevelMessage = object.string("message")
      let topLevelCode = object.string("code")
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: error?.string("message") ?? topLevelMessage
          ?? details.map { "OpenAI response failed: \($0)" }
          ?? "OpenAI Responses stream failed",
        providerID: providerID,
        operation: "openai-responses.event.error",
        causeDescription: error?.string("code") ?? topLevelCode ?? details
      )
    case "response.output_text.done", "response.content_part.added",
      "response.content_part.done",
      "response.function_call_arguments.done", "response.reasoning_summary_part.added",
      "response.reasoning_summary_text.done":
      return []
    default:
      throw invalid("unsupported OpenAI Responses event: \(type)")
    }
  }

  func validateTerminal() throws {
    guard started, terminal else {
      throw invalid("OpenAI Responses stream ended without a terminal event")
    }
    guard tools.isEmpty else {
      throw invalid("OpenAI Responses stream ended with incomplete tool calls")
    }
  }

  private func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: providerID,
      operation: "openai-responses.event.reduce",
      causeDescription: nil
    )
  }

  private func pricedUsage(
    _ raw: [String: JSONValue],
    responseServiceTier: String?
  ) throws -> ProviderUsage {
    guard let pricing else {
      throw ProviderRuntimeFailure(
        code: .upstreamDrift,
        message: "model cost rates are missing",
        providerID: providerID,
        operation: "openai-responses.usage.pricing",
        causeDescription: nil)
    }
    let cached = raw.object("input_tokens_details")?.int("cached_tokens") ?? 0
    let cacheWrite = raw.object("input_tokens_details")?.int("cache_write_tokens") ?? 0
    let input = max(0, (raw.int("input_tokens") ?? 0) - cached - cacheWrite)
    let output = raw.int("output_tokens") ?? 0
    let cost = pricing.cost(
      input: input,
      output: output,
      cacheRead: cached,
      cacheWrite: cacheWrite,
      multiplier: serviceTierMultiplier(responseServiceTier: responseServiceTier))
    return ProviderUsage(
      inputTokens: input,
      outputTokens: output,
      reasoningTokens: raw.object("output_tokens_details")?.int("reasoning_tokens") ?? 0,
      cachedInputTokens: cached,
      cacheWriteTokens: cacheWrite,
      totalTokens: raw.int("total_tokens") ?? 0,
      providerMetadata: raw,
      cost: cost)
  }

  private func serviceTierMultiplier(responseServiceTier: String?) -> Double {
    guard flavor != .azure else { return 1 }
    let effectiveTier: String?
    if flavor == .codex, responseServiceTier == "default",
      requestedServiceTier == "flex" || requestedServiceTier == "priority"
    {
      effectiveTier = requestedServiceTier
    } else {
      effectiveTier = responseServiceTier ?? requestedServiceTier
    }
    switch effectiveTier {
    case "flex": return 0.5
    case "priority": return requestedModelID == "gpt-5.5" ? 2.5 : 2
    default: return 1
    }
  }

  private func responseToolID(_ item: [String: JSONValue]) -> String? {
    let itemID = item.string("id")
    let callID = item.string("call_id")
    if let callID, let itemID, callID != itemID { return "\(callID)|\(itemID)" }
    return callID ?? itemID
  }

  private func responseSnapshot(
    _ reason: ProviderFinishReason,
    rawFinishReason: String?
  ) -> ProviderEvent {
    let indices = Set(textByIndex.keys).union(reasoningByIndex.keys).union(toolsByIndex.keys)
      .sorted()
    let content = indices.compactMap { index -> ProviderResponseContent? in
      if let reasoning = reasoningByIndex[index] { return .reasoning(reasoning) }
      if let text = textByIndex[index] { return .text(text) }
      if let tool = toolsByIndex[index] { return .toolCall(tool) }
      return nil
    }
    return .responseSnapshot(
      ProviderResponseSnapshot(
        responseID: responseID,
        providerID: providerID,
        protocolID: protocolID,
        modelID: requestedModelID,
        responseModelID: nil,
        content: content,
        usage: usage,
        finishReason: reason,
        rawFinishReason: rawFinishReason,
        timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
      ))
  }

  private mutating func backfillReasoningSignatures(
    from response: [String: JSONValue]
  ) throws {
    for value in response.array("output") ?? [] {
      guard let item = value.objectValue, item.string("type") == "reasoning",
        let id = item.string("id"), let encrypted = item.string("encrypted_content"),
        !encrypted.isEmpty, let index = reasoningIndexByID[id],
        let current = reasoningByIndex[index], let signature = current.signature,
        let data = signature.data(using: .utf8),
        case .object(var stored) = try JSONDecoder().decode(JSONValue.self, from: data),
        stored["encrypted_content"] == nil || stored["encrypted_content"] == .null
      else { continue }
      stored["encrypted_content"] = .string(encrypted)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let updated = try encoder.encode(JSONValue.object(stored))
      guard let updatedSignature = String(data: updated, encoding: .utf8) else {
        throw invalid("reasoning signature backfill is not valid UTF-8")
      }
      reasoningByIndex[index] = ProviderReasoningContent(
        text: current.text, signature: updatedSignature,
        isRedacted: current.isRedacted, providerMetadata: current.providerMetadata)
    }
  }

  private struct ToolState {
    let name: String
    var arguments: String
    let customInputProperty: String?
  }
}
