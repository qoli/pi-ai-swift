import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct BuiltinProviderRuntimeTests {
  @Test
  func exposesCompleteCatalogAndRoutesGenericAPIKeyAuthorization() async throws {
    let store = InMemoryProviderCredentialStore()
    let runtime = try BuiltinProviderRuntime(
      credentialStore: store,
      streamingTransport: RuntimeUnusedStreamingTransport(),
      authorizationTransport: RuntimeUnusedHTTPTransport()
    )
    let catalog = try await runtime.catalog()
    #expect(catalog.providers.count == 40)
    #expect(catalog.providers.flatMap(\.models).count == 1_290)

    let state = try await runtime.authorize(
      .login(providerID: "kimi-coding", methodID: "api-key")
    ) { challenge in
      guard case .prompt(let providerID, _, _, .secret) = challenge else {
        Issue.record("expected secret prompt")
        return .acknowledged
      }
      #expect(providerID == "kimi-coding")
      return .value(" fixture-kimi-key ")
    }
    #expect(
      state
        == .connected(
          ProviderAccount(
            providerID: "kimi-coding",
            accountID: nil,
            authorizationKind: .apiKey,
            expiresAt: nil
          )
        )
    )
    #expect(
      await store.read(providerID: "kimi-coding")
        == .apiKey(APIKeyCredential(key: "fixture-kimi-key", metadata: [:]))
    )
  }
}

private struct RuntimeUnusedStreamingTransport: ProviderHTTPStreamingTransport {
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    throw ProviderRuntimeFailure(
      code: .transportFailed,
      message: "unused",
      providerID: nil,
      operation: "fixture",
      causeDescription: nil
    )
  }
}

private struct RuntimeUnusedHTTPTransport: ProviderHTTPTransport {
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    throw ProviderRuntimeFailure(
      code: .transportFailed,
      message: "unused",
      providerID: nil,
      operation: "fixture",
      causeDescription: nil
    )
  }
}
