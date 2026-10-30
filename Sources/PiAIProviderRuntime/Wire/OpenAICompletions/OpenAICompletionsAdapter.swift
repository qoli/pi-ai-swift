import Foundation

struct OpenAICompletionsAdapter: WireProtocolAdapter {
  let protocolID = "openai-completions"

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
              operation: "openai-completions.response",
              message: "OpenAI Completions request failed (HTTP \(response.statusCode))",
              cause: body
            )
          }
          var decoder = ServerSentEventDecoder()
          var reducer = OpenAICompletionsReducer(
            providerID: request.providerID,
            requestedModelID: request.modelID,
            supportsFinishReason: OpenAICompletionsCompatibility.resolve(context)
              .bool("supportsFinishReason") != false,
            grammarInputProperties: try completionGrammarInputProperties(request, context: context),
            pricing: try ProviderUsagePricing.parse(
              metadata: context.modelConfiguration.metadata,
              providerID: request.providerID,
              operation: "openai-completions.usage.pricing"),
            isOpenRouter: request.providerID == "openrouter"
              || context.baseURL.absoluteString.contains("openrouter.ai")
          )
          continuation.yield(reducer.startEvent())
          readStream: for try await chunk in response.body {
            try Task.checkCancellation()
            for event in try decoder.append(chunk) {
              for normalized in try reducer.reduce(event) {
                continuation.yield(normalized)
              }
              if reducer.terminal { break readStream }
            }
          }
          if !reducer.terminal {
            for event in try decoder.finish() {
              for normalized in try reducer.reduce(event) {
                continuation.yield(normalized)
              }
            }
          }
          for event in try reducer.finish() {
            continuation.yield(event)
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

  private func applyReasoning(
    _ effort: ProviderReasoningEffort,
    metadata: [String: JSONValue],
    compat: [String: JSONValue],
    body: inout [String: JSONValue],
    providerID: String,
    maximumOutputTokens: Int?,
    thinkingBudgets: [ProviderReasoningEffort: Int]?
  ) {
    let enabled = effort != .off
    let mapping = metadata.object("thinkingLevelMap")?[effort.rawValue]
    let mapped = mapping?.stringValue
    let mappedOffIsNull = effort == .off && metadata.object("thinkingLevelMap")?["off"] == .null
    let wireEffort = mapped ?? (enabled ? effort.rawValue : "none")
    let supportsEffort = compat.bool("supportsReasoningEffort") != false
    // These provider defaults are the pinned upstream compatibility resolution.
    let format =
      compat.string("thinkingFormat") ?? (providerID == "openrouter" ? "openrouter" : "openai")
    switch format {
    case "zai":
      body["thinking"] = .object(
        enabled
          ? ["type": .string("enabled"), "clear_thinking": .bool(false)]
          : ["type": .string("disabled")])
      if enabled && supportsEffort { body["reasoning_effort"] = .string(wireEffort) }
    case "deepseek":
      if !mappedOffIsNull {
        body["thinking"] = .object(["type": .string(enabled ? "enabled" : "disabled")])
      }
      if enabled && supportsEffort { body["reasoning_effort"] = .string(wireEffort) }
    case "qwen":
      body["enable_thinking"] = .bool(enabled)
      if enabled && supportsEffort { body["reasoning_effort"] = .string(wireEffort) }
    case "qwen-chat-template":
      body["chat_template_kwargs"] = .object([
        "enable_thinking": .bool(enabled), "preserve_thinking": .bool(true),
      ])
    case "chat-template", "baseten":
      let key = format == "baseten" ? "chatTemplateArgs" : "chatTemplateKwargs"
      let field = format == "baseten" ? "chat_template_args" : "chat_template_kwargs"
      var values: [String: JSONValue] = [:]
      for (name, value) in compat.object(key) ?? [:] {
        guard let variable = value.objectValue else {
          values[name] = value
          continue
        }
        if !enabled && variable.bool("omitWhenOff") == true { continue }
        switch variable.string("$var") {
        case "thinking.enabled": values[name] = .bool(enabled)
        case "thinking.budget":
          if let budget = clampedThinkingBudget(
            effort, maximumOutputTokens: maximumOutputTokens, budgets: thinkingBudgets)
          {
            values[name] = .integer(Int64(budget))
          }
        default:
          if let mapped = mapping?.stringValue {
            values[name] = .string(mapped)
          } else if mapping == nil, enabled {
            values[name] = .string(effort.rawValue)
          }
        }
      }
      if !values.isEmpty { body[field] = .object(values) }
      if format == "baseten", supportsEffort, mapped != nil || (mapping == nil && enabled) {
        body["reasoning_effort"] = .string(wireEffort)
      }
    case "openrouter":
      if !mappedOffIsNull {
        body["reasoning"] = .object(["effort": .string(wireEffort)])
      }
    case "together":
      body["reasoning"] = .object(["enabled": .bool(enabled)])
      if enabled && supportsEffort { body["reasoning_effort"] = .string(wireEffort) }
    case "string-thinking":
      if !mappedOffIsNull { body["thinking"] = .string(wireEffort) }
    case "ant-ling" where enabled:
      if let mapped { body["reasoning"] = .object(["effort": .string(mapped)]) }
    default:
      if supportsEffort, enabled || mapped != nil {
        body["reasoning_effort"] = .string(wireEffort)
      }
    }
  }

  private func clampedThinkingBudget(
    _ effort: ProviderReasoningEffort,
    maximumOutputTokens: Int?,
    budgets: [ProviderReasoningEffort: Int]?
  ) -> Int? {
    guard effort != .off, let ceiling = maximumOutputTokens else { return nil }
    let level: ProviderReasoningEffort = effort == .xhigh || effort == .max ? .high : effort
    let defaults: [ProviderReasoningEffort: Int] = [
      .minimal: 1_024, .low: 2_048, .medium: 8_192, .high: 16_384,
    ]
    guard let budget = budgets?[level] ?? defaults[level] else { return nil }
    let clamped = min(budget, max(0, ceiling - 1_024))
    return clamped > 0 ? clamped : nil
  }

  private func makeURLRequest(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> URLRequest {
    try request.validateSingleSystemMessage(operation: "openai-completions.request.system")
    let azure =
      request.providerID == "azure"
      ? try ResolvedAzureOpenAIResponsesConfiguration.resolve(
        request: request, modelBaseURL: context.baseURL.absoluteString) : nil
    let endpoint = (azure.flatMap { URL(string: $0.baseURL) } ?? context.baseURL).appending(
      path: "chat/completions")
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (name, value) in context.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let compat = OpenAICompletionsCompatibility.resolve(context)
    ProviderSessionHeaders.applyOpenAICompletionsAffinity(
      request: request, context: context, compat: compat, to: &urlRequest)
    ProviderSessionHeaders.applyOpenCode(request: request, to: &urlRequest)
    applyGitHubCopilotHeaders(
      providerID: request.providerID,
      messages: request.messages,
      to: &urlRequest
    )
    switch context.credential {
    case .apiKey(let credential):
      if urlRequest.value(forHTTPHeaderField: "Authorization") == nil {
        urlRequest.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
      }
    case .oauth(let credential):
      if urlRequest.value(forHTTPHeaderField: "Authorization") == nil {
        urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
      }
    case nil
    where context.usesHeaderAuthentication
      && context.headers.contains(where: {
        ["authorization", "cf-aig-authorization"].contains($0.key.lowercased())
          && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }):
      break
    case nil:
      throw failure(
        .missingCredential,
        providerID: request.providerID,
        operation: "openai-completions.request.auth",
        message: "OpenAI Completions credential is missing"
      )
    }
    if urlRequest.value(forHTTPHeaderField: "Authorization")?.isEmpty == true {
      urlRequest.setValue(nil, forHTTPHeaderField: "Authorization")
    }
    var body = try makeBody(request, context: context)
    if let azure { body["model"] = .string(azure.deploymentName) }
    urlRequest.httpBody = try encodeJSONObject(
      body,
      providerID: request.providerID,
      operation: "openai-completions.request.encode"
    )
    return urlRequest
  }

  private func completionGrammarInputProperties(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: String] {
    let supports =
      OpenAICompletionsCompatibility.resolve(context)
      .bool("supportsOpenAIGrammarTools") == true
    var result: [String: String] = [:]
    for tool in request.tools {
      if let grammar = try ProviderConstrainedSamplingResolver.grammar(
        for: tool, supportsGrammarTools: supports, providerID: request.providerID,
        operation: "openai-completions.request.grammar-tool")
      {
        result[tool.name] = grammar.inputProperty
      }
    }
    return result
  }

  private func makeBody(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: JSONValue] {
    let metadata = context.modelConfiguration.metadata
    let compat = OpenAICompletionsCompatibility.resolve(context)
    let activeTools = request.tools
    var body: [String: JSONValue] = [
      "model": .string(request.modelID),
      "messages": .array(
        try makeMessages(
          request.messages.insertingMissingToolResults(), context: context, tools: request.tools)),
      "stream": .bool(true),
    ]
    if compat.bool("supportsUsageInStreaming") != false {
      body["stream_options"] = .object(["include_usage": .bool(true)])
    }
    if compat.bool("supportsStore") != false {
      body["store"] = .bool(false)
    }
    if let maximum = request.options.maximumOutputTokens
      ?? context.model.maximumOutputTokens
    {
      let field = compat.string("maxTokensField") ?? "max_completion_tokens"
      body[field] = .integer(Int64(maximum))
    }
    if let temperature = request.options.temperature {
      body["temperature"] = .number(temperature)
    }
    if let priority = compat["vllmPriority"] {
      switch priority {
      case .integer, .number:
        body["priority"] = priority
      default:
        throw failure(
          .invalidRequest, providerID: request.providerID,
          operation: "openai-completions.request.vllm-priority",
          message: "vLLM priority must be numeric")
      }
    }
    if request.options.cacheRetention != .none,
      let sessionID = request.options.sessionID,
      !sessionID.isEmpty,
      context.baseURL.host == "api.openai.com"
        || (request.options.cacheRetention == .long
          && compat.bool("supportsLongCacheRetention") != false)
    {
      body["prompt_cache_key"] = .string(String(sessionID.prefix(64)))
    }
    if request.options.cacheRetention == .long,
      compat.bool("supportsLongCacheRetention") != false
    {
      body["prompt_cache_retention"] = .string("24h")
    }
    if context.model.capabilities.reasoning {
      let effort =
        request.options.providerOptions["reasoningEffort"].map {
          $0.stringValue.flatMap(ProviderReasoningEffort.init(rawValue:)) ?? .off
        } ?? request.options.reasoningEffort ?? .off
      applyReasoning(
        effort, metadata: metadata, compat: compat, body: &body, providerID: request.providerID,
        maximumOutputTokens: request.options.maximumOutputTokens
          ?? context.model.maximumOutputTokens,
        thinkingBudgets: request.options.thinkingBudgets)
      let budgetField =
        compat.string("thinkingTokenBudgetField")
        ?? (compat.bool("supportsThinkingTokenBudget") == true ? "thinking_token_budget" : nil)
      if let budgetField,
        let budget = clampedThinkingBudget(
          effort,
          maximumOutputTokens: request.options.maximumOutputTokens
            ?? context.model.maximumOutputTokens,
          budgets: request.options.thinkingBudgets)
      {
        body[budgetField] = .integer(Int64(budget))
      }
    }
    if !activeTools.isEmpty {
      body["tools"] = .array(
        try activeTools.map { tool in
          try completionTool(tool, compat: compat, providerID: request.providerID)
        }
      )
      if compat.bool("zaiToolStream") == true { body["tool_stream"] = .bool(true) }
    } else if request.messages.contains(where: { message in
      switch message {
      case .toolResult: return true
      case .assistant(let content):
        return content.contains {
          if case .toolCall = $0 { return true }
          return false
        }
      case .assistantMessage(let assistant):
        return assistant.content.contains {
          if case .toolCall = $0 { return true }
          return false
        }
      default: return false
      }
    }) {
      body["tools"] = .array([])
    }
    try applyAnthropicCacheControl(
      body: &body, compat: compat, retention: request.options.cacheRetention,
      providerID: request.providerID)
    if let toolChoice = request.options.toolChoice {
      body["tool_choice"] = toolChoice
    }
    if let schema = request.options.responseSchema {
      body["response_format"] = .object([
        "type": .string("json_schema"),
        "json_schema": .object([
          "name": .string("response"),
          "strict": .bool(true),
          "schema": schema,
        ]),
      ])
    }
    if let routing = compat.object("openRouterRouting"), !routing.isEmpty {
      body["provider"] = .object(routing)
    }
    if let routing = compat.object("vercelGatewayRouting") {
      var gateway: [String: JSONValue] = [:]
      if let only = routing["only"] { gateway["only"] = only }
      if let order = routing["order"] { gateway["order"] = order }
      if !gateway.isEmpty {
        body["providerOptions"] = .object(["gateway": .object(gateway)])
      }
    }
    for (key, value) in request.options.providerOptions
    where key != "samplingParams" && key != "reasoningEffort" {
      body[key] = value
    }
    for (key, value) in ProviderSamplingParameters.resolve(request: request, context: context) {
      body[key] = value
    }
    return body
  }

  private func makeMessages(
    _ messages: [ProviderMessage],
    context: WireProtocolContext,
    tools: [ProviderToolDefinition]
  ) throws -> [JSONValue] {
    let target = ProviderMessageSource(
      api: protocolID, providerID: context.provider.id, modelID: context.model.id)
    let compat = OpenAICompletionsCompatibility.resolve(context)
    var result: [JSONValue] = []
    var pendingToolImages: [ProviderImage] = []
    for (messageIndex, message) in messages.enumerated() {
      switch message {
      case .system(let text):
        let supportsDeveloper = compat.bool("supportsDeveloperRole") != false
        let role =
          context.model.capabilities.reasoning && supportsDeveloper ? "developer" : "system"
        result.append(.object(["role": .string(role), "content": .string(text)]))
      case .user(let content):
        if compat.bool("requiresAssistantAfterToolResult") == true,
          result.last?.objectValue?.string("role") == "tool"
        {
          result.append(
            .object([
              "role": .string("assistant"),
              "content": .string("I have processed the tool results."),
            ]))
        }
        if content.count == 1, case .text(let text) = content[0] {
          guard !text.isEmpty else { continue }
          result.append(
            .object([
              "role": .string("user"),
              "content": .string(text),
            ]))
        } else {
          let filtered = content.filter { item in
            if case .text(let text) = item { return !text.isEmpty }
            return true
          }
          guard !filtered.isEmpty else { continue }
          result.append(
            .object([
              "role": .string("user"),
              "content": .array(try filtered.map(makeUserContent(_:))),
            ]))
        }
      case .userMessage(let user):
        result.append(
          contentsOf: try makeMessages([.user(user.content)], context: context, tools: tools))
      case .assistant(let content):
        var object: [String: JSONValue] = [
          "role": .string("assistant"),
          "content": compat.bool("requiresAssistantAfterToolResult") == true ? .string("") : .null,
        ]
        let texts = content.compactMap { item -> String? in
          switch item {
          case .text(let text): return text
          case .signedText(let text): return text.text
          default: return nil
          }
        }
        let nonEmptyTexts = texts.filter {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let reasoning = content.compactMap { item -> ProviderReasoningContent? in
          guard case .reasoning(let value) = item else { return nil }
          return value
        }
        let signedDetails = reasoning.lazy.compactMap {
          OpenAICompletionsReasoningDetails.parse($0.signature)
        }.first
        let legacyDetails = content.compactMap { item -> JSONValue? in
          guard case .toolCall(let call) = item else { return nil }
          return OpenAICompletionsReasoningDetails.legacy(call.thoughtSignature)
        }
        let preservedDetails = signedDetails ?? (legacyDetails.isEmpty ? nil : legacyDetails)
        let nonEmptyReasoning = reasoning.filter {
          !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if compat.bool("requiresThinkingAsText") == true, !nonEmptyReasoning.isEmpty {
          object["content"] = .array(
            [
              .object([
                "type": .string("text"),
                "text": .string(nonEmptyReasoning.map(\.text).joined(separator: "\n\n")),
              ])
            ]
              + nonEmptyTexts.map { .object(["type": .string("text"), "text": .string($0)]) })
        } else {
          if !nonEmptyTexts.isEmpty { object["content"] = .string(nonEmptyTexts.joined()) }
          if preservedDetails == nil,
            let first = nonEmptyReasoning.first, let signature = first.signature,
            ["reasoning", "reasoning_content", "reasoning_text"].contains(signature)
          {
            let field =
              context.provider.id == "opencode-go" && signature == "reasoning"
              ? "reasoning_content" : signature
            object[field] = .string(nonEmptyReasoning.map(\.text).joined(separator: "\n"))
          }
        }
        let calls = content.compactMap { item -> ProviderToolCall? in
          guard case .toolCall(let call) = item else { return nil }
          return call
        }
        if !calls.isEmpty {
          object["tool_calls"] = .array(
            try calls.map {
              .object([
                "id": .string($0.id),
                "type": .string("function"),
                "function": .object([
                  "name": .string($0.name),
                  "arguments": .string(try jsonString($0.arguments)),
                ]),
              ])
            }
          )
        }
        if let preservedDetails { object["reasoning_details"] = .array(preservedDetails) }
        if compat.bool("requiresReasoningContentOnAssistantMessages") == true,
          context.model.capabilities.reasoning,
          object["reasoning_content"] == nil
        {
          object["reasoning_content"] = .string("")
        }
        let hasContent: Bool
        switch object["content"] {
        case .string(let value): hasContent = !value.isEmpty
        case .array(let value): hasContent = !value.isEmpty
        default: hasContent = false
        }
        if hasContent || object["tool_calls"] != nil {
          result.append(.object(object))
        }
      case .assistantMessage(let assistant):
        guard let content = assistant.replayContent(for: target) else { continue }
        result.append(
          contentsOf: try makeMessages([.assistant(content)], context: context, tools: tools))
      case .toolResult(let toolResult):
        let text = toolResult.content.compactMap { content -> String? in
          guard case .text(let value) = content else { return nil }
          return value
        }.joined(separator: "\n")
        let images = toolResult.content.compactMap { content -> ProviderImage? in
          guard case .image(let image) = content else { return nil }
          return image
        }
        var toolMessage: [String: JSONValue] = [
          "role": .string("tool"),
          "tool_call_id": .string(toolResult.toolCallID),
          "content": .string(
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              ? text : (images.isEmpty ? "(no tool output)" : "(see attached image)")),
        ]
        if compat.bool("requiresToolResultName") == true, !toolResult.toolName.isEmpty {
          toolMessage["name"] = .string(toolResult.toolName)
        }
        result.append(.object(toolMessage))
        pendingToolImages.append(contentsOf: images)
        let followedByToolResult =
          messageIndex + 1 < messages.count
          && {
            if case .toolResult = messages[messageIndex + 1] { return true }
            return false
          }()
        if !followedByToolResult, !pendingToolImages.isEmpty, context.model.capabilities.imageInput
        {
          if compat.bool("requiresAssistantAfterToolResult") == true {
            result.append(
              .object([
                "role": .string("assistant"),
                "content": .string("I have processed the tool results."),
              ]))
          }
          var imageContent: [JSONValue] = [
            .object([
              "type": .string("text"),
              "text": .string("Attached image(s) from tool result:"),
            ])
          ]
          for image in pendingToolImages {
            switch image {
            case .data(let data, let mimeType):
              imageContent.append(
                .object([
                  "type": .string("image_url"),
                  "image_url": .object([
                    "url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")
                  ]),
                ]))
            case .remoteURL:
              throw failure(
                .unsupportedCapability,
                providerID: context.provider.id,
                operation: "openai-completions.request.tool-result-image",
                message: "OpenAI Completions tool-result images require inline bytes"
              )
            }
          }
          result.append(
            .object([
              "role": .string("user"),
              "content": .array(imageContent),
            ]))
        }
        if !followedByToolResult { pendingToolImages.removeAll() }

      }
    }
    return result
  }

  private func completionTool(
    _ tool: ProviderToolDefinition,
    compat: [String: JSONValue],
    providerID: String
  ) throws -> JSONValue {
    if let grammar = try ProviderConstrainedSamplingResolver.grammar(
      for: tool,
      supportsGrammarTools: compat.bool("supportsOpenAIGrammarTools") == true,
      providerID: providerID,
      operation: "openai-completions.request.grammar-tool"
    ) {
      return .object([
        "type": .string("custom"),
        "custom": .object([
          "name": .string(tool.name),
          "description": .string(tool.description),
          "format": .object([
            "type": .string("grammar"),
            "grammar": .object([
              "syntax": .string(grammar.syntax),
              "definition": .string(grammar.definition),
            ]),
          ]),
        ]),
      ])
    }
    let constrained = try ProviderConstrainedSamplingResolver.jsonSchema(
      for: tool,
      supportsStrictMode: compat.bool("supportsStrictMode") == true,
      providerID: providerID,
      operation: "openai-completions.request.tool-schema"
    )
    var function: [String: JSONValue] = [
      "name": .string(tool.name),
      "description": .string(tool.description),
      "parameters": constrained.schema,
    ]
    if compat.bool("supportsStrictMode") == true {
      function["strict"] = .bool(constrained.strict ?? false)
    }
    return .object(["type": .string("function"), "function": .object(function)])
  }

  private func applyAnthropicCacheControl(
    body: inout [String: JSONValue],
    compat: [String: JSONValue],
    retention: ProviderCacheRetention,
    providerID: String
  ) throws {
    guard compat.string("cacheControlFormat") == "anthropic", retention != .none else { return }
    var marker: [String: JSONValue] = ["type": .string("ephemeral")]
    if retention == .long, compat.bool("supportsLongCacheRetention") != false {
      marker["ttl"] = .string("1h")
    }
    guard case .array(var messages)? = body["messages"] else {
      throw failure(
        .invalidRequest, providerID: providerID,
        operation: "openai-completions.request.cache-control",
        message: "Anthropic cache control requires encoded messages")
    }
    if let index = messages.firstIndex(where: {
      guard case .object(let message) = $0 else { return false }
      return message.string("role") == "system" || message.string("role") == "developer"
    }) {
      messages[index] = addCacheMarker(messages[index], marker: marker)
    }
    if let index = messages.indices.reversed().first(where: { index in
      guard case .object(let message) = messages[index] else { return false }
      return ["user", "assistant", "tool"].contains(message.string("role") ?? "")
    }) {
      messages[index] = addCacheMarker(messages[index], marker: marker)
    }
    body["messages"] = .array(messages)
    if case .array(var tools)? = body["tools"], !tools.isEmpty,
      case .object(var last) = tools[tools.count - 1]
    {
      last["cache_control"] = .object(marker)
      tools[tools.count - 1] = .object(last)
      body["tools"] = .array(tools)
    }
  }

  private func addCacheMarker(_ value: JSONValue, marker: [String: JSONValue]) -> JSONValue {
    guard case .object(var message) = value, let content = message["content"] else { return value }
    if case .string(let text) = content, !text.isEmpty {
      message["content"] = .array([
        .object([
          "type": .string("text"), "text": .string(text),
          "cache_control": .object(marker),
        ])
      ])
      return .object(message)
    }
    if case .array(var parts) = content,
      let index = parts.indices.reversed().first(where: { index in
        guard case .object(let part) = parts[index] else { return false }
        return part.string("type") == "text"
      }), case .object(var part) = parts[index]
    {
      part["cache_control"] = .object(marker)
      parts[index] = .object(part)
      message["content"] = .array(parts)
    }
    return .object(message)
  }

  private func makeUserContent(_ content: ProviderUserContent) throws -> JSONValue {
    switch content {
    case .text(let text):
      .object(["type": .string("text"), "text": .string(text)])
    case .image(.data(let data, let mimeType)):
      .object([
        "type": .string("image_url"),
        "image_url": .object([
          "url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")
        ]),
      ])
    case .image(.remoteURL(let url, _)):
      .object([
        "type": .string("image_url"),
        "image_url": .object(["url": .string(url.absoluteString)]),
      ])
    }
  }

  private func jsonString(_ value: JSONValue) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw failure(
        .invalidRequest,
        providerID: nil,
        operation: "openai-completions.request.tool-call",
        message: "tool call arguments are not valid UTF-8 JSON"
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
}

private struct OpenAICompletionsReducer {
  let providerID: String
  let requestedModelID: String
  let supportsFinishReason: Bool
  let grammarInputProperties: [String: String]
  let pricing: ProviderUsagePricing?
  private(set) var terminal = false
  private var responseID: String?
  private var responseModelID: String?
  private var text = ""
  private var reasoning = ""
  private var rawFinishReason: String?
  private var finishReason: ProviderFinishReason?
  private var toolCalls: [Int: ToolCallState] = [:]
  private var toolSlotsByIndex: [Int: Int] = [:]
  private var toolSlotsByID: [String: Int] = [:]
  private var usage: ProviderUsage?
  private var reasoningSignature: String?
  private var reasoningDetails: [ProviderOrderedJSON] = []
  private let isOpenRouter: Bool
  private enum ContentBlock: Equatable {
    case text, reasoning
    case tool(Int)
  }
  private var contentOrder: [ContentBlock] = []

  private mutating func retainBlock(_ block: ContentBlock) {
    if !contentOrder.contains(block) { contentOrder.append(block) }
  }

  init(
    providerID: String,
    requestedModelID: String,
    supportsFinishReason: Bool,
    grammarInputProperties: [String: String],
    pricing: ProviderUsagePricing?,
    isOpenRouter: Bool = false
  ) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
    self.supportsFinishReason = supportsFinishReason
    self.grammarInputProperties = grammarInputProperties
    self.pricing = pricing
    self.isOpenRouter = isOpenRouter
  }

  func startEvent() -> ProviderEvent {
    .responseStarted(
      ProviderResponseMetadata(
        responseID: nil, providerID: providerID, modelID: requestedModelID, providerMetadata: [:]))
  }

  mutating func reduce(_ event: ServerSentEvent) throws -> [ProviderEvent] {
    if event.data == "[DONE]" {
      terminal = true
      return []
    }
    if event.data.trimmingCharacters(in: .whitespacesAndNewlines) == "null" { return [] }
    let object = try decodeJSONObject(
      Data(event.data.utf8),
      providerID: providerID,
      operation: "openai-completions.event.decode"
    )
    var events: [ProviderEvent] = []
    if responseID == nil, let id = object.string("id"), !id.isEmpty {
      responseID = id
    }
    if responseModelID == nil, let model = object.string("model"),
      !model.isEmpty, model != requestedModelID
    {
      responseModelID = model
    }
    if let usage = object.object("usage") {
      try updateUsage(usage)
    }
    let ordered = try ProviderOrderedJSON(data: Data(event.data.utf8))
    for (choiceIndex, choiceValue) in (object.array("choices") ?? []).enumerated() {
      guard let choice = choiceValue.objectValue else {
        throw invalid("completion choice is not an object")
      }
      if let reason = choice.string("finish_reason"), !reason.isEmpty {
        rawFinishReason = reason
        finishReason = mapFinishReason(reason)
      }
      if self.usage == nil, let choiceUsage = choice.object("usage") {
        try updateUsage(choiceUsage)
      }
      guard let delta = choice.object("delta") else { continue }
      for key in ["reasoning_content", "reasoning", "reasoning_text"] {
        if let text = delta.string(key), !text.isEmpty {
          retainBlock(.reasoning)
          reasoningSignature =
            providerID == "opencode-go" && key == "reasoning"
            ? "reasoning_content" : key
          reasoning += text
          events.append(.reasoningDelta(text))
          break
        }
      }
      let details =
        ordered["choices"]?.arrayValue?[choiceIndex]["delta"]?["reasoning_details"]?.arrayValue
        ?? []
      for detail in details {
        guard OpenAICompletionsReasoningDetails.valid(detail.jsonValue) else { continue }
        retainBlock(.reasoning)
        OpenAICompletionsReasoningDetails.append(detail, to: &reasoningDetails)
      }
      if let text = delta.string("content"), !text.isEmpty {
        retainBlock(.text)
        self.text += text
        events.append(.textDelta(text))
      }
      for toolValue in delta.array("tool_calls") ?? [] {
        guard let tool = toolValue.objectValue else {
          throw invalid("tool call delta is malformed")
        }
        let streamIndex = tool.int("index")
        let incomingID = tool.string("id").flatMap { $0.isEmpty ? nil : $0 }
        let index =
          streamIndex.flatMap { toolSlotsByIndex[$0] }
          ?? incomingID.flatMap { toolSlotsByID[$0] } ?? toolCalls.count
        if let streamIndex { toolSlotsByIndex[streamIndex] = index }
        retainBlock(.tool(index))
        let state = toolCalls[index] ?? ToolCallState()
        if state.id == nil, let incomingID {
          state.id = incomingID
          toolSlotsByID[incomingID] = index
        }
        if let function = tool.object("function") {
          if state.name == nil, let name = function.string("name"), !name.isEmpty {
            state.name = name
          }
          if let arguments = function.string("arguments") {
            state.arguments += arguments
            if let id = state.id, let name = state.name, !state.started {
              state.started = true
              events.append(.toolCallStarted(id: id, name: name))
            }
            if let id = state.id {
              events.append(.toolInputDelta(id: id, delta: arguments))
            }
          }
        } else if let custom = tool.object("custom") {
          if state.name == nil, let name = custom.string("name"), !name.isEmpty {
            state.name = name
          }
          if let input = custom.string("input") {
            state.arguments += input
            if let name = state.name {
              state.customInputProperty = grammarInputProperties[name] ?? "input"
            }
            if let id = state.id, let name = state.name, !state.started {
              state.started = true
              events.append(.toolCallStarted(id: id, name: name))
            }
            if let id = state.id { events.append(.toolInputDelta(id: id, delta: input)) }
          }
        }
        toolCalls[index] = state
      }
    }
    return events
  }

  mutating func finish() throws -> [ProviderEvent] {
    var events: [ProviderEvent] = []
    if !reasoningDetails.isEmpty {
      reasoningSignature = try ProviderOrderedJSON.array(reasoningDetails).encodedString()
    }
    if let reasoningSignature {
      events.append(.reasoningSignatureDelta(reasoningSignature))
    }
    for block in contentOrder {
      guard case .tool(let index) = block else { continue }
      guard let state = toolCalls[index], let id = state.id, let name = state.name else {
        throw invalid("tool call ended without id or name")
      }
      let call: ProviderToolCall
      if let property = state.customInputProperty {
        call = ProviderToolCall(
          id: id, name: name, arguments: .object([property: .string(state.arguments)]))
      } else {
        call = .parsing(id: id, name: name, input: state.arguments)
      }
      events.append(.toolCallCompleted(call))
    }
    if usage == nil {
      usage = ProviderUsage(
        inputTokens: 0, outputTokens: 0, reasoningTokens: nil,
        cachedInputTokens: 0, cacheWriteTokens: 0, totalTokens: 0, providerMetadata: [:],
        cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0))
    }
    if finishReason == nil, rawFinishReason == nil, !supportsFinishReason {
      finishReason = toolCalls.isEmpty ? .stop : .toolCalls
      rawFinishReason = nil
    }
    guard let finishReason else { return events }
    if let usage { events.append(.usage(usage)) }
    events.append(responseSnapshot(finishReason, completedTools: events))
    events.append(.completed(finishReason))
    return events
  }

  private func mapFinishReason(_ value: String) -> ProviderFinishReason? {
    switch value {
    case "length": .length
    case "tool_calls", "function_call": .toolCalls
    case "stop", "end": .stop
    default: nil
    }
  }

  func validateTerminal() throws {
    guard finishReason == nil else { return }
    if let rawFinishReason {
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: "Provider finish_reason: \(rawFinishReason)",
        providerID: providerID,
        operation: "openai-completions.event.finish",
        causeDescription: rawFinishReason,
        providerMetadata: failureMetadata()
      )
    }
    throw invalid("Stream ended without finish_reason")
  }

  private func failureMetadata() -> [String: JSONValue]? {
    var result: [String: JSONValue] = [:]
    if let responseID { result["responseId"] = .string(responseID) }
    if let responseModelID { result["responseModel"] = .string(responseModelID) }
    if let rawFinishReason { result["rawStopReason"] = .string(rawFinishReason) }
    return result.isEmpty ? nil : result
  }

  private func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: providerID,
      operation: "openai-completions.event.reduce",
      causeDescription: nil,
      providerMetadata: failureMetadata()
    )
  }

  private func responseSnapshot(
    _ reason: ProviderFinishReason,
    completedTools: [ProviderEvent]
  ) -> ProviderEvent {
    let calls = completedTools.compactMap { event -> ProviderToolCall? in
      if case .toolCallCompleted(let call) = event { return call }
      return nil
    }
    var toolIndex = 0
    let content: [ProviderResponseContent] = contentOrder.map { block in
      switch block {
      case .text: return .text(ProviderTextContent(text: text, signature: nil))
      case .reasoning:
        return .reasoning(
          ProviderReasoningContent(
            text: reasoning, signature: reasoningSignature, providerMetadata: [:]))
      case .tool:
        defer { toolIndex += 1 }
        return .toolCall(calls[toolIndex])
      }
    }
    return .responseSnapshot(
      ProviderResponseSnapshot(
        responseID: responseID,
        providerID: providerID,
        protocolID: "openai-completions",
        modelID: requestedModelID,
        responseModelID: responseModelID == requestedModelID ? nil : responseModelID,
        content: content,
        usage: usage,
        finishReason: reason,
        rawFinishReason: rawFinishReason,
        timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
      ))
  }

  private final class ToolCallState {
    var id: String?
    var name: String?
    var arguments = ""
    var started = false
    var customInputProperty: String?
  }

  private mutating func updateUsage(_ usage: [String: JSONValue]) throws {
    guard let pricing else {
      throw ProviderRuntimeFailure(
        code: .upstreamDrift, message: "model cost rates are missing",
        providerID: providerID, operation: "openai-completions.usage.pricing",
        causeDescription: nil)
    }
    let cached =
      usage.object("prompt_tokens_details")?.int("cached_tokens")
      ?? usage.int("prompt_cache_hit_tokens") ?? usage.int("cached_tokens")
    let cacheWrite = usage.object("prompt_tokens_details")?.int("cache_write_tokens")
    let input = max(
      0, (usage.int("prompt_tokens") ?? 0) - (cached ?? 0) - (cacheWrite ?? 0))
    let output = usage.int("completion_tokens") ?? 0
    self.usage = ProviderUsage(
      inputTokens: input, outputTokens: output,
      reasoningTokens: usage.object("completion_tokens_details")?.int("reasoning_tokens") ?? 0,
      cachedInputTokens: cached ?? 0, cacheWriteTokens: cacheWrite ?? 0,
      totalTokens: input + output + (cached ?? 0) + (cacheWrite ?? 0),
      providerMetadata: usage,
      cost: pricing.cost(
        input: input, output: output, cacheRead: cached ?? 0,
        cacheWrite: cacheWrite ?? 0)
    ).applyingOpenRouterCost(usage, enabled: isOpenRouter)
  }
}
