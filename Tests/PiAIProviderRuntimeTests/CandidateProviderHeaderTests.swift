import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct CandidateProviderHeaderTests {
  @Test
  func googleDispatchPreservesSourceCaseInsensitiveScopePrecedence() async throws {
    struct Oracle: Decodable {
      struct Case: Decodable {
        let id: String
        let sources: [[String: String?]]
        let result: [String: String]?
      }
      let cases: [Case]
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let oracle = try JSONDecoder().decode(
      Oracle.self,
      from: Data(
        contentsOf:
          root.appending(path: "Fixtures/Differential/Oracle/candidate-provider-headers.json")))
    let fixture = try #require(oracle.cases.first { $0.id == "cross-scope" })
    let expected = try #require(fixture.result)
    let model = ProviderModel(
      id: "gemini-fixture", providerID: "fixture", name: "fixture",
      protocolID: "google-generative-ai",
      capabilities: ProviderCapabilities(
        textInput: true,
        imageInput: false, toolCalling: false, reasoning: false, structuredOutput: false,
        imageGeneration: false), contextWindow: 1000, maximumOutputTokens: 100)
    let config = ProviderModelConfiguration(
      protocolID: model.protocolID, baseURL: nil,
      headers: fixture.sources[1].compactMapValues { $0 },
      metadata: [
        "cost": .object([
          "input": .integer(1), "output": .integer(2),
          "cacheRead": .integer(0), "cacheWrite": .integer(0),
        ])
      ])
    let provider = ProviderDefinition(
      descriptor: ProviderDescriptor(
        id: "fixture", name: "fixture",
        authorizationMethods: [], models: [model]), baseURL: "https://fixture.invalid",
      headers: fixture.sources[0].compactMapValues { $0 },
      modelConfigurations: [
        ProviderModelRoute(modelID: model.id, outputModality: .text): config
      ],
      credentialRequirement: .required,
      authorization: APIKeyAuthorizationAdapter(
        providerID: "fixture", methodID: "api-key", label: "key"))
    let recorder = CandidateHeaderRecorder()
    let runtime = try ProviderRuntimeKernel(
      catalogRevision: "candidate", providers: [provider],
      wireProtocols: [CandidateGoogleHeaderAdapter(recorder: recorder)],
      credentialStore: InMemoryProviderCredentialStore(credentials: [
        "fixture": .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:]))
      ]),
      transport: recorder)
    let request = ProviderRequest(
      id: "headers", providerID: "fixture", modelID: model.id,
      messages: [.user([.text("hello")])], tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil, responseSchema: nil,
        providerOptions: [:]))
    for try await _ in runtime.stream(request) {}
    #expect(await recorder.dispatched == expected)
    let sent = try #require(await recorder.sent)
    for (name, value) in expected { #expect(sent.value(forHTTPHeaderField: name) == value) }
  }
}

private struct CandidateGoogleHeaderAdapter: WireProtocolAdapter {
  let protocolID = "google-generative-ai"
  let recorder: CandidateHeaderRecorder
  func stream(
    _ request: ProviderRequest, context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport
  ) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await recorder.record(context.headers)
        do {
          for try await event in GoogleGenerativeAIAdapter().stream(
            request, context: context, transport: transport)
          {
            continuation.yield(event)
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
private actor CandidateHeaderRecorder: ProviderHTTPStreamingTransport {
  var dispatched: [String: String]?
  var sent: URLRequest?
  func record(_ headers: [String: String]) { dispatched = headers }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    sent = request
    let data = Data(
      #"data: {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}"#
        .utf8)
    return ProviderHTTPStreamingResponse(
      statusCode: 200, headers: ["content-type": "text/event-stream"],
      body: AsyncThrowingStream { continuation in
        continuation.yield(data + Data("\n\n".utf8))
        continuation.finish()
      })
  }
}
