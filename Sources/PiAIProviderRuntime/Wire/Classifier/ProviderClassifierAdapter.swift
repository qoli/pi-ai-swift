import Foundation

struct ProviderClassifierAdapter: WireProtocolAdapter {
  static let protocolIDs: Set<String> = [
    "typesafe-system-one", "cloudflare-workers-ai-system-one", "openai-decisions",
    "llama-cpp-classify",
  ]
  let protocolID: String

  var label: String {
    switch protocolID {
    case "cloudflare-workers-ai-system-one": "Cloudflare Workers AI"
    case "openai-decisions": "OpenAI Decisions"
    case "llama-cpp-classify": "llama.cpp"
    default: "System One API"
    }
  }

  func stream(
    _ request: ProviderRequest, context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport
  ) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        let result = await classify(request, context: context, transport: transport)
        continuation.yield(.classification(result))
        continuation.yield(.completed(result.finishReason))
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func classify(
    _ request: ProviderRequest, context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport
  ) async -> ProviderClassifierResult {
    let timestamp = Int64(context.clock.now().timeIntervalSince1970 * 1_000)
    var usage: ProviderClassifierUsage?
    do {
      guard context.model.protocolID == protocolID else {
        throw error("Unsupported classifier API: " + context.model.protocolID)
      }
      guard let input = request.classifier else { throw error("Classifier input is missing") }
      if protocolID == "llama-cpp-classify" {
        let answers = try await LlamaCPPClassifier.classify(
          request, context: context,
          transport: transport, adapter: self, input: input)
        return .init(
          protocolID: context.model.protocolID, providerID: request.providerID,
          modelID: request.modelID,
          answers: answers, finishReason: .stop, timestampMilliseconds: timestamp)
      }
      var body: [String: JSONValue]
      var headers: [String: String] = [:]
      if protocolID == "openai-decisions" {
        body = [
          "model": .string(request.modelID), "input": try decisionInput(input),
          "questions": .array(input.questions.map(decisionQuestion)),
        ]
      } else {
        var inner: [String: JSONValue] = [
          "state": input.state,
          "questions": .orderedObject(input.questions.map { .init($0.id, $0.systemOneQuestion) }),
        ]
        if !input.images.isEmpty {
          guard context.model.capabilities.imageInput else {
            throw error("\(label) does not support image input for \(request.modelID)")
          }
          let cloudflare = protocolID == "cloudflare-workers-ai-system-one"
          let openRouter =
            request.providerID == "openrouter"
            || context.baseURL.absoluteString.contains("openrouter.ai")
          let detected =
            cloudflare
            ? (request.modelID.hasPrefix("@cf/cloudflare/clef") ? "images" : "assets")
            : openRouter ? "state-image-urls" : "assets"
          let compat = context.modelConfiguration.metadata.object("compat") ?? [:]
          let mode = compat.string("imageInput") ?? detected
          try addImages(input, to: &inner, mode: mode, modelID: request.modelID)
          if compat.bool("sendImageOptInHeader") ?? (!cloudflare && !openRouter) {
            headers["TypeSafe-Danger-Zone-Images"] = "true"
          }
        }
        if protocolID == "cloudflare-workers-ai-system-one" {
          body = ["model": .string(request.modelID), "input": .object(inner)]
        } else {
          inner["model"] = .string(request.modelID)
          body = inner
        }
      }
      let endpoint = context.baseURL.appending(
        path: protocolID == "openai-decisions"
          ? "decisions" : protocolID == "cloudflare-workers-ai-system-one" ? "run" : "systemone")
      let raw = try await post(
        endpoint, body: .object(body), request: request, context: context,
        transport: transport, observe: true, defaultHeaders: headers,
        noRetryStatuses: protocolID == "openai-decisions" ? [504] : [])
      let output = try unwrap(raw)
      usage = try parseUsage(output["usage"], context: context)
      let answers = try parseAnswers(output["answers"], questions: input.questions)
      return .init(
        protocolID: context.model.protocolID, providerID: request.providerID,
        modelID: request.modelID,
        answers: answers, usage: usage, finishReason: .stop, timestampMilliseconds: timestamp)
    } catch {
      let message: String
      if protocolID == "openai-decisions", (error as? ClassifierHTTPFailure)?.retryStatus == 504 {
        message =
          "OpenAI Decisions error (504): the request timed out at the gateway. Very large inputs (above roughly 600K tokens) currently exceed its time limit."
      } else if let failure = error as? ClassifierHTTPFailure {
        let normalized = ProviderErrorText.normalize(
          isError: true, message: failure.retryMessage,
          serializedValue: nil, stringValue: failure.retryMessage,
          statusCandidates: failure.retryStatus.map { [.integer(Int64($0))] } ?? [],
          body: .text(failure.body), error: .other, responseBody: .other)
        message = ProviderErrorText.format(normalized, prefix: label + " error")
      } else if let failure = error as? ProviderRuntimeFailure {
        message = failure.message
      } else {
        message = error.localizedDescription
      }
      return .init(
        protocolID: context.model.protocolID, providerID: request.providerID,
        modelID: request.modelID,
        answers: [:], usage: usage,
        finishReason: Task.isCancelled || error is CancellationError ? .cancelled : .error,
        errorMessage: message, timestampMilliseconds: timestamp)
    }
  }

  func post(
    _ endpoint: URL, body: JSONValue, request: ProviderRequest, context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport, observe: Bool,
    defaultHeaders: [String: String] = [:],
    noRetryStatuses: [Int] = []
  ) async throws -> JSONValue {
    let key: String?
    switch context.credential {
    case .apiKey(let value): key = value.key
    case .oauth(let value): key = value.accessToken
    case nil: key = nil
    }
    if protocolID != "llama-cpp-classify", key?.isEmpty != false {
      throw error("No API key for provider: " + request.providerID)
    }
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    var headers = ["content-type": "application/json"]
    if let key, !key.isEmpty { headers["authorization"] = "Bearer " + key }
    for source in [context.headers, defaultHeaders] {
      for (name, value) in source {
        headers = headers.filter { $0.key.lowercased() != name.lowercased() }
        headers[name] = value
      }
    }
    for (name, value) in request.connectionOptions.headers ?? [:] {
      headers = headers.filter { $0.key.lowercased() != name.lowercased() }
      if let value { headers[name] = value }
    }
    urlRequest.allHTTPHeaderFields = headers
    urlRequest.httpBody = Data(try ProviderOrderedJSON(body).encodedString().utf8)
    let observation = ProviderWireObservation(request: request, wire: context)
    if observe { urlRequest = try await observation.payload(urlRequest) }
    let captured = urlRequest
    let response: (ProviderHTTPStreamingResponse, JSONValue) = try await ProviderRequestRetry.run(
      maximumRetries: request.connectionOptions.maximumRetries ?? 2,
      maximumDelayMilliseconds: request.connectionOptions.maximumRetryDelayMilliseconds,
      noRetryStatuses: noRetryStatuses, clock: context.clock
    ) {
      do {
        return try await withThrowingTaskGroup(of: ClassifierHTTPResult.self) { group in
          group.addTask {
            let response = try await transport.stream(captured)
            var data = Data()
            for try await chunk in response.body { data.append(chunk) }
            if !(200..<300).contains(response.statusCode) {
              throw ClassifierHTTPFailure(
                retryStatus: response.statusCode, retryHeaders: response.headers,
                retryMessage: "\(label) returned \(response.statusCode)",
                body: String(decoding: data, as: UTF8.self))
            }
            return .init(response: response, body: try JSONValue(jsonData: data))
          }
          if let timeout = request.connectionOptions.timeoutMilliseconds {
            group.addTask {
              try await context.clock.sleep(for: .milliseconds(timeout), purpose: .timeout)
              throw ClassifierHTTPFailure(
                retryStatus: nil, retryHeaders: nil,
                retryMessage: "Request timed out after \(Self.numberText(timeout))ms", body: "")
            }
          }
          defer { group.cancelAll() }
          let result = try await group.next()!
          return (result.response, result.body)
        }
      } catch {
        try Task.checkCancellation()
        if let error = error as? ClassifierHTTPFailure { throw error }
        throw ClassifierHTTPFailure(
          retryStatus: nil, retryHeaders: nil,
          retryMessage: (error as? ProviderRuntimeFailure)?.message ?? error.localizedDescription,
          body: "")
      }
    }
    if observe { try await observation.response(response.0) }
    return response.1
  }

  private func decisionInput(_ input: ProviderClassifierRequest) throws -> JSONValue {
    let state = try ProviderOrderedJSON(input.state).encodedString()
    guard !input.images.isEmpty else { return .string(state) }
    guard input.images.count <= 128 else {
      throw error("OpenAI Decisions accepts at most 128 images, got \(input.images.count)")
    }
    return .array([
      .object([
        "role": .string("user"),
        "content": .array(
          [
            .object(["type": .string("input_text"), "text": .string(state)])
          ]
            + input.images.map {
              .object([
                "type": .string("input_image"),
                "image_url": .string("data:\($0.mimeType);base64,\($0.data)"),
              ])
            }),
      ])
    ])
  }

  private func decisionQuestion(_ question: ProviderClassifierQuestion) -> JSONValue {
    var result: [String: JSONValue] = [
      "name": .string(question.id), "instructions": .string(question.instructions),
    ]
    switch question.kind {
    case .choice(let choices):
      result["type"] = .string("choice")
      result["choices"] = .array(
        choices.map {
          .object(
            $0.description.isEmpty
              ? ["value": .string($0.value)]
              : ["value": .string($0.value), "description": .string($0.description)])
        })
    case .score(let levels):
      result["type"] = .string("score")
      result["levels"] = .array(levels.map { .object(["label": .string($0)]) })
    case .bool(let yes, let no):
      result["type"] = .string("predicate")
      let meanings = [("True", yes), ("False", no)].filter { !$0.1.isEmpty }.map {
        "\($0.0) means: \($0.1)"
      }
      if !meanings.isEmpty {
        result["instructions"] = .string(
          question.instructions + "\n\n" + meanings.joined(separator: "\n"))
      }
    }
    return .object(result)
  }

  private func addImages(
    _ input: ProviderClassifierRequest, to body: inout [String: JSONValue], mode: String,
    modelID: String
  ) throws {
    switch mode {
    case "images":
      guard input.images.count <= 4 else {
        throw error("\(label) accepts at most 4 images for \(modelID), got \(input.images.count)")
      }
      body["images"] = .array(
        try input.images.map {
          guard ["image/png", "image/jpeg", "image/webp"].contains($0.mimeType) else {
            throw error(
              "\(label) accepts PNG, JPEG, and WebP images for \(modelID), got \($0.mimeType)")
          }
          return .string("data:\($0.mimeType);base64,\($0.data)")
        })
    case "state-image-urls":
      body["state"] = .array(
        input.images.map {
          .object([
            "type": .string("image_url"),
            "image_url": .object(["url": .string("data:\($0.mimeType);base64,\($0.data)")]),
          ])
        } + [input.state])
    default:
      var assets: [String: JSONValue] = [:]
      var names: [JSONValue] = []
      for (index, image) in input.images.enumerated() {
        guard let format = ["image/png": "png", "image/jpeg": "jpeg"][image.mimeType] else {
          throw error("\(label) accepts PNG and JPEG images for \(modelID), got \(image.mimeType)")
        }
        let name = "<image-\(index + 1)>"
        names.append(.string(name))
        assets[name] = .object([
          "type": .string("image"), "format": .string(format), "data_base64": .string(image.data),
        ])
      }
      body["assets"] = .object(assets)
      body["state"] = .array(names + [input.state])
    }
  }

  private func unwrap(_ raw: JSONValue) throws -> [String: JSONValue] {
    guard let body = raw.objectValue else {
      throw error("\(label) returned an unexpected response")
    }
    if protocolID != "cloudflare-workers-ai-system-one" { return body }
    if body.bool("success") == false {
      let messages = (body.array("errors") ?? []).compactMap { $0.objectValue?.string("message") }
      throw error(
        messages.isEmpty
          ? "\(label) request failed" : "\(label) error: " + messages.joined(separator: "; "))
    }
    guard let result = body.object("result") else {
      throw error("\(label) returned an unexpected response")
    }
    if result["answers"] != nil { return result }
    guard result.string("state") == "Completed" else {
      let state =
        result["state"].flatMap { $0.stringValue ?? (try? ProviderOrderedJSON($0).encodedString()) }
        ?? "undefined"
      throw error("\(label) run did not complete (state: \(state))")
    }
    guard let output = result.object("result") else {
      throw error("\(label) returned an unexpected response")
    }
    return output
  }

  private func parseAnswers(_ raw: JSONValue?, questions: [ProviderClassifierQuestion]) throws
    -> [String: ProviderClassifierAnswer]
  {
    let decisions = protocolID == "openai-decisions"
    let values: [String: JSONValue]
    if decisions {
      guard let items = raw?.arrayValue else {
        throw error("\(label) returned an unexpected response")
      }
      values = items.reduce(into: [:]) { result, item in
        if let object = item.objectValue, let name = object.string("name") { result[name] = item }
      }
    } else {
      guard let object = raw?.objectValue else {
        throw error("\(label) returned an unexpected response")
      }
      values = object
    }
    var answers: [String: ProviderClassifierAnswer] = [:]
    for question in questions {
      let id = question.id
      guard let value = values[id]?.objectValue else {
        throw error("\(label) did not return an answer for \(id)")
      }
      if decisions, value.string("type") == "refusal" {
        throw error("\(label) refused to answer \(id)")
      }
      switch question.kind {
      case .choice:
        guard value.string("type") == "choice", let choice = value.string("choice") else {
          throw error("\(label) did not return a choice answer for \(id)")
        }
        let probabilities: [String: JSONValue]
        if decisions {
          guard let items = value.array("probabilities") else {
            throw error("\(label) returned invalid probabilities for \(id)")
          }
          var result: [String: JSONValue] = [:]
          for item in items {
            guard let object = item.objectValue, let name = object.string("value") else {
              throw error("\(label) returned invalid probabilities for \(id)")
            }
            result[name] = .number(
              try requiredNumber(object["probability"], "probability for \(id).\(name)"))
          }
          probabilities = result
        } else {
          guard let object = value.object("probabilities") else {
            throw error("\(label) returned invalid probabilities for \(id)")
          }
          probabilities = object
        }
        var converted: [String: Double] = [:]
        for (name, probability) in probabilities {
          converted[name] = try requiredNumber(probability, "probability for \(id).\(name)")
        }
        answers[id] = .choice(
          choice, probabilities: converted,
          confidence: try requiredNumber(value["confidence"], "confidence for \(id)"))
      case .score:
        guard value.string("type") == "score" else {
          throw error("\(label) did not return a score answer for \(id)")
        }
        answers[id] = .score(
          try requiredNumber(value["score"], "score for \(id)"),
          confidence: try requiredNumber(value["confidence"], "confidence for \(id)"))
      case .bool:
        let expected = decisions ? "predicate" : "noul"
        guard value.string("type") == expected else {
          throw error(
            "\(label) did not return a \(decisions ? "predicate" : "bool") answer for \(id)")
        }
        answers[id] = .bool(
          probability: try requiredNumber(
            value[decisions ? "probability" : "noul"], "probability for \(id)"))
      }
    }
    return answers
  }

  private func requiredNumber(_ value: JSONValue?, _ field: String) throws -> Double {
    guard let number = Self.number(value), number.isFinite else {
      throw error("\(label) returned an invalid \(field)")
    }
    return number
  }
  private func parseUsage(_ raw: JSONValue?, context: WireProtocolContext) throws
    -> ProviderClassifierUsage?
  {
    guard let object = raw?.objectValue,
      object["input_tokens"] != nil || object["output_tokens"] != nil
    else { return nil }
    func count(_ value: JSONValue?) -> Double {
      guard let number = Self.number(value), number.isFinite, number > 0 else { return 0 }
      return number
    }
    let input = count(object["input_tokens"])
    let output = count(object["output_tokens"])
    let pricing = try ProviderUsagePricing.parse(
      metadata: context.modelConfiguration.metadata,
      providerID: context.model.providerID, operation: "classifier.usage.pricing")
    var rates = pricing?.base
    if let tier = pricing?.tiers.filter({ input > Double($0.inputTokensAbove) }).max(by: {
      $0.inputTokensAbove < $1.inputTokensAbove
    }) {
      rates = tier.rates
    }
    let inputCost = (rates?.input ?? 0) / 1_000_000 * input
    let outputCost = (rates?.output ?? 0) / 1_000_000 * output
    return .init(
      inputTokens: input, outputTokens: output,
      cost: .init(
        input: inputCost, output: outputCost, cacheRead: 0, cacheWrite: 0,
        total: inputCost + outputCost, totalFromProvider: false))
  }
  static func number(_ value: JSONValue?) -> Double? {
    switch value {
    case .number(let n): n
    case .integer(let n): Double(n)
    default: nil
    }
  }
  static func numberText(_ value: Double) -> String {
    value.rounded() == value && value.isFinite ? String(format: "%.0f", value) : String(value)
  }
  func error(_ message: String) -> ProviderRuntimeFailure {
    .init(
      code: .invalidResponse, message: message, providerID: nil, operation: "classifier",
      causeDescription: nil)
  }
}

private struct ClassifierHTTPResult: Sendable {
  let response: ProviderHTTPStreamingResponse
  let body: JSONValue
}
private struct ClassifierHTTPFailure: ProviderRetryableError {
  let retryStatus: Int?
  let retryHeaders: [String: String]?
  let retryMessage: String
  let body: String
}
