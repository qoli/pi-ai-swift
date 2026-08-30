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
}

struct ProviderDefinition: Sendable {
  let descriptor: ProviderDescriptor
  let baseURL: URL
  let headers: [String: String]
  let credentialRequirement: ProviderCredentialRequirement
  let authorization: any ProviderAuthorizationAdapter
}

struct WireProtocolContext: Sendable {
  let provider: ProviderDescriptor
  let model: ProviderModel
  let baseURL: URL
  let headers: [String: String]
  let credential: ProviderCredential?
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
    guard let wireProtocol = wireProtocols[model.protocolID] else {
      throw failure(
        .unsupportedCapability,
        providerID: request.providerID,
        operation: "stream.resolve-protocol",
        message: "wire protocol is not implemented: \(model.protocolID)"
      )
    }

    let credential = try await credentialStore.read(
      providerID: request.providerID
    )
    if provider.credentialRequirement == .required, credential == nil {
      throw failure(
        .missingCredential,
        providerID: request.providerID,
        operation: "stream.resolve-credential",
        message: "provider credential is missing: \(request.providerID)"
      )
    }

    return wireProtocol.stream(
      request,
      context: WireProtocolContext(
        provider: provider.descriptor,
        model: model,
        baseURL: provider.baseURL,
        headers: provider.headers,
        credential: credential
      ),
      transport: transport
    )
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

extension AuthorizationOperation {
  fileprivate var providerID: String {
    switch self {
    case .login(let providerID, _), .logout(let providerID): providerID
    }
  }
}
