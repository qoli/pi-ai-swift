import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct SourceDerivedRequestDifferentialTests {
  @Test
  func everySupportedWireProtocolMatchesPinnedSourceRequestOracle() async throws {
    let repository = repositoryRoot()
    let fixture = try decode(
      RequestCase.self,
      at: repository.appending(path: "Fixtures/Differential/Cases/request-rich.json")
    )
    let oracle = try decode(
      RequestOracle.self,
      at: repository.appending(path: "Fixtures/Differential/Oracle/request-rich.json")
    )

    #expect(fixture.schemaVersion == 1)
    #expect(oracle.schemaVersion == 1)
    #expect(fixture.caseID == oracle.caseID)
    let expectedRevision = try pinnedRevision(repository: repository)
    #expect(oracle.upstreamRevision == expectedRevision)

    let expectedProtocols = StandardWireProtocols.supportedProtocolIDs
    #expect(Set(fixture.protocols.map(\.protocolID)) == expectedProtocols)
    #expect(Set(oracle.protocols.keys) == expectedProtocols)

    for protocolCase in fixture.protocols {
      let expected = try #require(oracle.protocols[protocolCase.protocolID])
      let actual = try await captureRequestBody(fixture: fixture, protocolCase: protocolCase)
      #expect(
        actual == expected.requestBody,
        "source-derived request drift for \(protocolCase.protocolID)"
      )
    }
  }

  @Test
  func sourceReplaySemanticsMatchForSameCrossAndAbortedAssistantMessages() async throws {
    let repository = repositoryRoot()
    let protocolFixture = try decode(
      RequestCase.self,
      at: repository.appending(path: "Fixtures/Differential/Cases/request-rich.json")
    )
    let fixture = try decode(
      ReplayRequestCase.self,
      at: repository.appending(path: "Fixtures/Differential/Cases/request-replay.json")
    )
    let oracle = try decode(
      ReplayRequestOracle.self,
      at: repository.appending(path: "Fixtures/Differential/Oracle/request-replay.json")
    )
    #expect(fixture.upstreamRevision == oracle.upstreamRevision)
    let protocols = protocolFixture.protocols.filter { $0.protocolID != "openrouter-images" }
    #expect(Set(protocols.map(\.protocolID)) == Set(oracle.protocolSet))
    for scenario in fixture.scenarios {
      let expectedScenario = try #require(oracle.scenarios[scenario.caseID])
      for protocolCase in protocols {
        guard let expected = expectedScenario[protocolCase.protocolID] else { continue }
        let actual = try await captureReplayRequestBody(
          scenario: scenario,
          protocolCase: protocolCase
        )
        if actual != expected.requestBody {
          let difference = firstRequestDifference(actual, expected.requestBody)
          Issue.record(
            "source-derived replay request drift for \(scenario.caseID)/\(protocolCase.protocolID): \(difference)"
          )
        }
      }
    }
  }

  private func captureRequestBody(
    fixture: RequestCase,
    protocolCase: RequestProtocolCase
  ) async throws -> JSONValue {
    let capture = RequestCaptureTransport()
    let model = ProviderModel(
      id: protocolCase.modelID,
      providerID: protocolCase.providerID,
      name: protocolCase.modelID,
      protocolID: protocolCase.protocolID,
      capabilities: ProviderCapabilities(
        textInput: true,
        imageInput: true,
        toolCalling: true,
        reasoning: protocolCase.reasoning,
        structuredOutput: true,
        imageGeneration: protocolCase.protocolID == "openrouter-images"
      ),
      contextWindow: 262_144,
      maximumOutputTokens: protocolCase.maximumOutputTokens
    )
    let context = WireProtocolContext(
      provider: ProviderDescriptor(
        id: protocolCase.providerID,
        name: protocolCase.providerID,
        authorizationMethods: [],
        models: [model]
      ),
      model: model,
      baseURL: URL(string: protocolCase.baseURL)!,
      headers: [:],
      credential: .apiKey(
        APIKeyCredential(key: credential(protocolID: protocolCase.protocolID), metadata: [:])
      ),
      modelConfiguration: ProviderModelConfiguration(
        protocolID: protocolCase.protocolID,
        baseURL: nil,
        headers: [:],
        metadata: configurationMetadata(protocolCase)
      )
    )
    let isImage = protocolCase.protocolID == "openrouter-images"
    let request = ProviderRequest(
      id: fixture.caseID,
      providerID: protocolCase.providerID,
      modelID: protocolCase.modelID,
      messages: isImage
        ? [.user([.text(fixture.userText)])]
        : [.system(fixture.systemPrompt), .user([.text(fixture.userText)])],
      tools: isImage
        ? []
        : [
          ProviderToolDefinition(
            name: fixture.tool.name,
            description: fixture.tool.description,
            inputSchema: fixture.tool.parameters
          )
        ],
      options: ProviderGenerationOptions(
        maximumOutputTokens: isImage ? nil : fixture.options.maximumOutputTokens,
        temperature: isImage ? nil : fixture.options.temperature,
        reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: providerOptions(protocolID: protocolCase.protocolID),
        outputModality: isImage ? .image : .text,
        sessionID: fixture.options.sessionID,
        cacheRetention: ProviderCacheRetention(rawValue: fixture.options.cacheRetention)!,
        toolChoice: isImage ? nil : .string(fixture.options.toolChoice)
      )
    )

    do {
      let adapter = try #require(
        StandardWireProtocols.make().first { $0.protocolID == protocolCase.protocolID }
      )
      for try await _ in adapter.stream(request, context: context, transport: capture) {}
    } catch {
      // The capture transport deliberately returns HTTP 418 after retaining the request.
    }
    let captured = try #require(await capture.request())
    let body = try #require(captured.httpBody)
    return try JSONDecoder().decode(JSONValue.self, from: body)
  }

  private func credential(protocolID: String) -> String {
    guard protocolID == "openai-codex-responses" else { return "fixture-key" }
    return
      "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiZml4dHVyZS1hY2NvdW50In19.fixture"
  }

  private func captureReplayRequestBody(
    scenario: ReplayScenario,
    protocolCase: RequestProtocolCase
  ) async throws -> JSONValue {
    let capture = RequestCaptureTransport()
    let model = ProviderModel(
      id: protocolCase.modelID,
      providerID: protocolCase.providerID,
      name: protocolCase.modelID,
      protocolID: protocolCase.protocolID,
      capabilities: ProviderCapabilities(
        textInput: true,
        imageInput: true,
        toolCalling: true,
        reasoning: scenario.reasoningEffort != nil ? true : protocolCase.reasoning,
        structuredOutput: true,
        imageGeneration: false
      ),
      contextWindow: 262_144,
      maximumOutputTokens: protocolCase.maximumOutputTokens
    )
    let context = WireProtocolContext(
      provider: ProviderDescriptor(
        id: protocolCase.providerID,
        name: protocolCase.providerID,
        authorizationMethods: [],
        models: [model]
      ),
      model: model,
      baseURL: URL(string: protocolCase.baseURL)!,
      headers: [:],
      credential: .apiKey(
        APIKeyCredential(key: credential(protocolID: protocolCase.protocolID), metadata: [:])
      ),
      modelConfiguration: ProviderModelConfiguration(
        protocolID: protocolCase.protocolID,
        baseURL: nil,
        headers: [:],
        metadata: replayConfigurationMetadata(protocolCase, scenario: scenario)
      )
    )
    let signatures = replaySignatures(protocolID: protocolCase.protocolID)
    let source = ProviderMessageSource(
      api: scenario.sameSource ? protocolCase.protocolID : "different-api",
      providerID: scenario.sameSource ? protocolCase.providerID : "different-provider",
      modelID: scenario.sameSource ? protocolCase.modelID : "different-model"
    )
    let stopReason = ProviderAssistantStopReason(
      rawValue: scenario.assistantStopReason ?? "toolUse")!
    var assistantContent: [ProviderAssistantContent] = [
      .signedText(ProviderTextContent(text: "answer", signature: signatures.text)),
      .reasoning(
        ProviderReasoningContent(
          text: "private analysis",
          signature: signatures.thinking,
          isRedacted: scenario.redactedReasoning,
          providerMetadata: [:]
        )),
    ]
    if scenario.consecutiveToolResults == true {
      assistantContent.append(
        .toolCall(
          ProviderToolCall(
            id: "call-second",
            name: "weather2",
            arguments: .object(["city": .string("Tokyo")])
          )))
    }
    assistantContent.append(
      .toolCall(
        ProviderToolCall(
          id: signatures.toolID,
          name: "weather",
          arguments: .object(["city": .string("Taipei")]),
          thoughtSignature: signatures.tool,
          namespace: "fixture.namespace"
        )))
    let assistant = ProviderAssistantMessage(
      content: assistantContent,
      source: source,
      responseID: "prior-response",
      responseModelID: "concrete-prior-model",
      usage: ProviderUsage(
        inputTokens: 1,
        outputTokens: 2,
        reasoningTokens: 1,
        cachedInputTokens: 0,
        cacheWriteTokens: 0,
        totalTokens: 3,
        providerMetadata: [:]
      ),
      stopReason: stopReason,
      rawStopReason: "tool_use",
      timestampMilliseconds: 1
    )
    var messages: [ProviderMessage] = [
      .system("Replay exactly"),
      .user(
        scenario.imageInput == true
          ? [.text("First turn"), .image(.data(Data([1, 2]), mimeType: "image/png"))]
          : [.text("First turn")]
      ),
      .assistantMessage(assistant),
    ]
    if scenario.omitToolResult != true {
      messages.append(
        .toolResult(
          ProviderToolResult(
            toolCallID: signatures.toolID,
            toolName: "weather",
            content: scenario.toolResultImage == true
              ? [.text("sunny"), .image(.data(Data([1, 2]), mimeType: "image/png"))]
              : [.text("sunny")],
            isError: scenario.toolResultError == true,
            addedToolNames: scenario.addedToolNames,
            timestampMilliseconds: 2
          )))
      if scenario.consecutiveToolResults == true {
        messages.append(
          .toolResult(
            ProviderToolResult(
              toolCallID: "call-second",
              toolName: "weather2",
              content: [.text("rain")],
              isError: false,
              timestampMilliseconds: 3
            )))
      }
    }
    if scenario.appendUserAfterAssistant == true {
      messages.append(
        .userMessage(
          ProviderUserMessage(content: [.text("Continue")], timestampMilliseconds: 3)))
    }
    let request = ProviderRequest(
      id: scenario.caseID,
      providerID: protocolCase.providerID,
      modelID: protocolCase.modelID,
      messages: messages,
      tools: [
        ProviderToolDefinition(
          name: "weather",
          description: "Read weather",
          inputSchema: replayToolSchema(scenario.toolSchema),
          constrainedSampling: replayConstrainedSampling(scenario.constrainedSampling)
        )
      ]
        + (scenario.consecutiveToolResults == true
          ? [
            ProviderToolDefinition(
              name: "weather2",
              description: "Read another weather report",
              inputSchema: replayToolSchema(nil)
            )
          ]
          : [])
        + ((scenario.addedToolNames ?? []).contains("lookup")
          ? [
            ProviderToolDefinition(
              name: "lookup",
              description: "Look up a place",
              inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                  "query": .object(["type": .string("string")])
                ]),
                "required": .array([.string("query")]),
              ])
            )
          ]
          : []),
      options: ProviderGenerationOptions(
        maximumOutputTokens: scenario.omitMaximumOutputTokens == true ? nil : 64,
        temperature: scenario.temperature,
        reasoningEffort: scenario.reasoningEffort.flatMap(ProviderReasoningEffort.init(rawValue:)),
        responseSchema: nil,
        providerOptions: providerOptions(protocolID: protocolCase.protocolID),
        sessionID: scenario.sessionID,
        cacheRetention: ProviderCacheRetention(rawValue: scenario.cacheRetention ?? "none")!,
        toolChoice: scenario.toolChoice.map(JSONValue.string)
      )
    )
    do {
      let adapter = try #require(
        StandardWireProtocols.make().first { $0.protocolID == protocolCase.protocolID }
      )
      for try await _ in adapter.stream(request, context: context, transport: capture) {}
    } catch {
      // The capture transport deliberately returns HTTP 418 after retaining the request.
    }
    let captured = try #require(
      await capture.request(),
      "request was rejected before capture for \(scenario.caseID)/\(protocolCase.protocolID)"
    )
    return try JSONDecoder().decode(JSONValue.self, from: try #require(captured.httpBody))
  }

  private func replaySignatures(
    protocolID: String
  ) -> (text: String?, thinking: String?, tool: String?, toolID: String) {
    if ["openai-responses", "azure-openai-responses", "openai-codex-responses"].contains(protocolID)
    {
      return (
        #"{"v":1,"id":"msg_prior","phase":"final_answer"}"#,
        #"{"type":"reasoning","id":"rs_prior","summary":[{"type":"summary_text","text":"private analysis"}],"encrypted_content":"encrypted"}"#,
        nil,
        "call_prior|fc_prior"
      )
    }
    if ["google-generative-ai", "google-vertex"].contains(protocolID) {
      return ("dGV4dA==", "dGhpbms=", "dG9vbA==", "call-prior")
    }
    if protocolID == "openai-completions" {
      return (nil, "reasoning_content", nil, "call-prior")
    }
    return ("opaque-text", "opaque-thinking", "opaque-tool", "call-prior")
  }

  private func replayConstrainedSampling(_ value: String?) -> ProviderConstrainedSampling? {
    switch value {
    case "strict-prefer": return .jsonSchema(strict: .prefer)
    case "strict-require": return .jsonSchema(strict: .require)
    case "grammar": return .grammar(variants: ["openai_lark": "start: /[a-z]+/"])
    case "grammar-regex": return .grammar(variants: ["openai_regex": "[a-z]+"])
    default: return nil
    }
  }

  private func replayToolSchema(_ value: String?) -> JSONValue {
    if value == "root-ref" {
      return .object([
        "$ref": .string("#/$defs/input"),
        "$defs": .object([
          "input": .object([
            "type": .string("object"),
            "properties": .object([
              "city": .object(["type": .string("string")])
            ]),
            "required": .array([.string("city")]),
          ])
        ]),
      ])
    }
    return .object([
      "type": .string("object"),
      "properties": .object(["city": .object(["type": .string("string")])]),
      "required": .array([.string("city")]),
    ])
  }

  private func replayConfigurationMetadata(
    _ protocolCase: RequestProtocolCase,
    scenario: ReplayScenario
  ) -> [String: JSONValue] {
    var metadata = configurationMetadata(protocolCase)
    var compat = metadata["compat"]?.objectValue ?? [:]
    if scenario.forceStrictSupport == true { compat["supportsStrictMode"] = .bool(true) }
    if scenario.forceGrammarSupport == true {
      compat["supportsOpenAIGrammarTools"] = .bool(true)
    }
    if !compat.isEmpty { metadata["compat"] = .object(compat) }
    return metadata
  }

  private func configurationMetadata(
    _ protocolCase: RequestProtocolCase
  ) -> [String: JSONValue] {
    var metadata: [String: JSONValue] = [:]
    if let compat = protocolCase.compat {
      metadata["compat"] = .object(compat)
    }
    if protocolCase.protocolID == "google-vertex" {
      metadata["project"] = .string("fixture-project")
      metadata["location"] = .string("us-central1")
    }
    if let output = protocolCase.output {
      metadata["output"] = .array(output.map(JSONValue.string))
    }
    return metadata
  }

  private func providerOptions(protocolID: String) -> [String: JSONValue] {
    guard protocolID == "google-vertex" else { return [:] }
    return [
      "project": .string("fixture-project"),
      "location": .string("us-central1"),
    ]
  }
}

private actor RequestCaptureTransport: ProviderHTTPStreamingTransport {
  private var captured: URLRequest?

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    return ProviderHTTPStreamingResponse(
      statusCode: 418,
      headers: [:],
      body: AsyncThrowingStream { continuation in continuation.finish() }
    )
  }

  func request() -> URLRequest? { captured }
}

private struct RequestCase: Decodable {
  let schemaVersion: Int
  let caseID: String
  let systemPrompt: String
  let userText: String
  let tool: RequestTool
  let options: RequestOptions
  let protocols: [RequestProtocolCase]
}

private struct RequestTool: Decodable {
  let name: String
  let description: String
  let parameters: JSONValue
}

private struct RequestOptions: Decodable {
  let maximumOutputTokens: Int
  let temperature: Double
  let sessionID: String
  let cacheRetention: String
  let toolChoice: String
}

private struct RequestProtocolCase: Decodable {
  let protocolID: String
  let providerID: String
  let modelID: String
  let baseURL: String
  let reasoning: Bool
  let maximumOutputTokens: Int
  let compat: [String: JSONValue]?
  let output: [String]?
}

private struct RequestOracle: Decodable {
  let schemaVersion: Int
  let caseID: String
  let upstreamRevision: String
  let protocols: [String: RequestOracleProtocol]
}

private struct RequestOracleProtocol: Decodable {
  let requestBody: JSONValue
}

private struct ReplayRequestCase: Decodable {
  let upstreamRevision: String
  let scenarios: [ReplayScenario]
}

private struct ReplayScenario: Decodable {
  let caseID: String
  let sameSource: Bool
  let assistantStopReason: String?
  let redactedReasoning: Bool?
  let omitToolResult: Bool?
  let appendUserAfterAssistant: Bool?
  let reasoningEffort: String?
  let cacheRetention: String?
  let sessionID: String?
  let toolChoice: String?
  let imageInput: Bool?
  let toolResultImage: Bool?
  let toolResultError: Bool?
  let consecutiveToolResults: Bool?
  let addedToolNames: [String]?
  let constrainedSampling: String?
  let toolSchema: String?
  let protocolIDs: [String]?
  let forceStrictSupport: Bool?
  let forceGrammarSupport: Bool?
  let temperature: Double?
  let omitMaximumOutputTokens: Bool?
}

private struct ReplayRequestOracle: Decodable {
  let upstreamRevision: String
  let protocolSet: [String]
  let scenarios: [String: [String: RequestOracleProtocol]]
}

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

private func decode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
  try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

private func pinnedRevision(repository: URL) throws -> String {
  struct Lock: Decodable { let revision: String }
  return try decode(Lock.self, at: repository.appending(path: "Upstream.lock.json")).revision
}

private func firstRequestDifference(
  _ actual: JSONValue,
  _ expected: JSONValue,
  path: String = "$"
) -> String {
  switch (actual, expected) {
  case (.object(let lhs), .object(let rhs)):
    let keys = Set(lhs.keys).union(rhs.keys).sorted()
    for key in keys {
      guard let left = lhs[key] else { return "\(path).\(key) missing from Swift output" }
      guard let right = rhs[key] else { return "\(path).\(key) is unexpected in Swift output" }
      if left != right { return firstRequestDifference(left, right, path: "\(path).\(key)") }
    }
  case (.array(let lhs), .array(let rhs)):
    if lhs.count != rhs.count { return "\(path) count Swift=\(lhs.count) source=\(rhs.count)" }
    for index in lhs.indices where lhs[index] != rhs[index] {
      return firstRequestDifference(lhs[index], rhs[index], path: "\(path)[\(index)]")
    }
  default:
    return "\(path) Swift=\(actual) source=\(expected)"
  }
  return "unknown difference"
}
