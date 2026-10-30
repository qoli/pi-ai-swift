import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct AnthropicInlineToolDifferentialTests {
  @Test
  func inlineToolValuesAndStrictDowngradeMatchPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func load(_ path: String) throws -> [String: JSONValue] {
      try decodeJSONObject(
        Data(contentsOf: root.appending(path: path)), providerID: "fixture",
        operation: "inline-tools")
    }
    let fixture = try load("Fixtures/Differential/Cases/strict-fallback-inline.json")
    let oracle = try load("Fixtures/Differential/Oracle/strict-fallback-inline.json")
    for value in try #require(fixture.array("cases")) {
      let spec = try #require(value.objectValue)
      let name = try #require(spec.string("id"))
      let expected = try #require(oracle.object("cases")?.object(name))
      let model = ProviderModel(
        id: "fixture-claude", providerID: "anthropic", name: "Claude Fixture",
        protocolID: "anthropic-messages",
        capabilities: .init(
          textInput: true, imageInput: false, toolCalling: true, reasoning: false,
          structuredOutput: false, imageGeneration: false), contextWindow: 200_000,
        maximumOutputTokens: 100)
      var compat = spec.object("compat") ?? [:]
      compat["supportsStrictTools"] = .bool(true)
      let key = try #require(spec.string("apiKey"))
      let credential: ProviderCredential =
        key.contains("sk-ant-oat")
        ? .oauth(
          .init(accessToken: key, refreshToken: "", expiresAt: .distantFuture, metadata: [:]))
        : .apiKey(.init(key: key, metadata: [:]))
      var context = WireProtocolContext(
        provider: .init(
          id: "anthropic", name: "anthropic", authorizationMethods: [], models: [model]),
        model: model,
        baseURL: URL(string: "https://fixture.invalid")!, headers: [:],
        credential: credential,
        modelConfiguration: .init(
          protocolID: "anthropic-messages", baseURL: nil, headers: [:],
          metadata: [
            "compat": .object(compat),
            "cost": .object([
              "input": .integer(0), "output": .integer(0), "cacheRead": .integer(0),
              "cacheWrite": .integer(0),
            ]),
          ]))
      func tools(_ raw: [JSONValue]) throws -> [ProviderToolDefinition] {
        try raw.map { value in
          let tool = try #require(value.objectValue)
          return .init(
            name: try #require(tool.string("name")), description: tool.string("description") ?? "",
            inputSchema: try #require(tool["parameters"]),
            constrainedSampling: tool.object("constrainedSampling")?.string("strict").flatMap(
              ProviderStrictPreference.init(rawValue:)
            ).map { .jsonSchema(strict: $0) })
        }
      }
      let messages = try #require(spec.array("messages")).map { value -> ProviderMessage in
        let message = try #require(value.objectValue)
        switch message.string("role") {
        case "system":
          return .systemMessage(
            .init(
              content: message.string("content") ?? "",
              toolsAdded: try tools(message.array("toolsAdded") ?? []),
              toolsRemoved: (message.array("toolsRemoved") ?? []).compactMap {
                $0.objectValue?.string("name")
              }))
        case "assistant": return .assistant([])
        default: return .user([.text(message.string("content") ?? "")])
        }
      }
      let request = ProviderRequest(
        id: name, providerID: "anthropic", modelID: model.id, messages: messages,
        tools: try tools(spec.array("currentTools") ?? []),
        options: .init(
          maximumOutputTokens: 100, temperature: nil, reasoningEffort: nil, responseSchema: nil,
          providerOptions: [:],
          cacheRetention: spec.string("cacheRetention") == "none" ? .none : .short))
      let transport = InlineToolFixtureTransport(spec: spec)
      let payloads = InlineToolPayloadCapture()
      context.wireObserver = .init(onPayload: { payload, _ in
        await payloads.append(.object(payload))
        return nil
      })
      var completed = false
      do {
        for try await event in AnthropicMessagesAdapter().stream(
          request, context: context, transport: transport)
        {
          if case .completed = event { completed = true }
        }
      } catch { Issue.record("\(name): \(error)") }
      #expect(completed, Comment(rawValue: name))
      let actual = await payloads.values
      #expect(
        actual == expected.array("logicalPayloads"),
        Comment(
          rawValue:
            "\(name): \(firstRequestDifference(.array(actual), .array(expected.array("logicalPayloads") ?? [])))"
        ))
    }
  }
}

private actor InlineToolPayloadCapture {
  var values: [JSONValue] = []
  func append(_ value: JSONValue) { values.append(value) }
}

private actor InlineToolFixtureTransport: ProviderHTTPStreamingTransport {
  let spec: [String: JSONValue]
  var requests: [JSONValue] = []
  init(spec: [String: JSONValue]) { self.spec = spec }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    let index = requests.count
    requests.append(try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)))
    let failures = spec.array("failures") ?? []
    if index < failures.count, let failure = failures[index].objectValue {
      return .init(
        statusCode: try #require(failure.int("status")), headers: [:],
        body: AsyncThrowingStream {
          $0.yield(Data((failure.string("body") ?? "").utf8))
          $0.finish()
        })
    }
    let events = [
      #"{"type":"message_start","message":{"id":"msg_fixture","model":"fixture-claude","usage":{"input_tokens":0,"output_tokens":0}}}"#,
      #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}"#,
      #"{"type":"message_stop"}"#,
    ]
    let body = zip(["message_start", "message_delta", "message_stop"], events)
      .map { "event: \($0)\ndata: \($1)\n\n" }.joined()
    return .init(
      statusCode: 200, headers: [:],
      body: AsyncThrowingStream {
        $0.yield(Data(body.utf8))
        $0.finish()
      })
  }
}
