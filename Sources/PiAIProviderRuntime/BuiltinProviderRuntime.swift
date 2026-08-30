import Foundation

public struct BuiltinProviderRuntime: ProviderRuntime {
  private let kernel: ProviderRuntimeKernel

  public init(
    credentialStore: any ProviderCredentialStore,
    streamingTransport: any ProviderHTTPStreamingTransport =
      URLSessionProviderHTTPStreamingTransport(),
    authorizationTransport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
  ) throws {
    let registry = try BuiltinProviderRegistry.load()
    let definitions = try registry.providers.map {
      try Self.makeDefinition(
        $0,
        authorizationTransport: authorizationTransport
      )
    }
    kernel = try ProviderRuntimeKernel(
      catalogRevision: registry.upstreamRevision,
      providers: definitions,
      wireProtocols: [
        AnthropicMessagesAdapter(),
        OpenAICompletionsAdapter(),
        OpenAIResponsesAdapter(),
        OpenAIResponsesAdapter(
          protocolID: "azure-openai-responses",
          flavor: .azure
        ),
        OpenAIResponsesAdapter(
          protocolID: "openai-codex-responses",
          flavor: .codex
        ),
        GoogleGenerativeAIAdapter(),
        GoogleGenerativeAIAdapter(
          protocolID: "google-vertex",
          flavor: .vertex
        ),
        MistralConversationsAdapter(),
        PiMessagesAdapter(),
        BedrockConverseStreamAdapter(),
        OpenRouterImagesAdapter(),
      ],
      credentialStore: credentialStore,
      transport: streamingTransport
    )
  }

  public func catalog() async throws -> ProviderCatalog {
    try await kernel.catalog()
  }

  public func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction
  ) async throws -> AuthorizationState {
    try await kernel.authorize(operation, interaction: interaction)
  }

  public func stream(
    _ request: ProviderRequest
  ) -> AsyncThrowingStream<ProviderEvent, any Error> {
    kernel.stream(request)
  }

  private static func makeDefinition(
    _ record: BuiltinProviderRecord,
    authorizationTransport: any ProviderHTTPTransport
  ) throws -> ProviderDefinition {
    let methods = record.authorizationMethodIDs.map { methodID in
      switch methodID {
      case "apiKey":
        AuthorizationMethodDescriptor(
          id: "api-key",
          kind: .apiKey,
          label: "\(record.name) credential"
        )
      case "oauth":
        AuthorizationMethodDescriptor(
          id: "oauth",
          kind: .oauth,
          label: "Sign in to \(record.name)"
        )
      default:
        AuthorizationMethodDescriptor(
          id: methodID,
          kind: .apiKey,
          label: "\(record.name) credential"
        )
      }
    }
    var adapters: [String: any ProviderAuthorizationAdapter] = [:]
    for method in methods {
      switch method.id {
      case "api-key":
        adapters[method.id] = APIKeyAuthorizationAdapter(
          providerID: record.id,
          methodID: method.id,
          label: method.label
        )
      case "oauth" where record.id == OpenAICodexOAuthClient.providerID:
        adapters[method.id] = OpenAICodexAuthorizationAdapter(
          transport: authorizationTransport
        )
      case "oauth" where record.id == KimiCodingOAuthAuthorizationAdapter.providerID:
        adapters[method.id] = KimiCodingOAuthAuthorizationAdapter(
          transport: authorizationTransport
        )
      default:
        adapters[method.id] = UnimplementedAuthorizationAdapter(
          providerID: record.id,
          methodID: method.id
        )
      }
    }
    return ProviderDefinition(
      descriptor: ProviderDescriptor(
        id: record.id,
        name: record.name,
        authorizationMethods: methods,
        models: record.models
      ),
      baseURL: record.baseURL,
      headers: record.headers,
      modelConfigurations: record.modelConfigurations,
      credentialRequirement: .required,
      authorization: try CompositeAuthorizationAdapter(
        providerID: record.id,
        methods: adapters
      )
    )
  }
}
