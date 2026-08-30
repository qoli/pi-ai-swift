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
            requestedModelID: request.modelID
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
    let endpoint = context.baseURL.appending(path: "v1/messages")
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    for (name, value) in context.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    try applyCredential(context.credential, to: &urlRequest, providerID: request.providerID)
    urlRequest.httpBody = try encodeJSONObject(
      try makeBody(request, context: context),
      providerID: request.providerID,
      operation: "anthropic.request.encode"
    )
    return urlRequest
  }

  private func applyCredential(
    _ credential: ProviderCredential?,
    to request: inout URLRequest,
    providerID: String
  ) throws {
    switch credential {
    case .apiKey(let credential):
      request.setValue(credential.key, forHTTPHeaderField: "x-api-key")
    case .oauth(let credential):
      request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue(
        "claude-code-20250219,oauth-2025-04-20",
        forHTTPHeaderField: "anthropic-beta"
      )
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
    context: WireProtocolContext
  ) throws -> [String: JSONValue] {
    var body: [String: JSONValue] = [
      "model": .string(request.modelID),
      "messages": .array(try makeMessages(request.messages)),
      "max_tokens": .integer(
        Int64(request.options.maximumOutputTokens ?? context.model.maximumOutputTokens ?? 4_096)),
      "stream": .bool(true),
    ]
    let systems = request.messages.compactMap { message -> String? in
      guard case .system(let text) = message else { return nil }
      return text
    }
    if !systems.isEmpty {
      body["system"] = .array(
        systems.map { .object(["type": .string("text"), "text": .string($0)]) }
      )
    }
    if let temperature = request.options.temperature {
      body["temperature"] = .number(temperature)
    }
    if let effort = request.options.reasoningEffort, context.model.capabilities.reasoning {
      body["thinking"] = .object(["type": .string("adaptive")])
      body["output_config"] = .object(["effort": .string(effort)])
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(
        request.tools.map {
          .object([
            "name": .string($0.name),
            "description": .string($0.description),
            "input_schema": $0.inputSchema,
          ])
        }
      )
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
    for (key, value) in request.options.providerOptions {
      body[key] = value
    }
    return body
  }

  private func makeMessages(_ messages: [ProviderMessage]) throws -> [JSONValue] {
    try messages.compactMap { message in
      switch message {
      case .system:
        return nil
      case .user(let content):
        return .object([
          "role": .string("user"),
          "content": .array(try content.map(makeUserContent(_:))),
        ])
      case .assistant(let content):
        return .object([
          "role": .string("assistant"),
          "content": .array(content.map(makeAssistantContent(_:))),
        ])
      case .toolResult(let result):
        return .object([
          "role": .string("user"),
          "content": .array([
            .object([
              "type": .string("tool_result"),
              "tool_use_id": .string(result.toolCallID),
              "is_error": .bool(result.isError),
              "content": .array(try result.content.map(makeToolResultContent(_:))),
            ])
          ]),
        ])
      }
    }
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
      .object(["type": .string("text"), "text": .string(text)])
    case .reasoning(let reasoning):
      .object([
        "type": .string("thinking"),
        "thinking": .string(reasoning.text),
        "signature": reasoning.signature.map(JSONValue.string) ?? .string(""),
      ])
    case .toolCall(let call):
      .object([
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
  private var responseID: String?
  private var responseModelID: String?
  private var inputTokens: Int?
  private var cachedInputTokens: Int?
  private var toolBlocks: [Int: ToolBlock] = [:]
  private var finishReason: ProviderFinishReason = .stop
  private var terminal = false

  init(providerID: String, requestedModelID: String) {
    self.providerID = providerID
    self.requestedModelID = requestedModelID
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
        inputTokens = usage.int("input_tokens")
        cachedInputTokens = usage.int("cache_read_input_tokens")
      }
      return [
        .responseStarted(
          ProviderResponseMetadata(
            responseID: id,
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
      return []
    case "content_block_delta":
      guard let index = object.int("index"), let delta = object.object("delta"),
        let deltaType = delta.string("type")
      else { throw invalid("content_block_delta is malformed") }
      switch deltaType {
      case "text_delta":
        guard let text = delta.string("text") else { throw invalid("text delta is missing text") }
        return [.textDelta(text)]
      case "thinking_delta":
        guard let text = delta.string("thinking") else {
          throw invalid("thinking delta is missing text")
        }
        return [.reasoningDelta(text)]
      case "signature_delta":
        return []
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
      return [
        .toolCallCompleted(
          ProviderToolCall(id: block.id, name: block.name, arguments: arguments)
        )
      ]
    case "message_delta":
      if let delta = object.object("delta"), let reason = delta.string("stop_reason") {
        finishReason = mapFinishReason(reason)
      }
      let usage = object.object("usage")
      return [
        .usage(
          ProviderUsage(
            inputTokens: inputTokens,
            outputTokens: usage?.int("output_tokens"),
            reasoningTokens: nil,
            cachedInputTokens: cachedInputTokens,
            providerMetadata: [:]
          )
        )
      ]
    case "message_stop":
      guard responseID != nil else { throw invalid("message_stop arrived before message_start") }
      guard toolBlocks.isEmpty else {
        throw invalid("message_stop arrived with incomplete tool calls")
      }
      terminal = true
      return [.completed(finishReason)]
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

  private func mapFinishReason(_ value: String) -> ProviderFinishReason {
    switch value {
    case "max_tokens": .length
    case "tool_use": .toolCalls
    case "refusal": .contentFilter
    default: .stop
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

  private struct ToolBlock {
    let id: String
    let name: String
    var partialJSON: String
  }
}
