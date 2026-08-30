import Foundation

enum ProviderCredentialRequirement: Sendable {
  case required
  case none
}

protocol ProviderAuthorizationAdapter: Sendable {
  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState

  func resolveCredential(
    providerID: String,
    credentialStore: any ProviderCredentialStore
  ) async throws -> ProviderCredential?
}

extension ProviderAuthorizationAdapter {
  func resolveCredential(
    providerID: String,
    credentialStore: any ProviderCredentialStore
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
  let authorization: any ProviderAuthorizationAdapter
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
  private let transport: any ProviderHTTPStreamingTransport

  init(
    catalogRevision: String,
    providers: [ProviderDefinition],
    wireProtocols: [any WireProtocolAdapter],
    credentialStore: any ProviderCredentialStore,
    transport: any ProviderHTTPStreamingTransport
  ) throws {
    self.catalogRevision = catalogRevision
    self.providers = try Self.uniqueProviders(providers)
    self.wireProtocols = try Self.uniqueWireProtocols(wireProtocols)
    self.credentialStore = credentialStore
    self.transport = transport
  }

  func catalog() async throws -> ProviderCatalog {
    ProviderCatalog(
      revision: catalogRevision,
      providers: providers.values.map(\.descriptor).sorted { $0.id < $1.id }
    )
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
    let credential = try await provider.authorization.resolveCredential(
      providerID: request.providerID,
      credentialStore: credentialStore
    )
    if provider.credentialRequirement == .required, credential == nil {
      throw failure(
        .missingCredential,
        providerID: request.providerID,
        operation: "stream.resolve-credential",
        message: "provider credential is missing: \(request.providerID)"
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
    let credentialMetadata: [String: String]
    switch credential {
    case .apiKey(let credential): credentialMetadata = credential.metadata
    case .oauth(let credential): credentialMetadata = credential.metadata
    case nil: credentialMetadata = [:]
    }
    guard
      let baseURLTemplate = modelConfiguration.baseURL ?? provider.baseURL
        ?? credentialMetadata["baseURL"]
    else {
      throw failure(
        .invalidRequest,
        providerID: request.providerID,
        operation: "stream.resolve-base-url",
        message: "provider requires an explicit runtime base URL: \(request.providerID)"
      )
    }
    let baseURL = try resolveURLTemplate(
      baseURLTemplate,
      credential: credential,
      providerID: request.providerID
    )
    let headers = provider.headers.merging(modelConfiguration.headers) {
      _, modelValue in modelValue
    }

    return wireProtocol.stream(
      request,
      context: WireProtocolContext(
        provider: provider.descriptor,
        model: model.withProtocolID(modelConfiguration.protocolID),
        baseURL: baseURL,
        headers: headers,
        credential: credential,
        modelConfiguration: modelConfiguration
      ),
      transport: transport
    )
  }

  private func resolveURLTemplate(
    _ template: String,
    credential: ProviderCredential?,
    providerID: String
  ) throws -> URL {
    var value = template
    let metadata: [String: String]
    switch credential {
    case .apiKey(let credential): metadata = credential.metadata
    case .oauth(let credential): metadata = credential.metadata
    case nil: metadata = [:]
    }
    for (key, replacement) in metadata {
      value = value.replacingOccurrences(of: "{\(key)}", with: replacement)
      value = value.replacingOccurrences(
        of: "{\(key.uppercased())}",
        with: replacement
      )
      value = value.replacingOccurrences(
        of: "{\(key.lowercased())}",
        with: replacement
      )
    }
    guard !value.contains("{") && !value.contains("}") else {
      throw failure(
        .invalidCredential,
        providerID: providerID,
        operation: "stream.resolve-base-url",
        message: "provider base URL requires credential metadata: \(template)"
      )
    }
    guard let url = URL(string: value), url.scheme == "https" else {
      throw failure(
        .invalidRequest,
        providerID: providerID,
        operation: "stream.resolve-base-url",
        message: "provider base URL is invalid: \(value)"
      )
    }
    return url
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
      maximumOutputTokens: maximumOutputTokens
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
