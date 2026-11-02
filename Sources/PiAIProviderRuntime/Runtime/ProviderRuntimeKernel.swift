import Foundation

enum ProviderCredentialRequirement: Sendable {
  case required
  case none
}

enum ProviderEndpointPolicy: Sendable {
  case httpsOnly
  case httpOrHTTPS
}

struct ProviderRequestAuthorization: Sendable {
  let credential: ProviderCredential?
  let headers: [String: String?]
  var usesHeaderAuthentication: Bool { credential == nil && !headers.isEmpty }
}

private struct KernelResolvedAuthorization: Sendable {
  let credential: ProviderCredential?
  let request: ProviderRequestAuthorization
  let primary: ProviderPrimaryAuthorization?
}

protocol ProviderAuthorizationAdapter: Sendable {
  var supportsPrimaryAuthorization: Bool { get }
  var oauthRefresh: CredentialRefreshCoordinator.RefreshOperation? { get }
  var oauthNow: @Sendable () -> Date { get }
  func resolvePrimary(_ credential: APIKeyCredential?, context: ProviderAuthenticationContext)
    async throws -> ProviderPrimaryAuthorization?
  func requestAuthorization(for credential: ProviderCredential?) throws
    -> ProviderRequestAuthorization

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState

  func resolveCredential(
    providerID: String,
    credentialStore: any ProviderCredentialStore,
    refreshCoordinator: CredentialRefreshCoordinator
  ) async throws -> ProviderCredential?
}

extension ProviderAuthorizationAdapter {
  var supportsPrimaryAuthorization: Bool { true }
  var oauthRefresh: CredentialRefreshCoordinator.RefreshOperation? { nil }
  var oauthNow: @Sendable () -> Date { { Date() } }
  func resolvePrimary(_ credential: APIKeyCredential?, context: ProviderAuthenticationContext)
    async throws -> ProviderPrimaryAuthorization?
  {
    let value = try requestAuthorization(for: credential.map(ProviderCredential.apiKey))
    guard value.credential != nil || !value.headers.isEmpty else { return nil }
    return .init(
      credential: value.credential, headers: value.headers, environment: credential?.environment,
      source: "stored credential", connectionEnvironment: [:])
  }
  func requestAuthorization(for credential: ProviderCredential?) throws
    -> ProviderRequestAuthorization
  {
    .init(credential: credential, headers: [:])
  }

  func resolveCredential(
    providerID: String,
    credentialStore: any ProviderCredentialStore,
    refreshCoordinator: CredentialRefreshCoordinator
  ) async throws -> ProviderCredential? {
    let credential = try await credentialStore.read(providerID: providerID)
    if case .oauth(let oauth) = credential, oauth.expiresAt <= Date() {
      throw ProviderRuntimeFailure(
        code: .invalidCredential,
        message:
          "OAuth credential expired and this authorization adapter has no refresh implementation",
        providerID: providerID,
        operation: "credential.resolve",
        causeDescription: nil
      )
    }
    return credential
  }

}

struct ProviderDefinition: Sendable {
  let descriptor: ProviderDescriptor
  let baseURL: String?
  let headers: [String: String]
  let modelConfigurations: [ProviderModelRoute: ProviderModelConfiguration]
  let credentialRequirement: ProviderCredentialRequirement
  let endpointPolicy: ProviderEndpointPolicy
  let authorization: any ProviderAuthorizationAdapter

  init(
    descriptor: ProviderDescriptor,
    baseURL: String?,
    headers: [String: String],
    modelConfigurations: [ProviderModelRoute: ProviderModelConfiguration],
    credentialRequirement: ProviderCredentialRequirement,
    endpointPolicy: ProviderEndpointPolicy = .httpsOnly,
    authorization: any ProviderAuthorizationAdapter
  ) {
    self.descriptor = descriptor
    self.baseURL = baseURL
    self.headers = headers
    self.modelConfigurations = modelConfigurations
    self.credentialRequirement = credentialRequirement
    self.endpointPolicy = endpointPolicy
    self.authorization = authorization
  }
}

struct ProviderModelConfiguration: Sendable {
  let protocolID: String
  let baseURL: String?
  let headers: [String: String]
  let metadata: [String: JSONValue]
}

struct WireProtocolContext: Sendable {
  let provider: ProviderDescriptor
  let model: ProviderModel
  let baseURL: URL
  let headers: [String: String]
  let credential: ProviderCredential?
  let modelConfiguration: ProviderModelConfiguration
  var usesHeaderAuthentication = false
  var wireObserver: ProviderWireObserver? = nil
  var webSocketTransport: (any ProviderWebSocketTransport)? = nil
  var codexSessions = CodexWebSocketSessions()
  var clock: any ProviderOAuthClock = SystemProviderOAuthClock()
  var isFederatedCloudAuthorization = false
  var usesVertexCollectionScope = false
  var classifierSessions = ProviderClassifierSessions.shared
}

protocol WireProtocolAdapter: Sendable {
  var protocolID: String { get }

  func stream(
    _ request: ProviderRequest,
    context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport
  ) -> AsyncThrowingStream<ProviderEvent, any Error>
}

struct ProviderRuntimeKernel: ProviderRuntime {
  private let catalogRevision: String
  private let providers: [String: ProviderDefinition]
  private let wireProtocols: [String: any WireProtocolAdapter]
  private let credentialStore: any ProviderCredentialStore
  private let refreshCoordinator: CredentialRefreshCoordinator
  private let transport: any ProviderHTTPStreamingTransport
  private let wireObserver: ProviderWireObserver?
  private let identityHost: ProviderIdentityHost
  private let webSocketTransport: (any ProviderWebSocketTransport)?
  private let codexSessions: CodexWebSocketSessions
  private let clock: any ProviderOAuthClock
  private let cloudAuthorizationResolver: ProviderCloudAuthorizationResolver?
  private let cloudCredentialSources: ProviderCloudCredentialSources
  private let authenticationContext: ProviderAuthenticationContext?
  private let requestTransportResolver: ProviderRequestTransportResolver?

  init(
    catalogRevision: String,
    providers: [ProviderDefinition],
    wireProtocols: [any WireProtocolAdapter],
    credentialStore: any ProviderCredentialStore,
    transport: any ProviderHTTPStreamingTransport,
    wireObserver: ProviderWireObserver? = nil,
    identityHost: ProviderIdentityHost = .init(),
    webSocketTransport: (any ProviderWebSocketTransport)? = nil,
    codexSessions: CodexWebSocketSessions = .init(),
    clock: any ProviderOAuthClock = SystemProviderOAuthClock(),
    cloudAuthorizationResolver: ProviderCloudAuthorizationResolver? = nil,
    cloudCredentialSources: ProviderCloudCredentialSources = .init(),
    authenticationContext: ProviderAuthenticationContext? = nil,
    requestTransportResolver: ProviderRequestTransportResolver? = nil
  ) throws {
    self.catalogRevision = catalogRevision
    self.providers = try Self.uniqueProviders(providers)
    self.wireProtocols = try Self.uniqueWireProtocols(wireProtocols)
    self.credentialStore = credentialStore
    refreshCoordinator = CredentialRefreshCoordinator(
      credentialStore: credentialStore
    )
    self.transport = transport
    self.wireObserver = wireObserver
    self.identityHost = identityHost
    self.webSocketTransport = webSocketTransport
    self.codexSessions = codexSessions
    self.clock = clock
    self.cloudAuthorizationResolver = cloudAuthorizationResolver
    self.cloudCredentialSources = cloudCredentialSources
    self.authenticationContext = authenticationContext
    self.requestTransportResolver = requestTransportResolver
  }

  func catalog() async throws -> ProviderCatalog {
    var descriptors: [ProviderDescriptor] = []
    for provider in providers.values.sorted(by: { $0.descriptor.id < $1.descriptor.id }) {
      let descriptor = provider.descriptor
      guard let authenticationContext else {
        descriptors.append(descriptor)
        continue
      }
      let resolved = try await ProviderAuthorizationResolution.check(
        providerID: descriptor.id, store: credentialStore, context: authenticationContext,
        bindings: authorizationBindings(provider))
      let routes = provider.modelConfigurations.keys.map {
        ProviderAvailableModel(modelID: $0.modelID, outputModality: $0.outputModality)
      }.sorted {
        ($0.modelID, $0.outputModality.rawValue) < ($1.modelID, $1.outputModality.rawValue)
      }
      let available =
        resolved == nil
        ? []
        : ProviderPrimaryAuthorization.availableModels(
          routes, providerID: descriptor.id, credential: resolved?.credential)
      descriptors.append(
        .init(
          id: descriptor.id, name: descriptor.name,
          authorizationMethods: descriptor.authorizationMethods, models: descriptor.models,
          availability: .init(
            configured: resolved != nil, source: resolved?.source, models: available)))
    }
    return ProviderCatalog(revision: catalogRevision, providers: descriptors)
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction
  ) async throws -> AuthorizationState {
    let providerID = operation.providerID
    guard let provider = providers[providerID] else {
      throw failure(
        .unsupportedProvider,
        providerID: providerID,
        operation: "authorize",
        message: "unsupported provider: \(providerID)"
      )
    }
    return try await provider.authorization.authorize(
      operation,
      interaction: interaction,
      credentialStore: credentialStore
    )
  }

  func stream(
    _ request: ProviderRequest
  ) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let stream = try await prepareStream(request)
          for try await event in stream {
            try Task.checkCancellation()
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

  private func authorizationBindings(_ provider: ProviderDefinition)
    -> ProviderAuthorizationBindings<KernelResolvedAuthorization>
  {
    typealias Bindings = ProviderAuthorizationBindings<KernelResolvedAuthorization>
    let primary: Bindings.Primary?
    if provider.authorization.supportsPrimaryAuthorization {
      primary = { key, context in
        guard
          let resolved = try await provider.authorization.resolvePrimary(key, context: context)
        else { return nil }
        let request = try provider.authorization.requestAuthorization(for: resolved.credential)
        return .init(
          authorization: .init(
            credential: resolved.credential, request: request, primary: resolved),
          source: resolved.source, environment: resolved.environment)
      }
    } else {
      primary = nil
    }
    let oauth: Bindings.OAuth?
    if let refresh = provider.authorization.oauthRefresh {
      oauth = .init(
        refresh: refresh,
        derive: { value in
          let credential = ProviderCredential.oauth(value)
          return .init(
            credential: credential,
            request: try provider.authorization.requestAuthorization(for: credential), primary: nil)
        }, now: provider.authorization.oauthNow)
    } else {
      oauth = nil
    }
    return .init(primary: primary, oauth: oauth)
  }

  private func prepareStream(_ request: ProviderRequest) async throws
    -> AsyncThrowingStream<ProviderEvent, any Error>
  {
    guard let provider = providers[request.providerID] else {
      throw failure(
        .unsupportedProvider,
        providerID: request.providerID,
        operation: "stream.resolve-provider",
        message: "unsupported provider: \(request.providerID)"
      )
    }
    guard
      let model = provider.descriptor.models.first(where: {
        $0.id == request.modelID && $0.providerID == request.providerID
      })
    else {
      throw failure(
        .unsupportedModel,
        providerID: request.providerID,
        operation: "stream.resolve-model",
        message:
          "unsupported model for \(request.providerID): \(request.modelID)"
      )
    }
    if let effort = request.options.reasoningEffort,
      !model.supportedReasoningEfforts.contains(effort)
    {
      throw failure(
        .unsupportedCapability,
        providerID: request.providerID,
        operation: "stream.validate-reasoning",
        message: "model \(request.modelID) does not support reasoning effort \(effort.rawValue)"
      )
    }
    let route = ProviderModelRoute(
      modelID: model.id,
      outputModality: request.options.outputModality
    )
    guard let modelConfiguration = provider.modelConfigurations[route] else {
      throw failure(
        .unsupportedCapability,
        providerID: request.providerID,
        operation: "stream.resolve-model-configuration",
        message:
          "model does not support \(request.options.outputModality.rawValue) output: \(request.modelID)"
      )
    }
    guard let wireProtocol = wireProtocols[modelConfiguration.protocolID] else {
      throw failure(
        .unsupportedCapability,
        providerID: request.providerID,
        operation: "stream.resolve-protocol",
        message: "wire protocol is not implemented: \(modelConfiguration.protocolID)"
      )
    }
    let override = try await requestTransportResolver?(request)
    if override != nil,
      ["google-generative-ai", "google-vertex"].contains(modelConfiguration.protocolID)
    {
      throw failure(
        .unsupportedCapability, providerID: request.providerID,
        operation: "stream.resolve-transport",
        message:
          "Custom fetch is not supported by the Google \(modelConfiguration.protocolID == "google-vertex" ? "Vertex" : "Generative AI") adapter"
      )
    }
    let resolved: ProviderResolvedAuthorization<KernelResolvedAuthorization>?
    do {
      resolved = try await ProviderAuthorizationResolution.resolve(
        providerID: request.providerID, store: credentialStore,
        context: authenticationContext
          ?? .init(environment: { _ in nil }, fileExists: { _ in false }),
        bindings: authorizationBindings(provider), coordinator: refreshCoordinator,
        overrides: request.connectionOptions.authentication ?? .init())
    } catch let error as ProviderAuthorizationResolutionFailure { throw error.runtimeFailure }
    let primary = resolved?.authorization.primary
    let credential = resolved?.authorization.credential
    var resolvedCredential = credential
    var requestAuthorization =
      resolved?.authorization.request
      ?? ProviderRequestAuthorization(credential: nil, headers: [:])
    if let primary {
      requestAuthorization = .init(
        credential: requestAuthorization.credential,
        headers: requestAuthorization.headers.merging(primary.headers) { _, value in value })
    }
    var cloudAuthorization: ProviderCloudPlan.Authorization?
    var cloudOptions = request.connectionOptions.cloud
    if let primary,
      ["google-vertex", "bedrock-converse-stream", "anthropic-messages"].contains(
        modelConfiguration.protocolID)
    {
      let old = cloudOptions ?? .init()
      cloudOptions = .init(
        environment: primary.connectionEnvironment.merging(old.environment) { _, explicit in
          explicit
        },
        ambientEnvironment: old.ambientEnvironment, region: old.region, profile: old.profile,
        bearerToken: old.bearerToken, project: old.project, location: old.location)
    } else if case .apiKey(let key) = credential, let environment = key.environment {
      let old = cloudOptions ?? .init()
      cloudOptions = .init(
        environment: environment.merging(old.environment) { _, explicit in explicit },
        ambientEnvironment: old.ambientEnvironment, region: old.region, profile: old.profile,
        bearerToken: old.bearerToken, project: old.project, location: old.location)
    }
    if let options = cloudOptions,
      let declaredBaseURL = modelConfiguration.baseURL ?? provider.baseURL
    {
      var cloudHeaders = requestAuthorization.headers
      cloudHeaders.merge(request.connectionOptions.headers ?? [:]) { _, value in value }
      if let plan = try ProviderCloudPlan.resolve(
        protocolID: modelConfiguration.protocolID,
        providerID: request.providerID, modelID: request.modelID, baseURL: declaredBaseURL,
        credential: requestAuthorization.credential, headers: cloudHeaders, options: options)
      {
        let resolved = try await plan.authorization(
          providerID: request.providerID, resolver: cloudAuthorizationResolver,
          sources: cloudCredentialSources)
        cloudAuthorization = resolved
        resolvedCredential = resolved.credential
        requestAuthorization = .init(
          credential: resolved.credential, headers: resolved.headers.mapValues { Optional($0) })
      }
    }
    if provider.credentialRequirement == .required, resolvedCredential == nil,
      cloudAuthorization == nil,
      !requestAuthorization.usesHeaderAuthentication,
      request.options.outputModality != .classification
    {
      throw failure(
        .missingCredential, providerID: request.providerID, operation: "stream.resolve-credential",
        message: "provider credential is missing: \(request.providerID)")
    }
    if request.connectionOptions.azureOpenAIResponses != nil,
      modelConfiguration.protocolID != "azure-openai-responses",
      !(request.providerID == "azure" && modelConfiguration.protocolID == "openai-completions")
    {
      throw failure(
        .invalidRequest,
        providerID: request.providerID,
        operation: "stream.resolve-connection-configuration",
        message: "Azure OpenAI connection options require the azure-openai-responses protocol"
      )
    }
    let credentialMetadata: [String: String]
    switch resolvedCredential {
    case .apiKey(let credential): credentialMetadata = credential.routingMetadata
    case .oauth(let credential): credentialMetadata = credential.metadata
    case nil: credentialMetadata = [:]
    }
    let declaredModelBaseURL =
      cloudAuthorization?.baseURL ?? modelConfiguration.baseURL ?? provider.baseURL
    let baseURLTemplate: String
    if modelConfiguration.protocolID == "azure-openai-responses" || request.providerID == "azure" {
      baseURLTemplate = try ResolvedAzureOpenAIResponsesConfiguration.resolve(
        request: request,
        modelBaseURL: declaredModelBaseURL
      ).baseURL
    } else {
      guard let resolved = credentialMetadata["baseURL"] ?? declaredModelBaseURL else {
        throw failure(
          .invalidRequest,
          providerID: request.providerID,
          operation: "stream.resolve-base-url",
          message: "provider requires an explicit runtime base URL: \(request.providerID)"
        )
      }
      baseURLTemplate = resolved
    }
    let resolvedBaseURLTemplate = GoogleVertexConfiguration.resolveBaseURLTemplate(
      baseURLTemplate,
      protocolID: modelConfiguration.protocolID,
      credential: resolvedCredential
    )
    let baseURL = try resolveURLTemplate(
      resolvedBaseURLTemplate,
      credential: resolvedCredential,
      providerID: request.providerID,
      endpointPolicy: provider.endpointPolicy
    )
    let identity = request.options.providerOptions.object("identity")
    var headers: [String: String]
    if modelConfiguration.protocolID == "anthropic-messages",
      AnthropicMessagesAdapter.isOAuthCredential(
        requestAuthorization.credential, providerID: request.providerID)
    {
      headers = [:]
    } else if modelConfiguration.protocolID == "bedrock-converse-stream" {
      headers = ProviderClientIdentity.attributionHeaders(
        providerID: request.providerID, baseURL: baseURL.absoluteString, identity: identity)
    } else {
      headers = ProviderClientIdentity.headers(
        providerID: request.providerID, baseURL: baseURL.absoluteString, identity: identity,
        host: identityHost)
    }
    let authorizationHeaderNames = Set(requestAuthorization.headers.keys.map { $0.lowercased() })
    headers = headers.filter { !authorizationHeaderNames.contains($0.key.lowercased()) }
    headers.merge(requestAuthorization.headers.compactMapValues { $0 }) { _, value in value }
    let providerHeaderNames = Set(provider.headers.keys.map { $0.lowercased() })
    headers = headers.filter { !providerHeaderNames.contains($0.key.lowercased()) }
    headers.merge(provider.headers) { _, providerValue in providerValue }
    if [
      "google-generative-ai", "google-vertex", "openrouter-images",
      "openai-completions", "openai-responses", "openai-codex-responses", "anthropic-messages",
      "mistral-conversations",
    ].contains(modelConfiguration.protocolID) {
      // These adapters project provider headers case-insensitively upstream.
      // Preserve model-scope precedence before dictionary ordering is lost.
      let modelNames = Set(modelConfiguration.headers.keys.map { $0.lowercased() })
      headers = headers.filter { !modelNames.contains($0.key.lowercased()) }
    }
    headers.merge(modelConfiguration.headers) { _, modelValue in modelValue }
    for (name, value) in request.connectionOptions.headers ?? [:] {
      headers = headers.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
      if let value { headers[name] = value }
    }

    return wireProtocol.stream(
      request,
      context: WireProtocolContext(
        provider: provider.descriptor,
        model: model.withProtocolID(modelConfiguration.protocolID),
        baseURL: baseURL,
        headers: headers,
        credential: requestAuthorization.credential,
        modelConfiguration: modelConfiguration,
        usesHeaderAuthentication: requestAuthorization.usesHeaderAuthentication,
        wireObserver: wireObserver,
        webSocketTransport: webSocketTransport,
        codexSessions: codexSessions,
        clock: clock,
        isFederatedCloudAuthorization: cloudAuthorization?.federated ?? false,
        usesVertexCollectionScope: cloudAuthorization?.vertexCollectionScope ?? false
      ),
      transport: override ?? transport
    )
  }

  private func resolveURLTemplate(
    _ template: String,
    credential: ProviderCredential?,
    providerID: String,
    endpointPolicy: ProviderEndpointPolicy
  ) throws -> URL {
    let metadata: [String: String]
    switch credential {
    case .apiKey(let credential): metadata = credential.routingMetadata
    case .oauth(let credential): metadata = credential.metadata
    case nil: metadata = [:]
    }
    let value =
      CloudflareAuthorizationAdapter.providerIDs.contains(providerID)
      ? ProviderEndpointTemplate.cloudflare(template, environment: metadata)
      : ProviderEndpointTemplate.materialize(template, metadata: metadata)
    guard !value.contains("{") && !value.contains("}") else {
      throw failure(
        .invalidCredential,
        providerID: providerID,
        operation: "stream.resolve-base-url",
        message: "provider base URL requires credential metadata: \(template)"
      )
    }
    guard let url = URL(string: value), Self.isAllowed(url, policy: endpointPolicy) else {
      throw failure(
        .invalidRequest,
        providerID: providerID,
        operation: "stream.resolve-base-url",
        message: "provider base URL is invalid: \(value)"
      )
    }
    return url
  }

  private static func isAllowed(
    _ url: URL,
    policy: ProviderEndpointPolicy
  ) -> Bool {
    guard url.host != nil else { return false }
    if url.scheme?.lowercased() == "https" { return true }
    return policy == .httpOrHTTPS && url.scheme?.lowercased() == "http"
  }

  private static func uniqueProviders(
    _ definitions: [ProviderDefinition]
  ) throws -> [String: ProviderDefinition] {
    var result: [String: ProviderDefinition] = [:]
    for definition in definitions {
      let providerID = definition.descriptor.id
      guard result[providerID] == nil else {
        throw failure(
          .invalidRequest,
          providerID: providerID,
          operation: "runtime.configure-provider",
          message: "duplicate provider definition: \(providerID)"
        )
      }
      let modelIDs = definition.descriptor.models.map(\.id)
      guard Set(modelIDs).count == modelIDs.count else {
        throw failure(
          .invalidRequest,
          providerID: providerID,
          operation: "runtime.configure-provider",
          message: "provider contains duplicate model identifiers: \(providerID)"
        )
      }
      guard
        definition.descriptor.models.allSatisfy({
          $0.providerID == providerID
        })
      else {
        throw failure(
          .invalidRequest,
          providerID: providerID,
          operation: "runtime.configure-provider",
          message: "provider catalog contains a model owned by another provider"
        )
      }
      result[providerID] = definition
    }
    return result
  }

  private static func uniqueWireProtocols(
    _ adapters: [any WireProtocolAdapter]
  ) throws -> [String: any WireProtocolAdapter] {
    var result: [String: any WireProtocolAdapter] = [:]
    for adapter in adapters {
      guard !adapter.protocolID.isEmpty else {
        throw failure(
          .invalidRequest,
          providerID: nil,
          operation: "runtime.configure-protocol",
          message: "wire protocol identifier is empty"
        )
      }
      guard result[adapter.protocolID] == nil else {
        throw failure(
          .invalidRequest,
          providerID: nil,
          operation: "runtime.configure-protocol",
          message: "duplicate wire protocol adapter: \(adapter.protocolID)"
        )
      }
      result[adapter.protocolID] = adapter
    }
    return result
  }

  private static func failure(
    _ code: ProviderRuntimeFailure.Code,
    providerID: String?,
    operation: String,
    message: String
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: code,
      message: message,
      providerID: providerID,
      operation: operation,
      causeDescription: nil
    )
  }

  private func failure(
    _ code: ProviderRuntimeFailure.Code,
    providerID: String?,
    operation: String,
    message: String
  ) -> ProviderRuntimeFailure {
    Self.failure(
      code,
      providerID: providerID,
      operation: operation,
      message: message
    )
  }
}

struct ProviderModelRoute: Sendable, Hashable {
  let modelID: String
  let outputModality: ProviderOutputModality
}

extension ProviderModel {
  fileprivate func withProtocolID(_ protocolID: String) -> ProviderModel {
    ProviderModel(
      id: id,
      providerID: providerID,
      name: name,
      protocolID: protocolID,
      capabilities: capabilities,
      contextWindow: contextWindow,
      maximumOutputTokens: maximumOutputTokens,
      supportedReasoningEfforts: supportedReasoningEfforts
    )
  }
}

extension AuthorizationOperation {
  fileprivate var providerID: String {
    switch self {
    case .login(let providerID, _), .logout(let providerID): providerID
    }
  }
}
