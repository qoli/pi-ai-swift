import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct BedrockInputInteropDifferentialTests {
  @Test
  func importedContentMatchesPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func load(_ path: String) throws -> [String: JSONValue] {
      try decodeJSONObject(
        Data(contentsOf: root.appending(path: path)), providerID: "fixture",
        operation: "input-interop")
    }
    let fixture = try load("Fixtures/Differential/Cases/bedrock-input-interop.json")
    let oracle = try load("Fixtures/Differential/Oracle/bedrock-input-interop.json")
    for value in try #require(fixture.array("cases")) {
      let spec = try #require(value.objectValue)
      let name = try #require(spec.string("id"))
      let blocks = try #require(spec.array("content")).map { try #require($0.objectValue) }
      let message: ProviderMessage
      if spec.string("role") == "user" {
        message = .user(
          try blocks.map { block in
            if let units = block["utf16"] {
              return .textUTF16(
                try JSONDecoder().decode([UInt16].self, from: JSONEncoder().encode(units)))
            }
            if block.string("type") == "text" { return .text(block.string("text") ?? "") }
            return .unrecognized(block)
          })
      } else {
        message = .assistant(
          try blocks.map { block in
            if let units = block["utf16"] {
              return .textUTF16(
                try JSONDecoder().decode([UInt16].self, from: JSONEncoder().encode(units)))
            }
            if block.string("type") == "text" { return .text(block.string("text") ?? "") }
            return .unrecognized(block)
          })
      }
      let capture = BedrockInputCapture()
      let runtime = try CustomProviderRuntime(
        providers: [
          .init(
            id: "amazon-bedrock", baseURL: URL(string: "https://fixture.invalid")!,
            api: "bedrock-converse-stream",
            models: [
              .init(
                id: "fixture-model",
                capabilities: .init(
                  textInput: true, imageInput: true, toolCalling: true, reasoning: false,
                  structuredOutput: false, imageGeneration: false))
            ])
        ],
        credentialStore: InMemoryProviderCredentialStore(credentials: [
          "amazon-bedrock": .apiKey(
            .init(
              key: "fixture", metadata: ["AWS_BEDROCK_SKIP_AUTH": "1", "AWS_REGION": "us-east-1"]))
        ]), streamingTransport: BedrockInputNoTransport(),
        wireObserver: .init(onPayload: { payload, _ in
          await capture.set(payload["messages"])
          throw BedrockInputCaptureComplete()
        }))
      let request = ProviderRequest(
        id: name, providerID: "amazon-bedrock", modelID: "fixture-model", messages: [message],
        tools: [],
        options: .init(
          maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil, responseSchema: nil,
          providerOptions: [:], cacheRetention: .none))
      do { for try await _ in runtime.stream(request) {} } catch {}
      #expect(await capture.messages == oracle.object("cases")?[name], Comment(rawValue: name))
    }
  }
}

private actor BedrockInputCapture {
  var messages: JSONValue?
  func set(_ value: JSONValue?) { messages = value }
}

private struct BedrockInputCaptureComplete: Error {}

private struct BedrockInputNoTransport: ProviderHTTPStreamingTransport {
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    Issue.record("Input capture must finish before transport")
    throw BedrockInputCaptureComplete()
  }
}
