import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct SourceDerivedSecondaryRequestDifferentialTests {
  @Test
  func piMistralAndOpenRouterRequestBranchesMatchPinnedSource() async throws {
    let repository = secondaryRepositoryRoot()
    let fixture = try secondaryDecode(
      SecondaryRequestCase.self,
      at: repository.appending(path: "Fixtures/Differential/Cases/request-secondary.json")
    )
    let oracle = try secondaryDecode(
      SecondaryRequestOracle.self,
      at: repository.appending(path: "Fixtures/Differential/Oracle/request-secondary.json")
    )
    #expect(fixture.upstreamRevision == oracle.upstreamRevision)
    #expect(Set(fixture.cases.map(\.caseID)) == Set(oracle.cases.keys))
    for item in fixture.cases {
      let expected = try #require(oracle.cases[item.caseID])
      let actual = try await capture(item)
      #expect(
        actual.requestBody == expected.requestBody,
        "secondary source request drift for \(item.caseID)"
      )
      if let expectedURL = expected.url { #expect(actual.url == expectedURL) }
      #expect((actual.headers ?? [:]) == (expected.headers ?? [:]))
    }
  }

  private func capture(_ item: SecondaryRequestItem) async throws -> SecondaryRequestObservation {
    let model = secondaryModel(item.caseID, protocolID: item.protocolID)
    let providerID = model.providerID
    let metadata: [String: JSONValue] =
      item.protocolID == "openrouter-images"
      ? [
        "output": .array(
          (item.caseID == "openrouter-image-text-output" ? ["image", "text"] : ["image"])
            .map(JSONValue.string))
      ] : [:]
    let context = WireProtocolContext(
      provider: ProviderDescriptor(
        id: providerID, name: providerID, authorizationMethods: [], models: [model]),
      model: model,
      baseURL: secondaryBaseURL(item.protocolID),
      headers: [:],
      credential: .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:])),
      modelConfiguration: ProviderModelConfiguration(
        protocolID: item.protocolID, baseURL: nil, headers: [:], metadata: metadata)
    )
    let request = secondaryRequest(item.caseID, model: model)
    let transport = SecondaryRequestCaptureTransport()
    do {
      let adapter = try #require(
        StandardWireProtocols.make().first { $0.protocolID == item.protocolID })
      for try await _ in adapter.stream(request, context: context, transport: transport) {}
    } catch {
      // The transport deliberately returns 418 after retaining the request.
    }
    let captured = try #require(await transport.request())
    let body = try JSONDecoder().decode(JSONValue.self, from: try #require(captured.httpBody))
    let headers: [String: String]
    if let affinity = captured.value(forHTTPHeaderField: "x-affinity") {
      headers = ["x-affinity": affinity]
    } else {
      headers = [:]
    }
    return SecondaryRequestObservation(
      protocolID: item.protocolID,
      url: item.protocolID == "pi-messages" ? captured.url?.absoluteString : nil,
      headers: headers,
      requestBody: body
    )
  }

  private func secondaryModel(_ caseID: String, protocolID: String) -> ProviderModel {
    switch protocolID {
    case "pi-messages":
      return ProviderModel(
        id: "fixture-pi", providerID: "radius", name: "Fixture Pi", protocolID: protocolID,
        capabilities: secondaryCapabilities(reasoning: true, image: true),
        contextWindow: 128_000, maximumOutputTokens: 4_096)
    case "mistral-conversations":
      let effort = caseID.contains("reasoning-effort")
      let reasoning = effort || caseID == "mistral-prompt-mode"
      let modelID =
        caseID == "mistral-medium-reasoning-effort"
        ? "mistral-medium-2606"
        : caseID == "mistral-zai-reasoning-effort"
          ? "zai-glm-5-2"
          : effort ? "mistral-small-2603" : "mistral-fixture"
      return ProviderModel(
        id: modelID,
        providerID: "mistral", name: effort ? "Mistral Small" : "Mistral Fixture",
        protocolID: protocolID,
        capabilities: secondaryCapabilities(
          reasoning: reasoning, image: !caseID.contains("unsupported")),
        contextWindow: 128_000, maximumOutputTokens: 4_096)
    default:
      return ProviderModel(
        id: "openrouter/fixture-image", providerID: "openrouter", name: "Fixture Image",
        protocolID: protocolID,
        capabilities: ProviderCapabilities(
          textInput: true, imageInput: true, toolCalling: false, reasoning: false,
          structuredOutput: false, imageGeneration: true),
        contextWindow: 0, maximumOutputTokens: nil)
    }
  }

  private func secondaryCapabilities(reasoning: Bool, image: Bool) -> ProviderCapabilities {
    ProviderCapabilities(
      textInput: true, imageInput: image, toolCalling: true, reasoning: reasoning,
      structuredOutput: false, imageGeneration: false)
  }

  private func secondaryBaseURL(_ protocolID: String) -> URL {
    switch protocolID {
    case "pi-messages": URL(string: "https://radius.invalid/v1")!
    case "mistral-conversations": URL(string: "https://api.mistral.ai")!
    default: URL(string: "https://openrouter.ai/api/v1")!
    }
  }

  private func secondaryRequest(_ caseID: String, model: ProviderModel) -> ProviderRequest {
    switch model.protocolID {
    case "pi-messages": piRequest(caseID, model: model)
    case "mistral-conversations": mistralRequest(caseID, model: model)
    default: openRouterRequest(caseID, model: model)
    }
  }

  private func piRequest(_ caseID: String, model: ProviderModel) -> ProviderRequest {
    let full = caseID == "pi-full-context"
    var messages: [ProviderMessage] = [
      .system("Keep metadata"),
      .userMessage(ProviderUserMessage(content: [.text("First")], timestampMilliseconds: 11)),
    ]
    if full {
      messages.append(
        .assistantMessage(
          ProviderAssistantMessage(
            content: [
              .signedText(ProviderTextContent(text: "answer", signature: "text-signature")),
              .reasoning(
                ProviderReasoningContent(
                  text: "analysis", signature: "thinking-signature", isRedacted: nil,
                  providerMetadata: [:])),
              .toolCall(
                ProviderToolCall(
                  id: "call-1", name: "weather",
                  arguments: .object(["city": .string("Taipei")]),
                  thoughtSignature: "tool-signature", namespace: "fixture.namespace")),
            ],
            source: ProviderMessageSource(
              api: "pi-messages", providerID: "radius", modelID: "fixture-pi"),
            responseID: "response-1", responseModelID: "fixture-pi-runtime",
            usage: ProviderUsage(
              inputTokens: 1, outputTokens: 2, reasoningTokens: 1, cachedInputTokens: 3,
              cacheWriteTokens: 4, totalTokens: 10, providerMetadata: [:]),
            stopReason: .toolUse, rawStopReason: "tool_use", timestampMilliseconds: 12)))
      messages.append(
        .toolResult(
          ProviderToolResult(
            toolCallID: "call-1", toolName: "weather", content: [.text("sunny")],
            isError: false, addedToolNames: ["lookup"], timestampMilliseconds: 13)))
    }
    return ProviderRequest(
      id: caseID, providerID: model.providerID, modelID: model.id, messages: messages,
      tools: [
        ProviderToolDefinition(
          name: "weather", description: "Weather", inputSchema: secondarySchema("city"),
          constrainedSampling: .jsonSchema(strict: .prefer)),
        ProviderToolDefinition(
          name: "lookup", description: "Lookup", inputSchema: secondarySchema("query")),
      ],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 96, temperature: 0.25, reasoningEffort: .high,
        responseSchema: nil,
        providerOptions: caseID == "pi-debug-query" ? ["debug": .bool(true)] : [:],
        sessionID: "pi-session", cacheRetention: .short, toolChoice: .string("auto")))
  }

  private func mistralRequest(_ caseID: String, model: ProviderModel) -> ProviderRequest {
    var messages: [ProviderMessage] = [.system("Be concise"), .user([.text("Hello")])]
    if caseID == "mistral-image-unsupported" {
      messages = [
        .system("Be concise"), .user([.image(.data(Data([1, 2]), mimeType: "image/png"))]),
      ]
    } else if caseID == "mistral-tool-image-unsupported-error" {
      messages.append(
        .assistantMessage(
          ProviderAssistantMessage(
            content: [
              .toolCall(
                ProviderToolCall(
                  id: "call-1", name: "weather",
                  arguments: .object(["city": .string("Taipei")])))
            ],
            source: ProviderMessageSource(
              api: "mistral-conversations", providerID: "mistral", modelID: "mistral-fixture"),
            responseID: nil, responseModelID: nil,
            usage: ProviderUsage(
              inputTokens: 0, outputTokens: 0, reasoningTokens: nil, cachedInputTokens: 0,
              cacheWriteTokens: 0, totalTokens: 0, providerMetadata: [:]),
            stopReason: .toolUse, rawStopReason: nil, timestampMilliseconds: 2)))
      messages.append(
        .toolResult(
          ProviderToolResult(
            toolCallID: "call-1", toolName: "weather",
            content: [.text("failed"), .image(.data(Data([1, 2]), mimeType: "image/png"))],
            isError: true, timestampMilliseconds: 3)))
    }
    let reasoning: ProviderReasoningEffort? =
      (caseID.contains("reasoning-effort") || caseID == "mistral-prompt-mode") ? .high : nil
    let cache: ProviderCacheRetention = caseID == "mistral-cache-long" ? .long : .none
    let sessionID = caseID == "mistral-cache-long" ? "mistral-session" : nil
    let toolChoice: JSONValue?
    if caseID == "mistral-tool-choice-any" {
      toolChoice = .string("any")
    } else if caseID == "mistral-tool-choice-required" {
      toolChoice = .string("required")
    } else if caseID == "mistral-tool-choice-named" {
      toolChoice = .object([
        "type": .string("function"),
        "function": .object(["name": .string("weather")]),
      ])
    } else {
      toolChoice = nil
    }
    return ProviderRequest(
      id: caseID, providerID: model.providerID, modelID: model.id, messages: messages,
      tools: [
        ProviderToolDefinition(
          name: "weather", description: "Weather", inputSchema: secondarySchema("city"))
      ],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 64, temperature: nil, reasoningEffort: reasoning,
        responseSchema: nil, providerOptions: [:], sessionID: sessionID,
        cacheRetention: cache, toolChoice: toolChoice))
  }

  private func openRouterRequest(_ caseID: String, model: ProviderModel) -> ProviderRequest {
    let input: [ProviderUserContent]
    if caseID == "openrouter-empty-input" {
      input = []
    } else if caseID == "openrouter-mixed-input" {
      input = [.text("Draw"), .image(.data(Data([1, 2]), mimeType: "image/png"))]
    } else if caseID == "openrouter-image-input" {
      input = [.image(.data(Data([1, 2]), mimeType: "image/png"))]
    } else {
      input = [.text("Draw")]
    }
    return ProviderRequest(
      id: caseID, providerID: model.providerID, modelID: model.id,
      messages: [.user(input)], tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: nil, temperature: nil, reasoningEffort: nil,
        responseSchema: nil, providerOptions: [:], outputModality: .image))
  }

  private func secondarySchema(_ name: String) -> JSONValue {
    .object([
      "type": .string("object"),
      "properties": .object([name: .object(["type": .string("string")])]),
      "required": .array([.string(name)]),
    ])
  }
}

private actor SecondaryRequestCaptureTransport: ProviderHTTPStreamingTransport {
  private var captured: URLRequest?
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    return ProviderHTTPStreamingResponse(
      statusCode: 418, headers: [:],
      body: AsyncThrowingStream { continuation in continuation.finish() })
  }
  func request() -> URLRequest? { captured }
}

private struct SecondaryRequestCase: Decodable {
  let upstreamRevision: String
  let cases: [SecondaryRequestItem]
}
private struct SecondaryRequestItem: Decodable {
  let caseID: String
  let protocolID: String
}
private struct SecondaryRequestOracle: Decodable {
  let upstreamRevision: String
  let cases: [String: SecondaryRequestObservation]
}
private struct SecondaryRequestObservation: Decodable {
  let protocolID: String
  let url: String?
  let headers: [String: String]?
  let requestBody: JSONValue

  init(protocolID: String, url: String?, headers: [String: String], requestBody: JSONValue) {
    self.protocolID = protocolID
    self.url = url
    self.headers = headers
    self.requestBody = requestBody
  }
}

private func secondaryRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
private func secondaryDecode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
  try JSONDecoder().decode(type, from: Data(contentsOf: url))
}
