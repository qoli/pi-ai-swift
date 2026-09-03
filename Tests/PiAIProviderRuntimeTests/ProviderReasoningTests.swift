import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ProviderReasoningTests {
  // Pinned pi 853a80d: models.ts getSupportedThinkingLevels and types.ts ThinkingLevelMap.
  @Test
  func missingNullAndExtendedLevelsHaveDistinctMeanings() throws {
    #expect(try ProviderReasoning.supportedEfforts(reasoning: false, metadata: [:]) == [.off])
    #expect(
      try ProviderReasoning.supportedEfforts(reasoning: true, metadata: [:])
        == [.off, .minimal, .low, .medium, .high])
    #expect(
      try ProviderReasoning.supportedEfforts(
        reasoning: true,
        metadata: [
          "thinkingLevelMap": .object([
            "off": .null, "minimal": .null, "medium": .null,
            "xhigh": .null, "max": .string("max"),
          ])
        ]
      ) == [.low, .high, .max])
  }

  @Test
  func malformedMapsFailInsteadOfAdvertisingGuessedOptions() {
    for map: JSONValue in [
      .string("high"), .object(["high": .integer(42)]),
      .object(["unknown": .string("high")]), .object(["high": .string("")]),
    ] {
      #expect(throws: ProviderRuntimeFailure.self) {
        try ProviderReasoning.supportedEfforts(
          reasoning: true, metadata: ["thinkingLevelMap": map])
      }
    }
  }

  @Test
  func effortCodableRejectsUnknownValuesAndPreservesOff() throws {
    for effort in ProviderReasoningEffort.allCases {
      #expect(
        try JSONDecoder().decode(
          ProviderReasoningEffort.self, from: JSONEncoder().encode(effort)) == effort)
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ProviderReasoningEffort.self, from: Data("\"typo\"".utf8))
    }
  }

  @Test(arguments: ["gemini-3-flash-preview", "gemini-2.5-pro"])
  func googleMinimumThinkingIsNotAdvertisedAsDisabled(modelID: String) throws {
    let efforts = try ProviderReasoning.supportedEfforts(
      reasoning: true, metadata: [:], protocolID: "google-generative-ai",
      modelID: modelID)
    #expect(!efforts.contains(.off))
    #expect(efforts.contains(.high))
  }

  @Test
  func catalogProjectsModelSpecificChoicesAndRoundTrips() throws {
    let registry = try BuiltinProviderRegistry.load()
    let kimi = try #require(registry.providers.first { $0.id == "kimi-coding" })
    let model = try #require(kimi.models.first { $0.id == "k3-256k" })
    #expect(model.supportedReasoningEfforts == [.low, .high, .max])
    #expect(
      try JSONDecoder().decode(
        ProviderModel.self, from: JSONEncoder().encode(model)) == model)
    let openai = try #require(registry.providers.first { $0.id == "openai" })
    let gpt = try #require(openai.models.first { $0.id == "gpt-5.2" })
    #expect(gpt.supportedReasoningEfforts == [.off, .low, .medium, .high, .xhigh])
  }

  @Test
  func unsupportedSelectionFailsBeforeCredentialResolution() async throws {
    let runtime = try CustomProviderRuntime(
      providers: [
        CustomProvider(
          id: "fixture", baseURL: URL(string: "https://example.invalid/v1")!,
          api: "openai-responses",
          models: [
            CustomProviderModel(
              id: "model",
              capabilities: ProviderCapabilities(
                textInput: true, imageInput: false, toolCalling: true, reasoning: true,
                structuredOutput: true, imageGeneration: false),
              metadata: ["thinkingLevelMap": .object(["off": .null, "max": .null])])
          ])
      ],
      credentialStore: InMemoryProviderCredentialStore())
    let model = try #require(try await runtime.catalog().providers.first?.models.first)
    #expect(!model.supportedReasoningEfforts.contains(.off))
    for effort: ProviderReasoningEffort? in [.off, .max, nil] {
      let request = ProviderRequest(
        id: "fixture", providerID: "fixture", modelID: "model",
        messages: [.user([.text("hello")])], tools: [],
        options: .init(
          maximumOutputTokens: 64, temperature: nil,
          reasoningEffort: effort, responseSchema: nil, providerOptions: [:]))
      do {
        for try await _ in runtime.stream(request) {}
        Issue.record("request should fail before transport")
      } catch let failure as ProviderRuntimeFailure {
        #expect(failure.code == (effort == nil ? .missingCredential : .unsupportedCapability))
        if effort != nil { #expect(failure.operation == "stream.validate-reasoning") }
      }
    }
  }
}
