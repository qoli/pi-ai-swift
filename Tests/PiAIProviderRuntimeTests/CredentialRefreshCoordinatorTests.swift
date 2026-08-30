import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct CredentialRefreshCoordinatorTests {
  @Test
  func coalescesConcurrentRefreshAndCommitsRotatedCredentialOnce() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let source = refreshFixtureCredential(
      suffix: "old",
      expiresAt: now.addingTimeInterval(5)
    )
    let refreshed = refreshFixtureCredential(
      suffix: "new",
      expiresAt: now.addingTimeInterval(3_600)
    )
    let store = InMemoryProviderCredentialStore(
      credentials: ["provider": .oauth(source)]
    )
    let coordinator = CredentialRefreshCoordinator(credentialStore: store)
    let gate = CredentialRefreshGate(result: refreshed)

    let tasks = (0..<16).map { _ in
      Task {
        try await coordinator.credential(
          providerID: "provider",
          minimumValidity: 60,
          now: now,
          refresh: { credential in
            #expect(credential == source)
            return await gate.run()
          }
        )
      }
    }
    await gate.waitUntilStarted()
    #expect(await gate.callCount() == 1)
    await gate.release()

    for task in tasks {
      #expect(try await task.value == refreshed)
    }
    #expect(await gate.callCount() == 1)
    #expect(await store.read(providerID: "provider") == .oauth(refreshed))
  }

  @Test
  func logoutCancelsInFlightRefreshWithoutResurrectingCredential() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let source = refreshFixtureCredential(
      suffix: "logout-old",
      expiresAt: now
    )
    let refreshed = refreshFixtureCredential(
      suffix: "logout-new",
      expiresAt: now.addingTimeInterval(3_600)
    )
    let store = InMemoryProviderCredentialStore(
      credentials: ["provider": .oauth(source)]
    )
    let coordinator = CredentialRefreshCoordinator(credentialStore: store)
    let gate = CredentialRefreshGate(result: refreshed)
    let task = Task {
      try await coordinator.credential(
        providerID: "provider",
        now: now,
        refresh: { _ in await gate.run() }
      )
    }

    await gate.waitUntilStarted()
    try await coordinator.logout(providerID: "provider")
    await gate.release()
    do {
      _ = try await task.value
      Issue.record("logout race returned a refreshed credential")
    } catch is CancellationError {
    } catch {
      Issue.record("logout race returned an unexpected error: \(error)")
    }
    #expect(await store.read(providerID: "provider") == nil)
  }

  @Test
  func externalCredentialChangeWinsRefreshRaceExplicitly() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let source = refreshFixtureCredential(
      suffix: "race-old",
      expiresAt: now
    )
    let refreshed = refreshFixtureCredential(
      suffix: "race-new",
      expiresAt: now.addingTimeInterval(3_600)
    )
    let store = InMemoryProviderCredentialStore(
      credentials: ["provider": .oauth(source)]
    )
    let coordinator = CredentialRefreshCoordinator(credentialStore: store)
    let gate = CredentialRefreshGate(result: refreshed)
    let task = Task {
      try await coordinator.credential(
        providerID: "provider",
        now: now,
        refresh: { _ in await gate.run() }
      )
    }

    await gate.waitUntilStarted()
    await store.delete(providerID: "provider")
    await gate.release()
    do {
      _ = try await task.value
      Issue.record("credential race silently overwrote external state")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .authorizationFailed)
      #expect(error.operation == "credential.refresh")
    } catch {
      Issue.record("credential race returned an unexpected error: \(error)")
    }
    #expect(await store.read(providerID: "provider") == nil)
  }

  @Test
  func refreshFailureRedactsUnderlyingSecretBearingError() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let secret = "must-not-escape-\(UUID().uuidString)"
    let store = InMemoryProviderCredentialStore(
      credentials: [
        "provider": .oauth(
          refreshFixtureCredential(suffix: "redact", expiresAt: now))
      ]
    )
    let coordinator = CredentialRefreshCoordinator(credentialStore: store)

    do {
      _ = try await coordinator.credential(
        providerID: "provider",
        now: now,
        refresh: { _ in
          throw NSError(
            domain: "provider.\(secret)",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: secret]
          )
        }
      )
      Issue.record("secret-bearing refresh error completed successfully")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .authorizationFailed)
      #expect(!String(describing: error).contains(secret))
      #expect(!error.message.contains(secret))
      #expect(error.causeDescription == nil)
    } catch {
      Issue.record("refresh error escaped without redaction: \(error)")
    }
  }
}

private actor CredentialRefreshGate {
  private let result: OAuthCredential
  private var calls = 0
  private var continuation: CheckedContinuation<OAuthCredential, Never>?

  init(result: OAuthCredential) {
    self.result = result
  }

  func run() async -> OAuthCredential {
    calls += 1
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilStarted() async {
    while calls == 0 {
      await Task.yield()
    }
  }

  func callCount() -> Int { calls }

  func release() {
    continuation?.resume(returning: result)
    continuation = nil
  }
}

private func refreshFixtureCredential(
  suffix: String,
  expiresAt: Date
) -> OAuthCredential {
  OAuthCredential(
    accessToken: "access-\(suffix)",
    refreshToken: "refresh-\(suffix)",
    expiresAt: expiresAt,
    metadata: ["fixture": suffix]
  )
}
