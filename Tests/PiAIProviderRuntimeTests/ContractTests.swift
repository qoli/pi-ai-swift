import Foundation
import Testing

@testable import PiAIProviderRuntime

func fixtureMetadataWithCost(
  _ metadata: [String: JSONValue] = [:]
) -> [String: JSONValue] {
  var result = metadata
  if result["cost"] == nil {
    result["cost"] = .object([
      "input": .integer(0), "output": .integer(0),
      "cacheRead": .integer(0), "cacheWrite": .integer(0),
    ])
  }
  return result
}

@Suite
struct ContractTests {
  @Test
  func structuredRequestRoundTripsWithoutFlatteningRolesOrTools() throws {
    let request = ProviderRequest(
      id: "request-1",
      providerID: "openai-codex",
      modelID: "gpt-codex",
      messages: [
        .system("Do not flatten this conversation."),
        .user([
          .text("[assistant] is user data, not a role marker."),
          .image(.data(Data([0x89, 0x50]), mimeType: "image/png")),
        ]),
        .assistant([
          .toolCall(
            .init(
              id: "call-1",
              name: "lookup",
              arguments: .object(["query": .string("swift")])
            )
          )
        ]),
        .toolResult(
          .init(
            toolCallID: "call-1",
            toolName: "lookup",
            content: [.text("result")],
            isError: false
          )
        ),
      ],
      tools: [
        .init(
          name: "lookup",
          description: "Look up a value.",
          inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("query")]),
          ])
        )
      ],
      options: .init(
        maximumOutputTokens: 512,
        temperature: nil,
        reasoningEffort: .high,
        responseSchema: nil,
        providerOptions: [:]
      )
    )

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ProviderRequest.self, from: data)

    #expect(decoded == request)
    #expect(decoded.messages.count == 4)
  }

  @Test
  func normalizedEventsRoundTripWithPartialToolInput() throws {
    let events: [ProviderEvent] = [
      .responseStarted(
        .init(
          responseID: "response-1",
          providerID: "kimi-coding",
          modelID: "k3",
          providerMetadata: [:]
        )
      ),
      .reasoningDelta("inspect"),
      .reasoningSignatureDelta("opaque-signature"),
      .textDelta("hello"),
      .toolCallStarted(id: "call-1", name: "fetch"),
      .toolInputDelta(id: "call-1", delta: #"{"url":"https://"#),
      .toolInputDelta(id: "call-1", delta: #"example.com"}"#),
      .toolCallCompleted(
        .init(
          id: "call-1",
          name: "fetch",
          arguments: .object([
            "url": .string("https://example.com")
          ])
        )
      ),
      .usage(
        .init(
          inputTokens: 10,
          outputTokens: 4,
          reasoningTokens: 2,
          cachedInputTokens: nil,
          providerMetadata: [:]
        )
      ),
      .completed(.toolCalls),
    ]

    let data = try JSONEncoder().encode(events)
    let decoded = try JSONDecoder().decode([ProviderEvent].self, from: data)

    #expect(decoded == events)
  }

  @Test
  func responseSnapshotEventRoundTripsWithReplayState() throws {
    let snapshot = replayableSnapshot(
      content: [
        .text(
          ProviderTextContent(
            text: "answer",
            signature: #"{"v":1,"id":"message-1","phase":"final_answer"}"#,
            providerMetadata: ["phase": .string("final_answer")]
          )),
        .reasoning(
          ProviderReasoningContent(
            text: "inspect",
            signature: "opaque-reasoning",
            isRedacted: false,
            providerMetadata: ["kind": .string("summary")]
          )),
        .toolCall(
          ProviderToolCall(
            id: "call-1|item-1",
            name: "lookup",
            arguments: .object(["query": .string("Swift")]),
            thoughtSignature: "opaque-thought",
            namespace: "research",
            providerMetadata: ["kind": .string("function")]
          )),
      ]
    )
    let event = ProviderEvent.responseSnapshot(snapshot)

    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(ProviderEvent.self, from: data)

    #expect(decoded == event)
  }

  @Test
  func providerToolCallDecodesLegacyJSONWithoutReplayOptionals() throws {
    let argumentsData = try JSONEncoder().encode(
      JSONValue.object(["query": .string("Swift")])
    )
    let arguments = try JSONSerialization.jsonObject(with: argumentsData)
    let legacyData = try JSONSerialization.data(
      withJSONObject: [
        "id": "call-legacy",
        "name": "lookup",
        "arguments": arguments,
      ]
    )

    let decoded = try JSONDecoder().decode(ProviderToolCall.self, from: legacyData)

    #expect(decoded.id == "call-legacy")
    #expect(decoded.name == "lookup")
    #expect(decoded.arguments == .object(["query": .string("Swift")]))
    #expect(decoded.thoughtSignature == nil)
    #expect(decoded.namespace == nil)
    #expect(decoded.providerMetadata == nil)
  }

  @Test
  func richUserAndAssistantMessagesRoundTripWithoutLosingReplayMetadata() throws {
    let messages: [ProviderMessage] = [
      .userMessage(
        ProviderUserMessage(
          content: [
            .text("inspect this image"),
            .image(.data(Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")),
            .image(
              .remoteURL(
                URL(string: "https://example.invalid/image.jpg")!,
                mimeType: "image/jpeg"
              )),
          ],
          timestampMilliseconds: 1_725_000_000_000
        )),
      .assistantMessage(
        ProviderAssistantMessage(
          content: [
            .signedText(
              ProviderTextContent(
                text: "result",
                signature: "opaque-text",
                providerMetadata: ["phase": .string("final_answer")]
              )),
            .reasoning(
              ProviderReasoningContent(
                text: "[Reasoning redacted]",
                signature: "opaque-reasoning",
                isRedacted: true,
                providerMetadata: ["encrypted": .bool(true)]
              )),
            .toolCall(
              ProviderToolCall(
                id: "call-1|item-1",
                name: "lookup",
                arguments: .object(["query": .string("Swift")]),
                thoughtSignature: "opaque-thought",
                namespace: "research",
                providerMetadata: ["custom": .bool(true)]
              )),
          ],
          source: ProviderMessageSource(
            api: "openai-responses",
            providerID: "openai",
            modelID: "gpt-test"
          ),
          responseID: "response-1",
          responseModelID: "gpt-test-2026-09-19",
          usage: replayUsage(),
          stopReason: .toolUse,
          rawStopReason: "completed",
          timestampMilliseconds: 1_725_000_000_001,
          providerMetadata: ["endTurn": .bool(true)]
        )),
    ]

    let data = try JSONEncoder().encode(messages)
    let decoded = try JSONDecoder().decode([ProviderMessage].self, from: data)

    #expect(decoded == messages)
  }

  @Test
  func responseSnapshotRejectsAssetReplayAsAssistantMessage() {
    let snapshot = replayableSnapshot(
      content: [
        .asset(
          ProviderAsset(
            id: "image-1",
            kind: .image,
            mimeType: "image/png",
            data: Data([0x89, 0x50]),
            providerMetadata: [:]
          ))
      ]
    )

    expectReplayFailure(snapshot, code: .unsupportedCapability, messageContains: "image response")
  }

  @Test
  func responseSnapshotRejectsReplayWithoutUsage() {
    let snapshot = ProviderResponseSnapshot(
      responseID: "response-1",
      providerID: "openai",
      protocolID: "openai-responses",
      modelID: "gpt-test",
      responseModelID: nil,
      content: [.text(ProviderTextContent(text: "answer", signature: nil))],
      usage: nil,
      finishReason: .stop,
      rawFinishReason: "completed",
      timestampMilliseconds: 1_725_000_000_000
    )

    expectReplayFailure(snapshot, code: .invalidResponse, messageContains: "missing usage")
  }

  @Test
  func responseSnapshotRejectsNonReplayableFinishReasons() {
    for finishReason in [ProviderFinishReason.contentFilter, .cancelled] {
      let snapshot = replayableSnapshot(
        content: [.text(ProviderTextContent(text: "answer", signature: nil))],
        finishReason: finishReason
      )

      expectReplayFailure(
        snapshot,
        code: .invalidResponse,
        messageContains: "non-replayable finish reason: \(finishReason.rawValue)"
      )
    }
  }

  @Test
  func unknownEventFailsDecodingInsteadOfProducingSubstituteOutput() {
    let data = Data(#"[{"unknown":{"_0":"value"}}]"#.utf8)

    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode([ProviderEvent].self, from: data)
    }
  }

  @Test
  func providerUsageCostRoundTripsAndLegacyJSONWithoutCostStillDecodes() throws {
    let usage = ProviderUsage(
      inputTokens: 7,
      outputTokens: 5,
      reasoningTokens: 2,
      cachedInputTokens: 3,
      cacheWriteTokens: 1,
      totalTokens: 16,
      providerMetadata: ["source": .string("fixture")],
      cost: ProviderUsageCost(
        input: 0.007,
        output: 0.05,
        cacheRead: 0.0003,
        cacheWrite: 0.001,
        total: 0.0583))
    let roundTrip = try JSONDecoder().decode(
      ProviderUsage.self, from: JSONEncoder().encode(usage))
    #expect(roundTrip == usage)

    let legacy = Data(
      #"{"inputTokens":7,"outputTokens":5,"reasoningTokens":2,"cachedInputTokens":3,"cacheWriteTokens":1,"totalTokens":16,"providerMetadata":{"source":"fixture"}}"#
        .utf8)
    let decodedLegacy = try JSONDecoder().decode(ProviderUsage.self, from: legacy)
    #expect(decodedLegacy.cost == nil)
    #expect(decodedLegacy.inputTokens == 7)
    #expect(decodedLegacy.providerMetadata["source"] == .string("fixture"))
  }

  @Test
  func multipleSystemMessagesFailAtTheCallerAssembledRequestSeam() throws {
    let request = ProviderRequest(
      id: "multiple-system-explicit-failure",
      providerID: "fixture",
      modelID: "fixture-model",
      messages: [.system("first"), .system("second"), .user([.text("hello")])],
      tools: [],
      options: .init(
        maximumOutputTokens: nil,
        temperature: nil,
        reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: [:]
      )
    )

    do {
      try request.validateSingleSystemMessage(operation: "fixture.request.system")
      Issue.record("multiple system messages unexpectedly passed request-seam validation")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .invalidRequest)
      #expect(failure.operation == "fixture.request.system")
      #expect(failure.message.contains("one caller-assembled current system prompt"))
    }
  }

  @Test
  func runtimeSurfacesUnsupportedProviderAsAnExplicitStreamFailure() async {
    let runtime = UnsupportedRuntime()
    let request = ProviderRequest(
      id: "request-unsupported",
      providerID: "unknown",
      modelID: "unknown",
      messages: [.user([.text("hello")])],
      tools: [],
      options: .init(
        maximumOutputTokens: nil,
        temperature: nil,
        reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: [:]
      )
    )

    do {
      for try await _ in runtime.stream(request) {
        Issue.record("unsupported provider emitted a valid-looking event")
      }
      Issue.record("unsupported provider stream completed successfully")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .unsupportedProvider)
      #expect(error.providerID == "unknown")
    } catch {
      Issue.record("unexpected error type: \(error)")
    }
  }

  @Test
  func upstreamLockPinsExactPiPackageAndBuiltInProviderInventory() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let lockURL = repositoryRoot.appendingPathComponent("Upstream.lock.json")
    let mappingURL = repositoryRoot.appendingPathComponent(
      "UpstreamMappings/pi-ai.json"
    )
    let lock = try JSONDecoder().decode(
      UpstreamLock.self,
      from: Data(contentsOf: lockURL)
    )

    #expect(lock.schemaVersion == 4)
    #expect(lock.revision.count == 40)
    #expect(lock.package.name == "@earendil-works/pi-ai")
    #expect(lock.package.version == "0.87.1")
    #expect(lock.trackedBuiltinProviders.count == 42)
    #expect(lock.trackedBuiltinProviders.contains("github-copilot"))
    #expect(lock.trackedBuiltinProviders.contains("xai"))
    #expect(lock.trackedBuiltinProviders.contains("deepseek"))
    #expect(lock.trackedBuiltinProviders.contains("qwen-token-plan"))
    #expect(lock.trackedBuiltinProviders.contains("meta"))
    #expect(!lock.requiredSourcePaths.isEmpty)
    let mapping = try JSONDecoder().decode(
      UpstreamMapping.self,
      from: Data(contentsOf: mappingURL)
    )
    #expect(mapping.schemaVersion == 3)
    #expect(mapping.areas.count == 65)
    #expect(mapping.areas.allSatisfy { !$0.dependsOn.contains($0.id) })
  }
}

private func replayUsage() -> ProviderUsage {
  ProviderUsage(
    inputTokens: 7,
    outputTokens: 5,
    reasoningTokens: 2,
    cachedInputTokens: 3,
    cacheWriteTokens: 1,
    totalTokens: 16,
    providerMetadata: ["source": .string("fixture")]
  )
}

private func replayableSnapshot(
  content: [ProviderResponseContent],
  finishReason: ProviderFinishReason = .toolCalls
) -> ProviderResponseSnapshot {
  ProviderResponseSnapshot(
    responseID: "response-1",
    providerID: "openai",
    protocolID: "openai-responses",
    modelID: "gpt-test",
    responseModelID: "gpt-test-2026-09-19",
    content: content,
    usage: replayUsage(),
    finishReason: finishReason,
    rawFinishReason: "completed",
    timestampMilliseconds: 1_725_000_000_000,
    providerMetadata: ["endTurn": .bool(true)]
  )
}

private func expectReplayFailure(
  _ snapshot: ProviderResponseSnapshot,
  code: ProviderRuntimeFailure.Code,
  messageContains fragment: String
) {
  do {
    _ = try snapshot.replayAssistantMessage()
    Issue.record("response snapshot unexpectedly produced a replay assistant message")
  } catch let error as ProviderRuntimeFailure {
    #expect(error.code == code)
    #expect(error.operation == "response-snapshot.replay")
    #expect(error.providerID == snapshot.providerID)
    #expect(error.message.contains(fragment))
  } catch {
    Issue.record("unexpected replay error type: \(error)")
  }
}

private struct UpstreamMapping: Decodable {
  struct Area: Decodable {
    let id: String
    let dependsOn: [String]
  }

  let schemaVersion: Int
  let areas: [Area]
}

private struct UnsupportedRuntime: ProviderRuntime {
  func catalog() async throws -> ProviderCatalog {
    ProviderCatalog(revision: "test", providers: [])
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction
  ) async throws -> AuthorizationState {
    throw ProviderRuntimeFailure(
      code: .unsupportedProvider,
      message: "authorization is unsupported in this fixture",
      providerID: nil,
      operation: "authorize",
      causeDescription: nil
    )
  }

  func stream(
    _ request: ProviderRequest
  ) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.finish(
        throwing: ProviderRuntimeFailure(
          code: .unsupportedProvider,
          message: "unsupported provider: \(request.providerID)",
          providerID: request.providerID,
          operation: "stream",
          causeDescription: nil
        )
      )
    }
  }
}

private struct UpstreamLock: Decodable {
  struct Package: Decodable {
    let name: String
    let version: String
  }

  let schemaVersion: Int
  let revision: String
  let package: Package
  let trackedBuiltinProviders: [String]
  let requiredSourcePaths: [String]
}
