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
