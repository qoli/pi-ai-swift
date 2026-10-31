import Foundation

@testable import PiAIProviderRuntime

enum ProviderAdaptationFixtures {
  static func replay(_ spec: [String: JSONValue], addChatRoute: Bool = false) async throws
    -> [String: JSONValue]
  {
    let transport = AdaptationFixtureTransport(spec: spec)
    let clock = AdaptationFixtureClock()
    let result: JSONValue
    if spec.string("kind") == "oauth" {
      let provider = spec.string("provider")!
      let owner = provider == "openai-chatgpt" ? "openai" : provider
      let adapter: any ProviderAuthorizationAdapter
      switch provider {
      case "meta":
        adapter = MetaOAuthAuthorizationAdapter(transport: transport, clock: clock)
      case "kimi-coding":
        adapter = KimiCodingOAuthAuthorizationAdapter(transport: transport, clock: clock)
      default:
        adapter = OpenAIChatGPTAuthorizationAdapter(
          transport: transport, clock: clock, deviceID: nil)
      }
      let raw = spec.object("credential")!
      let credential = OAuthCredential(
        accessToken: raw.string("access")!, refreshToken: raw.string("refresh")!,
        expiresAt: .distantPast, metadata: raw.string("clientId").map { ["clientID": $0] } ?? [:])
      let store = InMemoryProviderCredentialStore(credentials: [owner: .oauth(credential)])
      do {
        let resolved = try await adapter.resolveCredential(
          providerID: owner, credentialStore: store,
          refreshCoordinator: CredentialRefreshCoordinator(credentialStore: store))
        guard case .oauth(let value) = resolved else {
          throw AdaptationFixtureError("Missing OAuth credential")
        }
        var fields: [String: JSONValue] = [
          "type": .string("oauth"), "access": .string(value.accessToken),
          "refresh": .string(value.refreshToken),
          "lifetimeSeconds": .number(value.expiresAt.timeIntervalSince1970 - 1_700_000_000),
        ]
        if let id = value.metadata["clientID"] { fields["clientId"] = .string(id) }
        if let scopes = value.metadata["scopes"] {
          fields["scopes"] = try JSONValue(jsonData: Data(scopes.utf8))
        }
        result = .object(fields)
      } catch {
        result = .object([
          "errorMessage": .string(
            (error as? ProviderRuntimeFailure)?.message ?? error.localizedDescription)
        ])
      }
    } else {
      let model = spec.object("model")!
      let api = model.string("api")!
      let provider = model.string("provider")!
      let id = model.string("id")!
      let options = spec.object("options") ?? [:]
      let rawInput = spec.object("context")!
      let rawQuestions = rawInput["questions"]!
      let questions = rawQuestions.objectValue!
      let classifier = ProviderClassifierRequest(
        state: rawInput["state"]!,
        questions: (rawQuestions.objectPropertyNames ?? []).map { key in
          let question = questions[key]!.objectValue!
          let criteria = question["criteria"]!
          let kind: ProviderClassifierQuestion.Kind
          switch question.string("type") {
          case "choice":
            kind = .choice(
              (criteria.objectPropertyNames ?? []).map {
                .init(value: $0, description: criteria.objectValue![$0]!.stringValue!)
              })
          case "score": kind = .score(criteria.arrayValue!.compactMap(\.stringValue))
          default:
            kind = .bool(
              trueMeaning: criteria.objectValue!.string("true")!,
              falseMeaning: criteria.objectValue!.string("false")!)
          }
          return .init(id: key, instructions: question.string("instructions")!, kind: kind)
        },
        images: (rawInput.array("images") ?? []).map {
          .init(
            data: $0.objectValue!.string("data")!, mimeType: $0.objectValue!.string("mimeType")!)
        })
      let runtime = try CustomProviderRuntime(
        providers: [
          .init(
            id: provider,
            baseURL: URL(string: model.string("baseUrl")!)!, api: api,
            models: [
              .init(
                id: id,
                capabilities: .init(
                  textInput: true,
                  imageInput: model.array("input")!.contains(.string("image")), toolCalling: false,
                  reasoning: false,
                  structuredOutput: false, imageGeneration: false, classification: true),
                contextWindow: model.int("contextWindow"), metadata: model)
            ]
              + (addChatRoute
                ? [
                  CustomProviderModel(
                    id: id, api: "openai-responses",
                    capabilities: .init(
                      textInput: true, imageInput: false, toolCalling: true,
                      reasoning: false, structuredOutput: true, imageGeneration: false))
                ] : []))
        ],
        credentialStore: InMemoryProviderCredentialStore(
          credentials: options.string("apiKey").map {
            [provider: .apiKey(.init(key: $0, metadata: [:]))]
          } ?? [:]),
        streamingTransport: transport)
      let request = ProviderRequest(
        id: "fixture-classify", providerID: provider, modelID: id, messages: [], tools: [],
        options: .init(
          maximumOutputTokens: nil, temperature: nil, reasoningEffort: nil, responseSchema: nil,
          providerOptions: [:], outputModality: .classification),
        connectionOptions: .init(maximumRetries: options.int("maxRetries")), classifier: classifier)
      var observed: ProviderClassifierResult?
      for try await event in runtime.stream(request) {
        if case .classification(let value) = event { observed = value }
      }
      guard let value = observed else {
        throw AdaptationFixtureError("Missing classification result")
      }
      var fields: [String: JSONValue] = [
        "api": .string(value.protocolID), "provider": .string(value.providerID),
        "model": .string(value.modelID), "answers": .object(value.answers.mapValues(\.jsonValue)),
        "stopReason": .string(value.finishReason.rawValue),
      ]
      fields["errorMessage"] = value.errorMessage.map(JSONValue.string)
      if let usage = value.usage {
        fields["usage"] = .object([
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
      result = .object(fields)
    }
    let requests = await transport.requests
    func auxiliary(_ value: JSONValue) -> Bool {
      let path = value.objectValue!.string("url")!
      return path.hasSuffix("/tokenize") || path.hasSuffix("/apply-template")
    }
    return [
      "id": .string(spec.string("id")!), "result": result,
      "requests": .array(requests.filter { !auxiliary($0) }),
      "auxiliary": .array(requests.filter(auxiliary)),
      "delays": .array(clock.delays.map(JSONValue.number)),
    ]
  }

  static func canonical(_ value: [String: JSONValue]) throws -> JSONValue {
    var fields = value
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let items = try (fields.array("auxiliary") ?? []).map {
      (try encoder.encode($0).base64EncodedString(), $0)
    }
    fields["auxiliary"] = .array(items.sorted { $0.0 < $1.0 }.map(\.1))
    return try JSONValue(jsonData: encoder.encode(JSONValue.object(fields)))
  }
}

private final class AdaptationFixtureClock: ProviderOAuthClock, @unchecked Sendable {
  private let lock = NSLock()
  private var durations: [Double] = []
  var delays: [Double] { lock.withLock { durations } }
  func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
  func sleep(for duration: Duration) async throws {
    let value = duration.components
    lock.withLock {
      durations.append(Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15)
    }
  }
}
private struct AdaptationFixtureError: Error, LocalizedError {
  let errorDescription: String?
  init(_ value: String) { errorDescription = value }
}

private actor AdaptationFixtureTransport: ProviderHTTPTransport, ProviderHTTPStreamingTransport {
  let spec: [String: JSONValue]
  private var completions = 0
  private(set) var requests: [JSONValue] = []
  init(spec: [String: JSONValue]) { self.spec = spec }

  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    let bytes = request.httpBody!
    let body: JSONValue
    if request.value(forHTTPHeaderField: "Content-Type")?.contains(
      "application/x-www-form-urlencoded") == true
    {
      let query = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "+", with: " ")
      body = .object(
        Dictionary(
          uniqueKeysWithValues: (URLComponents(string: "?" + query)?.queryItems ?? []).map {
            ($0.name, .string($0.value ?? ""))
          }))
    } else {
      body = try JSONValue(jsonData: bytes)
    }
    var headers: [String: JSONValue] = [:]
    for name in ["authorization", "content-type", "typesafe-danger-zone-images"] {
      if let value = request.value(forHTTPHeaderField: name) { headers[name] = .string(value) }
    }
    requests.append(
      .object([
        "url": .string(request.url!.absoluteString), "body": body, "headers": .object(headers),
      ]))
    let response: JSONValue
    var status = spec.int("status") ?? 200
    if let sequence = spec.array("responseSequence"), requests.count <= sequence.count {
      let item = sequence[requests.count - 1].objectValue!
      response = item["body"]!
      status = item.int("status")!
    } else if spec.object("model")?.string("api") == "llama-cpp-classify" {
      if request.url!.path.hasSuffix("/tokenize") {
        response = .object([
          "tokens": .array(
            body.objectValue!.string("content")!.unicodeScalars.map { .integer(Int64($0.value)) })
        ])
      } else if request.url!.path.hasSuffix("/apply-template") {
        response = .object([
          "prompt": .string(
            body.objectValue!.array("messages")!.map {
              let value = $0.objectValue!
              return value.string("role")! + "\n" + value.string("content")! + "\n"
            }.joined())
        ])
      } else {
        completions += 1
        var entries: [JSONValue] = [.object(["id": .integer(65), "logprob": .number(-0.1)])]
        if spec.bool("readoutEscalation") != true || completions > 1 {
          entries.append(.object(["id": .integer(66), "logprob": .number(-2.5)]))
        }
        response = .object([
          "completion_probabilities": .array([.object(["top_logprobs": .array(entries)])])
        ])
      }
    } else {
      response = spec["response"]!
    }
    let data = try response.stringValue.map { Data($0.utf8) } ?? JSONEncoder().encode(response)
    return .init(statusCode: status, headers: [:], body: data)
  }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    let response = try await send(request)
    return .init(
      statusCode: response.statusCode, headers: response.headers,
      body: AsyncThrowingStream {
        $0.yield(response.body)
        $0.finish()
      })
  }
}
