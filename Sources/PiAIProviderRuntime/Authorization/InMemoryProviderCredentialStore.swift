import Foundation

public actor InMemoryProviderCredentialStore: ProviderCredentialStore {
  private var credentials: [String: ProviderCredential]
  private var providerOrder: [String]
  private let transactions = ProviderCredentialTransactions()

  public init(credentials: [String: ProviderCredential] = [:]) {
    self.credentials = credentials
    providerOrder = credentials.keys.sorted()
  }

  public func read(providerID: String) throws -> ProviderCredential? {
    try Task.checkCancellation()
    return credentials[providerID]
  }

  public func list() throws -> [ProviderCredentialInfo] {
    try Task.checkCancellation()
    return providerOrder.map { ProviderCredentialInfo(providerID: $0, kind: credentials[$0]!.kind) }
  }

  public func modify(
    providerID: String,
    _ transform:
      @escaping @Sendable (
        ProviderCredential?
      ) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    try await ProviderCancellableOperation.run {
      try await self.transactions.withLock(providerID) {
        try await self.update(providerID: providerID, transform)
      }
    }
  }

  public func delete(providerID: String) async throws {
    try await ProviderCancellableOperation.run {
      try await self.transactions.withLock(providerID) { try await self.remove(providerID) }
    }
  }

  private func update(
    providerID: String,
    _ transform: @escaping @Sendable (ProviderCredential?) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    try Task.checkCancellation()
    let current = credentials[providerID]
    let updated = try await transform(current)
    try Task.checkCancellation()
    if let updated {
      if current == nil { providerOrder.append(providerID) }
      credentials[providerID] = updated
    }
    return updated ?? current
  }

  private func remove(_ providerID: String) throws {
    try Task.checkCancellation()
    credentials[providerID] = nil
    providerOrder.removeAll { $0 == providerID }
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
