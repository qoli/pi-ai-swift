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
          let observation = ProviderWireObservation(request: request, wire: context)
          if flavor == .codex {
            try await streamCodex(
              request, context: context, transport: transport,
              observation: observation, continuation: continuation)
            continuation.finish()
            return
          }
          let response = try await ProviderRequestRetry.stream(
            observation.payload(makeURLRequest(request, context: context)),
            request: request, context: context, transport: transport)
          if flavor == .codex { try await observation.response(response) }
          guard (200..<300).contains(response.statusCode) else {
            let body = try await collectErrorBody(from: response.body)
            throw failure(
              .transportFailed,
              providerID: request.providerID,
              operation: "openai-responses.response",
              message: httpErrorMessage(
                status: response.statusCode, body: body, providerID: request.providerID),
              cause: body
            )
          }
          if flavor != .codex { try await observation.response(response) }
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
            flavor: flavor,
            providerThinkingLevel: configurationUpdateEffort(request, context: context)
          )
          streamChunks: for try await chunk in response.body {
            try Task.checkCancellation()
            for event in try decoder.append(chunk) {
              for normalized in try await reducer.reduce(event, observation: observation) {
                try await observation.toolEvent(normalized)
                continuation.yield(normalized)
              }
              if flavor == .codex, reducer.isTerminal { break streamChunks }
            }
          }
          try Task.checkCancellation()
          for event in try decoder.finish() {
            for normalized in try await reducer.reduce(event, observation: observation) {
              try await observation.toolEvent(normalized)
              continuation.yield(normalized)
            }
          }
          for event in try reducer.finish() {
            try await observation.toolEvent(event)
            continuation.yield(event)
          }
          continuation.finish()
        } catch let error as CodexStreamCallbackError {
          continuation.finish(throwing: error.underlying)
        } catch let error as ProviderRuntimeFailure {
          continuation.finish(
            throwing: ProviderRuntimeFailure(
              code: error.code, message: usageLimitMessage(error.message),
              providerID: error.providerID,
              operation: error.operation, causeDescription: error.causeDescription,
              providerMetadata: error.providerMetadata,
              underlyingURLErrorCode: error.underlyingURLErrorCode))
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func codexReducer(_ request: ProviderRequest, context: WireProtocolContext) throws
    -> OpenAIResponsesReducer
  {
    OpenAIResponsesReducer(
      providerID: request.providerID, protocolID: protocolID, requestedModelID: request.modelID,
      acceptsCodexTerminalAliases: true,
      grammarInputProperties: try grammarInputProperties(request, context: context),
      pricing: try ProviderUsagePricing.parse(
        metadata: context.modelConfiguration.metadata, providerID: request.providerID,
        operation: "openai-responses.usage.pricing"),
      requestedServiceTier: request.options.serviceTier, flavor: .codex,
      providerThinkingLevel: configurationUpdateEffort(request, context: context))
  }

  private func codexTimeoutValue(_ value: Double?) throws -> Double? {
    guard let value else { return nil }
    guard value.isFinite, value >= 0 else {
      throw failure(
        .invalidRequest, providerID: nil, operation: "codex.timeout",
        message: "Invalid timeoutMs: \(value)")
    }
    return floor(value)
  }

  private func streamCodex(
    _ request: ProviderRequest, context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport, observation: ProviderWireObservation,
    continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
  ) async throws {
    let urlRequest = try await observation.payload(makeURLRequest(request, context: context))
    let body = try decodeJSONObject(
      urlRequest.httpBody ?? Data(),
      providerID: request.providerID, operation: "codex.request")
    let mode = request.connectionOptions.transport ?? .auto
    let timeout = try codexTimeoutValue(request.connectionOptions.timeoutMilliseconds)
    let connectTimeout = try codexTimeoutValue(
      request.connectionOptions.webSocketConnectTimeoutMilliseconds)
    let session = request.options.cacheRetention == .none ? nil : request.options.sessionID
    let cachedContext = mode == .auto || mode == .websocketCached
    let sessions = context.codexSessions
    let fallbackActive = await sessions.isFallbackActive(session)
    let disabled = mode == .auto && fallbackActive
    if disabled { await sessions.recordFallback(session: session) }
    if mode != .sse && !disabled {
      var retriedLimit = false
      var retriedContinuation = false
      websocketAttempts: while true {
        var lease: CodexWebSocketSessions.Lease?
        var started = false
        var apiFailure = false
        var apiCode: String?
        do {
          var socketRequest = urlRequest
          var components = URLComponents(url: urlRequest.url!, resolvingAgainstBaseURL: false)!
          components.scheme = components.scheme == "http" ? "ws" : "wss"
          socketRequest.url = components.url
          socketRequest.httpBody = nil
          for name in ["Accept", "Content-Type", "OpenAI-Beta"] {
            socketRequest.setValue(nil, forHTTPHeaderField: name)
          }
          socketRequest.setValue(
            "responses_websockets=2026-02-06", forHTTPHeaderField: "OpenAI-Beta")
          let requestID = codexSessionID(request.options) ?? UUID().uuidString.lowercased()
          socketRequest.setValue(requestID, forHTTPHeaderField: "session-id")
          socketRequest.setValue(requestID, forHTTPHeaderField: "x-client-request-id")
          let acquired = try await sessions.acquire(
            request: socketRequest, session: session,
            account: urlRequest.value(forHTTPHeaderField: "chatgpt-account-id") ?? "",
            transport: context.webSocketTransport, clock: context.clock,
            connectTimeout: connectTimeout)
          lease = acquired
          var projected = await sessions.requestBody(
            body, lease: acquired, session: session, cachedContext: cachedContext)
          if projected["type"] == nil { projected["type"] = .string("response.create") }
          let encoded = try encodeJSONObject(
            projected, providerID: request.providerID,
            operation: "codex.websocket.encode")
          try await acquired.socket.send(String(decoding: encoded, as: UTF8.self))
          var reducer = try codexReducer(request, context: context)
          while !reducer.isTerminal {
            let text = try await codexTimeout(
              milliseconds: timeout, clock: context.clock,
              message: "WebSocket idle timeout after \(Int(timeout ?? 0))ms"
            ) { try await acquired.socket.receive() }
            try Task.checkCancellation()
            let object = try decodeJSONObject(
              Data(text.utf8), providerID: request.providerID,
              operation: "codex.websocket.decode")
            apiFailure = ["error", "response.failed"].contains(object.string("type") ?? "")
            apiCode =
              object.string("code") ?? object.object("error")?.string("code")
              ?? object.object("response")?.object("error")?.string("code")
            let events = try await reducer.reduce(
              .init(event: nil, data: text, id: nil), observation: observation)
            if let type = object.string("type"), type != "codex.rate_limits" {
              started = true
              if let start = reducer.startEvent() { continuation.yield(start) }
            }
            for event in events {
              try await observation.toolEvent(event)
              continuation.yield(event)
            }
          }
          try Task.checkCancellation()
          let final = try reducer.finish()
          var responseID: String?
          var responseItems: [JSONValue] = []
          for event in final {
            if case .responseSnapshot(let snapshot) = event, cachedContext {
              responseID = snapshot.responseID
              if responseID != nil {
                responseItems = try makeInput(
                  [.assistantMessage(try snapshot.replayAssistantMessage())], includeSystem: false,
                  context: context,
                  grammarInputProperties: grammarInputProperties(request, context: context),
                  deferredTools: [:], deferredToolsMode: nil, supportsStrictMode: true
                )
                .filter {
                  !["function_call_output", "custom_tool_call_output"].contains(
                    $0.objectValue?.string("type") ?? "")
                }
              }
            }
          }
          await sessions.release(
            acquired, keep: true, body: body, responseID: responseID,
            responseItems: responseItems, cachedContext: cachedContext, clock: context.clock)
          lease = nil
          for event in final {
            try await observation.toolEvent(event)
            continuation.yield(event)
          }
          return
        } catch {
          if let lease {
            await sessions.release(
              lease, keep: false, body: body,
              cachedContext: cachedContext, clock: context.clock)
          }
          try Task.checkCancellation()
          if error is CodexStreamCallbackError { throw error }
          if apiCode == "previous_response_not_found", !retriedContinuation {
            retriedContinuation = true
            continue websocketAttempts
          }
          if apiCode == "websocket_connection_limit_reached", !started, !retriedLimit {
            retriedLimit = true
            continue websocketAttempts
          }
          let runtimeFailure = error as? ProviderRuntimeFailure
          if apiFailure || runtimeFailure?.code == .invalidResponse
            || runtimeFailure?.operation == "conformance.observer"
            || runtimeFailure?.operation == "wire-observer.stream-event"
          {
            throw error
          }
          let message = runtimeFailure?.message ?? String(describing: error)
          await sessions.recordFailure(session: session, message: message)
          let allowsSSE = mode == .auto || (mode == .websocketCached && retriedContinuation)
          guard allowsSSE, !started else { throw error }
          await sessions.recordFallback(session: session)
          break websocketAttempts
        }
      }
    }
    let response = try await codexSSEResponse(
      urlRequest, request: request, context: context, transport: transport,
      observation: observation, timeout: timeout)
    var reducer = try codexReducer(request, context: context)
    if let start = reducer.startEvent() { continuation.yield(start) }
    var decoder = ServerSentEventDecoder()
    responseChunks: for try await chunk in response.body {
      try Task.checkCancellation()
      for raw in try decoder.append(chunk) {
        for event in try await reducer.reduce(raw, observation: observation) {
          try await observation.toolEvent(event)
          continuation.yield(event)
        }
        if reducer.isTerminal { break responseChunks }
      }
    }
    try Task.checkCancellation()
    if !reducer.isTerminal {
      for raw in try decoder.finish() {
        for event in try await reducer.reduce(raw, observation: observation) {
          try await observation.toolEvent(event)
          continuation.yield(event)
        }
      }
    }
    for event in try reducer.finish() {
      try await observation.toolEvent(event)
      continuation.yield(event)
    }
  }

  private struct CodexRetryDelayExceeded: Error {
    let message: String
  }

  private func codexSSEResponse(
    _ urlRequest: URLRequest, request: ProviderRequest, context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport, observation: ProviderWireObservation,
    timeout: Double?
  ) async throws -> ProviderHTTPStreamingResponse {
    var compressedRequest = urlRequest
    compressedRequest.httpBody = try CodexRequestCompression.compress(urlRequest.httpBody ?? Data())
    compressedRequest.setValue("zstd", forHTTPHeaderField: "Content-Encoding")
    let urlRequest = compressedRequest
    let retries = request.connectionOptions.maximumRetries ?? 0
    guard retries >= 0 else {
      throw failure(
        .transportFailed, providerID: request.providerID,
        operation: "codex.sse.retry", message: "Failed after retries")
    }
    var attempt = 0
    while true {
      try Task.checkCancellation()
      do {
        let response = try await codexTimeout(
          milliseconds: timeout, clock: context.clock,
          message: "Codex SSE response headers timed out after \(Int(timeout ?? 0))ms"
        ) { try await transport.stream(urlRequest) }
        try await observation.response(response)
        if (200..<300).contains(response.statusCode) { return response }
        let text = try await collectErrorBody(from: response.body) ?? ""
        let terminal =
          text.range(
            of:
              "GoUsageLimitError|FreeUsageLimitError|Monthly usage limit reached|available balance|insufficient_quota|out of budget|quota exceeded|billing",
            options: .regularExpression.union(.caseInsensitive)) != nil
        let retryable =
          !(response.statusCode == 429 && terminal)
          && ([429, 500, 502, 503, 504].contains(response.statusCode)
            || text.range(
              of:
                "rate.?limit|overloaded|service.?unavailable|upstream.?connect|connection.?refused",
              options: .regularExpression.union(.caseInsensitive)) != nil)
        if attempt < retries && retryable {
          let headers = Dictionary(
            response.headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, value in value })
          let serverDelay = codexRetryDelay(headers, now: context.clock.now())
          let delay = serverDelay ?? 1_000 * pow(2, Double(attempt))
          let limit = request.connectionOptions.maximumRetryDelayMilliseconds ?? 60_000
          if serverDelay != nil, limit > 0, delay > limit {
            throw CodexRetryDelayExceeded(
              message:
                "Server requested \(Int(ceil(delay / 1_000)))s retry delay (max: \(Int(ceil(limit / 1_000)))s)"
            )
          }
          try await context.clock.sleep(for: .milliseconds(delay))
          attempt += 1
          continue
        }
        throw failure(
          .transportFailed, providerID: request.providerID,
          operation: "codex.sse.response",
          message: codexHTTPError(text, status: response.statusCode, now: context.clock.now()))
      } catch let error as CodexRetryDelayExceeded {
        throw failure(
          .transportFailed, providerID: request.providerID,
          operation: "codex.sse.retry", message: error.message)
      } catch {
        try Task.checkCancellation()
        let message = (error as? ProviderRuntimeFailure)?.message ?? String(describing: error)
        guard attempt < retries, !message.contains("usage limit") else { throw error }
        try await context.clock.sleep(for: .milliseconds(1_000 * pow(2, Double(attempt))))
        attempt += 1
      }
    }
  }

  private func codexRetryDelay(_ headers: [String: String], now: Date) -> Double? {
    if let text = headers["retry-after-ms"], let number = Double(text), number.isFinite {
      return max(0, number)
    }
    guard let text = headers["retry-after"], !text.isEmpty else { return nil }
    if let number = Double(text), number.isFinite { return max(0, number * 1_000) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: text).map { max(0, $0.timeIntervalSince(now) * 1_000) }
  }

  private func codexHTTPError(_ text: String, status: Int, now: Date) -> String {
    guard
      let object = try? decodeJSONObject(
        Data(text.utf8), providerID: "openai-codex",
        operation: "codex.sse.error"), let error = object.object("error")
    else {
      return text.isEmpty ? "Request failed" : text
    }
    let code = error.string("code") ?? error.string("type") ?? ""
    if status == 429
      || code.range(
        of: "usage_limit_reached|usage_not_included|rate_limit_exceeded",
        options: .regularExpression.union(.caseInsensitive)) != nil
    {
      let plan = error.string("plan_type").map { " (\($0.lowercased()) plan)" } ?? ""
      let when =
        error.int("resets_at").map {
          " Try again in ~\(max(0, Int(floor((Double($0) - now.timeIntervalSince1970) / 60 + 0.5)))) min."
        } ?? ""
      return "You have hit your ChatGPT usage limit\(plan).\(when)"
    }
    return error.string("message").flatMap { $0.isEmpty ? nil : $0 } ?? text
  }

  private func usageLimitMessage(_ message: String) -> String {
    guard flavor == .standard else { return message }
    if message.contains("subscription_sharing_usage_limit_exceeded") {
      return message + "\nCheck your ChatGPT usage: https://chatgpt.com/settings/usage"
    }
    if message.contains("subscription_sharing_workplace_individual_usage_limit_exceeded") {
      return message
        + "\nYou've reached your ChatGPT workspace's usage limit. Ask your workspace admin to increase it at admin.openai.com → Workspace → Usage limits."
    }
    return message
  }

  private func httpErrorMessage(status: Int, body: String?, providerID: String) -> String {
    guard flavor != .codex else { return "OpenAI Responses request failed (HTTP \(status))" }
    let parsed = body.flatMap { try? ProviderOrderedJSON(data: Data($0.utf8)) }
    let error: ProviderOrderedJSON?
    switch parsed {
    case .object:
      error = parsed?["error"].flatMap { $0.isNullish ? nil : $0 } ?? parsed
    case .array: error = parsed
    default: error = nil
    }
    let detail: String?
    if let value = error?["message"], value.isTruthy {
      detail = value.stringValue ?? (try? value.encodedString())
    } else if let error, error.isTruthy {
      detail = try? error.encodedString()
    } else {
      detail = parsed?.isTruthy == true ? nil : body
    }
    let sdkMessage =
      detail.flatMap { $0.isEmpty ? nil : "\(status) \($0)" }
      ?? "\(status) status code (no body)"
    var normalizedBody: String?
    if case .object(let members) = error, !members.isEmpty,
      let serialized = try? error?.encodedString()
    {
      // The pinned error-body normalizer caps JSON bodies at 4,000 UTF-16 units.
      let length = serialized.utf16.count
      normalizedBody =
        length > 4_000
        ? String(decoding: serialized.utf16.prefix(4_000), as: UTF16.self)
          + "... [truncated \(length - 4_000) chars]"
        : serialized
    }
    let message = normalizedBody.map { sdkMessage.contains($0) ? sdkMessage : $0 } ?? sdkMessage
    let name = flavor == .azure ? "Azure OpenAI" : (providerID == "openai" ? "OpenAI" : providerID)
    return "\(name) API error (\(status)): \(message)"
  }

  private func makeURLRequest(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> URLRequest {
    if context.modelConfiguration.metadata.object("compat")?.bool("supportsMidConvoSystemMessages")
      != true
    {
      try request.validateSingleSystemMessage(operation: "openai-responses.request.system")
    }
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
      let suppressOriginator =
        request.connectionOptions.headers?.contains {
          $0.key.caseInsensitiveCompare("originator") == .orderedSame && $0.value == nil
        } == true
      if urlRequest.value(forHTTPHeaderField: "originator") == nil, !suppressOriginator {
        urlRequest.setValue("pi", forHTTPHeaderField: "originator")
      }
      urlRequest.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
      urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      if let sessionID = codexSessionID(request.options) {
        urlRequest.setValue(sessionID, forHTTPHeaderField: "session-id")
        urlRequest.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
      }
    case (_, .apiKey(let credential)):
      if flavor != .standard || urlRequest.value(forHTTPHeaderField: "Authorization") == nil {
        urlRequest.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
      }
    case (_, .oauth(let credential)):
      if flavor != .standard || urlRequest.value(forHTTPHeaderField: "Authorization") == nil {
        urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
      }
    case (_, nil)
    where context.usesHeaderAuthentication
      && context.headers.contains(where: {
        ["authorization", "cf-aig-authorization"].contains($0.key.lowercased())
          && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }):
      break
    case (_, nil):
      throw failure(
        .missingCredential,
        providerID: request.providerID,
        operation: "openai-responses.request.auth",
        message: "OpenAI Responses credential is missing"
      )
    }
    if flavor == .standard,
      urlRequest.value(forHTTPHeaderField: "Authorization")?.isEmpty == true
    {
      urlRequest.setValue(nil, forHTTPHeaderField: "Authorization")
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
    for (name, property) in request.options.providerOptions.object("grammarToolInputProperties")
      ?? [:]
    {
      if let property = property.stringValue { result[name] = property }
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
      // The pinned SDK concatenates baseURL and path before parsing the query.
      var components = URLComponents(
        url: URL(string: baseURL.absoluteString + "/responses")!,
        resolvingAgainstBaseURL: false
      )
      let originalQuery = components?.percentEncodedQuery?.replacingOccurrences(
        of: "+", with: "%20")
      components?.percentEncodedQuery = originalQuery
      var query: [(String, String)] = []
      for item in components?.queryItems ?? [] {
        if let index = query.firstIndex(where: { $0.0 == item.name }) {
          query[index].1 = item.value ?? ""
        } else {
          query.append((item.name, item.value ?? ""))
        }
      }
      if let index = query.firstIndex(where: { $0.0 == "api-version" }) {
        query[index].1 = configuration.apiVersion
      } else {
        query.append(("api-version", configuration.apiVersion))
      }
      let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
      components?.percentEncodedQuery = query.map { key, value in
        "\(key.addingPercentEncoding(withAllowedCharacters: unreserved)!)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved)!)"
      }.joined(separator: "&")
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
    let omitUnsupportedFields = isChatGPTSignIn(context)
    let configurationEffort = configurationUpdateEffort(request, context: context)
    let supportsStrictMode: Bool = {
      if let configured = compat.bool("supportsStrictMode") { return configured }
      return flavor != .standard
    }()
    let supportsGrammarTools = compat.bool("supportsOpenAIGrammarTools") == true
    let usesInitialToolItem =
      ProviderToolDeclarationMode.resolve(protocolID: protocolID, compatibility: compat) == .changes
    let toolPlacement:
      (immediate: [ProviderToolDefinition], deferred: [String: ProviderToolDefinition]) =
        (usesInitialToolItem ? [] : request.tools, [:])
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
          grammarInputProperties: try grammarInputProperties(request, context: context),
          deferredTools: toolPlacement.deferred,
          deferredToolsMode: nil,
          supportsStrictMode: supportsStrictMode,
          configurationEffort: configurationEffort
        )),
      "stream": .bool(true),
      "store": .bool(false),
    ]
    if usesInitialToolItem, !request.tools.isEmpty,
      !request.messages.contains(where: { $0.systemPayload?.toolsAdded.isEmpty == false }),
      case .array(var input)? = body["input"]
    {
      input.insert(
        .object([
          "type": .string("additional_tools"), "role": .string("developer"),
          "tools": .array(
            try request.tools.map {
              try responseTool(
                $0, grammarTools: grammarTools, supportsStrictMode: supportsStrictMode,
                providerID: request.providerID, deferLoading: false)
            }),
        ]), at: 0)
      body["input"] = .array(input)
    }
    let instructions = request.messages.first?.systemPayload?.content ?? ""
    if flavor != .codex, !omitUnsupportedFields, compat.bool("supportsMaxOutputTokens") != false,
      let maximum = request.options.maximumOutputTokens
        ?? context.model.maximumOutputTokens
    {
      body["max_output_tokens"] = .integer(Int64(max(16, maximum)))
    }
    if let temperature = request.options.temperature, !omitUnsupportedFields {
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
    if flavor == .standard, !omitUnsupportedFields, cacheRetention == .long,
      compat.bool("supportsLongCacheRetention") != false,
      compat.bool("supportsExplicitPromptCacheMode") != true
    {
      body["prompt_cache_retention"] = .string("24h")
    }
    if flavor == .standard, !omitUnsupportedFields,
      compat.bool("supportsExplicitPromptCacheMode") == true
    {
      if cacheRetention == .none {
        body["prompt_cache_options"] = .object(["mode": .string("explicit")])
      } else if cacheRetention == .long, compat.bool("supportsLongCacheRetention") != false {
        body["prompt_cache_options"] = .object(["ttl": .string("30m")])
      }
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
          "effort": .string(configurationEffort == nil ? (mapped ?? effort.rawValue) : "medium"),
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
          : instructions
      )
      body["text"] = .object(["verbosity": .string(request.options.textVerbosity ?? "low")])
      body["include"] = .array([.string("reasoning.encrypted_content")])
      body["tool_choice"] = request.options.toolChoice ?? .string("auto")
      body["parallel_tool_calls"] = .bool(true)
      if let sessionID = codexSessionID(request.options) {
        body["prompt_cache_key"] = .string(sessionID)
      }
    }
    for (key, value) in request.options.providerOptions
    where key != "samplingParams" && key != "grammarToolInputProperties" {
      body[key] = value
    }
    for (key, value) in ProviderSamplingParameters.resolve(request: request, context: context) {
      body[key] = value
    }
    return body
  }

  private func isChatGPTSignIn(_ context: WireProtocolContext) -> Bool {
    guard flavor == .standard, context.provider.id == "openai",
      context.baseURL.absoluteString == "https://api.openai.com/v1"
    else { return false }
    switch context.credential {
    case .apiKey(let credential): return !credential.key.hasPrefix("sk-")
    case .oauth(let credential): return !credential.accessToken.hasPrefix("sk-")
    case nil: return false
    }
  }

  private func configurationUpdateEffort(_ request: ProviderRequest, context: WireProtocolContext)
    -> String?
  {
    guard flavor == .standard,
      context.modelConfiguration.metadata.object("compat")?.bool("supportsMidConvoEffort") == true,
      let effort = request.options.reasoningEffort, effort != .off,
      !isChatGPTSignIn(context)
    else { return nil }
    return context.modelConfiguration.metadata.object("thinkingLevelMap")?.string(effort.rawValue)
      ?? effort.rawValue
  }

  private func configurationUpdate(_ effort: String) -> JSONValue {
    .object([
      "type": .string("configuration_update"), "reasoning": .object(["effort": .string(effort)]),
    ])
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
    grammarInputProperties: [String: String],
    deferredTools: [String: ProviderToolDefinition],
    deferredToolsMode: String?,
    supportsStrictMode: Bool,
    configurationEffort: String? = nil
  ) throws -> [JSONValue] {
    let target = ProviderMessageSource(
      api: protocolID, providerID: context.provider.id, modelID: context.model.id)
    var result: [JSONValue] = []
    var replayMessageIndex = 0
    var normalizedToolIDs: [String: String] = [:]
    let compat = context.modelConfiguration.metadata.object("compat") ?? [:]
    let toolMode = ProviderToolDeclarationMode.resolve(
      protocolID: protocolID, compatibility: compat)
    var declaredAdditionalTools = false
    var unavailableTools: [String] = []
    func appendToolChanges(_ value: ProviderSystemMessage, role: String, messageIndex: Int) throws
      -> String
    {
      guard toolMode != .none else { return value.content }
      let added = Set(value.toolsAdded.map(\.name))
      unavailableTools.removeAll { added.contains($0) }
      if !value.toolsAdded.isEmpty {
        if toolMode == .changes, declaredAdditionalTools {
          var notice =
            "This is an incremental tools update. Previously declared tools remain available unless explicitly marked unavailable. A tool declared again here is available again, and its latest definition replaces the earlier one."
          if !unavailableTools.isEmpty {
            notice += "\nStill unavailable: " + unavailableTools.joined(separator: ", ") + "."
          }
          result.append(.object(["role": .string(role), "content": .string(notice)]))
        }
        if toolMode == .changes { declaredAdditionalTools = true }
        var grammars: [String: ProviderConstrainedSamplingResolver.Grammar] = [:]
        for tool in value.toolsAdded {
          if let grammar = try ProviderConstrainedSamplingResolver.grammar(
            for: tool, supportsGrammarTools: compat.bool("supportsOpenAIGrammarTools") == true,
            providerID: context.provider.id, operation: "openai-responses.request.grammar-tool")
          {
            grammars[tool.name] = grammar
          }
        }
        let tools = try value.toolsAdded.map {
          try responseTool(
            $0, grammarTools: grammars, supportsStrictMode: supportsStrictMode,
            providerID: context.provider.id, deferLoading: toolMode == .additions)
        }
        if toolMode == .changes {
          result.append(
            .object([
              "type": .string("additional_tools"), "role": .string("developer"),
              "tools": .array(tools),
            ]))
        } else {
          let names = value.toolsAdded.map(\.name)
          let callID =
            "pi_tool_load_"
            + responsesShortHash("system:\(messageIndex):" + names.joined(separator: ","))
          result.append(
            .object([
              "type": .string("tool_search_call"), "call_id": .string(callID),
              "execution": .string("client"), "status": .string("completed"),
              "arguments": .object([
                "query": .string(names.joined(separator: " ")),
                "limit": .integer(Int64(names.count)),
              ]),
            ]))
          result.append(
            .object([
              "type": .string("tool_search_output"), "call_id": .string(callID),
              "execution": .string("client"), "status": .string("completed"),
              "tools": .array(tools),
            ]))
        }
      }
      let removed = value.toolsRemoved.filter { !added.contains($0) }
      for name in removed where !unavailableTools.contains(name) { unavailableTools.append(name) }
      guard !removed.isEmpty else { return value.content }
      let notice =
        "The following tools are no longer available. Do not call them:\n"
        + removed.map { "- " + $0 }.joined(separator: "\n")
      return [value.content, notice].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    var sourceIndex = 0
    for message in messages {
      let isLeadingSystem = sourceIndex == 0 && message.systemPayload != nil
      sourceIndex += 1
      let messageIndex = replayMessageIndex
      switch message {
      case .system(let text):
        if includeSystem || !isLeadingSystem {
          let supportsDeveloper =
            context.modelConfiguration.metadata.object("compat")?
            .bool("supportsDeveloperRole") != false
          let role =
            context.model.capabilities.reasoning && supportsDeveloper ? "developer" : "system"
          result.append(.object(["role": .string(role), "content": .string(text)]))
        }
        if !isLeadingSystem { replayMessageIndex += 1 }
        continue
      case .systemMessage(let value):
        let role =
          context.model.capabilities.reasoning && compat.bool("supportsDeveloperRole") != false
          ? "developer" : "system"
        let text = try appendToolChanges(value, role: role, messageIndex: messageIndex)
        if includeSystem || !isLeadingSystem {
          if !text.isEmpty {
            result.append(.object(["role": .string(role), "content": .string(text)]))
          }
        }
        if !isLeadingSystem { replayMessageIndex += 1 }
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
        let outputStart = result.count
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
          case .unrecognized:
            continue
          case .textUTF16(let units):
            result.append(
              responseMessageInput(
                text: ProviderInputText.sanitizeUTF16(units), signature: nil,
                fallbackID: textIndex == 0
                  ? "msg_pi_\(messageIndex)" : "msg_pi_\(messageIndex)_\(textIndex)"))
            textIndex += 1
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
            let expectedPrefix = grammarInputProperties[call.name] == nil ? "fc_" : "ctc_"
            if differentModel || itemID?.hasPrefix(expectedPrefix) == false {
              itemID = nil
            }
            var object: [String: JSONValue]
            if let inputProperty = grammarInputProperties[call.name] {
              guard let arguments = call.arguments.objectValue,
                let input = arguments.string(inputProperty)
              else {
                throw failure(
                  .invalidRequest,
                  providerID: context.provider.id,
                  operation: "openai-responses.request.grammar-tool-call",
                  message:
                    "Grammar tool call \"\(call.name)\" requires argument \"\(inputProperty)\" to be a string."
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
        if configurationEffort != nil, assistant.source == target,
          result.count > outputStart,
          let previous = assistant.providerMetadata["providerThinkingLevel"]?.stringValue
        {
          result.insert(configurationUpdate(previous), at: outputStart)
        }
      case .toolResult(let toolResult):
        let normalizedID = normalizedToolIDs[toolResult.toolCallID] ?? toolResult.toolCallID
        let callID =
          normalizedID.split(separator: "|", maxSplits: 1).first.map(String.init)
          ?? toolResult.toolCallID
        result.append(
          .object([
            "type": .string(
              grammarInputProperties[toolResult.toolName] == nil
                ? "function_call_output" : "custom_tool_call_output"),
            "call_id": .string(callID),
            "output": try makeToolResultOutput(toolResult, context: context),
          ]))

      }
      replayMessageIndex += 1
    }
    if let configurationEffort { result.append(configurationUpdate(configurationEffort)) }
    return result
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
    } else if flavor != .codex, supportsStrictMode {
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
      allowedProviders = ["openai", "openai-codex", "opencode", "azure"]
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
    case .textUTF16(let units):
      try makeUserContent(.text(ProviderInputText.sanitizeUTF16(units)))
    case .unrecognized:
      throw ProviderInputText.unsupportedContent("openai-responses")
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
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard !images.isEmpty, context.model.capabilities.imageInput else {
      if hasText { return .string(text) }
      return .string(images.isEmpty ? "(no tool output)" : "(see attached image)")
    }
    var output: [JSONValue] = []
    if hasText {
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
  private var emittedStart = false
  private var terminal = false
  private var terminalFinishReason: ProviderFinishReason?
  private var rawTerminalFinishReason: String?
  private var terminalErrorMessage: String?
  private var responseID: String?
  private var tools: [String: ToolState] = [:]
  private var toolOrder: [String] = []
  let providerThinkingLevel: String?
  private var toolIDsByOutputIndex: [Int?: String] = [:]
  private var completedToolCall = false
  private var textByIndex: [Int: ProviderTextContent] = [:]
  private var reasoningByIndex: [Int: ProviderReasoningContent] = [:]
  private var reasoningIndexByID: [String: Int] = [:]
  private var toolsByIndex: [Int: ProviderToolCall] = [:]
  private var usage: ProviderUsage?
  private var blockSlots: [Int?: (kind: String, index: Int)] = [:]
  private var nextContentIndex = 0
  private var provisionalFinishReason: ProviderFinishReason?
  private var endTurn: Bool?

  var isTerminal: Bool { terminal }

  mutating func startEvent() -> ProviderEvent? {
    guard !emittedStart else { return nil }
    emittedStart = true
    return .responseStarted(
      .init(
        responseID: nil, providerID: providerID, modelID: requestedModelID, providerMetadata: [:]))
  }

  init(
    providerID: String,
    protocolID: String,
    requestedModelID: String,
    acceptsCodexTerminalAliases: Bool,
    grammarInputProperties: [String: String],
    pricing: ProviderUsagePricing?,
    requestedServiceTier: String?,
    flavor: OpenAIResponsesAdapter.Flavor,
    providerThinkingLevel: String? = nil
  ) {
    self.providerID = providerID
    self.protocolID = protocolID
    self.requestedModelID = requestedModelID
    self.acceptsCodexTerminalAliases = acceptsCodexTerminalAliases
    self.grammarInputProperties = grammarInputProperties
    self.pricing = pricing
    self.requestedServiceTier = requestedServiceTier
    self.flavor = flavor
    self.providerThinkingLevel = providerThinkingLevel
  }

  mutating func reduce(_ event: ServerSentEvent, observation: ProviderWireObservation) async throws
    -> [ProviderEvent]
  {
    if event.data == "[DONE]" { return [] }
    let data = Data(event.data.utf8)
    let object = try decodeJSONObject(
      data,
      providerID: providerID,
      operation: "openai-responses.event.decode"
    )
    let sdkError =
      event.event == "error"
      || object["error"].map { ProviderOrderedJSON.scalar($0).isTruthy } == true
    if flavor != .codex, sdkError {
      let error = try ProviderErrorText.openAIStreamError(data)
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: error.message,
        providerID: providerID,
        operation: "openai-responses.event.error",
        causeDescription: error.code)
    }
    try await observation.streamEvent(.object(object))
    do {
      return try await reduceObject(
        object, eventName: event.event, eventData: event.data, observation: observation)
    } catch let
      error
      as GrammarToolInputJSONError
    { throw invalid(error.description) }
  }

  private mutating func reduceObject(
    _ object: [String: JSONValue], eventName: String?, eventData: String,
    observation: ProviderWireObservation
  ) async throws -> [ProviderEvent] {
    guard let type = object.string("type") ?? eventName else {
      throw invalid("Responses event is missing type")
    }
    switch type {
    case "codex.rate_limits" where flavor == .codex:
      return []
    case "response.created", "response.in_progress":
      guard !started else { return [] }
      guard let response = object.object("response"), let id = response.string("id") else {
        throw invalid("response.created is missing response identity")
      }
      started = true
      responseID = id
      return startEvent().map { [$0] } ?? []
    case "response.output_text.delta":
      guard let delta = object.string("delta") else { throw invalid("text delta is missing delta") }
      guard let slot = blockSlots[object.int("output_index")], slot.kind == "message" else {
        return []
      }
      let index = slot.index
      let previous = textByIndex[index]?.text ?? ""
      textByIndex[index] = ProviderTextContent(
        text: previous + delta, signature: textByIndex[index]?.signature,
        phase: textByIndex[index]?.phase)
      return [blockEvent(index, .text(textByIndex[index]!), .delta(delta)), .textDelta(delta)]
    case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
      guard let delta = object.string("delta") else {
        throw invalid("reasoning delta is missing delta")
      }
      guard let slot = blockSlots[object.int("output_index")], slot.kind == "reasoning" else {
        return []
      }
      let index = slot.index
      let previous = reasoningByIndex[index]?.text ?? ""
      reasoningByIndex[index] = ProviderReasoningContent(
        text: previous + delta,
        signature: reasoningByIndex[index]?.signature,
        providerMetadata: [:]
      )
      return [
        blockEvent(index, .reasoning(reasoningByIndex[index]!), .delta(delta)),
        .reasoningDelta(delta),
      ]
    case "response.reasoning_summary_part.done":
      guard let slot = blockSlots[object.int("output_index")], slot.kind == "reasoning" else {
        return []
      }
      let index = slot.index
      guard let current = reasoningByIndex[index] else { return [] }
      reasoningByIndex[index] = ProviderReasoningContent(
        text: current.text + "\n\n", signature: current.signature,
        isRedacted: current.isRedacted, providerMetadata: current.providerMetadata)
      return [
        blockEvent(index, .reasoning(reasoningByIndex[index]!), .delta("\n\n")),
        .reasoningDelta("\n\n"),
      ]
    case "response.output_item.added":
      guard let item = object.object("item") else { return [] }
      if ["message", "reasoning"].contains(item.string("type") ?? "") {
        return createBlock(item, at: object.int("output_index")).events
      }
      guard ["function_call", "custom_tool_call"].contains(item.string("type") ?? "") else {
        return []
      }
      return try await startTool(item, at: object.int("output_index"), observation: observation)
    case "response.function_call_arguments.delta":
      guard
        let id = toolIDsByOutputIndex[object.int("output_index")],
        let delta = object.string("delta"),
        let state = tools[id], state.customInputProperty == nil
      else { return [] }
      state.arguments += delta
      tools[id] = state
      return [.toolInputDelta(id: id, delta: delta)]
    case "response.function_call_arguments.done":
      guard let id = toolIDsByOutputIndex[object.int("output_index")],
        let arguments = object.string("arguments"), let state = tools[id],
        state.customInputProperty == nil
      else { return [] }
      let previous = state.arguments
      state.arguments = arguments
      guard arguments.utf8.starts(with: previous.utf8) else { return [] }
      let delta = String(decoding: arguments.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
      return delta.isEmpty ? [] : [.toolInputDelta(id: id, delta: delta)]
    case "response.custom_tool_call_input.delta":
      guard
        let id = toolIDsByOutputIndex[object.int("output_index")],
        let delta = object.string("delta"),
        let state = tools[id], state.customInputProperty != nil
      else { return [] }
      guard let json = try state.customInput?.append(delta) else { return [] }
      return [.toolInputDelta(id: id, delta: json)]
    case "response.custom_tool_call_input.done":
      guard
        let id = toolIDsByOutputIndex[object.int("output_index")],
        let state = tools[id], state.customInputProperty != nil
      else { return [] }
      guard let json = try state.customInput?.close(object.string("input")) else { return [] }
      return [.toolInputDelta(id: id, delta: json)]
    case "response.output_item.done":
      guard let item = object.object("item"), let itemType = item.string("type") else {
        throw invalid("completed output item is missing type")
      }
      if itemType == "reasoning" {
        let slot = getOrCreateBlock(item, at: object.int("output_index"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(item)),
          let signature = String(data: data, encoding: .utf8)
        else { throw invalid("reasoning item cannot be encoded") }
        let index = slot.index
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
        blockSlots.removeValue(forKey: object.int("output_index"))
        return slot.events + [
          blockEvent(index, .reasoning(reasoningByIndex[index]!), .completed),
          .reasoningSignatureDelta(signature),
        ]
      }
      if itemType == "message" {
        if item.string("phase") == "final_answer" { provisionalFinishReason = .stop }
        let slot = getOrCreateBlock(item, at: object.int("output_index"))
        let index = slot.index
        let text = (item.array("content") ?? []).compactMap { part -> String? in
          guard let part = part.objectValue else { return nil }
          return part.string("text") ?? part.string("refusal")
        }.joined()
        guard let id = item.string("id"), !id.isEmpty else {
          throw invalid("completed message item is missing id")
        }
        var signatureMembers: [(String, ProviderOrderedJSON)] = [
          ("v", .scalar(.integer(1))), ("id", .scalar(.string(id))),
        ]
        if let phase = item.string("phase") {
          signatureMembers.append(("phase", .scalar(.string(phase))))
        }
        let signature = try ProviderOrderedJSON.object(signatureMembers).encodedString()
        textByIndex[index] = ProviderTextContent(
          text: text, signature: signature, phase: item.string("phase"))
        blockSlots.removeValue(forKey: object.int("output_index"))
        return slot.events + [blockEvent(index, .text(textByIndex[index]!), .completed)]
      }
      guard ["function_call", "custom_tool_call"].contains(itemType) else { return [] }
      let index = object.int("output_index")
      var events: [ProviderEvent] = []
      if toolIDsByOutputIndex[index] == nil {
        events += try await startTool(item, at: index, observation: observation)
      }
      guard let id = toolIDsByOutputIndex[index], let state = tools[id]
      else { throw invalid("completed function call has no matching item") }
      guard (itemType == "function_call") == (state.customInputProperty == nil) else {
        return events
      }
      let call: ProviderToolCall
      if let property = state.customInputProperty {
        if let json = try state.customInput?.close(item.string("input")) {
          events.append(.toolInputDelta(id: id, delta: json))
        }
        call = ProviderToolCall(
          id: id, name: state.name,
          arguments: .object([property: .string(state.customInput?.input ?? "")]),
          namespace: item.string("namespace") ?? state.namespace)
      } else {
        let raw = item.string("arguments").flatMap { $0.isEmpty ? nil : $0 } ?? state.arguments
        call = .parsing(
          id: id, name: state.name, input: raw,
          namespace: item.string("namespace") ?? state.namespace)
      }
      tools.removeValue(forKey: id)
      toolIDsByOutputIndex.removeValue(forKey: index)
      completedToolCall = true
      let contentIndex = blockSlots[index]?.index ?? nextContentIndex
      toolsByIndex[contentIndex] = call
      blockSlots.removeValue(forKey: index)
      return events + [.toolCallCompleted(call)]
    case "response.completed", "response.incomplete",
      "response.done"
    where type != "response.done" || acceptsCodexTerminalAliases:
      guard let response = object.object("response") else {
        throw invalid("terminal event is missing response")
      }
      terminal = true
      if flavor == .codex { endTurn = response.bool("end_turn") }
      try backfillReasoningSignatures(from: response)
      var events: [ProviderEvent] = []
      if let usage = response.object("usage") {
        self.usage = try pricedUsage(
          usage, responseServiceTier: response.string("service_tier"))
        events.append(.usage(self.usage!))
      }
      if let id = response.string("id"), !id.isEmpty { responseID = id }
      let status = response.string("status")
      let incompleteReason = response.object("incomplete_details")?.string("reason")
      var reason: ProviderFinishReason
      terminalErrorMessage = nil
      switch status {
      case nil, "", "completed", "in_progress", "queued":
        reason = .stop
      case "incomplete":
        if incompleteReason == "max_output_tokens" {
          reason = .length
        } else {
          reason = .error
          terminalErrorMessage =
            incompleteReason.flatMap { $0.isEmpty ? nil : $0 }
            .map { "Response incomplete: \($0)" }
            ?? "Response incomplete without a provider reason"
        }
      case "failed", "cancelled":
        reason = .error
      default:
        throw ProviderRuntimeFailure(
          code: .transportFailed,
          message: "Unhandled stop reason: \(status!)",
          providerID: providerID,
          operation: "openai-responses.event.completed",
          causeDescription: status)
      }
      if reason == .stop, completedToolCall || !tools.isEmpty { reason = .toolCalls }
      terminalFinishReason = reason
      let raw =
        incompleteReason.flatMap { $0.isEmpty ? nil : $0 }
        .map { "\(status ?? "undefined").\($0)" } ?? status
      rawTerminalFinishReason = raw
      return events
    case "response.failed", "error":
      terminal = true
      let error = object.object("error") ?? object.object("response")?.object("error")
      let details = object.object("response")?.object("incomplete_details")?.string("reason")
      let message: String
      if type == "response.failed", flavor == .codex {
        message =
          error?.string("message").flatMap { $0.isEmpty ? nil : $0 } ?? "Codex response failed"
      } else if type == "error", flavor == .codex {
        let code = object.string("code") ?? error?.string("code")
        let detail = object.string("message") ?? error?.string("message")
        let description =
          try detail.flatMap { $0.isEmpty ? nil : $0 }
          ?? code.flatMap { $0.isEmpty ? nil : $0 }
          ?? ProviderOrderedJSON(data: Data(eventData.utf8)).encodedString()
        message = "Codex error: \(description)"
      } else if type == "error" {
        message =
          "Error Code \(object.string("code") ?? "undefined"): \(object.string("message") ?? "undefined")"
      } else if let error {
        message =
          "\(error.string("code").flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"): \(error.string("message").flatMap { $0.isEmpty ? nil : $0 } ?? "no message")"
      } else if let details, !details.isEmpty {
        message = "incomplete: \(details)"
      } else {
        message = "Unknown error (no error details in response)"
      }
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: message,
        providerID: providerID,
        operation: "openai-responses.event.error",
        causeDescription: error?.string("code") ?? object.string("code") ?? details,
        providerMetadata: type == "response.failed" && flavor != .codex
          ? object.object("response")?.string("status").map { ["rawStopReason": .string($0)] } : nil
      )
    case "keepalive", "response.output_text.done", "response.content_part.added",
      "response.content_part.done",
      "response.reasoning_summary_part.added",
      "response.reasoning_summary_text.done", "response.metadata", "codex.response.metadata",
      "responsesapi.websocket_timing":
      return []
    default:
      throw invalid("unsupported OpenAI Responses event: \(type)")
    }
  }

  func finish() throws -> [ProviderEvent] {
    guard terminal else {
      throw invalid("OpenAI Responses stream ended before a terminal response event")
    }
    if terminalFinishReason == .toolCalls,
      let id = toolOrder.first(where: { tools[$0] != nil }), let state = tools[id]
    {
      throw invalid(
        "OpenAI Responses stream completed with an unfinished tool call: \(state.name) (\(id))")
    }
    guard let terminalFinishReason else { return [] }
    return [
      responseSnapshot(terminalFinishReason, rawFinishReason: rawTerminalFinishReason),
      .completed(terminalFinishReason),
    ]
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
    case "priority", "fast": return requestedModelID == "gpt-5.5" ? 2.5 : 2
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
    var metadata =
      providerThinkingLevel.map { ["providerThinkingLevel": JSONValue.string($0)] }
      ?? [:]
    if let terminalErrorMessage { metadata["errorMessage"] = .string(terminalErrorMessage) }
    if let endTurn { metadata["endTurn"] = .bool(endTurn) }
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
        timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
        providerMetadata: metadata
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

  private mutating func startTool(
    _ item: [String: JSONValue], at index: Int?, observation: ProviderWireObservation
  ) async throws
    -> [ProviderEvent]
  {
    guard let id = responseToolID(item), let name = item.string("name") else {
      throw invalid("function call item is missing id or name")
    }
    let customProperty =
      item.string("type") == "custom_tool_call" ? (grammarInputProperties[name] ?? "input") : nil
    blockSlots[index] = ("toolCall", nextContentIndex)
    nextContentIndex += 1
    toolIDsByOutputIndex[index] = id
    if tools[id] == nil { toolOrder.append(id) }
    tools[id] = try ToolState(
      name: name, arguments: item.string("arguments") ?? item.string("input") ?? "",
      customInputProperty: customProperty, namespace: item.string("namespace"))
    try await observation.startToolArguments(
      id: id,
      initial: customProperty.map { .object([$0: .string(item.string("input") ?? "")]) }
        ?? .object([:]),
      seedText: customProperty == nil ? item.string("arguments") : nil)
    return [.toolCallStarted(id: id, name: name)]
  }

  private func blockEvent(
    _ index: Int, _ content: ProviderResponseContent,
    _ update: ProviderContentBlock.Update
  ) -> ProviderEvent {
    var content = content
    if case .delta(let delta) = update {
      switch content {
      case .text(let value):
        content = .text(
          .init(
            text: delta, signature: value.signature, phase: value.phase,
            providerMetadata: value.providerMetadata))
      case .reasoning(let value):
        content = .reasoning(
          .init(
            text: delta, signature: value.signature,
            isRedacted: value.isRedacted, providerMetadata: value.providerMetadata))
      case .toolCall, .asset: break
      }
    }
    return .contentBlock(
      .init(
        index: index, content: content, update: update,
        provisionalFinishReason: provisionalFinishReason))
  }

  private mutating func getOrCreateBlock(_ item: [String: JSONValue], at outputIndex: Int?)
    -> (index: Int, events: [ProviderEvent])
  {
    if let slot = blockSlots[outputIndex], slot.kind == item.string("type") {
      return (slot.index, [])
    }
    return createBlock(item, at: outputIndex)
  }

  private mutating func createBlock(_ item: [String: JSONValue], at outputIndex: Int?)
    -> (index: Int, events: [ProviderEvent])
  {
    let index = nextContentIndex
    nextContentIndex += 1
    let kind = item.string("type") ?? ""
    blockSlots[outputIndex] = (kind, index)
    if kind == "message" {
      if item.string("phase") == "final_answer" { provisionalFinishReason = .stop }
      let text = ProviderTextContent(text: "", signature: nil, phase: item.string("phase"))
      textByIndex[index] = text
      return (index, [blockEvent(index, .text(text), .started)])
    }
    let reasoning = ProviderReasoningContent(text: "", signature: nil, providerMetadata: [:])
    reasoningByIndex[index] = reasoning
    return (index, [blockEvent(index, .reasoning(reasoning), .started)])
  }

  private final class ToolState {
    let name: String
    var arguments: String
    let customInputProperty: String?
    let namespace: String?
    var customInput: GrammarToolInputJSONBuffer?
    init(name: String, arguments: String, customInputProperty: String?, namespace: String?) throws {
      self.name = name
      self.arguments = arguments
      self.customInputProperty = customInputProperty
      self.namespace = namespace
      if let customInputProperty {
        customInput = try .init(property: customInputProperty, initialInput: arguments)
      }
    }
  }
}
