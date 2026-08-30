import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct BuiltinProviderRuntimeTests {
  @Test
  func exposesCompleteCatalogAndRoutesGenericAPIKeyAuthorization() async throws {
    let store = InMemoryProviderCredentialStore()
    let runtime = try BuiltinProviderRuntime(
      credentialStore: store,
      streamingTransport: RuntimeUnusedStreamingTransport(),
      authorizationTransport: RuntimeUnusedHTTPTransport()
    )
    let catalog = try await runtime.catalog()
    #expect(catalog.providers.count == 40)
    #expect(catalog.providers.flatMap(\.models).count == 1_337)

    let state = try await runtime.authorize(
      .login(providerID: "kimi-coding", methodID: "api-key")
    ) { challenge in
      guard case .prompt(let providerID, _, _, .secret) = challenge else {
        Issue.record("expected secret prompt")
        return .acknowledged
      }
      #expect(providerID == "kimi-coding")
      return .value(" fixture-kimi-key ")
    }
    #expect(
      state
        == .connected(
          ProviderAccount(
            providerID: "kimi-coding",
            accountID: nil,
            authorizationKind: .apiKey,
            expiresAt: nil
          )
        )
    )
    #expect(
      await store.read(providerID: "kimi-coding")
        == .apiKey(APIKeyCredential(key: "fixture-kimi-key", metadata: [:]))
    )
  }

  @Test
  func outputModalitySelectsImageRouteForTextImageModelCollision() async throws {
    let store = InMemoryProviderCredentialStore(
      credentials: [
        "openrouter": .apiKey(
          APIKeyCredential(key: "fixture-openrouter-key", metadata: [:])
        )
      ]
    )
    let transport = RuntimeCaptureStreamingTransport(
      body: Data(
        #"{"id":"image-response","choices":[{"message":{"content":null,"images":[]}}]}"#.utf8
      )
    )
    let runtime = try BuiltinProviderRuntime(
      credentialStore: store,
      streamingTransport: transport,
      authorizationTransport: RuntimeUnusedHTTPTransport()
    )
    let request = ProviderRequest(
      id: "request",
      providerID: "openrouter",
      modelID: "google/gemini-3-pro-image",
      messages: [.user([.text("draw a circle")])],
      tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: nil,
        temperature: nil,
        reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: [:],
        outputModality: .image
      )
    )
    var events: [ProviderEvent] = []
    for try await event in runtime.stream(request) { events.append(event) }
    #expect(events.last == .completed(.stop))
    let sent = try #require(await transport.request())
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(body.bool("stream") == false)
    #expect(body.array("modalities")?.first == .string("image"))
  }
}

private struct RuntimeUnusedStreamingTransport: ProviderHTTPStreamingTransport {
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    throw ProviderRuntimeFailure(
      code: .transportFailed,
      message: "unused",
      providerID: nil,
      operation: "fixture",
      causeDescription: nil
    )
  }
}

private struct RuntimeUnusedHTTPTransport: ProviderHTTPTransport {
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    throw ProviderRuntimeFailure(
      code: .transportFailed,
      message: "unused",
      providerID: nil,
      operation: "fixture",
      causeDescription: nil
    )
  }
}

private actor RuntimeCaptureStreamingTransport: ProviderHTTPStreamingTransport {
  private let body: Data
  private var captured: URLRequest?

  init(body: Data) { self.body = body }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    let body = self.body
    return ProviderHTTPStreamingResponse(
      statusCode: 200,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.yield(body)
        continuation.finish()
      }
    )
  }

  func request() -> URLRequest? { captured }
}
