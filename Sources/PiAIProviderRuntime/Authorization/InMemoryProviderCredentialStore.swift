import Foundation

public actor InMemoryProviderCredentialStore: ProviderCredentialStore {
  private var credentials: [String: ProviderCredential]

  public init(credentials: [String: ProviderCredential] = [:]) {
    self.credentials = credentials
  }

  public func read(providerID: String) -> ProviderCredential? {
    credentials[providerID]
  }

  public func list() -> [ProviderCredentialInfo] {
    credentials.map { providerID, credential in
      ProviderCredentialInfo(providerID: providerID, kind: credential.kind)
    }.sorted { $0.providerID < $1.providerID }
  }

  public func modify(
    providerID: String,
    _ transform:
      @escaping @Sendable (
        ProviderCredential?
      ) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    let updated = try await transform(credentials[providerID])
    credentials[providerID] = updated
    return updated
  }

  public func delete(providerID: String) {
    credentials[providerID] = nil
  }
}

extension ProviderCredential {
  fileprivate var kind: AuthorizationMethodDescriptor.Kind {
    switch self {
    case .apiKey: .apiKey
    case .oauth: .oauth
    }
  }
}
