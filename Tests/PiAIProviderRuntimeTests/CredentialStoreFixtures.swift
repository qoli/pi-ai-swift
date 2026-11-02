import Foundation

@testable import PiAIProviderRuntime

enum CredentialStoreFixtures {
  static func replay(
    _ spec: [String: JSONValue],
    store: any ProviderCredentialStore = InMemoryProviderCredentialStore()
  ) async throws -> JSONValue {
    let provider = "fixture"
    let scenario = spec.string("scenario")!
    var observed: [String: JSONValue] = ["id": spec["id"]!]
    if ["serial-modify", "independent-providers"].contains(scenario) {
      let independent = scenario == "independent-providers"
      _ = try await store.modify(providerID: provider) { _ in key("0") }
      if independent { _ = try await store.modify(providerID: "other") { _ in key("0") } }
      let recorder = StoreTransactionRecorder()
      let increment: @Sendable (ProviderCredential?) async throws -> ProviderCredential? = {
        current in
        let value = keyValue(current)!
        await recorder.enter(value)
        try await Task.sleep(for: .milliseconds(spec.int("holdMilliseconds")!))
        await recorder.leave()
        return key(String(Int(value)! + 1))
      }
      let first = Task { try await store.modify(providerID: provider, increment) }
      await recorder.waitForFirst()
      let second = Task {
        try await store.modify(providerID: independent ? "other" : provider, increment)
      }
      observed["results"] = .array(try await [project(first.value), project(second.value)])
      observed["reads"] = .array(await recorder.reads.map(JSONValue.string))
      observed["maximumActive"] = .integer(Int64(await recorder.maximumActive))
    } else if scenario == "delete-after-modify" {
      let recorder = StoreTransactionRecorder()
      let first = Task {
        try await store.modify(providerID: provider) { _ in
          await recorder.enter("")
          try await Task.sleep(for: .milliseconds(spec.int("holdMilliseconds")!))
          return key("rotated")
        }
      }
      await recorder.waitForFirst()
      try await store.delete(providerID: provider)
      _ = try await first.value
    } else if ["cancel-queued-modify", "cancel-active-modify", "read-during-modify"].contains(
      scenario)
    {
      _ = try await store.modify(providerID: provider) { _ in key("old") }
      let gate = StoreTransactionGate()
      let first = Task {
        try await store.modify(providerID: provider) { _ in
          await gate.block()
          return key("new")
        }
      }
      await gate.waitForFirst()
      if scenario == "read-during-modify" {
        observed["during"] = try await project(store.read(providerID: provider))
      } else {
        let recorder = StoreTransactionRecorder()
        let cancelled =
          scenario == "cancel-active-modify"
          ? first
          : Task {
            try await store.modify(providerID: provider) { _ in
              await recorder.enter("queued")
              return key("queued")
            }
          }
        cancelled.cancel()
        observed["error"] = await cancellationResult(
          cancelled, milliseconds: spec.int("observeMilliseconds")!)
        if scenario == "cancel-queued-modify" {
          observed["queuedRan"] = .bool(await !recorder.reads.isEmpty)
        }
      }
      await gate.release()
      _ = await first.result
    } else if ["noop-stored", "noop-missing"].contains(scenario) {
      if scenario == "noop-stored" {
        _ = try await store.modify(providerID: provider) { _ in key("old") }
      }
      observed["result"] = try await project(store.modify(providerID: provider) { _ in nil })
    } else if scenario == "rejected-modify" {
      _ = try await store.modify(providerID: provider) { _ in key("old") }
      do {
        _ = try await store.modify(providerID: provider) { _ in throw StoreFixtureFailure() }
      } catch { observed["error"] = .string(error.localizedDescription) }
      observed["next"] = try await project(store.modify(providerID: provider) { _ in key("next") })
    } else if scenario == "list-insertion-order" {
      _ = try await store.modify(providerID: "z-provider") { _ in key("private-fixture-z") }
      _ = try await store.modify(providerID: "a-provider") { _ in
        .oauth(
          .init(
            accessToken: "fixture", refreshToken: "fixture",
            expiresAt: .init(timeIntervalSince1970: 0), metadata: [:]))
      }
      observed["initial"] = try await projectList(store.list())
      _ = try await store.modify(providerID: "z-provider") { _ in key("replacement") }
      observed["replaced"] = try await projectList(store.list())
      try await store.delete(providerID: "z-provider")
      _ = try await store.modify(providerID: "z-provider") { _ in key("reinserted") }
      observed["reinserted"] = try await projectList(store.list())
    } else if scenario == "empty-key" {
      observed["result"] = try await project(store.modify(providerID: provider) { _ in key("") })
    }
    observed["stored"] = try await project(store.read(providerID: provider))
    return .object(observed)
  }

  private static func key(_ value: String) -> ProviderCredential {
    .apiKey(.init(key: value, metadata: [:]))
  }
  private static func keyValue(_ value: ProviderCredential?) -> String? {
    if case .apiKey(let key) = value { return key.key }
    return nil
  }
  private static func project(_ value: ProviderCredential?) -> JSONValue {
    value.map { .object(["type": .string("api_key"), "key": .string(keyValue($0)!)]) } ?? .null
  }
  private static func projectList(_ values: [ProviderCredentialInfo]) -> JSONValue {
    .array(
      values.map {
        .object([
          "providerId": .string($0.providerID),
          "type": .string($0.kind == .apiKey ? "api_key" : "oauth"),
        ])
      })
  }
  private static func cancellationResult(
    _ task: Task<ProviderCredential?, any Error>, milliseconds: Int
  ) async -> JSONValue {
    let result = StoreFixtureResult()
    let completion = Task {
      do {
        _ = try await task.value
        await result.finish(.null)
      } catch is CancellationError { await result.finish(.string("AbortError")) } catch {
        await result.finish(.string(error.localizedDescription))
      }
    }
    let timer = Task {
      do {
        try await Task.sleep(for: .milliseconds(milliseconds))
        await result.finish(.string("pending"))
      } catch {}
    }
    let value = await result.wait()
    completion.cancel()
    timer.cancel()
    return value
  }
}

private actor StoreTransactionRecorder {
  var reads: [String] = []
  var maximumActive = 0
  private var active = 0
  func enter(_ value: String) {
    reads.append(value)
    active += 1
    maximumActive = max(maximumActive, active)
  }
  func leave() { active -= 1 }
  func waitForFirst() async { while reads.isEmpty { await Task.yield() } }
}
private actor StoreTransactionGate {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?
  func block() async {
    started = true
    await withCheckedContinuation { continuation = $0 }
  }
  func waitForFirst() async { while !started { await Task.yield() } }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
private actor StoreFixtureResult {
  private var value: JSONValue?
  private var continuation: CheckedContinuation<JSONValue, Never>?
  func finish(_ value: JSONValue) {
    guard self.value == nil else { return }
    self.value = value
    continuation?.resume(returning: value)
    continuation = nil
  }
  func wait() async -> JSONValue {
    if let value { return value }
    return await withCheckedContinuation { continuation = $0 }
  }
}
private struct StoreFixtureFailure: LocalizedError {
  var errorDescription: String? { "fixture-rejection" }
}
