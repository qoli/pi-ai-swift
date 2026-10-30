import Foundation

/// The exact provider rejection transition, explicitly adopted for this sync.
/// It is confined to the initial HTTP request, before any stream is consumed.
enum PreferredStrictToolFallback {
  enum API { case anthropic, bedrock }

  static func response(
    request: ProviderRequest,
    api: API,
    transport: any ProviderHTTPStreamingTransport,
    makeRequest: (ProviderRequest) throws -> URLRequest
  ) async throws -> ProviderHTTPStreamingResponse {
    var current = request
    var downgraded = false
    while true {
      try Task.checkCancellation()
      let wire = try makeRequest(current)
      let response = try await transport.stream(wire)
      if (200..<300).contains(response.statusCode) { return response }
      let body = try await collectErrorBody(from: response.body)
      try Task.checkCancellation()
      if !downgraded,
        hasPreferredStrictTool(request: request, wire: wire, api: api),
        isLimitRejection(response: response, body: body, api: api)
      {
        downgraded = true
        current = ProviderRequest(
          id: request.id, providerID: request.providerID, modelID: request.modelID,
          messages: request.messages,
          tools: request.tools.map { tool in
            guard tool.constrainedSampling == .jsonSchema(strict: .prefer) else { return tool }
            return ProviderToolDefinition(
              name: tool.name, description: tool.description, inputSchema: tool.inputSchema)
          },
          options: request.options, connectionOptions: request.connectionOptions)
        continue
      }
      let name = api == .anthropic ? "Anthropic Messages" : "Bedrock ConverseStream"
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: "\(name) request failed (HTTP \(response.statusCode))",
        providerID: request.providerID,
        operation: api == .anthropic ? "anthropic.response" : "bedrock.response",
        causeDescription: body)
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
    return request.tools.enumerated().contains { index, tool in
      guard tool.constrainedSampling == .jsonSchema(strict: .prefer), index < tools.count,
        let value = tools[index].objectValue
      else { return false }
      return (api == .anthropic ? value.bool("strict") : value.object("toolSpec")?.bool("strict"))
        == true
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
