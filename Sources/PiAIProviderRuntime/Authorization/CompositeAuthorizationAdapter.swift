import Foundation

struct CompositeAuthorizationAdapter: ProviderAuthorizationAdapter {
  private let providerID: String
  private let methods: [String: any ProviderAuthorizationAdapter]

  init(
    providerID: String,
    methods: [String: any ProviderAuthorizationAdapter]
  ) throws {
    self.providerID = providerID
    self.methods = methods
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    switch operation {
    case .logout(let requestedProviderID):
      guard requestedProviderID == providerID else {
        throw failure("authorization provider mismatch")
      }
      try await credentialStore.delete(providerID: providerID)
      return .disconnected(providerID: providerID)
    case .login(let requestedProviderID, let methodID):
      guard requestedProviderID == providerID else {
        throw failure("authorization provider mismatch")
      }
      guard let adapter = methods[methodID] else {
        throw failure("unsupported authorization method: \(methodID)")
      }
      return try await adapter.authorize(
        operation,
        interaction: interaction,
        credentialStore: credentialStore
      )
    }
  }

  func resolveCredential(
    providerID requestedProviderID: String,
    credentialStore: any ProviderCredentialStore,
    refreshCoordinator: CredentialRefreshCoordinator
  ) async throws -> ProviderCredential? {
    guard requestedProviderID == providerID else {
      throw failure("credential provider mismatch")
    }
    guard let credential = try await credentialStore.read(providerID: providerID) else {
      return nil
    }
    let methodID: String
    switch credential {
    case .apiKey: methodID = "api-key"
    case .oauth: methodID = "oauth"
    }
    guard let adapter = methods[methodID] else {
      throw failure("stored credential has no authorization adapter: \(methodID)")
    }
    return try await adapter.resolveCredential(
      providerID: providerID,
      credentialStore: credentialStore,
      refreshCoordinator: refreshCoordinator
    )
  }

  private func failure(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .authorizationFailed,
      message: message,
      providerID: providerID,
      operation: "authorize.route",
      causeDescription: nil
    )
  }
}
