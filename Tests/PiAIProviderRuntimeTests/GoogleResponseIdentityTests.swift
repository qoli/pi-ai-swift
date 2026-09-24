import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct GoogleResponseIdentityTests {
  @Test
  func identityAtEmissionMatchesSourceWithEarlyLateAndMissingIDs() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/GoogleResponseIdentity/identity.json")),
      providerID: "fixture", operation: "identity.fixture")
    for entry in try #require(fixture.array("cases")) {
      let item = try #require(entry.objectValue)
      let protocolID = try #require(item.string("protocolID"))
      let vertex = protocolID == "google-vertex"
      let providerID = vertex ? "google-vertex" : "google"
      let model = ProviderModel(
        id: "gemini-fixture", providerID: providerID, name: "Fixture", protocolID: protocolID,
        capabilities: ProviderCapabilities(
          textInput: true, imageInput: false, toolCalling: false, reasoning: false,
          structuredOutput: false, imageGeneration: false),
        contextWindow: 32768, maximumOutputTokens: 4096)
      let context = WireProtocolContext(
        provider: ProviderDescriptor(
          id: providerID, name: "Fixture", authorizationMethods: [], models: [model]),
        model: model, baseURL: URL(string: "https://fixture.invalid")!, headers: [:],
        credential: .apiKey(APIKeyCredential(key: "fixture", metadata: [:])),
        modelConfiguration: ProviderModelConfiguration(
          protocolID: protocolID, baseURL: nil, headers: [:], metadata: [:]))
      let request = ProviderRequest(
        id: "identity", providerID: providerID, modelID: model.id,
        messages: [.user([.text("hello")])], tools: [],
        options: .init(
          maximumOutputTokens: nil, temperature: nil, reasoningEffort: nil, responseSchema: nil,
          providerOptions: [:]))
      let frames = try #require(item.array("chunks")).map { chunk in
        "data: " + String(data: try JSONEncoder().encode(chunk), encoding: .utf8)! + "\n\n"
      }
      var start: [String: JSONValue]?
      var terminal: [String: JSONValue]?
      for try await event in GoogleGenerativeAIAdapter(
        protocolID: protocolID, flavor: vertex ? .vertex : .generativeAI
      ).stream(
        request, context: context,
        transport: GoogleIdentityTransport(bytes: Data(frames.joined().utf8)))
      {
        switch event {
        case .responseStarted(let metadata):
          start = [
            "responseID": metadata.responseID.map(JSONValue.string) ?? .null,
            "modelID": .string(metadata.modelID),
          ]
        case .responseSnapshot(let snapshot):
          terminal = [
            "responseID": snapshot.responseID.map(JSONValue.string) ?? .null,
            "modelID": .string(snapshot.modelID),
          ]
        default: break
        }
      }
      #expect(start == item.object("start"))
      #expect(terminal == item.object("terminal"))
    }
  }
}

private struct GoogleIdentityTransport: ProviderHTTPStreamingTransport {
  let bytes: Data
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    ProviderHTTPStreamingResponse(
      statusCode: 200, headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.yield(bytes)
        continuation.finish()
      })
  }
}
