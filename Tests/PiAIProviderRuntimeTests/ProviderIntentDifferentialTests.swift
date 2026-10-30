import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ProviderIntentDifferentialTests {
  @Test
  func candidateProviderRequestsMatchExactSourceIntent() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let input = try JSONDecoder().decode(
      Input.self,
      from: Data(
        contentsOf:
          root.appending(path: "Fixtures/Differential/Cases/provider-intent.json")))
    let oracle = try JSONDecoder().decode(
      Oracle.self,
      from: Data(
        contentsOf:
          root.appending(path: "Fixtures/Differential/Oracle/provider-intent.json")))
    #expect(input.upstreamRevision == oracle.upstreamRevision)
    #expect(Set(input.cases.map(\.id)) == Set(oracle.cases.keys))
    for spec in input.cases {
      let raw = spec.model
      let api = try #require(raw.string("api"))
      let provider = try #require(raw.string("provider"))
      let id = try #require(raw.string("id"))
      let model = ProviderModel(
        id: id, providerID: provider, name: raw.string("name") ?? id, protocolID: api,
        capabilities: .init(
          textInput: true, imageInput: true, toolCalling: true,
          reasoning: raw.bool("reasoning") == true, structuredOutput: false, imageGeneration: false),
        contextWindow: raw.int("contextWindow"), maximumOutputTokens: raw.int("maxTokens"))
      let context = WireProtocolContext(
        provider: .init(id: provider, name: provider, authorizationMethods: [], models: [model]),
        model: model, baseURL: URL(string: try #require(raw.string("baseUrl")))!, headers: [:],
        credential: .apiKey(.init(key: spec.apiKey ?? "sk-fixture", metadata: [:])),
        modelConfiguration: .init(protocolID: api, baseURL: nil, headers: [:], metadata: raw))
      var messages: [ProviderMessage] = [.user([.text("hello")])]
      if spec.history == true {
        messages.append(
          .assistantMessage(
            .init(
              content: [.text("answer")],
              source: .init(api: api, providerID: provider, modelID: id),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: nil,
                cachedInputTokens: 0, providerMetadata: [:]),
              stopReason: .stop, timestampMilliseconds: 1,
              providerMetadata: ["providerThinkingLevel": .string("low")])))
        messages.append(.user([.text("again")]))
      }
      let options = spec.options ?? [:]
      let effort =
        options.string("reasoningEffort") ?? options.string("reasoning")
        ?? (options.bool("thinkingEnabled") == false || spec.explicitOff == true ? "off" : nil)
      let request = ProviderRequest(
        id: spec.id, providerID: provider, modelID: id, messages: messages,
        tools: try (spec.tools ?? []).map {
          .init(
            name: try #require($0.string("name")), description: $0.string("description") ?? "",
            inputSchema: try #require($0["parameters"]))
        },
        options: .init(
          maximumOutputTokens: 4096,
          temperature: options["temperature"].flatMap {
            if case .number(let value) = $0 { return value }
            if case .integer(let value) = $0 { return Double(value) }
            return nil
          },
          reasoningEffort: effort.flatMap(ProviderReasoningEffort.init(rawValue:)),
          responseSchema: nil,
          providerOptions: options["samplingParams"].map { ["samplingParams": $0] } ?? [:],
          sessionID: options.string("sessionId"),
          cacheRetention: options.string("cacheRetention").flatMap(
            ProviderCacheRetention.init(rawValue:)) ?? .none),
        connectionOptions: .init(
          azureOpenAIResponses: options.string("azureDeploymentName").map {
            .init(azureResourceName: options.string("azureResourceName"), azureDeploymentName: $0)
          }))
      let transport = IntentCaptureTransport()
      let adapter = try #require(StandardWireProtocols.make().first { $0.protocolID == api })
      do {
        for try await _ in adapter.stream(request, context: context, transport: transport) {}
      } catch {
        if await transport.body == nil { throw error }
      }
      let actual = try #require(await transport.body, Comment(rawValue: spec.id))
      let expected = try #require(oracle.cases[spec.id]?.requestBody)
      if actual != expected {
        Issue.record("\(spec.id): \(firstRequestDifference(actual, expected))")
      }
    }
  }

  private struct Input: Decodable {
    let upstreamRevision: String
    let cases: [Spec]
  }
  private struct Spec: Decodable {
    let id: String
    let model: [String: JSONValue]
    let options: [String: JSONValue]?
    let history: Bool?
    let explicitOff: Bool?
    let apiKey: String?
    let tools: [[String: JSONValue]]?
  }
  private struct Oracle: Decodable {
    let upstreamRevision: String
    let cases: [String: Observation]
  }
  private struct Observation: Decodable { let requestBody: JSONValue }
}

private actor IntentCaptureTransport: ProviderHTTPStreamingTransport {
  var body: JSONValue?
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
    throw CancellationError()
  }
}
