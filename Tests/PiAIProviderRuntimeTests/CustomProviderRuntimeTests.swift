import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct CustomProviderRuntimeTests {
  @Test
  func projectsUpstreamStyleProviderAndModelAPIOverrideIntoCatalog() async throws {
    let runtime = try CustomProviderRuntime(
      providers: [
        CustomProvider(
          id: "my-provider",
          baseURL: URL(string: "https://api.example.com/v1")!,
          api: "openai-completions",
          models: [
            customModel(id: "chat-model"),
            customModel(id: "response-model", api: "openai-responses"),
          ]
        )
      ],
      credentialStore: InMemoryProviderCredentialStore()
    )

    let catalog = try await runtime.catalog()
    let provider = try #require(catalog.providers.first)
    #expect(catalog.revision == "custom-provider-v1")
    #expect(provider.id == "my-provider")
    #expect(provider.name == "my-provider")
    #expect(provider.authorizationMethods.map(\.id) == ["api-key"])
    #expect(provider.models.map(\.providerID) == ["my-provider", "my-provider"])
    #expect(provider.models.map(\.protocolID) == ["openai-completions", "openai-responses"])
  }

  @Test
  func reusesOpenAIAdapterWithExactAPIRootHeadersCredentialAndCompatibility()
    async throws
  {
    let transport = CustomProviderFixtureTransport()
    let store = InMemoryProviderCredentialStore(
      credentials: [
        "my-provider": .apiKey(
          APIKeyCredential(key: "fixture-key", metadata: [:])
        )
      ]
    )
    let runtime = try CustomProviderRuntime(
      providers: [
        CustomProvider(
          id: "my-provider",
          name: "My Provider",
          baseURL: URL(string: "https://api.example.com/v1")!,
          api: "openai-completions",
          headers: ["X-Provider": "provider"],
          models: [
            customModel(
              id: "my-model",
              headers: ["X-Model": "model"],
              metadata: [
                "compat": .object([
                  "maxTokensField": .string("max_tokens"),
                  "supportsStore": .bool(false),
                ])
              ]
            )
          ]
        )
      ],
      credentialStore: store,
      streamingTransport: transport
    )

    var events: [ProviderEvent] = []
    for try await event in runtime.stream(customRequest()) {
      events.append(event)
    }
    #expect(events.contains(.textDelta("ok")))
    #expect(events.last == .completed(.stop))

    let request = try #require(await transport.request)
    #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "X-Provider") == "provider")
    #expect(request.value(forHTTPHeaderField: "X-Model") == "model")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    let body = try decodeJSONObject(
      try #require(request.httpBody),
      providerID: "my-provider",
      operation: "custom-provider.fixture"
    )
    #expect(body.string("model") == "my-model")
    #expect(body.int("max_tokens") == 64)
    #expect(body["max_completion_tokens"] == nil)
    #expect(body["store"] == nil)
  }

  @Test
  func invalidDeclarationsFailAtConstructionWithoutProtocolFallback() {
    let store = InMemoryProviderCredentialStore()
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try CustomProviderRuntime(
        providers: [
          CustomProvider(
            id: "my-provider",
            baseURL: URL(string: "https://api.example.com/v1")!,
            api: "unknown-api",
            models: [customModel(id: "my-model")]
          )
        ],
        credentialStore: store
      )
    }
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try CustomProviderRuntime(
        providers: [
          CustomProvider(
            id: "my-provider",
            baseURL: URL(string: "https://api.example.com/v1")!,
            api: "openai-completions",
            models: [customModel(id: "same"), customModel(id: "same")]
          )
        ],
        credentialStore: store
      )
    }
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try CustomProviderRuntime(
        providers: [
          CustomProvider(
            id: "my-provider",
            baseURL: URL(string: "http://api.example.com/v1")!,
            api: "openai-completions",
            models: [customModel(id: "my-model")]
          )
        ],
        credentialStore: store
      )
    }
  }

  @Test
  func permitsExplicitLoopbackHTTPForLocalCustomProviders() async throws {
    let runtime = try CustomProviderRuntime(
      providers: [
        CustomProvider(
          id: "local-provider",
          baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
          api: "openai-completions",
          models: [customModel(id: "local-model")]
        )
      ],
      credentialStore: InMemoryProviderCredentialStore()
    )
    #expect(try await runtime.catalog().providers.map(\.id) == ["local-provider"])
  }

  @Test
  func missingBaseURLFailsAtRequestTimeWithoutEndpointFallback() async throws {
    let runtime = try CustomProviderRuntime(
      providers: [
        CustomProvider(
          id: "my-provider",
          api: "openai-completions",
          models: [customModel(id: "my-model")]
        )
      ],
      credentialStore: InMemoryProviderCredentialStore(
        credentials: [
          "my-provider": .apiKey(
            APIKeyCredential(key: "fixture-key", metadata: [:])
          )
        ]
      )
    )

    do {
      for try await _ in runtime.stream(customRequest()) {}
      Issue.record("custom provider unexpectedly selected an endpoint")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .invalidRequest)
      #expect(failure.operation == "stream.resolve-base-url")
    }
  }
}

private actor CustomProviderFixtureTransport: ProviderHTTPStreamingTransport {
  private(set) var request: URLRequest?

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    self.request = request
    let stream =
      [
        #"data: {"id":"response","model":"my-model","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
        #"data: {"id":"response","model":"my-model","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#,
        "data: [DONE]",
      ].joined(separator: "\n\n") + "\n\n"
    return ProviderHTTPStreamingResponse(
      statusCode: 200,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.yield(Data(stream.utf8))
        continuation.finish()
      }
    )
  }
}

private func customModel(
  id: String,
  api: String? = nil,
  headers: [String: String] = [:],
  metadata: [String: JSONValue] = [:]
) -> CustomProviderModel {
  CustomProviderModel(
    id: id,
    api: api,
    headers: headers,
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: false,
      toolCalling: true,
      reasoning: false,
      structuredOutput: true,
      imageGeneration: false
    ),
    contextWindow: 16_384,
    maximumOutputTokens: 1_024,
    metadata: metadata
  )
}

private func customRequest() -> ProviderRequest {
  ProviderRequest(
    id: "request",
    providerID: "my-provider",
    modelID: "my-model",
    messages: [.user([.text("hello")])],
    tools: [],
    options: ProviderGenerationOptions(
      maximumOutputTokens: 64,
      temperature: nil,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: [:]
    )
  )
}
