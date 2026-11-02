import Foundation

@testable import PiAIProviderRuntime

enum OAuthRefreshLifecycleFixtures {
  static func replay(_ spec: [String: JSONValue]) async throws -> JSONValue {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let scenario = spec.string("scenario")!
    let milliseconds = spec.int("observeMilliseconds")!
    let old = OAuthCredential(
      accessToken: "old-access", refreshToken: "old-refresh", expiresAt: now, metadata: [:])
    let external: ProviderCredential =
      scenario == "replace-kind"
      ? .apiKey(.init(key: "external-key", metadata: [:]))
      : .oauth(
        .init(
          accessToken: "external-access", refreshToken: "old-refresh",
          expiresAt: now.addingTimeInterval(3_600), metadata: [:]))
    let store = InMemoryProviderCredentialStore(credentials: ["fixture": .oauth(old)])
    let recorder = OAuthLifecycleRecorder()
    let clock = OAuthLifecycleClock(recorder: recorder, date: now)
    let coordinator = CredentialRefreshCoordinator(credentialStore: store, clock: clock)
    let otherCoordinator = CredentialRefreshCoordinator(credentialStore: store, clock: clock)
    let refreshGate = OAuthLifecycleGate()
    let refresh: CredentialRefreshCoordinator.RefreshOperation = { current in
      let index = await recorder.refreshed()
      if scenario == "refresh-failure" { throw OAuthLifecycleDenied() }
      if ["concurrent", "cancel-active", "logout"].contains(scenario) { await refreshGate.block() }
      await recorder.cancelled(Task.isCancelled)
      return OAuthCredential(
        accessToken: "fresh-access-\(index)", refreshToken: "fresh-refresh-\(index)",
        expiresAt: now.addingTimeInterval(3_600), metadata: current.metadata)
    }
    func resolve(_ owner: CredentialRefreshCoordinator) -> Task<JSONValue, Never> {
      Task {
        do {
          let value = try await owner.credential(
            providerID: "fixture", now: { now }, refresh: refresh)
          return value.map { .string($0.accessToken) } ?? .null
        } catch { return projectError(error) }
      }
    }
    var result: [String: JSONValue] = ["id": spec["id"]!]
    if scenario == "refresh-failure" {
      result["result"] = await resolve(coordinator).value
    } else if ["cancel-queued", "replace-oauth", "replace-kind"].contains(scenario) {
      let writeGate = OAuthLifecycleGate()
      let write = Task {
        try await store.modify(providerID: "fixture") { current in
          await writeGate.block()
          return scenario == "cancel-queued" ? current : external
        }
      }
      await writeGate.waitUntilStarted()
      let caller = resolve(coordinator)
      try await Task.sleep(for: .milliseconds(milliseconds))
      if scenario == "cancel-queued" {
        caller.cancel()
        result["beforeRelease"] = await race(
          caller, milliseconds: milliseconds, pending: .string("pending"))
      }
      await writeGate.release()
      _ = try await write.value
      result["result"] = await caller.value
    } else {
      let first = resolve(coordinator)
      await refreshGate.waitUntilStarted()
      if scenario == "concurrent" {
        let second = resolve(otherCoordinator)
        try await Task.sleep(for: .milliseconds(milliseconds))
        await refreshGate.release()
        result["results"] = .array(await [first.value, second.value])
      } else if scenario == "cancel-active" {
        first.cancel()
        result["beforeRelease"] = await race(
          first, milliseconds: milliseconds, pending: .string("pending"))
        await refreshGate.release()
        result["result"] = await first.value
        _ = try await store.modify(providerID: "fixture") { _ in nil }
      } else {
        let deletion = Task<JSONValue, Never> {
          do {
            try await coordinator.logout(providerID: "fixture")
            return .bool(true)
          } catch { return projectError(error) }
        }
        result["deletedBeforeRelease"] = await race(
          deletion, milliseconds: milliseconds, pending: .bool(false))
        await refreshGate.release()
        result["result"] = await first.value
        _ = await deletion.value
      }
    }
    result["refreshCount"] = .integer(Int64(await recorder.refreshCount))
    result["refreshCancelled"] = .bool(await recorder.refreshCancelled)
    result["timeouts"] = .array(await recorder.timeouts.map { .integer(Int64($0)) })
    result["stored"] = project(try await store.read(providerID: "fixture"))
    return .object(result)
  }

  private static func projectError(_ error: any Error) -> JSONValue {
    if error is CancellationError { return .object(["error": .string("AbortError")]) }
    guard let failure = error as? ProviderRuntimeFailure else {
      return .object(["error": .string(error.localizedDescription)])
    }
    var result: [String: JSONValue] = [
      "error": .string(failure.code == .authorizationFailed ? "oauth" : failure.code.rawValue)
    ]
    if let cause = failure.causeDescription { result["reason"] = .string(cause) }
    return .object(result)
  }
  private static func project(_ credential: ProviderCredential?) -> JSONValue {
    switch credential {
    case .none: .null
    case .apiKey(let value): .object(["type": .string("api_key"), "key": .string(value.key)])
    case .oauth(let value):
      .object([
        "type": .string("oauth"), "access": .string(value.accessToken),
        "refresh": .string(value.refreshToken),
        "expires": .integer(Int64((value.expiresAt.timeIntervalSince1970 * 1_000).rounded())),
      ])
    }
  }
  private static func race(_ task: Task<JSONValue, Never>, milliseconds: Int, pending: JSONValue)
    async -> JSONValue
  {
    let result = OAuthLifecycleResult()
    let completion = Task { await result.finish(task.value) }
    let timer = Task {
      do {
        try await Task.sleep(for: .milliseconds(milliseconds))
        await result.finish(pending)
      } catch {}
    }
    let value = await result.wait()
    completion.cancel()
    timer.cancel()
    return value
  }
}

private actor OAuthLifecycleRecorder {
  var refreshCount = 0
  var refreshCancelled = false
  var timeouts: [Int] = []
  func refreshed() -> Int {
    refreshCount += 1
    return refreshCount
  }
  func cancelled(_ value: Bool) { refreshCancelled = value }
  func timeout(_ milliseconds: Int) { timeouts.append(milliseconds) }
}
private struct OAuthLifecycleClock: ProviderOAuthClock {
  let recorder: OAuthLifecycleRecorder
  let date: Date
  func now() -> Date { date }
  func sleep(for duration: Duration) async throws {
    let components = duration.components
    let milliseconds = Int(
      components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    await recorder.timeout(milliseconds)
    try await Task.sleep(for: duration)
  }
}
private actor OAuthLifecycleGate {
  private var started = false
  private var released = false
  private var continuations: [CheckedContinuation<Void, Never>] = []
  func block() async {
    started = true
    if released { return }
    await withCheckedContinuation { continuations.append($0) }
  }
  func waitUntilStarted() async { while !started { await Task.yield() } }
  func release() {
    released = true
    let pending = continuations
    continuations = []
    for continuation in pending { continuation.resume() }
  }
}
private actor OAuthLifecycleResult {
  private var value: JSONValue?
  private var continuation: CheckedContinuation<JSONValue, Never>?
  func finish(_ value: JSONValue) {
    if self.value != nil { return }
    self.value = value
    continuation?.resume(returning: value)
    continuation = nil
  }
  func wait() async -> JSONValue {
    if let value { return value }
    return await withCheckedContinuation { continuation = $0 }
  }
}
private struct OAuthLifecycleDenied: LocalizedError {
  var errorDescription: String? { "fixture-refresh-denied" }
}
