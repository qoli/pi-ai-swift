import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct CredentialRefreshCoordinatorTests {
  @Test func oauthResolutionMatchesPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func cases(_ folder: String) throws -> [JSONValue] {
      try JSONValue(
        jsonData: Data(
          contentsOf: root.appending(
            path: "Fixtures/Differential/\(folder)/oauth-resolution.json"))
      ).objectValue!.array("cases")!
    }
    let inputs = try cases("Cases")
    let expected = try cases("Oracle")
    #expect(inputs.count == expected.count)
    for (input, oracle) in zip(inputs, expected) {
      let actual = try await OAuthResolutionFixtures.replay(input.objectValue!)
      #expect(actual == oracle, Comment(rawValue: input.objectValue!.string("id")!))
    }
  }

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
          now: { now },
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
    #expect(try await store.read(providerID: "provider") == .oauth(refreshed))
  }

  @Test
  func preservesNormalizedProviderRefreshFailure() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let store = InMemoryProviderCredentialStore(credentials: [
      "provider": .oauth(refreshFixtureCredential(suffix: "denied", expiresAt: now))
    ])
    let coordinator = CredentialRefreshCoordinator(credentialStore: store)
    let denied = ProviderRuntimeFailure(
      code: .authorizationFailed, message: "invalid_grant: refresh token revoked",
      providerID: "provider", operation: "fixture.oauth.refresh", causeDescription: nil)
    do {
      _ = try await coordinator.credential(
        providerID: "provider", now: { now }, refresh: { _ in throw denied })
      Issue.record("denied refresh completed successfully")
    } catch let error as ProviderRuntimeFailure {
      #expect(error == denied)
    }
  }

  @Test
  func refreshFailurePreservesUnderlyingReason() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let reason = "fixture-refresh-denied"
    let store = InMemoryProviderCredentialStore(
      credentials: [
        "provider": .oauth(
          refreshFixtureCredential(suffix: "reason", expiresAt: now))
      ]
    )
    let coordinator = CredentialRefreshCoordinator(credentialStore: store)

    do {
      _ = try await coordinator.credential(
        providerID: "provider",
        now: { now },
        refresh: { _ in
          throw NSError(
            domain: "provider.\(reason)",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
          )
        }
      )
      Issue.record("failed refresh completed successfully")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .authorizationFailed)
      #expect(!error.message.contains(reason))
      #expect(error.causeDescription == reason)
    } catch {
      Issue.record("refresh error escaped without normalization: \(error)")
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
