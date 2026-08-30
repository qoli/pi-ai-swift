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
