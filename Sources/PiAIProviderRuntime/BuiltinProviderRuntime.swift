import Foundation

public struct BuiltinProviderRuntime: ProviderRuntime {
  private let registry: BuiltinProviderRegistry
  private let kernel: ProviderRuntimeKernel
  private let modelStore: ProviderModelStore
  private let credentialStore: any ProviderCredentialStore
  private let streamingTransport: any ProviderHTTPStreamingTransport
  private let authorizationTransport: any ProviderHTTPTransport
  private let radiusAuthorization: RadiusOAuthAuthorizationAdapter
  private let radiusRefreshCoordinator: CredentialRefreshCoordinator

  public init(
    credentialStore: any ProviderCredentialStore,
    streamingTransport: any ProviderHTTPStreamingTransport =
      URLSessionProviderHTTPStreamingTransport(),
    authorizationTransport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport(),
    radiusCatalogPersistenceURL: URL? = nil
  ) throws {
    let registry = try BuiltinProviderRegistry.load()
    self.registry = registry
    self.credentialStore = credentialStore
    self.streamingTransport = streamingTransport
    self.authorizationTransport = authorizationTransport
    radiusAuthorization = RadiusOAuthAuthorizationAdapter(
      transport: authorizationTransport
    )
    radiusRefreshCoordinator = CredentialRefreshCoordinator(
      credentialStore: credentialStore
    )
    modelStore = try ProviderModelStore(
      expectedRevision: registry.upstreamRevision,
      persistenceURL: radiusCatalogPersistenceURL
    )
    kernel = try Self.makeKernel(
      registry: registry,
      credentialStore: credentialStore,
      streamingTransport: streamingTransport,
      authorizationTransport: authorizationTransport
    )
  }

  public func catalog() async throws -> ProviderCatalog {
    try await radiusKernel(refreshFromNetwork: true).catalog()
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
    guard request.providerID == RadiusOAuthAuthorizationAdapter.providerID else {
      return kernel.stream(request)
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let runtime = try await radiusKernel(refreshFromNetwork: true)
          for try await event in runtime.stream(request) {
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func radiusKernel(
    refreshFromNetwork: Bool
  ) async throws -> ProviderRuntimeKernel {
    var records = await modelStore.records(
      providerID: RadiusOAuthAuthorizationAdapter.providerID
    )
    let credential = try await radiusAuthorization.resolveCredential(
      providerID: RadiusOAuthAuthorizationAdapter.providerID,
      credentialStore: credentialStore,
      refreshCoordinator: radiusRefreshCoordinator
    )
    if refreshFromNetwork, let credential {
      let gateway = try radiusGateway(credential)
      var request = URLRequest(url: gateway.appending(path: "v1/config"))
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      switch credential {
      case .apiKey(let value):
        request.setValue("Bearer \(value.key)", forHTTPHeaderField: "Authorization")
      case .oauth(let value):
        request.setValue("Bearer \(value.accessToken)", forHTTPHeaderField: "Authorization")
      }
      let response = try await authorizationTransport.send(request)
      guard (200..<300).contains(response.statusCode) else {
        throw ProviderRuntimeFailure(
          code: .transportFailed,
          message: "Radius gateway config request failed (HTTP \(response.statusCode))",
          providerID: RadiusOAuthAuthorizationAdapter.providerID,
          operation: "radius.catalog.refresh",
          causeDescription: nil
        )
      }
      _ = try await modelStore.refreshRadius {
        ProviderModelRefreshPayload(
          data: response.body,
          checkedAt: Date(),
          etag: response.headers.first {
            $0.key.lowercased() == "etag"
          }?.value
        )
      }
      records = await modelStore.records(
        providerID: RadiusOAuthAuthorizationAdapter.providerID
      )
    }
    guard !records.isEmpty else { return kernel }
    let providers = registry.providers.map { record in
      record.id == RadiusOAuthAuthorizationAdapter.providerID
        ? record.replacingModels(with: records) : record
    }
    return try Self.makeKernel(
      registry: BuiltinProviderRegistry(
        upstreamRevision: registry.upstreamRevision,
        providers: providers
      ),
      credentialStore: credentialStore,
      streamingTransport: streamingTransport,
      authorizationTransport: authorizationTransport
    )
  }

  private func radiusGateway(_ credential: ProviderCredential) throws -> URL {
    let metadata: [String: String]
    switch credential {
    case .apiKey(let value): metadata = value.metadata
    case .oauth(let value): metadata = value.metadata
    }
    let raw =
      metadata["gateway"] ?? metadata["baseURL"]
      ?? RadiusOAuthAuthorizationAdapter.defaultGateway
    guard let url = URL(string: raw),
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      url.host != nil
    else {
      throw ProviderRuntimeFailure(
        code: .invalidCredential,
        message: "Radius credential gateway metadata is invalid",
        providerID: RadiusOAuthAuthorizationAdapter.providerID,
        operation: "radius.catalog.gateway",
        causeDescription: nil
      )
    }
    return url
  }

  private static func makeKernel(
    registry: BuiltinProviderRegistry,
    credentialStore: any ProviderCredentialStore,
    streamingTransport: any ProviderHTTPStreamingTransport,
    authorizationTransport: any ProviderHTTPTransport
  ) throws -> ProviderRuntimeKernel {
    let definitions = try registry.providers.map {
      try makeDefinition(
        $0,
        authorizationTransport: authorizationTransport
      )
    }
    return try ProviderRuntimeKernel(
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
      case "oauth" where record.id == AnthropicOAuthAuthorizationAdapter.providerID:
        adapters[method.id] = AnthropicOAuthAuthorizationAdapter(
          transport: authorizationTransport
        )
      case "oauth" where record.id == GitHubCopilotOAuthAuthorizationAdapter.providerID:
        adapters[method.id] = GitHubCopilotOAuthAuthorizationAdapter(
          transport: authorizationTransport
        )
      case "oauth" where record.id == OpenRouterOAuthAuthorizationAdapter.providerID:
        adapters[method.id] = OpenRouterOAuthAuthorizationAdapter(
          transport: authorizationTransport
        )
      case "oauth" where record.id == XAIOAuthAuthorizationAdapter.providerID:
        adapters[method.id] = XAIOAuthAuthorizationAdapter(
          transport: authorizationTransport
        )
      case "oauth" where record.id == RadiusOAuthAuthorizationAdapter.providerID:
        adapters[method.id] = RadiusOAuthAuthorizationAdapter(
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
