import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct CandidateCompletionsTests {
  @Test
  func candidateStrictDefaultsAndEmptyArrayTextMatchSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/CandidateCompletions/request.json")),
      providerID: "fixture", operation: "candidate.fixture")
    for entry in try #require(fixture.array("cases")) {
      let item = try #require(entry.objectValue)
      let expected = try #require(item.object("expected"))
      let content = try #require(item.array("content")).map { value -> ProviderUserContent in
        let part = value.objectValue!
        if part.string("type") == "text" { return .text(part.string("text")!) }
        return .image(.data(Data(base64Encoded: part.string("data")!)!, mimeType: "image/png"))
      }
      var compat: [String: JSONValue] = [:]
      if let strict = item.bool("strict") { compat["supportsStrictMode"] = .bool(strict) }
      let model = ProviderModel(
        id: "fixture-model", providerID: "fixture", name: "Fixture",
        protocolID: "openai-completions",
        capabilities: ProviderCapabilities(
          textInput: true, imageInput: true, toolCalling: true, reasoning: false,
          structuredOutput: true, imageGeneration: false),
        contextWindow: 32768, maximumOutputTokens: 4096)
      let context = WireProtocolContext(
        provider: ProviderDescriptor(
          id: "fixture", name: "Fixture", authorizationMethods: [], models: [model]),
        model: model, baseURL: URL(string: "https://fixture.invalid/v1")!, headers: [:],
        credential: .apiKey(APIKeyCredential(key: "fixture", metadata: [:])),
        modelConfiguration: ProviderModelConfiguration(
          protocolID: model.protocolID, baseURL: nil, headers: [:],
          metadata: ["compat": .object(compat)]))
      let request = ProviderRequest(
        id: "candidate", providerID: "fixture", modelID: model.id, messages: [.user(content)],
        tools: [
          ProviderToolDefinition(
            name: "lookup", description: "Lookup",
            inputSchema: .object([
              "type": .string("object"), "properties": .object([:]),
            ]))
        ],
        options: .init(
          maximumOutputTokens: nil, temperature: nil, reasoningEffort: nil, reasoningSummary: nil,
          responseSchema: nil, providerOptions: [:]))
      let transport = CandidateCompletionCapture()
      do {
        for try await _ in OpenAICompletionsAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch is ProviderRuntimeFailure {}
      let sent = try #require(await transport.request())
      let actual = try decodeJSONObject(
        try #require(sent.httpBody), providerID: "fixture", operation: "candidate.capture")
      #expect(actual["messages"] == expected["messages"])
      #expect(actual["tools"] == expected["tools"])
    }
  }
}

private actor CandidateCompletionCapture: ProviderHTTPStreamingTransport {
  private var captured: URLRequest?
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    return ProviderHTTPStreamingResponse(
      statusCode: 418, headers: [:], body: AsyncThrowingStream { $0.finish() })
  }
  func request() -> URLRequest? { captured }
}
