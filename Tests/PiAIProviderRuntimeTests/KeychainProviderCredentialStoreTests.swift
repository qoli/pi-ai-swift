import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct KeychainProviderCredentialStoreTests {
  @Test
  func roundTripsListsUpdatesAndDeletesCredentialsWithoutExposingSecrets()
    async throws
  {
    let store = try KeychainProviderCredentialStore(
      service: "pi-ai-swift.tests.\(UUID().uuidString)"
    )
    let apiSecret = "api-secret-\(UUID().uuidString)"
    let oauthAccess = "oauth-access-\(UUID().uuidString)"
    let oauthRefresh = "oauth-refresh-\(UUID().uuidString)"

    _ = try await store.modify(providerID: "api-provider") { _ in
      .apiKey(
        APIKeyCredential(
          key: apiSecret,
          metadata: ["region": "test"]
        ))
    }
    _ = try await store.modify(providerID: "oauth-provider") { _ in
      .oauth(
        OAuthCredential(
          accessToken: oauthAccess,
          refreshToken: oauthRefresh,
          expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
          metadata: ["accountID": "fixture"]
        ))
    }

    #expect(
      try await store.read(providerID: "api-provider")
        == .apiKey(
          APIKeyCredential(
            key: apiSecret,
            metadata: ["region": "test"]
          )))
    #expect(
      try await store.list()
        == [
          ProviderCredentialInfo(providerID: "api-provider", kind: .apiKey),
          ProviderCredentialInfo(providerID: "oauth-provider", kind: .oauth),
        ])

    _ = try await store.modify(providerID: "api-provider") { current in
      guard case .apiKey(let credential) = current else {
        Issue.record("Keychain update did not receive the current credential")
        return current
      }
      return .apiKey(
        APIKeyCredential(
          key: credential.key,
          metadata: ["region": "updated"]
        ))
    }
    guard
      case .apiKey(let updated)? = try await store.read(
        providerID: "api-provider"
      )
    else {
      Issue.record("updated Keychain credential is missing")
      return
    }
    #expect(updated.key == apiSecret)
    #expect(updated.metadata == ["region": "updated"])

    try await store.delete(providerID: "api-provider")
    try await store.delete(providerID: "oauth-provider")
    #expect(try await store.read(providerID: "api-provider") == nil)
    #expect(try await store.list().isEmpty)
  }

  @Test
  func serializesConcurrentModifyTransformsForOneProvider() async throws {
    let store = try KeychainProviderCredentialStore(
      service: "pi-ai-swift.tests.\(UUID().uuidString)"
    )
    _ = try await store.modify(providerID: "provider") { _ in
      .apiKey(
        APIKeyCredential(key: "fixture-secret", metadata: ["count": "0"]))
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<12 {
        group.addTask {
          _ = try await store.modify(providerID: "provider") { current in
            await Task.yield()
            guard case .apiKey(let credential) = current,
              let count = Int(credential.metadata["count"] ?? "")
            else {
              throw ProviderRuntimeFailure(
                code: .invalidCredential,
                message: "fixture credential is malformed",
                providerID: "provider",
                operation: "fixture.modify",
                causeDescription: nil
              )
            }
            return .apiKey(
              APIKeyCredential(
                key: credential.key,
                metadata: ["count": String(count + 1)]
              ))
          }
        }
      }
      try await group.waitForAll()
    }

    guard
      case .apiKey(let credential)? = try await store.read(
        providerID: "provider"
      )
    else {
      Issue.record("concurrently updated credential is missing")
      return
    }
    #expect(credential.metadata["count"] == "12")
    try await store.delete(providerID: "provider")
  }
}
