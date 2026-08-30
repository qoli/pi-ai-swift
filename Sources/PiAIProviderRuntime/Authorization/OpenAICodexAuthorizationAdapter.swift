import Foundation

struct OpenAICodexAuthorizationAdapter: ProviderAuthorizationAdapter {
  private let client: OpenAICodexOAuthClient

  init(transport: any ProviderHTTPTransport) {
    client = OpenAICodexOAuthClient(transport: transport)
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    switch operation {
    case .logout(let providerID):
      guard providerID == OpenAICodexOAuthClient.providerID else {
        throw failure("authorization provider mismatch")
      }
      try await credentialStore.delete(providerID: providerID)
      return .disconnected(providerID: providerID)
    case .login(let providerID, let methodID):
      guard providerID == OpenAICodexOAuthClient.providerID,
        methodID == "oauth"
      else {
        throw failure("unsupported OpenAI Codex authorization request")
      }
      let credential = try await client.login(interaction: interaction)
      _ = try await credentialStore.modify(providerID: providerID) { _ in
        .oauth(credential)
      }
      return .connected(
        ProviderAccount(
          providerID: providerID,
          accountID: credential.metadata["accountID"],
          authorizationKind: .oauth,
          expiresAt: credential.expiresAt
        )
      )
    }
  }

  func resolveCredential(
    providerID: String,
    credentialStore: any ProviderCredentialStore,
    refreshCoordinator: CredentialRefreshCoordinator
  ) async throws -> ProviderCredential? {
    guard providerID == OpenAICodexOAuthClient.providerID else {
      throw failure("credential provider mismatch")
    }
    guard let stored = try await credentialStore.read(providerID: providerID) else {
      return nil
    }
    guard case .oauth = stored else {
      throw ProviderRuntimeFailure(
        code: .invalidCredential,
        message: "OpenAI Codex requires an OAuth credential",
        providerID: providerID,
        operation: "oauth.credential.resolve",
        causeDescription: nil
      )
    }
    let refreshed = try await refreshCoordinator.credential(
      providerID: providerID,
      minimumValidity: 60,
      refresh: { credential in try await client.refresh(credential) }
    )
    return .oauth(refreshed)
  }

  private func failure(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .authorizationFailed,
      message: message,
      providerID: OpenAICodexOAuthClient.providerID,
      operation: "oauth.authorize",
      causeDescription: nil
    )
  }
}

struct UnimplementedAuthorizationAdapter: ProviderAuthorizationAdapter {
  let providerID: String
  let methodID: String

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    throw ProviderRuntimeFailure(
      code: .unsupportedCapability,
      message: "authorization method is not implemented: \(methodID)",
      providerID: providerID,
      operation: "authorize.login",
      causeDescription: nil
    )
  }
}
