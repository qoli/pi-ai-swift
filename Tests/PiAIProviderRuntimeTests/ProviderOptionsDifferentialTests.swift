import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ProviderOptionsDifferentialTests {
  @Test
  func sessionHeadersAndCompatibilityOptionsMatchPinnedSource() async throws {
    let oracle = try decodeOracle()
    #expect(oracle.upstreamRevision == "d5629e20489ccf770ed90b5a33941cb3b7ef24d0")

    let openRouterCompletions = try await capture(
      protocolID: "openai-completions", providerID: "openrouter",
      baseURL: "https://openrouter.ai/api/v1")
    #expect(
      selectedHeaders(openRouterCompletions)
        == oracle.cases["openrouter-completions-session"]?.headers)

    let baseten = try await capture(
      protocolID: "openai-completions", providerID: "baseten",
      baseURL: "https://inference.baseten.co/v1",
      compat: ["sendSessionAffinityHeaders": .bool(true)])
    #expect(selectedHeaders(baseten) == oracle.cases["baseten-completions-session"]?.headers)

    let openRouterResponses = try await capture(
      protocolID: "openai-responses", providerID: "openrouter",
      baseURL: "https://openrouter.ai/api/v1")
    #expect(
      selectedHeaders(openRouterResponses)
        == oracle.cases["openrouter-responses-session"]?.headers)

    let openRouterAnthropic = try await capture(
      protocolID: "anthropic-messages", providerID: "openrouter",
      baseURL: "https://openrouter.ai/api/v1")
    #expect(
      selectedHeaders(openRouterAnthropic)
        == oracle.cases["openrouter-anthropic-session"]?.headers)

    let expectedOpenCode = oracle.cases["opencode-session-wrapper"]?.headers
    for protocolID in [
      "anthropic-messages", "google-generative-ai", "openai-completions", "openai-responses",
    ] {
      let captured = try await capture(
        protocolID: protocolID, providerID: "opencode",
        baseURL: "https://opencode.ai/zen/v1")
      #expect(
        captured.value(forHTTPHeaderField: "x-opencode-session")
          == expectedOpenCode?["x-opencode-session"])
    }

    let priority = try await capture(
      protocolID: "openai-completions", providerID: "fixture",
      baseURL: "https://fixture.invalid/v1", compat: ["vllmPriority": .integer(7)])
    let priorityBody = try body(priority)
    #expect(
      priorityBody["priority"]
        == oracle.cases["vllm-priority"]?.requestBody?["priority"])

    let maxDisabled = try await capture(
      protocolID: "openai-responses", providerID: "fixture",
      baseURL: "https://fixture.invalid/v1",
      compat: ["supportsMaxOutputTokens": .bool(false)])
    let maxDisabledBody = try body(maxDisabled)
    #expect(
      (maxDisabledBody["max_output_tokens"] != nil)
        == oracle.cases["responses-max-output-disabled"]?.requestBody?["maxOutputTokensPresent"]?
        .boolValue)
  }

  private func capture(
    protocolID: String,
    providerID: String,
    baseURL: String,
    compat: [String: JSONValue] = [:]
  ) async throws -> URLRequest {
    let model = ProviderModel(
      id: "fixture-model", providerID: providerID, name: "Fixture", protocolID: protocolID,
      capabilities: ProviderCapabilities(
        textInput: true, imageInput: false, toolCalling: true, reasoning: false,
        structuredOutput: true, imageGeneration: false),
      contextWindow: 128_000, maximumOutputTokens: 4_096)
    let context = WireProtocolContext(
      provider: ProviderDescriptor(
        id: providerID, name: providerID, authorizationMethods: [], models: [model]),
      model: model,
      baseURL: URL(string: baseURL)!,
      headers: [:],
      credential: .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:])),
      modelConfiguration: ProviderModelConfiguration(
        protocolID: protocolID, baseURL: nil, headers: [:],
        metadata: compat.isEmpty ? [:] : ["compat": .object(compat)]))
    let request = ProviderRequest(
      id: "provider-options", providerID: providerID, modelID: model.id,
      messages: [.system("system"), .user([.text("hello")])], tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 32, temperature: nil, reasoningEffort: nil,
        responseSchema: nil, providerOptions: [:], sessionID: "fixture-session",
        cacheRetention: .short))
    let transport = ProviderOptionsCaptureTransport()
    let adapter = try #require(
      StandardWireProtocols.make().first { $0.protocolID == protocolID })
    do {
      for try await _ in adapter.stream(request, context: context, transport: transport) {}
    } catch {
      // The transport terminates after capturing the exact outbound request.
    }
    return try #require(await transport.request())
  }

  private func selectedHeaders(_ request: URLRequest) -> [String: String] {
    let names = ["session_id", "x-client-request-id", "x-session-affinity", "x-session-id"]
    return Dictionary(
      uniqueKeysWithValues: names.compactMap { name in
        request.value(forHTTPHeaderField: name).map { (name, $0) }
      })
  }

  private func body(_ request: URLRequest) throws -> [String: JSONValue] {
    let data = try #require(request.httpBody)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    return try #require(decoded.objectValue)
  }

  private func decodeOracle() throws -> ProviderOptionsOracle {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try JSONDecoder().decode(
      ProviderOptionsOracle.self,
      from: Data(
        contentsOf: repository.appending(
          path: "Fixtures/Differential/Oracle/provider-options.json")))
  }
}

private actor ProviderOptionsCaptureTransport: ProviderHTTPStreamingTransport {
  private var captured: URLRequest?

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    return ProviderHTTPStreamingResponse(
      statusCode: 418, headers: [:],
      body: AsyncThrowingStream { continuation in continuation.finish() })
  }

  func request() -> URLRequest? { captured }
}

private struct ProviderOptionsOracle: Decodable {
  let upstreamRevision: String
  let cases: [String: ProviderOptionsObservation]
}

private struct ProviderOptionsObservation: Decodable {
  let headers: [String: String]?
  let requestBody: [String: JSONValue]?
}
