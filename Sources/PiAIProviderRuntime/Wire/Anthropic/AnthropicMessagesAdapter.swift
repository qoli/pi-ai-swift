import Foundation

struct AnthropicMessagesAdapter: WireProtocolAdapter {
  let protocolID = "anthropic-messages"

  func stream(
    _ request: ProviderRequest,
    context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport
  ) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = try makeRequest(request, context: context)
          let response = try await transport.stream(urlRequest)
          guard (200..<300).contains(response.statusCode) else {
            let body = try await collectErrorBody(from: response.body)
            throw failure(
              .transportFailed,
              providerID: request.providerID,
              operation: "anthropic.response",
              message: "Anthropic Messages request failed (HTTP \(response.statusCode))",
              cause: body
            )
          }
          var reducer = AnthropicEventReducer(
            providerID: request.providerID,
            requestedModelID: request.modelID,
            providerThinkingLevel: managedThinkingLevel(request: request, context: context),
            pricing: try ProviderUsagePricing.parse(
              metadata: context.modelConfiguration.metadata,
              providerID: request.providerID,
              operation: "anthropic.usage.pricing")
          )
          var decoder = ServerSentEventDecoder()
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

  private func makeRequest(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> URLRequest {
    try request.validateSingleSystemMessage(operation: "anthropic.request.system")
    let compat = context.modelConfiguration.metadata.object("compat") ?? [:]
    if let fallbacks = compat["allowedFallbackModels"]?.arrayValue, !fallbacks.isEmpty {
      throw failure(
        .unsupportedCapability,
        providerID: request.providerID,
        operation: "anthropic.request.server-fallback",
        message: "Anthropic server-side model fallback is forbidden by runtime policy"
      )
    }
    let endpoint = context.baseURL.appending(path: "v1/messages")
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    urlRequest.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
    let isOAuth = isOAuthCredential(context.credential)
    let betaFeatures = betaFeatures(
      request: request, compat: compat, isOAuth: isOAuth, headers: context.headers)
    if isOAuth {
      urlRequest.setValue("claude-cli/2.1.251", forHTTPHeaderField: "User-Agent")
      urlRequest.setValue("cli", forHTTPHeaderField: "x-app")
    }
    if !betaFeatures.isEmpty {
      urlRequest.setValue(betaFeatures.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
    }
    for (name, value) in context.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    ProviderSessionHeaders.applyAnthropicAffinity(
      request: request, context: context, compat: compat, to: &urlRequest)
    ProviderSessionHeaders.applyOpenCode(request: request, to: &urlRequest)
    applyGitHubCopilotHeaders(
      providerID: request.providerID,
      messages: request.messages,
      to: &urlRequest
    )
    try applyCredential(
      context.credential, to: &urlRequest, providerID: request.providerID,
      headerOwned: hasCredentialHeader(context.headers))
    var body = try makeBody(request, context: context, isOAuth: isOAuth)
    if !betaFeatures.isEmpty { body["betas"] = .array(betaFeatures.map(JSONValue.string)) }
    urlRequest.httpBody = try encodeJSONObject(
      body,
      providerID: request.providerID,
      operation: "anthropic.request.encode"
    )
    return urlRequest
  }

  private func betaFeatures(
    request: ProviderRequest,
    compat: [String: JSONValue],
    isOAuth: Bool,
    headers: [String: String]
  ) -> [String] {
    if let configured = headers.first(where: { $0.key.lowercased() == "anthropic-beta" })?.value {
      return Array(
        Set(
          configured.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        )
      ).sorted()
    }
    var features: [String] = []
    if isOAuth { features.append(contentsOf: ["claude-code-20250219", "oauth-2025-04-20"]) }
    if !request.tools.isEmpty, compat.bool("supportsEagerToolInputStreaming") == false {
      features.append("fine-grained-tool-streaming-2025-05-14")
    }
    if request.options.reasoningEffort != nil, request.options.reasoningEffort != .off,
      request.options.providerOptions["interleavedThinking"]?.boolValue != false,
      compat.bool("forceAdaptiveThinking") != true
    {
      features.append("interleaved-thinking-2025-05-14")
    }
    if compat.bool("supportsMidConvoEffort") == true {
      features.append("mid-conversation-output-config-2026-07-01")
      features.append("thinking-binding-controls-2026-08-01")
    }
    var seen = Set<String>()
    return features.filter { seen.insert($0).inserted }
  }

  private func applyCredential(
    _ credential: ProviderCredential?,
    to request: inout URLRequest,
    providerID: String,
    headerOwned: Bool
  ) throws {
    switch credential {
    case .apiKey(let credential):
      if providerID == "github-copilot" {
        request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
      } else {
        request.setValue(credential.key, forHTTPHeaderField: "x-api-key")
      }
    case .oauth(let credential):
      request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    case nil where headerOwned:
      break
    case nil:
      throw failure(
        .missingCredential,
        providerID: providerID,
        operation: "anthropic.request.auth",
        message: "Anthropic Messages credential is missing"
      )
    }
  }

  private func makeBody(
    _ request: ProviderRequest,
    context: WireProtocolContext,
    isOAuth: Bool
  ) throws -> [String: JSONValue] {
    guard
      let maximumOutputTokens = request.options.maximumOutputTokens
        ?? context.model.maximumOutputTokens
    else {
      throw failure(
        .invalidRequest,
        providerID: request.providerID,
        operation: "anthropic.request.options",
        message: "maximum output tokens are required"
      )
    }
    let compat = context.modelConfiguration.metadata.object("compat") ?? [:]
    let cacheControl: JSONValue? = {
      guard request.options.cacheRetention != .none else { return nil }
      var value: [String: JSONValue] = ["type": .string("ephemeral")]
      if request.options.cacheRetention == .long,
        compat.bool("supportsLongCacheRetention") != false
      {
        value["ttl"] = .string("1h")
      }
      return .object(value)
    }()
    let cachedMessages = applyingCacheControlToLastUserMessage(
      try makeMessages(request.messages.insertingMissingToolResults(), context: context),
      cacheControl: cacheControl
    )
    let managedEffort = managedThinkingLevel(request: request, context: context)
    let wireMessages =
      managedEffort.map {
        insertingThinkingLevelMessages(
          cachedMessages, messages: request.messages.insertingMissingToolResults(),
          activeEffort: $0, providerID: request.providerID)
      } ?? cachedMessages
    var body: [String: JSONValue] = [
      "model": .string(request.modelID),
      "messages": .array(wireMessages),
      "max_tokens": .integer(Int64(maximumOutputTokens)),
      "stream": .bool(true),
    ]
    let systems = request.messages.compactMap { message -> String? in
      guard case .system(let text) = message else { return nil }
      return text
    }
    if isOAuth || !systems.isEmpty {
      var systemTexts = systems
      if isOAuth {
        systemTexts.insert("You are Claude Code, Anthropic's official CLI for Claude.", at: 0)
      }
      body["system"] = .array(
        systemTexts.map {
          var block: [String: JSONValue] = [
            "type": .string("text"), "text": .string($0),
          ]
          if let cacheControl { block["cache_control"] = cacheControl }
          return .object(block)
        }
      )
    }
    if let temperature = request.options.temperature,
      request.options.reasoningEffort == nil || request.options.reasoningEffort == .off,
      managedEffort == nil,
      compat.bool("supportsTemperature") != false
    {
      body["temperature"] = .number(temperature)
    }
    if let managedEffort {
      let display = request.options.providerOptions["thinkingDisplay"]?.stringValue ?? "summarized"
      body["thinking"] = .object([
        "type": .string("adaptive"),
        "display": .string(display),
        "block_binding": .object(["prefix_mismatch_behavior": .string("drop_block")]),
      ])
      body["output_config"] = .object(["effort": .string("high")])
    } else if let effort = request.options.reasoningEffort, context.model.capabilities.reasoning {
      let metadata = context.modelConfiguration.metadata
      if effort == .off {
        body["thinking"] = .object(["type": .string("disabled")])
      } else if metadata.object("compat")?.bool("forceAdaptiveThinking") == true {
        let mapped = metadata.object("thinkingLevelMap")?.string(effort.rawValue)
        let wireEffort = mapped ?? (effort == .minimal ? "low" : effort.rawValue)
        let display =
          request.options.providerOptions["thinkingDisplay"]?.stringValue ?? "summarized"
        body["thinking"] = .object(["type": .string("adaptive"), "display": .string(display)])
        body["output_config"] = .object(["effort": .string(wireEffort)])
      } else {
        let defaultBudgets: [ProviderReasoningEffort: Int] = [
          .minimal: 1_024, .low: 2_048, .medium: 8_192, .high: 16_384,
        ]
        let budgetLevel: ProviderReasoningEffort =
          effort == .xhigh || effort == .max ? .high : effort
        guard
          var budget = request.options.thinkingBudgets?[budgetLevel] ?? defaultBudgets[budgetLevel]
        else {
          throw failure(
            .unsupportedCapability, providerID: request.providerID,
            operation: "anthropic.request.reasoning",
            message: "reasoning effort is unsupported by budget thinking")
        }
        let modelLimit = context.model.maximumOutputTokens ?? maximumOutputTokens
        let outputLimit =
          request.options.maximumOutputTokens.map { min($0 + budget, modelLimit) } ?? modelLimit
        budget = min(budget, max(0, outputLimit - 1_024))
        guard budget > 0 else {
          throw failure(
            .invalidRequest, providerID: request.providerID,
            operation: "anthropic.request.reasoning",
            message: "output limit leaves no room for reasoning")
        }
        body["max_tokens"] = .integer(Int64(outputLimit))
        let display =
          request.options.providerOptions["thinkingDisplay"]?.stringValue ?? "summarized"
        body["thinking"] = .object([
          "type": .string("enabled"), "budget_tokens": .integer(Int64(budget)),
          "display": .string(display),
        ])
      }
    } else if context.model.capabilities.reasoning,
      context.modelConfiguration.metadata.object("thinkingLevelMap")?["off"] != .null
    {
      body["thinking"] = .object(["type": .string("disabled")])
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        try request.tools.enumerated().map { index, tool in
          let resolved = try ProviderConstrainedSamplingResolver.jsonSchema(
            for: tool,
            supportsStrictMode: compat.bool("supportsStrictTools") == true,
            providerID: request.providerID,
            operation: "anthropic.request.tool-schema")
          let schema = anthropicToolSchema(resolved.schema, strict: resolved.strict == true)
          var value: [String: JSONValue] = [
            "name": .string(isOAuth ? claudeCodeToolName(tool.name) : tool.name),
            "description": .string(tool.description),
            "input_schema": schema,
          ]
          if resolved.strict == true { value["strict"] = .bool(true) }
          if compat.bool("supportsEagerToolInputStreaming") != false {
            value["eager_input_streaming"] = .bool(true)
          }
          if index == request.tools.indices.last,
            compat.bool("supportsCacheControlOnTools") != false,
            let cacheControl
          {
            value["cache_control"] = cacheControl
          }
          return .object(value)
        }
      )
    }
    if let choice = request.options.toolChoice {
      switch choice {
      case .string(let value) where ["auto", "any", "none"].contains(value):
        body["tool_choice"] = .object(["type": .string(value)])
      case .object(let value) where value.string("type") == "tool":
        guard let name = value.string("name"), !name.isEmpty else {
          throw failure(
            .invalidRequest, providerID: request.providerID,
            operation: "anthropic.request.tool-choice",
            message: "Anthropic named tool choice requires a non-empty name")
        }
        body["tool_choice"] = .object([
          "type": .string("tool"), "name": .string(name),
        ])
      default:
        throw failure(
          .invalidRequest,
          providerID: request.providerID,
          operation: "anthropic.request.tool-choice",
          message: "unsupported Anthropic tool choice"
        )
      }
    }
    if let schema = request.options.responseSchema {
      body["tools"] = .array([
        .object([
          "name": .string("respond"),
          "description": .string("Return the structured response"),
          "input_schema": schema,
        ])
      ])
      body["tool_choice"] = .object([
        "type": .string("tool"), "name": .string("respond"),
      ])
    }
    let supportedProviderOptions: Set<String> = [
      "interleavedThinking", "metadata", "thinkingDisplay",
    ]
    let unknown = Set(request.options.providerOptions.keys).subtracting(supportedProviderOptions)
    guard unknown.isEmpty else {
      throw failure(
        .unsupportedCapability, providerID: request.providerID,
        operation: "anthropic.request.options",
        message:
          "unsupported Anthropic provider options: \(unknown.sorted().joined(separator: ", "))")
    }
    if case .object(let metadata)? = request.options.providerOptions["metadata"],
      let userID = metadata.string("user_id")
    {
      body["metadata"] = .object(["user_id": .string(userID)])
    }
    return body
  }

  private func isOAuthCredential(_ credential: ProviderCredential?) -> Bool {
    if case .oauth = credential { return true }
    return false
  }

  private func hasCredentialHeader(_ headers: [String: String]) -> Bool {
    let names = Set(
      headers.compactMap { name, value in
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name.lowercased()
      })
    return !names.isDisjoint(with: ["authorization", "x-api-key", "cf-aig-authorization"])
  }

  private func claudeCodeToolName(_ name: String) -> String {
    let canonical = [
      "read": "Read", "write": "Write", "edit": "Edit", "bash": "Bash", "grep": "Grep",
      "glob": "Glob", "askuserquestion": "AskUserQuestion", "enterplanmode": "EnterPlanMode",
      "exitplanmode": "ExitPlanMode", "killshell": "KillShell", "notebookedit": "NotebookEdit",
      "skill": "Skill", "task": "Task", "taskoutput": "TaskOutput", "todowrite": "TodoWrite",
      "webfetch": "WebFetch", "websearch": "WebSearch",
    ]
    return canonical[name.lowercased()] ?? name
  }

  private func anthropicToolSchema(_ schema: JSONValue, strict: Bool) -> JSONValue {
    guard case .object(var object) = schema else {
      return .object([
        "type": .string("object"), "properties": .object([:]), "required": .array([]),
      ])
    }
    let legacy: [String: JSONValue] = [
      "type": .string("object"),
      "properties": object["properties"]?.objectValue.map(JSONValue.object) ?? .object([:]),
      "required": object["required"]?.arrayValue.map(JSONValue.array) ?? .array([]),
    ]
    guard strict else { return .object(legacy) }
    for (key, value) in legacy { object[key] = value }
    return .object(object)
  }

  private func applyingCacheControlToLastUserMessage(
    _ messages: [JSONValue],
    cacheControl: JSONValue?
  ) -> [JSONValue] {
    guard let cacheControl, !messages.isEmpty else { return messages }
    var messages = messages
    let index = messages.index(before: messages.endIndex)
    guard case .object(var message) = messages[index], message.string("role") == "user",
      let content = message["content"]
    else { return messages }
    switch content {
    case .string(let text):
      message["content"] = .array([
        .object([
          "type": .string("text"),
          "text": .string(text),
          "cache_control": cacheControl,
        ])
      ])
    case .array(var blocks):
      guard !blocks.isEmpty else { return messages }
      let blockIndex = blocks.index(before: blocks.endIndex)
      guard case .object(var block) = blocks[blockIndex],
        let type = block.string("type"),
        ["text", "image", "tool_result"].contains(type)
      else { return messages }
      block["cache_control"] = cacheControl
      blocks[blockIndex] = .object(block)
      message["content"] = .array(blocks)
    default:
      return messages
    }
    messages[index] = .object(message)
    return messages
  }

  private func makeMessages(
    _ messages: [ProviderMessage],
    context: WireProtocolContext
  ) throws -> [JSONValue] {
    let target = ProviderMessageSource(
      api: protocolID, providerID: context.provider.id, modelID: context.model.id)
    let converted: [JSONValue] = try messages.compactMap { message -> JSONValue? in
      switch message {
      case .system:
        return nil
      case .user(let content):
        if content.count == 1, case .text(let text) = content[0] {
          return .object([
            "role": .string("user"),
            "content": .string(text),
          ])
        }
        return .object([
          "role": .string("user"),
          "content": .array(try content.map(makeUserContent(_:))),
        ])
      case .userMessage(let user):
        return try makeMessages([.user(user.content)], context: context)[0]
      case .assistant(let content):
        return .object([
          "role": .string("assistant"),
          "content": .array(content.map(makeAssistantContent(_:))),
        ])
      case .assistantMessage(let assistant):
        guard let content = assistant.replayContent(for: target) else { return nil }
        return .object([
          "role": .string("assistant"),
          "content": .array(content.map(makeAssistantContent(_:))),
        ])
      case .toolResult(let result):
        let hasImage = result.content.contains { item in
          if case .image = item { return true }
          return false
        }
        let resultContent: JSONValue
        if !hasImage {
          resultContent = .string(
            result.content.compactMap { item -> String? in
              guard case .text(let text) = item else { return nil }
              return text
            }.joined(separator: "\n")
          )
        } else {
          resultContent = .array(try result.content.map(makeToolResultContent(_:)))
        }
        return .object([
          "role": .string("user"),
          "content": .array([
            .object([
              "type": .string("tool_result"),
              "tool_use_id": .string(result.toolCallID),
              "is_error": .bool(result.isError),
              "content": resultContent,
            ])
          ]),
        ])
      }
    }
    return groupingConsecutiveToolResults(converted)
  }

  private func managedThinkingLevel(
    request: ProviderRequest,
    context: WireProtocolContext
  ) -> String? {
    guard
      context.modelConfiguration.metadata.object("compat")?.bool("supportsMidConvoEffort")
        == true
    else { return nil }
    let requested = request.options.reasoningEffort ?? .high
    guard requested != .off else { return nil }
    return context.modelConfiguration.metadata.object("thinkingLevelMap")?.string(
      requested.rawValue)
      ?? (requested == .minimal ? "low" : requested.rawValue)
  }

  private func insertingThinkingLevelMessages(
    _ wireMessages: [JSONValue],
    messages: [ProviderMessage],
    activeEffort: String,
    providerID: String
  ) -> [JSONValue] {
    var result: [JSONValue] = []
    var wireIndex = 0
    for message in messages {
      guard case .assistantMessage(let assistant) = message else { continue }
      guard
        assistant.replayContent(
          for: ProviderMessageSource(
            api: protocolID, providerID: providerID, modelID: assistant.source.modelID)) != nil
      else { continue }
      while wireIndex < wireMessages.count,
        wireMessages[wireIndex].objectValue?.string("role") != "assistant"
      {
        result.append(wireMessages[wireIndex])
        wireIndex += 1
      }
      guard wireIndex < wireMessages.count else { break }
      if assistant.source.api == protocolID,
        assistant.source.providerID == providerID,
        let effort = assistant.providerMetadata["providerThinkingLevel"]?.stringValue,
        isAnthropicEffort(effort)
      {
        result.append(thinkingLevelMessage(effort))
      }
      result.append(wireMessages[wireIndex])
      wireIndex += 1
    }
    result.append(contentsOf: wireMessages.dropFirst(wireIndex))
    result.append(thinkingLevelMessage(activeEffort))
    return result
  }

  private func thinkingLevelMessage(_ effort: String) -> JSONValue {
    .object([
      "role": .string("system"),
      "content": .array([]),
      "output_config": .object(["effort": .string(effort)]),
    ])
  }

  private func isAnthropicEffort(_ value: String) -> Bool {
    ["low", "medium", "high", "xhigh", "max"].contains(value)
  }

  private func groupingConsecutiveToolResults(_ messages: [JSONValue]) -> [JSONValue] {
    var grouped: [JSONValue] = []
    for value in messages {
      guard case .object(let message) = value,
        message.string("role") == "user",
        case .array(let content)? = message["content"],
        content.allSatisfy({ $0.objectValue?.string("type") == "tool_result" }),
        let last = grouped.indices.last,
        case .object(var previous) = grouped[last],
        previous.string("role") == "user",
        case .array(let previousContent)? = previous["content"],
        previousContent.allSatisfy({ $0.objectValue?.string("type") == "tool_result" })
      else {
        grouped.append(value)
        continue
      }
      previous["content"] = .array(previousContent + content)
      grouped[last] = .object(previous)
    }
    return grouped
  }

  private func makeUserContent(_ content: ProviderUserContent) throws -> JSONValue {
    switch content {
    case .text(let text):
      .object(["type": .string("text"), "text": .string(text)])
    case .image(let image):
      try makeImage(image)
    }
  }

  private func makeAssistantContent(_ content: ProviderAssistantContent) -> JSONValue {
    switch content {
    case .text(let text):
      return .object(["type": .string("text"), "text": .string(text)])
    case .signedText(let text):
      return .object(["type": .string("text"), "text": .string(text.text)])
    case .reasoning(let reasoning):
      if reasoning.isRedacted == true {
        return .object([
          "type": .string("redacted_thinking"),
          "data": reasoning.signature.map(JSONValue.string) ?? .string(""),
        ])
      }
      return .object([
        "type": .string("thinking"),
        "thinking": .string(reasoning.text),
        "signature": reasoning.signature.map(JSONValue.string) ?? .string(""),
      ])
    case .toolCall(let call):
      return .object([
        "type": .string("tool_use"),
        "id": .string(call.id),
        "name": .string(call.name),
        "input": call.arguments,
      ])
    }
  }

  private func makeToolResultContent(_ content: ProviderToolResultContent) throws -> JSONValue {
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
        "source": .object([
          "type": .string("base64"),
          "media_type": .string(mimeType),
          "data": .string(data.base64EncodedString()),
        ]),
      ])
    case .remoteURL:
      throw failure(
        .unsupportedCapability,
        providerID: nil,
        operation: "anthropic.request.image",
        message: "Anthropic Messages requires image bytes instead of a remote URL"
      )
    }
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

private struct AnthropicEventReducer {
  let providerID: String
  let requestedModelID: String
  let providerThinkingLevel: String?
  let pricing: ProviderUsagePricing?
  private var responseID: String?
  private var responseModelID: String?
  private var inputTokens: Int? = 0
  private var cachedInputTokens: Int? = 0
  private var cacheWriteTokens: Int? = 0
  private var cacheWrite1hTokens = 0
  private var outputTokens: Int? = 0
  private var reasoningTokens: Int?
  private var rawFinishReason: String?
  private var textBlocks: [Int: String] = [:]
  private var reasoningBlocks: [Int: ReasoningBlock] = [:]
  private var completedTools: [Int: ProviderToolCall] = [:]
  private var toolBlocks: [Int: ToolBlock] = [:]
  private var finishReason: ProviderFinishReason?
  private var terminal = false

  init(
    providerID: String,
    requestedModelID: String,
    providerThinkingLevel: String?,
    pricing: ProviderUsagePricing?
  ) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
    self.providerThinkingLevel = providerThinkingLevel
    self.pricing = pricing
  }

  mutating func reduce(_ event: ServerSentEvent) throws -> [ProviderEvent] {
    if event.data == "[DONE]" { return [] }
    let object = try decodeJSONObject(
      Data(event.data.utf8),
      providerID: providerID,
      operation: "anthropic.event.decode"
    )
    let type = object.string("type") ?? event.event
    switch type {
    case "ping":
      return []
    case "message_start":
      guard let message = object.object("message"),
        let id = message.string("id"),
        let model = message.string("model")
      else { throw invalid("message_start is missing identity") }
      responseID = id
      responseModelID = model
      if let usage = message.object("usage") {
        if let input = usage.int("input_tokens") { inputTokens = input }
        if let output = usage.int("output_tokens") { outputTokens = output }
        if let cacheRead = usage.int("cache_read_input_tokens") { cachedInputTokens = cacheRead }
        if let cacheWrite = usage.int("cache_creation_input_tokens") {
          cacheWriteTokens = cacheWrite
        }
        cacheWrite1hTokens =
          usage.object("cache_creation")?.int("ephemeral_1h_input_tokens") ?? 0
      }
      return [
        .responseStarted(
          ProviderResponseMetadata(
            responseID: nil,
            providerID: providerID,
            modelID: model,
            providerMetadata: [:]
          )
        )
      ]
    case "content_block_start":
      guard let index = object.int("index"),
        let block = object.object("content_block"),
        let blockType = block.string("type")
      else { throw invalid("content_block_start is malformed") }
      if blockType == "tool_use" {
        guard let id = block.string("id"), let name = block.string("name") else {
          throw invalid("tool_use block is missing id or name")
        }
        toolBlocks[index] = ToolBlock(id: id, name: name, partialJSON: "")
        return [.toolCallStarted(id: id, name: name)]
      }
      if blockType == "text" {
        textBlocks[index] = block.string("text") ?? ""
      } else if blockType == "thinking" {
        reasoningBlocks[index] = ReasoningBlock(
          text: block.string("thinking") ?? "",
          signature: block.string("signature") ?? "",
          isRedacted: false
        )
      } else if blockType == "redacted_thinking" {
        guard let data = block.string("data"), !data.isEmpty else {
          throw invalid("redacted_thinking block is missing data")
        }
        reasoningBlocks[index] = ReasoningBlock(
          text: "[Reasoning redacted]", signature: data, isRedacted: true)
        return [.reasoningDelta("[Reasoning redacted]")]
      }
      return []
    case "content_block_delta":
      guard let index = object.int("index"), let delta = object.object("delta"),
        let deltaType = delta.string("type")
      else { throw invalid("content_block_delta is malformed") }
      switch deltaType {
      case "text_delta":
        guard let text = delta.string("text") else { throw invalid("text delta is missing text") }
        textBlocks[index, default: ""] += text
        return [.textDelta(text)]
      case "thinking_delta":
        guard let text = delta.string("thinking") else {
          throw invalid("thinking delta is missing text")
        }
        var block =
          reasoningBlocks[index]
          ?? ReasoningBlock(text: "", signature: "", isRedacted: false)
        block.text += text
        reasoningBlocks[index] = block
        return [.reasoningDelta(text)]
      case "signature_delta":
        guard let signature = delta.string("signature"), !signature.isEmpty else {
          throw invalid("signature delta is missing signature")
        }
        var block =
          reasoningBlocks[index]
          ?? ReasoningBlock(text: "", signature: "", isRedacted: false)
        block.signature += signature
        reasoningBlocks[index] = block
        return [.reasoningSignatureDelta(signature)]
      case "input_json_delta":
        guard let partial = delta.string("partial_json"), var block = toolBlocks[index] else {
          throw invalid("tool input delta has no matching tool block")
        }
        block.partialJSON += partial
        toolBlocks[index] = block
        return [.toolInputDelta(id: block.id, delta: partial)]
      default:
        throw invalid("unsupported Anthropic delta: \(deltaType)")
      }
    case "content_block_stop":
      guard let index = object.int("index") else {
        throw invalid("content_block_stop is missing index")
      }
      if let reasoning = reasoningBlocks[index], reasoning.isRedacted {
        return [.reasoningSignatureDelta(reasoning.signature)]
      }
      guard let block = toolBlocks.removeValue(forKey: index) else { return [] }
      let arguments: JSONValue
      if block.partialJSON.isEmpty {
        arguments = .object([:])
      } else {
        do {
          arguments = try JSONDecoder().decode(JSONValue.self, from: Data(block.partialJSON.utf8))
        } catch {
          throw invalid("tool input JSON is malformed")
        }
      }
      let call = ProviderToolCall(id: block.id, name: block.name, arguments: arguments)
      completedTools[index] = call
      return [.toolCallCompleted(call)]
    case "message_delta":
      if let delta = object.object("delta"), let reason = delta.string("stop_reason") {
        rawFinishReason = reason
        if reason == "refusal" || reason == "sensitive" {
          throw ProviderRuntimeFailure(
            code: .transportFailed,
            message: delta.object("stop_details")?.string("explanation")
              ?? "Provider stopped with: \(reason)",
            providerID: providerID,
            operation: "anthropic.event.error",
            causeDescription: reason
          )
        }
        finishReason = try mapFinishReason(reason)
      }
      if let usage = object.object("usage") {
        if let input = usage.int("input_tokens") { inputTokens = input }
        if let output = usage.int("output_tokens") { outputTokens = output }
        if let cacheRead = usage.int("cache_read_input_tokens") { cachedInputTokens = cacheRead }
        if let cacheWrite = usage.int("cache_creation_input_tokens") {
          cacheWriteTokens = cacheWrite
        }
        if let reasoning = usage.object("output_tokens_details")?.int("thinking_tokens") {
          reasoningTokens = reasoning
        }
      }
      let input = inputTokens ?? 0
      let output = outputTokens ?? 0
      let cacheRead = cachedInputTokens ?? 0
      let cacheWrite = cacheWriteTokens ?? 0
      guard let pricing else {
        throw ProviderRuntimeFailure(
          code: .upstreamDrift, message: "model cost rates are missing",
          providerID: providerID, operation: "anthropic.usage.pricing",
          causeDescription: nil)
      }
      return [
        .usage(
          ProviderUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteTokens: cacheWriteTokens,
            totalTokens: input + output + cacheRead + cacheWrite,
            providerMetadata: object.object("usage") ?? [:],
            cost: pricing.cost(
              input: input, output: output, cacheRead: cacheRead,
              cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1hTokens)
          )
        )
      ]
    case "message_stop":
      guard responseID != nil else { throw invalid("message_stop arrived before message_start") }
      guard toolBlocks.isEmpty else {
        throw invalid("message_stop arrived with incomplete tool calls")
      }
      guard let finishReason else {
        throw invalid("message_stop arrived without a stop reason")
      }
      terminal = true
      return [responseSnapshot(finishReason), .completed(finishReason)]
    case "error":
      let error = object.object("error")
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: error?.string("message") ?? "Anthropic stream returned an error",
        providerID: providerID,
        operation: "anthropic.event.error",
        causeDescription: error?.string("type")
      )
    default:
      throw invalid("unsupported Anthropic event: \(type ?? "<missing>")")
    }
  }

  func validateTerminal() throws {
    guard terminal else { throw invalid("Anthropic stream ended without message_stop") }
  }

  private func mapFinishReason(_ value: String) throws -> ProviderFinishReason {
    switch value {
    case "max_tokens": .length
    case "tool_use": .toolCalls
    case "end_turn", "pause_turn", "stop_sequence": .stop
    default: throw invalid("unsupported Anthropic stop reason: \(value)")
    }
  }

  private func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: providerID,
      operation: "anthropic.event.reduce",
      causeDescription: nil
    )
  }

  private func responseSnapshot(_ reason: ProviderFinishReason) -> ProviderEvent {
    let indices = Set(textBlocks.keys)
      .union(reasoningBlocks.keys)
      .union(completedTools.keys)
      .sorted()
    let content: [ProviderResponseContent] = indices.compactMap { index in
      if let text = textBlocks[index] {
        return .text(ProviderTextContent(text: text, signature: nil))
      }
      if let reasoning = reasoningBlocks[index] {
        return .reasoning(
          ProviderReasoningContent(
            text: reasoning.text,
            signature: reasoning.signature.isEmpty ? nil : reasoning.signature,
            isRedacted: reasoning.isRedacted ? true : nil,
            providerMetadata: [:]
          ))
      }
      if let tool = completedTools[index] { return .toolCall(tool) }
      return nil
    }
    let input = inputTokens ?? 0
    let output = outputTokens ?? 0
    let cacheRead = cachedInputTokens ?? 0
    let cacheWrite = cacheWriteTokens ?? 0
    return .responseSnapshot(
      ProviderResponseSnapshot(
        responseID: responseID,
        providerID: providerID,
        protocolID: "anthropic-messages",
        modelID: requestedModelID,
        responseModelID: responseModelID == requestedModelID ? nil : responseModelID,
        content: content,
        usage: ProviderUsage(
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          reasoningTokens: reasoningTokens,
          cachedInputTokens: cachedInputTokens,
          cacheWriteTokens: cacheWriteTokens ?? 0,
          totalTokens: input + output + cacheRead + cacheWrite,
          providerMetadata: [:],
          cost: pricing?.cost(
            input: input, output: output, cacheRead: cacheRead,
            cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1hTokens)
        ),
        finishReason: reason,
        rawFinishReason: rawFinishReason,
        timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
        providerMetadata: providerThinkingLevel.map {
          ["providerThinkingLevel": .string($0)]
        } ?? [:]
      ))
  }

  private struct ToolBlock {
    let id: String
    let name: String
    var partialJSON: String
  }

  private struct ReasoningBlock {
    var text: String
    var signature: String
    var isRedacted: Bool
  }
}
