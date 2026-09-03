import Foundation

/// A host-declared model belonging to a custom provider.
public struct CustomProviderModel: Sendable, Equatable, Codable {
  public let id: String
  public let name: String
  public let api: String?
  public let baseURL: URL?
  public let headers: [String: String]
  public let capabilities: ProviderCapabilities
  public let contextWindow: Int?
  public let maximumOutputTokens: Int?
  public let metadata: [String: JSONValue]

  public init(
    id: String,
    name: String? = nil,
    api: String? = nil,
    baseURL: URL? = nil,
    headers: [String: String] = [:],
    capabilities: ProviderCapabilities,
    contextWindow: Int? = nil,
    maximumOutputTokens: Int? = nil,
    metadata: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.name = name ?? id
    self.api = api
    self.baseURL = baseURL
    self.headers = headers
    self.capabilities = capabilities
    self.contextWindow = contextWindow
    self.maximumOutputTokens = maximumOutputTokens
    self.metadata = metadata
  }
}

/// A custom provider declaration modeled after pi upstream's `createProvider` input.
public struct CustomProvider: Sendable, Equatable, Codable {
  public let id: String
  public let name: String
  public let baseURL: URL?
  public let api: String
  public let headers: [String: String]
  public let models: [CustomProviderModel]

  public init(
    id: String,
    name: String? = nil,
    baseURL: URL? = nil,
    api: String,
    headers: [String: String] = [:],
    models: [CustomProviderModel]
  ) {
    self.id = id
    self.name = name ?? id
    self.baseURL = baseURL
    self.api = api
    self.headers = headers
    self.models = models
  }
}

/// A provider runtime assembled from host-declared providers and pi-ai-swift's
/// existing authorization and wire protocol implementations.
public struct CustomProviderRuntime: ProviderRuntime {
  private let kernel: ProviderRuntimeKernel

  public init(
    providers: [CustomProvider],
    credentialStore: any ProviderCredentialStore,
    streamingTransport: any ProviderHTTPStreamingTransport =
      URLSessionProviderHTTPStreamingTransport()
  ) throws {
    let definitions = try providers.map(Self.makeDefinition)
    kernel = try ProviderRuntimeKernel(
      catalogRevision: "custom-provider-v1",
      providers: definitions,
      wireProtocols: StandardWireProtocols.make(),
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
    _ provider: CustomProvider
  ) throws -> ProviderDefinition {
    try requireIdentifier(provider.id, kind: "provider", providerID: provider.id)
    guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw configurationFailure(
        providerID: provider.id,
        message: "custom provider name is empty"
      )
    }
    guard !provider.models.isEmpty else {
      throw configurationFailure(
        providerID: provider.id,
        message: "custom provider has no models"
      )
    }
    try validateBaseURL(provider.baseURL, providerID: provider.id)

    var models: [ProviderModel] = []
    var configurations: [ProviderModelRoute: ProviderModelConfiguration] = [:]
    for model in provider.models {
      try requireIdentifier(model.id, kind: "model", providerID: provider.id)
      guard !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw configurationFailure(
          providerID: provider.id,
          message: "custom model name is empty: \(model.id)"
        )
      }
      try validateBaseURL(model.baseURL, providerID: provider.id)
      let api = model.api ?? provider.api
      guard StandardWireProtocols.supportedProtocolIDs.contains(api) else {
        throw configurationFailure(
          providerID: provider.id,
          message: "custom model uses an unsupported API: \(api)"
        )
      }
      let outputModality: ProviderOutputModality =
        api == "openrouter-images" ? .image : .text
      models.append(
        ProviderModel(
          id: model.id,
          providerID: provider.id,
          name: model.name,
          protocolID: api,
          capabilities: model.capabilities,
          contextWindow: model.contextWindow,
          maximumOutputTokens: model.maximumOutputTokens,
          supportedReasoningEfforts: try ProviderReasoning.supportedEfforts(
            reasoning: model.capabilities.reasoning, metadata: model.metadata,
            protocolID: api, providerID: provider.id, modelID: model.id, modelName: model.name)
        )
      )
      configurations[
        ProviderModelRoute(
          modelID: model.id,
          outputModality: outputModality
        )
      ] = ProviderModelConfiguration(
        protocolID: api,
        baseURL: model.baseURL?.absoluteString,
        headers: model.headers,
        metadata: model.metadata
      )
    }

    let authorizationMethod = AuthorizationMethodDescriptor(
      id: "api-key",
      kind: .apiKey,
      label: "\(provider.name) credential"
    )
    return ProviderDefinition(
      descriptor: ProviderDescriptor(
        id: provider.id,
        name: provider.name,
        authorizationMethods: [authorizationMethod],
        models: models
      ),
      baseURL: provider.baseURL?.absoluteString,
      headers: provider.headers,
      modelConfigurations: configurations,
      credentialRequirement: .required,
      endpointPolicy: .httpsOrLoopbackHTTP,
      authorization: APIKeyAuthorizationAdapter(
        providerID: provider.id,
        methodID: authorizationMethod.id,
        label: authorizationMethod.label
      )
    )
  }

  private static func requireIdentifier(
    _ value: String,
    kind: String,
    providerID: String
  ) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw configurationFailure(
        providerID: providerID,
        message: "custom \(kind) identifier is empty"
      )
    }
  }

  private static func validateBaseURL(
    _ url: URL?,
    providerID: String
  ) throws {
    guard let url else { return }
    guard isAllowedCustomBaseURL(url) else {
      throw configurationFailure(
        providerID: providerID,
        message:
          "custom provider base URL must use HTTPS or loopback HTTP: \(url.absoluteString)"
      )
    }
  }

  private static func isAllowedCustomBaseURL(_ url: URL) -> Bool {
    guard let rawHost = url.host?.lowercased() else { return false }
    if url.scheme?.lowercased() == "https" { return true }
    guard url.scheme?.lowercased() == "http" else { return false }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return host == "localhost" || host.hasSuffix(".localhost") || host == "::1"
      || host.split(separator: ".").first == "127"
  }

  private static func configurationFailure(
    providerID: String,
    message: String
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidRequest,
      message: message,
      providerID: providerID,
      operation: "custom-provider.configure",
      causeDescription: nil
    )
  }
}
