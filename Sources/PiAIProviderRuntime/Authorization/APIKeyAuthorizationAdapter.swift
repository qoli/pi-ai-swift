import Foundation

struct APIKeyAuthorizationAdapter: ProviderAuthorizationAdapter {
  let providerID: String
  let methodID: String
  let label: String

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    switch operation {
    case .login(let requestedProviderID, let requestedMethodID):
      try requireProvider(requestedProviderID, operation: "api-key.login")
      guard requestedMethodID == methodID else {
        throw failure(
          .unsupportedCapability,
          operation: "api-key.login",
          message: "unsupported authorization method: \(requestedMethodID)"
        )
      }
      let response = try await interaction(
        .prompt(
          providerID: providerID,
          id: methodID,
          message: label,
          kind: .secret
        )
      )
      guard case .value(let submittedKey) = response else {
        throw failure(
          .authorizationFailed,
          operation: "api-key.login",
          message: "API-key authorization was not completed"
        )
      }
      let key = submittedKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else {
        throw failure(
          .invalidCredential,
          operation: "api-key.login",
          message: "API key is empty"
        )
      }
      _ = try await credentialStore.modify(providerID: providerID) { _ in
        .apiKey(APIKeyCredential(key: key, metadata: [:]))
      }
      return .connected(
        ProviderAccount(
          providerID: providerID,
          accountID: nil,
          authorizationKind: .apiKey,
          expiresAt: nil
        )
      )

    case .logout(let requestedProviderID):
      try requireProvider(requestedProviderID, operation: "api-key.logout")
      try await credentialStore.delete(providerID: providerID)
      return .disconnected(providerID: providerID)
    }
  }

  private func requireProvider(
    _ requestedProviderID: String,
    operation: String
  ) throws {
    guard requestedProviderID == providerID else {
      throw ProviderRuntimeFailure(
        code: .unsupportedProvider,
        message: "unsupported provider: \(requestedProviderID)",
        providerID: requestedProviderID,
        operation: operation,
        causeDescription: nil
      )
    }
  }

  private func failure(
    _ code: ProviderRuntimeFailure.Code,
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
}
