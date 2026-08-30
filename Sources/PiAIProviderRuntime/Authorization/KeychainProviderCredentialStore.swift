import Foundation
import Security

public actor KeychainProviderCredentialStore: ProviderCredentialStore {
  private let service: String
  private let accessGroup: String?
  private var lockedProviderIDs: Set<String> = []
  private var lockWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  public init(service: String, accessGroup: String? = nil) throws {
    let normalized = service.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw Self.failure(
        .invalidRequest,
        operation: "keychain.configure",
        message: "Keychain credential service is empty"
      )
    }
    self.service = normalized
    self.accessGroup = accessGroup
  }

  public func read(providerID: String) async throws -> ProviderCredential? {
    let providerID = try normalizedProviderID(providerID)
    await acquire(providerID)
    defer { release(providerID) }
    return try load(providerID: providerID)
  }

  public func list() async throws -> [ProviderCredentialInfo] {
    var query = baseQuery()
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else {
      throw Self.keychainFailure(status, operation: "keychain.list")
    }
    guard let rows = result as? [[String: Any]] else {
      throw Self.failure(
        .invalidResponse,
        operation: "keychain.list",
        message: "Keychain credential attributes are malformed"
      )
    }

    return try rows.map { row in
      guard let providerID = row[kSecAttrAccount as String] as? String,
        !providerID.isEmpty,
        let rawKind = row[kSecAttrComment as String] as? String,
        let kind = AuthorizationMethodDescriptor.Kind(rawValue: rawKind)
      else {
        throw Self.failure(
          .invalidResponse,
          operation: "keychain.list",
          message: "Keychain credential metadata is malformed"
        )
      }
      return ProviderCredentialInfo(providerID: providerID, kind: kind)
    }.sorted { $0.providerID < $1.providerID }
  }

  public func modify(
    providerID: String,
    _ transform:
      @escaping @Sendable (
        ProviderCredential?
      ) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    let providerID = try normalizedProviderID(providerID)
    await acquire(providerID)
    defer { release(providerID) }

    let current = try load(providerID: providerID)
    let updated: ProviderCredential?
    do {
      updated = try await transform(current)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.failure(
        .invalidCredential,
        operation: "keychain.modify",
        message: "Provider credential update was rejected"
      )
    }
    if let updated {
      try save(updated, providerID: providerID)
    } else {
      try remove(providerID: providerID)
    }
    return updated
  }

  public func delete(providerID: String) async throws {
    let providerID = try normalizedProviderID(providerID)
    await acquire(providerID)
    defer { release(providerID) }
    try remove(providerID: providerID)
  }

  private func load(providerID: String) throws -> ProviderCredential? {
    var query = itemQuery(providerID: providerID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw Self.keychainFailure(status, operation: "keychain.read")
    }
    guard let data = result as? Data else {
      throw Self.failure(
        .invalidResponse,
        operation: "keychain.read",
        message: "Keychain credential payload is malformed"
      )
    }
    do {
      return try JSONDecoder().decode(ProviderCredential.self, from: data)
    } catch {
      throw Self.failure(
        .invalidCredential,
        operation: "keychain.read",
        message: "Keychain credential cannot be decoded"
      )
    }
  }

  private func save(
    _ credential: ProviderCredential,
    providerID: String
  ) throws {
    let data: Data
    do {
      data = try JSONEncoder().encode(credential)
    } catch {
      throw Self.failure(
        .invalidCredential,
        operation: "keychain.write",
        message: "Provider credential cannot be encoded"
      )
    }
    let kind: AuthorizationMethodDescriptor.Kind
    switch credential {
    case .apiKey: kind = .apiKey
    case .oauth: kind = .oauth
    }

    let query = itemQuery(providerID: providerID)
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrComment as String: kind.rawValue,
    ]
    var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var addition = query
      addition[kSecValueData as String] = data
      addition[kSecAttrComment as String] = kind.rawValue
      addition[kSecAttrAccessible as String] =
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(addition as CFDictionary, nil)
      if status == errSecDuplicateItem {
        status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
      }
    }
    guard status == errSecSuccess else {
      throw Self.keychainFailure(status, operation: "keychain.write")
    }
  }

  private func remove(providerID: String) throws {
    let status = SecItemDelete(itemQuery(providerID: providerID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.keychainFailure(status, operation: "keychain.delete")
    }
  }

  private func baseQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
  }

  private func itemQuery(providerID: String) -> [String: Any] {
    var query = baseQuery()
    query[kSecAttrAccount as String] = providerID
    return query
  }

  private func normalizedProviderID(_ providerID: String) throws -> String {
    let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw Self.failure(
        .invalidRequest,
        operation: "keychain.provider",
        message: "Keychain provider identifier is empty"
      )
    }
    return normalized
  }

  private func acquire(_ providerID: String) async {
    if lockedProviderIDs.insert(providerID).inserted { return }
    await withCheckedContinuation { continuation in
      lockWaiters[providerID, default: []].append(continuation)
    }
  }

  private func release(_ providerID: String) {
    guard var waiters = lockWaiters[providerID], !waiters.isEmpty else {
      lockedProviderIDs.remove(providerID)
      lockWaiters[providerID] = nil
      return
    }
    let next = waiters.removeFirst()
    lockWaiters[providerID] = waiters.isEmpty ? nil : waiters
    next.resume()
  }

  private static func keychainFailure(
    _ status: OSStatus,
    operation: String
  ) -> ProviderRuntimeFailure {
    failure(
      .transportFailed,
      operation: operation,
      message: "Keychain credential operation failed (status \(status))"
    )
  }

  private static func failure(
    _ code: ProviderRuntimeFailure.Code,
    operation: String,
    message: String
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: code,
      message: message,
      providerID: nil,
      operation: operation,
      causeDescription: nil
    )
  }
}
