import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct AnthropicCandidateUsageDifferentialTests {
  @Test
  func deltaCacheTTLPreservesMissingAndNullAndAcceptsZeroAtEveryEvent() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let decoder = JSONDecoder()
    let fixture = try decoder.decode(
      CandidateTTLCase.self,
      from: Data(
        contentsOf: root.appending(
          path: "Fixtures/Differential/Cases/anthropic-candidate-cache-ttl.json")))
    let oracle = try decoder.decode(
      CandidateTTLOracle.self,
      from: Data(
        contentsOf: root.appending(
          path: "Fixtures/Differential/Oracle/anthropic-candidate-cache-ttl.json")))
    #expect(fixture.upstreamRevision == oracle.upstreamRevision)
    let model = ProviderModel(
      id: "claude-fixture", providerID: "anthropic", name: "fixture",
      protocolID: "anthropic-messages",
      capabilities: ProviderCapabilities(
        textInput: true, imageInput: false, toolCalling: false, reasoning: false,
        structuredOutput: false, imageGeneration: false), contextWindow: 200_000,
      maximumOutputTokens: 4096)
    let context = WireProtocolContext(
      provider: ProviderDescriptor(
        id: "anthropic", name: "anthropic", authorizationMethods: [], models: [model]),
      model: model, baseURL: URL(string: "https://fixture.invalid")!, headers: [:],
      credential: .oauth(
        OAuthCredential(
          accessToken: "sk-ant-oat01-synthetic-fixture", refreshToken: "",
          expiresAt: Date(timeIntervalSince1970: 4_102_444_800), metadata: [:])),
      modelConfiguration: ProviderModelConfiguration(
        protocolID: "anthropic-messages", baseURL: nil, headers: [:],
        metadata: [
          "cost": .object([
            "input": .integer(1_000_000), "output": .integer(2_000_000),
            "cacheRead": .integer(3_000_000), "cacheWrite": .integer(4_000_000),
          ])
        ]))
    let transport = CandidateTTLTransport(frames: fixture.frames)
    let request = ProviderRequest(
      id: "ttl", providerID: "anthropic", modelID: model.id, messages: [.user([.text("hello")])],
      tools: [],
      options: .init(
        maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil, responseSchema: nil,
        providerOptions: [:]))
    var latestUsage: ProviderUsage?
    var snapshots: [ProviderUsage] = []
    var terminal: ProviderResponseSnapshot?
    for try await event in AnthropicMessagesAdapter().stream(
      request, context: context, transport: transport)
    {
      switch event {
      case .usage(let usage): latestUsage = usage
      case .textDelta: snapshots.append(try #require(latestUsage))
      case .responseSnapshot(let snapshot):
        terminal = snapshot
        snapshots.append(try #require(snapshot.usage))
      default: break
      }
    }
    #expect(await transport.userAgent == oracle.userAgent)
    #expect(snapshots.count == oracle.observations.count)
    for (actual, expected) in zip(snapshots, oracle.observations) {
      #expect(actual.inputTokens == expected.usage.input)
      #expect(actual.outputTokens == expected.usage.output)
      #expect(actual.cachedInputTokens == expected.usage.cacheRead)
      #expect(actual.cacheWriteTokens == expected.usage.cacheWrite)
      #expect(actual.totalTokens == expected.usage.totalTokens)
      #expect(actual.cost == expected.usage.cost)
    }
    #expect(
      snapshots.dropLast().map { $0.providerMetadata }
        == fixture.frames.compactMap {
          guard $0.objectValue?.string("type") == "message_delta" else { return nil }
          return $0.objectValue?.object("usage")
        })
    #expect(terminal?.finishReason == .stop)
    #expect(try terminal?.replayAssistantMessage().usage == terminal?.usage)
  }
}

private struct CandidateTTLCase: Decodable {
  let upstreamRevision: String
  let frames: [JSONValue]
}
private struct CandidateTTLOracle: Decodable {
  let upstreamRevision: String
  let userAgent: String
  let observations: [Observation]
  struct Observation: Decodable {
    let usage: Usage
  }
  struct Usage: Decodable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let totalTokens: Int
    let cost: ProviderUsageCost
  }
}
private actor CandidateTTLTransport: ProviderHTTPStreamingTransport {
  let frames: [JSONValue]
  var userAgent: String?
  init(frames: [JSONValue]) { self.frames = frames }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    userAgent = request.value(forHTTPHeaderField: "User-Agent")
    let chunks = try frames.map { frame in
      Data("data: \(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self))\n\n".utf8)
    }
    return ProviderHTTPStreamingResponse(
      statusCode: 200, headers: ["content-type": "text/event-stream"],
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      })
  }
}
