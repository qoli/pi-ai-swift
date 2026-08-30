import Testing

@testable import PiAIProviderRuntime

@Suite
struct APIKeyAuthorizationAdapterTests {
  @Test
  func loginUsesSecretChallengeAndStoresTrimmedKey() async throws {
    let store = AuthorizationCredentialStore()
    let adapter = makeAdapter()

    let state = try await adapter.authorize(
      .login(providerID: "provider", methodID: "api-key"),
      interaction: { challenge in
        guard case .prompt(let providerID, let id, let message, let kind) = challenge
        else {
          Issue.record("API-key login emitted a non-prompt challenge")
          return .acknowledged
        }
        #expect(providerID == "provider")
        #expect(id == "api-key")
        #expect(message == "Provider API key")
        #expect(kind == .secret)
        return .value("  fixture-key  ")
      },
      credentialStore: store
    )

    #expect(
      state
        == .connected(
          ProviderAccount(
            providerID: "provider",
            accountID: nil,
            authorizationKind: .apiKey,
            expiresAt: nil
          )
        ))
    #expect(
      await store.read(providerID: "provider")
        == .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:])))
  }

  @Test
  func logoutDeletesOnlyTheExactProviderCredential() async throws {
    let store = AuthorizationCredentialStore(
      values: [
        "provider": .apiKey(APIKeyCredential(key: "fixture", metadata: [:])),
        "other": .apiKey(APIKeyCredential(key: "other", metadata: [:])),
      ])

    let state = try await makeAdapter().authorize(
      .logout(providerID: "provider"),
      interaction: { _ in
        Issue.record("logout unexpectedly requested interaction")
        return .acknowledged
      },
      credentialStore: store
    )

    #expect(state == .disconnected(providerID: "provider"))
    #expect(await store.read(providerID: "provider") == nil)
    #expect(await store.read(providerID: "other") != nil)
  }

  @Test
  func wrongProviderMethodResponseAndEmptyKeyFailExplicitly() async {
    let store = AuthorizationCredentialStore()
    let adapter = makeAdapter()

    await expectAuthorizationFailure(
      adapter,
      operation: .login(providerID: "other", methodID: "api-key"),
      store: store,
      response: .value("key"),
      code: .unsupportedProvider
    )
    await expectAuthorizationFailure(
      adapter,
      operation: .login(providerID: "provider", methodID: "oauth"),
      store: store,
      response: .value("key"),
      code: .unsupportedCapability
    )
    await expectAuthorizationFailure(
      adapter,
      operation: .login(providerID: "provider", methodID: "api-key"),
      store: store,
      response: .acknowledged,
      code: .authorizationFailed
    )
    await expectAuthorizationFailure(
      adapter,
      operation: .login(providerID: "provider", methodID: "api-key"),
      store: store,
      response: .value(" \n "),
      code: .invalidCredential
    )
    #expect(await store.read(providerID: "provider") == nil)
  }
}

private actor AuthorizationCredentialStore: ProviderCredentialStore {
  private var values: [String: ProviderCredential]

  init(values: [String: ProviderCredential] = [:]) {
    self.values = values
  }

  func read(providerID: String) -> ProviderCredential? {
    values[providerID]
  }

  func list() -> [ProviderCredentialInfo] {
    values.map { providerID, credential in
      ProviderCredentialInfo(
        providerID: providerID,
        kind: credential.authorizationKind
      )
    }
  }

  func modify(
    providerID: String,
    _ transform:
      @escaping @Sendable (ProviderCredential?) async throws
      -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    let next = try await transform(values[providerID])
    values[providerID] = next
    return next
  }

  func delete(providerID: String) {
    values[providerID] = nil
  }
}

extension ProviderCredential {
  fileprivate var authorizationKind: AuthorizationMethodDescriptor.Kind {
    switch self {
    case .apiKey: .apiKey
    case .oauth: .oauth
    }
  }
}

private func makeAdapter() -> APIKeyAuthorizationAdapter {
  APIKeyAuthorizationAdapter(
    providerID: "provider",
    methodID: "api-key",
    label: "Provider API key"
  )
}

private func expectAuthorizationFailure(
  _ adapter: APIKeyAuthorizationAdapter,
  operation: AuthorizationOperation,
  store: AuthorizationCredentialStore,
  response: AuthorizationResponse,
  code: ProviderRuntimeFailure.Code
) async {
  do {
    _ = try await adapter.authorize(
      operation,
      interaction: { _ in response },
      credentialStore: store
    )
    Issue.record("invalid authorization completed successfully")
  } catch let error as ProviderRuntimeFailure {
    #expect(error.code == code)
  } catch {
    Issue.record("unexpected error type: \(error)")
  }
}
