import Foundation

@testable import PiAIProviderRuntime

enum OpenRouterPersonalizationFixtures {
  static func credential(_ spec: [String: JSONValue]) -> ProviderCredential? {
    guard let raw = spec.object("credential") else { return nil }
    if raw.string("type") == "oauth" {
      return .oauth(
        .init(
          accessToken: raw.string("access")!, refreshToken: raw.string("refresh")!,
          expiresAt: Date(timeIntervalSince1970: Double(raw.int("expires")!) / 1000), metadata: [:])
      )
    }
    return .apiKey(.init(key: raw.string("key")!, metadata: [:]))
  }

  static func replay(_ spec: [String: JSONValue]) async throws -> JSONValue {
    let transport = try Transport(spec)
    var output: [String: JSONValue] = ["id": spec["id"]!]
    do {
      let result = try await OpenRouterCatalogPersonalization.apply(
        spec.array("catalog")!, baseURL: spec.string("baseURL"),
        credential: credential(spec), transport: transport)
      output["catalog"] = .array(result.catalog)
      output["personalized"] = .bool(result.personalized)
      output["retainedIndices"] = .array(
        result.sourceIndices.map {
          .integer(result.updatedIndices.contains($0) ? -1 : Int64($0))
        })
    } catch let error as ProviderRuntimeFailure { output["error"] = .string(error.message) }
    output["requests"] = .array(await transport.requests)
    return .object(output)
  }

  static func publicCatalog(_ spec: [String: JSONValue]) async throws -> [JSONValue] {
    let models = spec.array("catalog")!.map { value -> CustomProviderModel in
      let raw = value.objectValue!
      return .init(
        id: raw.string("id")!, name: raw.string("name"), api: raw.string("api"),
        capabilities: .init(
          textInput: true, imageInput: false, toolCalling: false,
          reasoning: raw.bool("reasoning") ?? false, structuredOutput: false,
          imageGeneration: raw.string("type") == "image",
          classification: raw.string("type") == "classifier"),
        contextWindow: raw.int("contextWindow"), maximumOutputTokens: raw.int("maxTokens"),
        metadata: raw)
    }
    let provider = CustomProvider(
      id: "openrouter", baseURL: spec.string("baseURL").flatMap(URL.init(string:)),
      api: "openai-completions", models: models)
    let result = try await provider.personalizingOpenRouterCatalog(
      credential: credential(spec), transport: Transport(spec))
    return result.models.map { .object($0.metadata) }
  }

  actor Transport: ProviderHTTPTransport {
    let response: ProviderHTTPResponse
    var requests: [JSONValue] = []
    init(_ spec: [String: JSONValue]) throws {
      response = .init(
        statusCode: spec.int("status")!, headers: [:], body: try JSONEncoder().encode(spec["body"]!)
      )
    }
    func send(_ request: URLRequest) -> ProviderHTTPResponse {
      requests.append(
        .object([
          "url": .string(request.url!.absoluteString),
          "headers": .object(
            Dictionary(
              uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map {
                ($0.key.lowercased(), .string($0.value))
              })),
        ]))
      return response
    }
  }
}
