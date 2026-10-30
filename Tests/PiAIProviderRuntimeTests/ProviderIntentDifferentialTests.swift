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
      let options = spec.options ?? [:]
      if spec.operation == "googleThinkingLevel" {
        let expected = try #require(oracle.cases[spec.id])
        let effort = try #require(
          options.string("reasoningEffort").flatMap(ProviderReasoningEffort.init(rawValue:)))
        do {
          let actual = try GoogleGenerativeAIAdapter.resolveThinkingLevel(
            effort: effort, providerID: provider, modelID: id, metadata: raw)
          #expect(expected.error == nil, Comment(rawValue: spec.id))
          #expect(actual == expected.resolvedLevel, Comment(rawValue: spec.id))
        } catch let failure as ProviderRuntimeFailure {
          #expect(failure.message == expected.error, Comment(rawValue: spec.id))
        }
        continue
      }
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
      let initialContent: [ProviderUserContent] = try
        (spec.userContent ?? [
          ["type": .string("text"), "text": .string("hello")]
        ]).map { block in
          if block.string("type") == "text" { return .text(block.string("text") ?? "") }
          let encoded = try #require(block.string("data"))
          let data = try #require(Data(base64Encoded: encoded))
          return .image(.data(data, mimeType: try #require(block.string("mimeType"))))
        }
      var messages: [ProviderMessage] = [.user(initialContent)]
      if spec.history == true {
        messages.append(
          .assistantMessage(
            .init(
              content: (spec.assistantContent ?? [
                ["type": .string("text"), "text": .string("answer")]
              ]).map { block in
                if block.string("type") == "toolCall" {
                  return .toolCall(
                    .init(
                      id: block.string("id")!, name: block.string("name")!,
                      arguments: block["arguments"]!,
                      thoughtSignature: block.string("thoughtSignature")))
                }
                if block.string("type") == "thinking" {
                  return .reasoning(
                    .init(
                      text: block.string("thinking") ?? "",
                      signature: block.string("thinkingSignature"), providerMetadata: [:]))
                }
                return .signedText(
                  .init(text: block.string("text") ?? "", signature: block.string("textSignature")))
              },
              source: .init(
                api: spec.assistantSource?.string("api") ?? api,
                providerID: spec.assistantSource?.string("provider") ?? provider,
                modelID: spec.assistantSource?.string("model") ?? id),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: nil,
                cachedInputTokens: 0, providerMetadata: [:]),
              stopReason: .stop, timestampMilliseconds: 1,
              providerMetadata: ["providerThinkingLevel": .string("low")])))
        if let blocks = spec.toolResultContent {
          let content: [ProviderToolResultContent] = try blocks.map { block in
            if block.string("type") == "text" { return .text(block.string("text") ?? "") }
            let encoded = try #require(block.string("data"))
            let data = try #require(Data(base64Encoded: encoded))
            return .image(.data(data, mimeType: try #require(block.string("mimeType"))))
          }
          messages.append(
            .toolResult(
              .init(
                toolCallID: "call_1", toolName: "read", content: content,
                isError: spec.toolResultIsError ?? false, timestampMilliseconds: 2)))
        } else if let text = spec.toolResultText {
          messages.append(
            .toolResult(
              .init(
                toolCallID: "call_1", toolName: "read", content: [.text(text)], isError: false,
                timestampMilliseconds: 2)))
        }
        if spec.omitFollowup != true { messages.append(.user([.text("again")])) }
      }
      let effort =
        spec.rawOptions == true
        ? nil
        : options.string("reasoningEffort") ?? options.string("reasoning")
          ?? (options.bool("thinkingEnabled") == false || spec.explicitOff == true ? "off" : nil)
      var providerOptions = options.filter { ["samplingParams", "thinking"].contains($0.key) }
      if spec.rawOptions == true {
        for key in spec.rawOptionKeys ?? ["thinkingEnabled", "thinkingBudgetTokens", "effort"] {
          providerOptions[key] = options[key] ?? .null
        }
      }
      let request = ProviderRequest(
        id: spec.id, providerID: provider, modelID: id, messages: messages,
        tools: try (spec.tools ?? []).map {
          .init(
            name: try #require($0.string("name")), description: $0.string("description") ?? "",
            inputSchema: try spec.toolParametersJSON.map {
              try JSONValue(jsonData: Data($0.utf8))
            }
              ?? #require($0["parameters"]),
            constrainedSampling: $0.object("constrainedSampling")?.string("strict").flatMap(
              ProviderStrictPreference.init(rawValue:)
            ).map {
              .jsonSchema(strict: $0)
            })
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
          providerOptions: providerOptions,
          sessionID: options.string("sessionId"),
          cacheRetention: options.string("cacheRetention").flatMap(
            ProviderCacheRetention.init(rawValue:)) ?? .none,
          thinkingBudgets: options.object("thinkingBudgets").map { values in
            Dictionary(
              uniqueKeysWithValues: values.compactMap {
                key, value -> (ProviderReasoningEffort, Int)? in
                guard let effort = ProviderReasoningEffort(rawValue: key),
                  case .integer(let budget) = value
                else { return nil }
                return (effort, Int(budget))
              })
          }),
        connectionOptions: .init(
          azureOpenAIResponses: options.string("azureDeploymentName").map {
            .init(azureResourceName: options.string("azureResourceName"), azureDeploymentName: $0)
          }))
      let transport = IntentCaptureTransport()
      let adapter = try #require(StandardWireProtocols.make().first { $0.protocolID == api })
      var failure: ProviderRuntimeFailure?
      var providerThinkingLevel: String?
      do {
        for try await _ in adapter.stream(request, context: context, transport: transport) {}
      } catch {
        providerThinkingLevel = (error as? ProviderRuntimeFailure)?.providerMetadata?.string(
          "providerThinkingLevel")
        if await transport.body == nil {
          failure = try #require(error as? ProviderRuntimeFailure)
        }
      }
      let observation = try #require(oracle.cases[spec.id])
      if spec.rawOptions == true {
        #expect(
          providerThinkingLevel == observation.providerThinkingLevel, Comment(rawValue: spec.id))
      }
      if let expectedError = observation.error {
        #expect(await transport.body == nil, Comment(rawValue: spec.id))
        #expect(failure?.message == expectedError, Comment(rawValue: spec.id))
        continue
      }
      if let failure { throw failure }
      var actual = try #require(await transport.body, Comment(rawValue: spec.id))
      if let fields = spec.projectFields {
        actual = .object(
          Dictionary(
            uniqueKeysWithValues: fields.compactMap { key in
              actual.objectValue?[key].map { (key, $0) }
            }))
      } else if api.hasPrefix("google-") {
        actual = .object([
          "thinkingConfig": actual.objectValue?.object("generationConfig")?["thinkingConfig"]
            ?? .null
        ])
      }
      let expected = try #require(observation.requestBody)
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
    let operation: String?
    let model: [String: JSONValue]
    let options: [String: JSONValue]?
    let history: Bool?
    let explicitOff: Bool?
    let apiKey: String?
    let tools: [[String: JSONValue]]?
    let assistantContent: [[String: JSONValue]]?
    let assistantSource: [String: JSONValue]?
    let projectFields: [String]?
    let rawOptions: Bool?
    let rawOptionKeys: [String]?
    let toolResultText: String?
    let omitFollowup: Bool?
    let toolResultContent: [[String: JSONValue]]?
    let toolResultIsError: Bool?
    let userContent: [[String: JSONValue]]?
    let toolParametersJSON: String?
  }
  private struct Oracle: Decodable {
    let upstreamRevision: String
    let cases: [String: Observation]
  }
  private struct Observation: Decodable {
    let requestBody: JSONValue?
    let resolvedLevel: String?
    let error: String?
    let providerThinkingLevel: String?
  }
}

private actor IntentCaptureTransport: ProviderHTTPStreamingTransport {
  var body: JSONValue?
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
    throw ProviderRuntimeFailure(
      code: .transportFailed, message: "fixture request captured", providerID: nil,
      operation: "fixture.capture", causeDescription: nil)
  }
}
