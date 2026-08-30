import Foundation

struct OpenRouterImagesAdapter: WireProtocolAdapter {
  let protocolID = "openrouter-images"
  private let maximumResponseBytes = 32 * 1_024 * 1_024

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
          let data = try await collect(response.body, request: request)
          guard (200..<300).contains(response.statusCode) else {
            throw failure(
              .transportFailed,
              request,
              "openrouter-images.response",
              "OpenRouter image request failed (HTTP \(response.statusCode))",
              cause: String(data: data, encoding: .utf8)
            )
          }
          for event in try decode(data, request: request) {
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

  private func makeURLRequest(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> URLRequest {
    guard request.tools.isEmpty else {
      throw failure(
        .unsupportedCapability,
        request,
        "openrouter-images.request.tools",
        "OpenRouter image generation does not accept tools"
      )
    }
    guard
      request.options.maximumOutputTokens == nil,
      request.options.temperature == nil,
      request.options.reasoningEffort == nil,
      request.options.responseSchema == nil
    else {
      throw failure(
        .unsupportedCapability,
        request,
        "openrouter-images.request.options",
        "OpenRouter image generation does not accept language-model generation options"
      )
    }
    let endpoint = context.baseURL.appending(path: "chat/completions")
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    for (name, value) in context.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    switch context.credential {
    case .apiKey(let credential):
      urlRequest.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
    case .oauth(let credential):
      urlRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
    case nil:
      throw failure(
        .missingCredential,
        request,
        "openrouter-images.request.auth",
        "OpenRouter image credential is missing"
      )
    }
    urlRequest.httpBody = try encodeJSONObject(
      try makeBody(request, context: context),
      providerID: request.providerID,
      operation: "openrouter-images.request.encode"
    )
    return urlRequest
  }

  private func makeBody(
    _ request: ProviderRequest,
    context: WireProtocolContext
  ) throws -> [String: JSONValue] {
    guard request.messages.count == 1, case .user(let input) = request.messages[0] else {
      throw failure(
        .invalidRequest,
        request,
        "openrouter-images.request.messages",
        "OpenRouter image generation requires exactly one user input message"
      )
    }
    let reserved: Set<String> = ["model", "messages", "stream", "modalities"]
    let collisions = Set(request.options.providerOptions.keys).intersection(reserved)
    guard collisions.isEmpty else {
      throw failure(
        .invalidRequest,
        request,
        "openrouter-images.request.options",
        "provider options cannot override reserved fields: \(collisions.sorted().joined(separator: ", "))"
      )
    }
    let output =
      context.modelConfiguration.metadata.array("output")?.compactMap(\.stringValue)
      ?? ["image"]
    var body: [String: JSONValue] = [
      "model": .string(request.modelID),
      "messages": .array([
        .object([
          "role": .string("user"),
          "content": .array(try input.map(content)),
        ])
      ]),
      "stream": .bool(false),
      "modalities": .array(
        output.contains("text")
          ? [.string("image"), .string("text")]
          : [.string("image")]
      ),
    ]
    for (key, value) in request.options.providerOptions { body[key] = value }
    return body
  }

  private func content(_ input: ProviderUserContent) throws -> JSONValue {
    switch input {
    case .text(let text):
      return .object(["type": .string("text"), "text": .string(text)])
    case .image(.data(let data, let mimeType)):
      return .object([
        "type": .string("image_url"),
        "image_url": .object([
          "url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")
        ]),
      ])
    case .image(.remoteURL):
      throw ProviderRuntimeFailure(
        code: .unsupportedCapability,
        message: "OpenRouter image generation requires inline image bytes",
        providerID: "openrouter",
        operation: "openrouter-images.request.image",
        causeDescription: nil
      )
    }
  }

  private func collect(
    _ stream: AsyncThrowingStream<Data, any Error>,
    request: ProviderRequest
  ) async throws -> Data {
    var data = Data()
    for try await chunk in stream {
      try Task.checkCancellation()
      guard data.count + chunk.count <= maximumResponseBytes else {
        throw failure(
          .invalidResponse,
          request,
          "openrouter-images.response.size",
          "OpenRouter image response exceeds \(maximumResponseBytes) bytes"
        )
      }
      data.append(chunk)
    }
    return data
  }

  private func decode(
    _ data: Data,
    request: ProviderRequest
  ) throws -> [ProviderEvent] {
    let object = try decodeJSONObject(
      data,
      providerID: request.providerID,
      operation: "openrouter-images.response.decode"
    )
    guard let responseID = object.string("id"), !responseID.isEmpty else {
      throw failure(
        .invalidResponse,
        request,
        "openrouter-images.response.identity",
        "OpenRouter image response is missing id"
      )
    }
    var events: [ProviderEvent] = [
      .responseStarted(
        ProviderResponseMetadata(
          responseID: responseID,
          providerID: request.providerID,
          modelID: object.string("model") ?? request.modelID,
          providerMetadata: [:]
        )
      )
    ]
    if let choice = object.array("choices")?.first?.objectValue,
      let message = choice.object("message")
    {
      if let text = message.string("content"), !text.isEmpty {
        events.append(.textDelta(text))
      }
      for (index, image) in (message.array("images") ?? []).enumerated() {
        guard let image = image.objectValue else { continue }
        let raw: String?
        if let value = image.string("image_url") {
          raw = value
        } else {
          raw = image.object("image_url")?.string("url")
        }
        guard let raw, raw.hasPrefix("data:") else { continue }
        let parts = raw.dropFirst(5).split(
          separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].hasSuffix(";base64") else { continue }
        let mimeType = String(parts[0].dropLast(";base64".count))
        guard !mimeType.isEmpty, let bytes = Data(base64Encoded: String(parts[1])) else {
          throw failure(
            .invalidResponse,
            request,
            "openrouter-images.response.image",
            "OpenRouter returned malformed base64 image data"
          )
        }
        events.append(
          .asset(
            ProviderAsset(
              id: "\(responseID)-image-\(index)",
              kind: .image,
              mimeType: mimeType,
              data: bytes,
              providerMetadata: ["choiceIndex": .integer(0), "imageIndex": .integer(Int64(index))]
            )
          )
        )
      }
    }
    if let usage = object.object("usage") {
      let prompt = usage.int("prompt_tokens") ?? 0
      let details = usage.object("prompt_tokens_details")
      let reportedCached = details?.int("cached_tokens") ?? 0
      let cacheWrite = details?.int("cache_write_tokens") ?? 0
      let cacheRead = cacheWrite > 0 ? max(0, reportedCached - cacheWrite) : reportedCached
      events.append(
        .usage(
          ProviderUsage(
            inputTokens: max(0, prompt - cacheRead - cacheWrite),
            outputTokens: usage.int("completion_tokens") ?? 0,
            reasoningTokens: nil,
            cachedInputTokens: cacheRead,
            providerMetadata: usage
          )
        )
      )
    }
    events.append(.completed(.stop))
    return events
  }

  private func failure(
    _ code: ProviderRuntimeFailure.Code,
    _ request: ProviderRequest,
    _ operation: String,
    _ message: String,
    cause: String? = nil
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: code,
      message: message,
      providerID: request.providerID,
      operation: operation,
      causeDescription: cause
    )
  }
}
