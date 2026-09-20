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
            supportsFinishReason: context.modelConfiguration.metadata.object("compat")?
              .bool("supportsFinishReason") != false,
            grammarInputProperties: try completionGrammarInputProperties(request, context: context),
            pricing: try ProviderUsagePricing.parse(
              metadata: context.modelConfiguration.metadata,
              providerID: request.providerID,
              operation: "openai-completions.usage.pricing")
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

  private func applyReasoning(
    _ effort: ProviderReasoningEffort,
    metadata: [String: JSONValue],
    compat: [String: JSONValue],
    body: inout [String: JSONValue],
    providerID: String,
    maximumOutputTokens: Int?,
    thinkingBudgets: [ProviderReasoningEffort: Int]?
  ) throws {
    let enabled = effort != .off
    let mapped = metadata.object("thinkingLevelMap")?.string(effort.rawValue)
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
        guard case .object(let variable) = value else {
          values[name] = value
          continue
        }
        if !enabled && variable.bool("omitWhenOff") == true { continue }
        switch variable.string("$var") {
        case "thinking.enabled": values[name] = .bool(enabled)
        case "thinking.level":
          if enabled || mapped != nil { values[name] = .string(wireEffort) }
        case "thinking.budget":
          if enabled {
            let defaults: [ProviderReasoningEffort: Int] = [
              .minimal: 1_024, .low: 2_048, .medium: 8_192, .high: 16_384,
            ]
            guard let budget = thinkingBudgets?[effort] ?? defaults[effort] else {
              throw failure(
                .unsupportedCapability, providerID: providerID,
                operation: "openai-completions.request.reasoning",
                message: "reasoning budget requires a supported budget level")
            }
            guard let ceiling = maximumOutputTokens else {
              throw failure(
                .invalidRequest, providerID: providerID,
                operation: "openai-completions.request.reasoning",
                message: "reasoning budget requires an output limit")
            }
            let clamped = min(budget, max(0, ceiling - 1_024))
            guard clamped > 0 else {
              throw failure(
                .invalidRequest, providerID: providerID,
                operation: "openai-completions.request.reasoning",
                message: "output limit leaves no room for reasoning")
            }
            values[name] = .integer(Int64(clamped))
          }
        default:
          throw failure(
            .unsupportedCapability, providerID: providerID,
            operation: "openai-completions.request.reasoning",
            message: "unknown reasoning template variable")
        }
      }
      guard !values.isEmpty || (format == "baseten" && supportsEffort && (enabled || mapped != nil))
      else {
        throw failure(
          .unsupportedCapability, providerID: providerID,
          operation: "openai-completions.request.reasoning",
          message: "reasoning template has no encodable control")
      }
      if !values.isEmpty { body[field] = .object(values) }
      if format == "baseten", supportsEffort, enabled || mapped != nil {
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
    case "ant-ling":
      guard enabled else { break }
      guard let mapped else {
        throw failure(
          .unsupportedCapability, providerID: providerID,
          operation: "openai-completions.request.reasoning",
          message: "reasoning effort requires a model mapping")
      }
      body["reasoning"] = .object(["effort": .string(mapped)])
    case "openai":
      guard supportsEffort else {
        throw failure(
          .unsupportedCapability, providerID: providerID,
          operation: "openai-completions.request.reasoning",
          message: "model does not encode reasoning effort")
      }
      if enabled || mapped != nil {
        body["reasoning_effort"] = .string(wireEffort)
      }
    default:
      throw failure(
        .unsupportedCapability, providerID: providerID,
        operation: "openai-completions.request.reasoning",
        message: "unsupported reasoning format: \(format)")
    }
  }

  private func makeURLRequest(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> URLRequest {
    try request.validateSingleSystemMessage(operation: "openai-completions.request.system")
    let endpoint = context.baseURL.appending(path: "chat/completions")
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for (name, value) in context.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let compat = context.modelConfiguration.metadata.object("compat") ?? [:]
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
      urlRequest.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
    case .oauth(let credential):
      urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    case nil:
      throw failure(
        .missingCredential,
        providerID: request.providerID,
        operation: "openai-completions.request.auth",
        message: "OpenAI Completions credential is missing"
      )
    }
    urlRequest.httpBody = try encodeJSONObject(
      try makeBody(request, context: context),
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
      context.modelConfiguration.metadata.object("compat")?
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
    let compat = metadata.object("compat") ?? [:]
    let deferredNames: Set<String> =
      compat.string("deferredToolsMode") == "kimi"
      ? Set(
        request.messages.flatMap { message -> [String] in
          guard case .toolResult(let result) = message else { return [] }
          return result.addedToolNames ?? []
        })
      : []
    let activeTools = request.tools.filter { !deferredNames.contains($0.name) }
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
    if let effort = request.options.reasoningEffort, context.model.capabilities.reasoning {
      try applyReasoning(
        effort, metadata: metadata, compat: compat, body: &body, providerID: request.providerID,
        maximumOutputTokens: request.options.maximumOutputTokens
          ?? context.model.maximumOutputTokens,
        thinkingBudgets: request.options.thinkingBudgets)
      let budgetField =
        compat.string("thinkingTokenBudgetField")
        ?? (compat.bool("supportsThinkingTokenBudget") == true ? "thinking_token_budget" : nil)
      if effort != .off, let budgetField {
        let defaults: [ProviderReasoningEffort: Int] = [
          .minimal: 1_024, .low: 2_048, .medium: 8_192, .high: 16_384,
        ]
        if let requested = request.options.thinkingBudgets?[effort] ?? defaults[effort],
          let ceiling = request.options.maximumOutputTokens ?? context.model.maximumOutputTokens
        {
          let clamped = min(requested, max(0, ceiling - 1_024))
          if clamped > 0 { body[budgetField] = .integer(Int64(clamped)) }
        }
      }
    }
    if !activeTools.isEmpty {
      body["tools"] = .array(
        try activeTools.map { tool in
          try completionTool(tool, compat: compat, providerID: request.providerID)
        }
      )
      if compat.bool("zaiToolStream") == true { body["tool_stream"] = .bool(true) }
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
    for (key, value) in request.options.providerOptions {
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
    let compat = context.modelConfiguration.metadata.object("compat") ?? [:]
    let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    var loadedToolNames = Set<String>()
    var result: [JSONValue] = []
    for message in messages {
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
          result.append(
            .object([
              "role": .string("user"),
              "content": .string(text),
            ]))
        } else {
          result.append(
            .object([
              "role": .string("user"),
              "content": .array(try content.map(makeUserContent(_:))),
            ]))
        }
      case .userMessage(let user):
        result.append(
          contentsOf: try makeMessages([.user(user.content)], context: context, tools: tools))
      case .assistant(let content):
        var object: [String: JSONValue] = ["role": .string("assistant")]
        let texts = content.compactMap { item -> String? in
          switch item {
          case .text(let text): return text
          case .signedText(let text): return text.text
          default: return nil
          }
        }
        let reasoning = content.compactMap { item -> ProviderReasoningContent? in
          guard case .reasoning(let value) = item else { return nil }
          return value
        }
        if compat.bool("requiresThinkingAsText") == true, !reasoning.isEmpty {
          object["content"] = .array(
            reasoning.map { .object(["type": .string("text"), "text": .string($0.text)]) }
              + texts.map { .object(["type": .string("text"), "text": .string($0)]) })
        } else {
          object["content"] = texts.isEmpty ? .null : .string(texts.joined())
          if let first = reasoning.first,
            let signature = first.signature,
            ["reasoning", "reasoning_content", "reasoning_text"].contains(signature)
          {
            object[signature] = .string(reasoning.map(\.text).joined(separator: "\n"))
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
        if compat.bool("requiresReasoningContentOnAssistantMessages") == true,
          context.model.capabilities.reasoning,
          object["reasoning_content"] == nil
        {
          object["reasoning_content"] = .string("")
        }
        let hasContent = object["content"] != .null
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
            !text.isEmpty ? text : (images.isEmpty ? "(no tool output)" : "(see attached image)")),
        ]
        if compat.bool("requiresToolResultName") == true, !toolResult.toolName.isEmpty {
          toolMessage["name"] = .string(toolResult.toolName)
        }
        result.append(.object(toolMessage))
        if !images.isEmpty, context.model.capabilities.imageInput {
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
          for image in images {
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
        if compat.string("deferredToolsMode") == "kimi" {
          let added = (toolResult.addedToolNames ?? []).compactMap {
            name -> ProviderToolDefinition? in
            guard !loadedToolNames.contains(name), let tool = toolsByName[name] else { return nil }
            loadedToolNames.insert(name)
            return tool
          }
          if !added.isEmpty {
            result.append(
              .object([
                "role": .string("system"),
                "tools": .array(
                  try added.map {
                    try completionTool($0, compat: compat, providerID: context.provider.id)
                  }),
              ]))
          }
        }
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
      supportsStrictMode: compat.bool("supportsStrictMode") != false,
      providerID: providerID,
      operation: "openai-completions.request.tool-schema"
    )
    var function: [String: JSONValue] = [
      "name": .string(tool.name),
      "description": .string(tool.description),
      "parameters": constrained.schema,
    ]
    if compat.bool("supportsStrictMode") != false {
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
  private var started = false
  private var terminal = false
  private var responseID: String?
  private var responseModelID: String?
  private var text = ""
  private var reasoning = ""
  private var rawFinishReason: String?
  private var finishReason: ProviderFinishReason?
  private var toolCalls: [Int: ToolCallState] = [:]
  private var usage: ProviderUsage?
  private var reasoningSignature: String?
  private var reasoningDetails: [[String: JSONValue]] = []

  init(
    providerID: String,
    requestedModelID: String,
    supportsFinishReason: Bool,
    grammarInputProperties: [String: String],
    pricing: ProviderUsagePricing?
  ) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
    self.supportsFinishReason = supportsFinishReason
    self.grammarInputProperties = grammarInputProperties
    self.pricing = pricing
  }

  mutating func reduce(_ event: ServerSentEvent) throws -> [ProviderEvent] {
    if event.data == "[DONE]" {
      terminal = true
      return []
    }
    let object = try decodeJSONObject(
      Data(event.data.utf8),
      providerID: providerID,
      operation: "openai-completions.event.decode"
    )
    var events: [ProviderEvent] = []
    if !started {
      guard let responseID = object.string("id") else {
        throw invalid("completion chunk is missing response id")
      }
      started = true
      self.responseID = responseID
      responseModelID = object.string("model")
      events.append(
        .responseStarted(
          ProviderResponseMetadata(
            responseID: nil,
            providerID: providerID,
            modelID: object.string("model") ?? requestedModelID,
            providerMetadata: [:]
          )
        )
      )
    }
    if let usage = object.object("usage") {
      try updateUsage(usage)
    }
    for choiceValue in object.array("choices") ?? [] {
      guard let choice = choiceValue.objectValue else {
        throw invalid("completion choice is not an object")
      }
      if let reason = choice.string("finish_reason") {
        rawFinishReason = reason
        finishReason = try mapFinishReason(reason)
      }
      if self.usage == nil, let choiceUsage = choice.object("usage") {
        try updateUsage(choiceUsage)
      }
      guard let delta = choice.object("delta") else { continue }
      if let text = delta.string("content"), !text.isEmpty {
        self.text += text
        events.append(.textDelta(text))
      }
      for key in ["reasoning_content", "reasoning", "reasoning_text"] {
        if let text = delta.string(key), !text.isEmpty {
          reasoningSignature = key
          reasoning += text
          events.append(.reasoningDelta(text))
          break
        }
      }
      for detail in delta.array("reasoning_details") ?? [] {
        guard let object = validReasoningDetail(detail) else { continue }
        appendReasoningDetail(object)
      }
      for toolValue in delta.array("tool_calls") ?? [] {
        guard let tool = toolValue.objectValue, let index = tool.int("index") else {
          throw invalid("tool call delta is malformed")
        }
        var state = toolCalls[index] ?? ToolCallState()
        if let id = tool.string("id") { state.id = id }
        if let function = tool.object("function") {
          if let name = function.string("name") { state.name = name }
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
          if let name = custom.string("name") { state.name = name }
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
    guard started, terminal else {
      throw invalid("OpenAI Completions stream ended without [DONE]")
    }
    var events: [ProviderEvent] = []
    if !reasoningDetails.isEmpty {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(JSONValue.array(reasoningDetails.map(JSONValue.object)))
      guard let signature = String(data: data, encoding: .utf8) else {
        throw invalid("structured reasoning details are not valid UTF-8 JSON")
      }
      reasoningSignature = signature
    }
    if let reasoningSignature {
      events.append(.reasoningSignatureDelta(reasoningSignature))
    }
    for index in toolCalls.keys.sorted() {
      guard let state = toolCalls[index], let id = state.id, let name = state.name else {
        throw invalid("tool call ended without id or name")
      }
      let arguments: JSONValue
      if let property = state.customInputProperty {
        arguments = .object([property: .string(state.arguments)])
      } else {
        do {
          arguments = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(state.arguments.utf8)
          )
        } catch {
          throw invalid("tool call arguments are malformed")
        }
      }
      events.append(
        .toolCallCompleted(
          ProviderToolCall(id: id, name: name, arguments: arguments)
        )
      )
    }
    if let usage { events.append(.usage(usage)) }
    if finishReason == nil, !supportsFinishReason {
      finishReason = toolCalls.isEmpty ? .stop : .toolCalls
      rawFinishReason = nil
    }
    guard let finishReason else {
      throw invalid("OpenAI Completions stream ended without a finish reason")
    }
    events.append(responseSnapshot(finishReason, completedTools: events))
    events.append(.completed(finishReason))
    return events
  }

  private func mapFinishReason(_ value: String) throws -> ProviderFinishReason {
    switch value {
    case "length": .length
    case "tool_calls", "function_call": .toolCalls
    case "content_filter", "network_error":
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: "OpenAI provider returned an error finish reason: \(value)",
        providerID: providerID,
        operation: "openai-completions.event.finish",
        causeDescription: value
      )
    case "stop": .stop
    default: throw invalid("unsupported OpenAI finish reason: \(value)")
    }
  }

  private func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: providerID,
      operation: "openai-completions.event.reduce",
      causeDescription: nil
    )
  }

  private func responseSnapshot(
    _ reason: ProviderFinishReason,
    completedTools: [ProviderEvent]
  ) -> ProviderEvent {
    var content: [ProviderResponseContent] = []
    if !text.isEmpty {
      content.append(.text(ProviderTextContent(text: text, signature: nil)))
    }
    if !reasoning.isEmpty || !reasoningDetails.isEmpty {
      content.append(
        .reasoning(
          ProviderReasoningContent(
            text: reasoning,
            signature: reasoningSignature,
            providerMetadata: [:]
          )))
    }
    for event in completedTools {
      if case .toolCallCompleted(let call) = event { content.append(.toolCall(call)) }
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

  private func validReasoningDetail(_ value: JSONValue) -> [String: JSONValue]? {
    guard case .object(let object) = value, let type = object.string("type") else { return nil }
    if let id = object["id"], id != .null, id.stringValue == nil { return nil }
    if object["format"] != nil, object.string("format") == nil { return nil }
    if object["index"] != nil, object.int("index") == nil { return nil }
    switch type {
    case "reasoning.summary": guard object.string("summary") != nil else { return nil }
    case "reasoning.encrypted": guard object.string("data") != nil else { return nil }
    case "reasoning.text":
      guard object.string("text") != nil else { return nil }
      if let signature = object["signature"], signature != .null, signature.stringValue == nil {
        return nil
      }
    default: return nil
    }
    return object
  }

  private mutating func appendReasoningDetail(_ detail: [String: JSONValue]) {
    guard var last = reasoningDetails.last, last.string("type") == detail.string("type"),
      ["reasoning.text", "reasoning.summary"].contains(detail.string("type") ?? "")
    else {
      reasoningDetails.append(detail)
      return
    }
    let valueKey = detail.string("type") == "reasoning.text" ? "text" : "summary"
    last[valueKey] = .string((last.string(valueKey) ?? "") + (detail.string(valueKey) ?? ""))
    for key in ["id", "format", "index"] where last[key] == nil || last[key] == .null {
      if let value = detail[key] { last[key] = value }
    }
    if valueKey == "text", last["signature"] == nil || last["signature"] == .null,
      let signature = detail["signature"]
    {
      last["signature"] = signature
    }
    reasoningDetails[reasoningDetails.count - 1] = last
  }

  private struct ToolCallState {
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
        cacheWrite: cacheWrite ?? 0))
  }
}
