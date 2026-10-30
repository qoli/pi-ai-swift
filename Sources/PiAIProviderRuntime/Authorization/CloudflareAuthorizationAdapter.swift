import Foundation

struct CloudflareAuthorizationAdapter: ProviderAuthorizationAdapter {
  static let providerIDs: Set<String> = ["cloudflare-ai-gateway", "cloudflare-workers-ai"]
  let providerID: String
  let methodID: String

  private var environmentFields: [(String, String)] {
    var fields = [("CLOUDFLARE_ACCOUNT_ID", "Enter Cloudflare account ID")]
    if providerID == "cloudflare-ai-gateway" {
      fields.append(("CLOUDFLARE_GATEWAY_ID", "Enter Cloudflare AI Gateway ID"))
    }
    return fields
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    switch operation {
    case .logout(let requestedProvider):
      guard requestedProvider == providerID else { throw routingFailure() }
      try await credentialStore.delete(providerID: providerID)
      return .disconnected(providerID: providerID)
    case .login(let requestedProvider, let requestedMethod):
      guard requestedProvider == providerID, requestedMethod == methodID else {
        throw routingFailure()
      }
      let key = try await prompt(
        id: methodID, message: "Enter Cloudflare API key", kind: .secret, interaction: interaction)
      var metadata: [String: String] = [:]
      for (field, message) in environmentFields {
        metadata[field] = try await prompt(
          id: field, message: message, kind: .text, interaction: interaction)
      }
      let stored = ProviderCredential.apiKey(.init(key: key, metadata: metadata))
      _ = try await credentialStore.modify(providerID: providerID) { _ in stored }
      return .connected(
        .init(
          providerID: providerID, accountID: nil, authorizationKind: .apiKey, expiresAt: nil))
    }
  }

  func resolveCredential(
    providerID requestedProvider: String,
    credentialStore: any ProviderCredentialStore,
    refreshCoordinator: CredentialRefreshCoordinator
  ) async throws -> ProviderCredential? {
    guard requestedProvider == providerID else { throw routingFailure() }
    guard case .apiKey(let credential) = try await credentialStore.read(providerID: providerID),
      !credential.key.isEmpty,
      environmentFields.allSatisfy({ !(credential.metadata[$0.0] ?? "").isEmpty })
    else { return nil }
    return .apiKey(credential)
  }

  func requestAuthorization(for credential: ProviderCredential?) throws
    -> ProviderRequestAuthorization
  {
    guard providerID == "cloudflare-ai-gateway", case .apiKey(let key) = credential else {
      return .init(credential: credential, headers: [:])
    }
    return .init(
      credential: nil,
      headers: [
        "cf-aig-authorization": "Bearer \(key.key)", "Authorization": nil, "x-api-key": nil,
      ])
  }

  private func prompt(
    id: String, message: String, kind: AuthorizationPromptKind,
    interaction: AuthorizationInteraction
  ) async throws -> String {
    guard
      case .value(let value) = try await interaction(
        .prompt(providerID: providerID, id: id, message: message, kind: kind))
    else {
      throw ProviderRuntimeFailure(
        code: .authorizationFailed, message: "Cloudflare authorization was not completed",
        providerID: providerID, operation: "cloudflare.login", causeDescription: nil)
    }
    return value
  }

  private func routingFailure() -> ProviderRuntimeFailure {
    .init(
      code: .unsupportedCapability, message: "unsupported Cloudflare authorization operation",
      providerID: providerID, operation: "cloudflare.authorize", causeDescription: nil)
  }
}
