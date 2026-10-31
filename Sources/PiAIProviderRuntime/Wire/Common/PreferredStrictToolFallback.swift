import Foundation

/// The exact provider rejection transition, explicitly adopted for this sync.
/// It is confined to the initial HTTP request, before any stream is consumed.
enum PreferredStrictToolFallback {
  enum API { case anthropic, bedrock }

  static func response(
    request: ProviderRequest,
    api: API,
    transport: any ProviderHTTPStreamingTransport,
    onDowngrade: (JSONValue) -> Void = { _ in },
    onResponse: (ProviderHTTPStreamingResponse) async throws -> Void = { _ in },
    makeRequest: (ProviderRequest) async throws -> URLRequest
  ) async throws -> ProviderHTTPStreamingResponse {
    var current = request
    var downgraded = false
    while true {
      try Task.checkCancellation()
      let wire = try await makeRequest(current)
      let response = try await transport.stream(wire)
      try await onResponse(response)
      if (200..<300).contains(response.statusCode) { return response }
      let body = try await collectErrorBody(from: response.body)
      try Task.checkCancellation()
      if !downgraded,
        hasPreferredStrictTool(request: request, wire: wire, api: api),
        isLimitRejection(response: response, body: body, api: api)
      {
        downgraded = true
        let message: String
        if api == .anthropic {
          message = errorMessage(api: api, response: response, body: body)
        } else {
          let object = body.flatMap {
            try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)).objectValue
          }
          message = object?.string("message") ?? object?.string("Message") ?? body ?? "UnknownError"
        }
        onDowngrade(
          .object([
            "type": .string(
              api == .anthropic
                ? "anthropic_strict_tools_fallback" : "bedrock_strict_tools_fallback"),
            "timestamp": .integer(Int64(Date().timeIntervalSince1970 * 1_000)),
            "error": .object(["message": .string(message)]),
            "details": .object(["reason": .string("strict_tool_limits_exceeded")]),
          ]))
        current = ProviderRequest(
          id: request.id, providerID: request.providerID, modelID: request.modelID,
          messages: request.messages.map { message in
            guard case .systemMessage(let system) = message else { return message }
            return .systemMessage(
              .init(
                content: system.content,
                toolsAdded: system.toolsAdded.map(withoutPreferredStrict),
                toolsRemoved: system.toolsRemoved))
          },
          tools: request.tools.map(withoutPreferredStrict),
          options: request.options, connectionOptions: request.connectionOptions)
        continue
      }
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: errorMessage(api: api, response: response, body: body),
        providerID: request.providerID,
        operation: api == .anthropic ? "anthropic.response" : "bedrock.response",
        causeDescription: body,
        providerMetadata: api == .bedrock ? bedrockFailureMetadata(response, body: body) : nil)
    }
  }

  private static func bedrockFailureMetadata(
    _ response: ProviderHTTPStreamingResponse, body: String?
  ) -> [String: JSONValue]? {
    let object = body.flatMap {
      try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)).objectValue
    }
    let name = BedrockFailure.responseErrorName(headers: response.headers, body: object)
    let requestID = response.headers.first { $0.key.lowercased() == "x-amzn-requestid" }?.value
    return BedrockFailure.diagnostic(
      status: response.statusCode, errorCode: name, requestID: requestID
    )
    .map { ["diagnostics": .array([$0])] }
  }

  private static func withoutPreferredStrict(_ tool: ProviderToolDefinition)
    -> ProviderToolDefinition
  {
    guard tool.constrainedSampling == .jsonSchema(strict: .prefer) else { return tool }
    return .init(name: tool.name, description: tool.description, inputSchema: tool.inputSchema)
  }

  private static func errorMessage(
    api: API, response: ProviderHTTPStreamingResponse, body: String?
  ) -> String {
    switch api {
    case .anthropic:
      var message = body
      if let body, let parsed = try? ProviderOrderedJSON(data: Data(body.utf8)) {
        if let detail = parsed["message"], detail.isTruthy {
          if case .scalar(.string(let text)) = detail {
            message = text
          } else {
            message = try? detail.encodedString()
          }
        } else if parsed.isTruthy {
          message = try? parsed.encodedString()
        }
      }
      guard let message, !message.isEmpty else {
        return "\(response.statusCode) status code (no body)"
      }
      return "\(response.statusCode) \(message)"
    case .bedrock:
      let object = body.flatMap {
        try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)).objectValue
      }
      let type =
        BedrockFailure.responseErrorName(headers: response.headers, body: object)
        ?? (object != nil ? "Unknown" : nil)
      let message =
        object?.string("message") ?? object?.string("Message")
        ?? (object != nil ? "UnknownError" : body ?? "UnknownError")
      return BedrockFailure.message(message, exceptionName: type)
    }
  }

  private static func hasPreferredStrictTool(
    request: ProviderRequest, wire: URLRequest, api: API
  ) -> Bool {
    guard let data = wire.httpBody,
      let body = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue
    else { return false }
    let tools = api == .anthropic ? body.array("tools") : body.object("toolConfig")?.array("tools")
    guard let tools else { return false }
    let nativeTools =
      api == .anthropic
      && tools.last?.objectValue?.string("name") == "__pi_deferred_placeholder__"
    let initial =
      nativeTools ? request.messages.first?.systemPayload?.toolsAdded ?? [] : request.tools
    if initial.enumerated().contains(where: { index, tool in
      guard tool.constrainedSampling == .jsonSchema(strict: .prefer), index < tools.count,
        let value = tools[index].objectValue
      else { return false }
      return (api == .anthropic ? value.bool("strict") : value.object("toolSpec")?.bool("strict"))
        == true
    }) {
      return true
    }
    guard nativeTools else { return false }
    let additions = request.messages.dropFirst().flatMap { $0.systemPayload?.toolsAdded ?? [] }
    let definitions = (body.array("messages") ?? []).flatMap {
      $0.objectValue?.array("content") ?? []
    }
    .compactMap { value -> [String: JSONValue]? in
      guard let block = value.objectValue, block.string("type") == "tool_addition" else {
        return nil
      }
      return block.object("tool")?.object("definition")
    }
    return zip(additions, definitions).contains { tool, definition in
      tool.constrainedSampling == .jsonSchema(strict: .prefer) && definition.bool("strict") == true
    }
  }

  private static func isLimitRejection(
    response: ProviderHTTPStreamingResponse, body: String?, api: API
  ) -> Bool {
    guard let body,
      let object = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)).objectValue
    else { return false }
    let message: String?
    switch api {
    case .anthropic:
      guard response.statusCode == 400, let error = object.object("error"),
        error.string("type") == "invalid_request_error"
      else { return false }
      message = error.string("message")
    case .bedrock:
      let header = response.headers.first { $0.key.lowercased() == "x-amzn-errortype" }?.value
      let type = (header ?? object.string("__type") ?? object.string("code"))?
        .split(separator: "#").last?.split(separator: ":").first.map(String.init)
      guard type == "ValidationException" else { return false }
      message = object.string("message") ?? object.string("Message")
    }
    guard let message else { return false }
    return [
      "The compiled grammar is too large", "Too many strict tools (",
      "Schemas contains too many parameters with union types (",
    ].contains { message.contains($0) }
  }
}
