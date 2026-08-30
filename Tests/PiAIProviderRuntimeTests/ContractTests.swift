import Foundation
import Testing

@testable import PiAIProviderRuntime

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
        reasoningEffort: "high",
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
  func unknownEventFailsDecodingInsteadOfProducingSubstituteOutput() {
    let data = Data(#"[{"unknown":{"_0":"value"}}]"#.utf8)

    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode([ProviderEvent].self, from: data)
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
    let lock = try JSONDecoder().decode(
      UpstreamLock.self,
      from: Data(contentsOf: lockURL)
    )

    #expect(lock.schemaVersion == 2)
    #expect(lock.revision.count == 40)
    #expect(lock.package.name == "@earendil-works/pi-ai")
    #expect(lock.package.version == "0.84.4")
    #expect(lock.trackedBuiltinProviders.count == 40)
    #expect(lock.trackedBuiltinProviders.contains("github-copilot"))
    #expect(lock.trackedBuiltinProviders.contains("xai"))
    #expect(lock.trackedBuiltinProviders.contains("deepseek"))
    #expect(lock.trackedBuiltinProviders.contains("qwen-token-plan"))
    #expect(!lock.requiredSourcePaths.isEmpty)
  }
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
