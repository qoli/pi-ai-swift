import Foundation

struct APIKeyAuthorizationAdapter: ProviderAuthorizationAdapter {
  let providerID: String
  let methodID: String
  let label: String
  var usesBuiltinPrimaryAuthorization = true
  func resolvePrimary(_ credential: APIKeyCredential?, context: ProviderAuthenticationContext)
    async throws -> ProviderPrimaryAuthorization?
  {
    if !usesBuiltinPrimaryAuthorization {
      if let credential, credential.configuredKey?.isEmpty == false {
        return .init(
          credential: .apiKey(credential), headers: [:], environment: credential.environment,
          source: "stored credential", connectionEnvironment: [:])
      }
      guard
        let key = try await ProviderEnvironmentKeys.firstAPIKey(
          providerID: providerID, environment: context.environment)
      else { return nil }
      return .init(
        credential: .apiKey(.init(key: key.value, metadata: [:])), headers: [:], environment: nil,
        source: key.name, connectionEnvironment: [:])
    }
    return try await ProviderPrimaryAuthorization.resolve(
      providerID: providerID,
      credential: credential.map(ProviderCredential.apiKey), context: context)
  }

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
      let credential = try await ProviderPrimaryLogin.credential(
        providerID: providerID, label: label, interaction: interaction)
      _ = try await credentialStore.modify(providerID: providerID) { _ in
        .apiKey(credential)
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
