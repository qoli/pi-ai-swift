import Foundation

@testable import PiAIProviderRuntime

enum ClassifierConformanceProbe {
  static func input(_ value: [String: JSONValue]) throws -> ProviderClassifierRequest {
    let questions = value["questions"] ?? .object([:])
    let object = questions.objectValue ?? [:]
    return .init(
      state: value["state"] ?? .object([:]),
      questions: try (questions.objectPropertyNames ?? []).map {
        try question(object[$0]!, id: $0)
      },
      images: (value.array("images") ?? []).map {
        .init(
          data: $0.objectValue?.string("data") ?? "",
          mimeType: $0.objectValue?.string("mimeType") ?? "")
      })
  }

  static func question(_ value: JSONValue, id: String = "") throws -> ProviderClassifierQuestion {
    let object = value.objectValue ?? [:]
    let criteria = object["criteria"] ?? .object([:])
    let kind: ProviderClassifierQuestion.Kind
    switch object.string("type") {
    case "choice":
      let values = criteria.objectValue ?? [:]
      kind = .choice(
        (criteria.objectPropertyNames ?? []).map {
          .init(value: $0, description: values[$0]?.stringValue ?? "")
        })
    case "score": kind = .score((criteria.arrayValue ?? []).compactMap(\.stringValue))
    default:
      kind = .bool(
        trueMeaning: criteria.objectValue?.string("true") ?? "",
        falseMeaning: criteria.objectValue?.string("false") ?? "")
    }
    return .init(id: id, instructions: object.string("instructions") ?? "", kind: kind)
  }

  static func helper(_ raw: [String: JSONValue]) throws -> JSONValue {
    let args = raw.array("args") ?? []
    func numbers(_ value: JSONValue) -> [Double] {
      (value.arrayValue ?? []).compactMap { ProviderClassifierAdapter.number($0) }
    }
    switch raw.string("name") {
    case "llamaServerRoot": return .string(LlamaCPPClassifier.serverRoot(args[0].stringValue!))
    case "renderQuestion":
      let value = try LlamaCPPClassifier.renderQuestion(
        input(args[0].objectValue!), id: args[1].stringValue!)
      return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    case "labelProbabilities":
      return .array(
        LlamaCPPClassifier.probabilities(
          numbers(args[0]), temperature: ProviderClassifierAdapter.number(args[1])!
        ).map(JSONValue.number))
    case "peakConfidence": return .number(LlamaCPPClassifier.confidence(numbers(args[0])))
    case "answerFromProbabilities":
      return LlamaCPPClassifier.answer(
        try question(args[0]), keys: args[1].arrayValue!.compactMap(\.stringValue),
        probabilities: numbers(args[2])
      ).jsonValue
    default:
      throw ProviderRuntimeFailure(
        code: .unsupportedCapability, message: "Unknown classifier helper",
        providerID: nil, operation: "conformance.classifier.helper", causeDescription: nil)
    }
  }

  static func run(
    _ raw: [String: JSONValue], server: WireConformanceServer,
    incoming: AsyncStream<[String: JSONValue]>?
  ) async throws {
    let model = raw.object("model")!
    let options = raw.object("options") ?? [:]
    let providerID = model.string("provider")!
    let modelID = model.string("id")!
    let protocolID = model.string("api")!
    let selected = raw.string("selectedAPI")!
    let classifier = try input(raw.object("context")!)
    let providerModel = ProviderModel(
      id: modelID, providerID: providerID, name: model.string("name") ?? modelID,
      protocolID: protocolID,
      capabilities: .init(
        textInput: true, imageInput: model.array("input")?.contains(.string("image")) == true,
        toolCalling: false, reasoning: false, structuredOutput: false, imageGeneration: false,
        classification: true),
      contextWindow: model.int("contextWindow"), maximumOutputTokens: nil)
    let host = try JSONDecoder().decode(
      ProviderIdentityHost.self, from: JSONEncoder().encode(raw["identityHost"] ?? .object([:])))
    var headers = ProviderClientIdentity.headers(
      providerID: providerID, baseURL: model.string("baseUrl")!,
      identity: options.object("identity"), host: host)
    for (name, value) in model.object("headers") ?? [:] {
      headers = headers.filter { $0.key.lowercased() != name.lowercased() }
      if let value = value.stringValue { headers[name] = value }
    }
    let observer = ProviderWireObserver(
      onPayload: { value, _ in
        let reply = try await server.classifierExchange(
          "payload", value: ["payload": .object(value)])
        return reply["payload"]?.objectValue
      },
      onResponse: { response, _ in
        _ = try await server.classifierExchange(
          "response",
          value: [
            "status": .integer(Int64(response.status)),
            "headers": .object(response.headers.mapValues(JSONValue.string)),
          ])
      })
    let context = WireProtocolContext(
      provider: .init(
        id: providerID, name: providerID, authorizationMethods: [], models: [providerModel]),
      model: providerModel, baseURL: URL(string: model.string("baseUrl")!)!, headers: headers,
      credential: options.string("apiKey").map { .apiKey(.init(key: $0, metadata: [:])) },
      modelConfiguration: .init(
        protocolID: protocolID, baseURL: model.string("baseUrl"), headers: [:], metadata: model),
      wireObserver: observer, clock: server.clock)
    let request = ProviderRequest(
      id: "classifier", providerID: providerID, modelID: modelID, messages: [], tools: [],
      options: .init(
        maximumOutputTokens: nil,
        temperature: options["temperature"].flatMap { ProviderClassifierAdapter.number($0) },
        reasoningEffort: nil, responseSchema: nil, providerOptions: [:],
        outputModality: .classification),
      connectionOptions: .init(
        headers: options.object("headers")?.mapValues(\.stringValue),
        timeoutMilliseconds: options["timeoutMs"].flatMap { ProviderClassifierAdapter.number($0) },
        maximumRetries: options.int("maxRetries"),
        maximumRetryDelayMilliseconds: options["maxRetryDelayMs"].flatMap {
          ProviderClassifierAdapter.number($0)
        }),
      classifier: classifier)
    let operation = Task {
      await ProviderClassifierAdapter(protocolID: selected).classify(
        request, context: context, transport: ClassifierProbeTransport(server: server))
    }
    if raw.bool("aborted") == true { operation.cancel() }
    let monitor = Task {
      if let incoming {
        for await frame in incoming where frame.string("kind") == "cancel" { operation.cancel() }
      }
    }
    defer { monitor.cancel() }
    let result = await operation.value
    var output: [String: JSONValue] = [
      "api": .string(result.protocolID), "provider": .string(result.providerID),
      "model": .string(result.modelID),
      "answers": .object(result.answers.mapValues(\.jsonValue)),
      "timestamp": .integer(result.timestampMilliseconds),
      "stopReason": .string(
        result.finishReason == .cancelled ? "aborted" : result.finishReason.rawValue),
    ]
    output["errorMessage"] = result.errorMessage.map(JSONValue.string)
    if let usage = result.usage {
      output["usage"] = .object([
        "input": .number(usage.inputTokens), "output": .number(usage.outputTokens),
        "cacheRead": .integer(0), "cacheWrite": .integer(0),
        "totalTokens": .number(usage.inputTokens + usage.outputTokens),
        "cost": .object([
          "input": .number(usage.cost.input), "output": .number(usage.cost.output),
          "cacheRead": .integer(0),
          "cacheWrite": .integer(0), "total": .number(usage.cost.total),
          "totalFromProvider": .bool(usage.cost.totalFromProvider ?? false),
        ]),
      ])
    }
    try ProbeChannel().write("classifierFinished", output)
  }
}

private struct ClassifierProbeTransport: ProviderHTTPStreamingTransport {
  let server: WireConformanceServer
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    let reply = try await server.classifierExchange(
      "http",
      value: [
        "url": .string(request.url!.absoluteString),
        "headers": .object((request.allHTTPHeaderFields ?? [:]).mapValues(JSONValue.string)),
        "body": .string(request.httpBody!.base64EncodedString()),
      ])
    let data = Data(base64Encoded: reply.string("body")!)!
    return .init(
      statusCode: reply.int("status")!,
      headers: (reply.object("headers") ?? [:]).compactMapValues(\.stringValue),
      body: AsyncThrowingStream {
        $0.yield(data)
        $0.finish()
      })
  }
}
