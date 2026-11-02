import Foundation

actor CredentialRefreshCoordinator {
  typealias RefreshOperation = @Sendable (OAuthCredential) async throws -> OAuthCredential

  private let credentialStore: any ProviderCredentialStore
  private let clock: any ProviderOAuthClock

  init(
    credentialStore: any ProviderCredentialStore,
    clock: any ProviderOAuthClock = SystemProviderOAuthClock()
  ) {
    self.credentialStore = credentialStore
    self.clock = clock
  }

  func credential(
    providerID: String,
    minimumValidity: TimeInterval? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    refresh: @escaping RefreshOperation
  ) async throws -> OAuthCredential? {
    let ownership = ProviderRefreshOwnership()
    let result = ProviderOperationResult<OAuthCredential?>()
    let store = credentialStore
    let clock = clock
    let minimum = max(300, minimumValidity ?? 0)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let task = Task<Void, Never> {
        do {
          guard case .oauth(let stored) = try await store.read(providerID: providerID) else {
            result.finish(.success(nil))
            return
          }
          guard stored.expiresAt.timeIntervalSince(now()) <= minimum else {
            result.finish(.success(stored))
            return
          }
          let post = try await store.modify(providerID: providerID) { current in
            guard ownership.begin() else { throw CancellationError() }
            guard case .oauth(let credential) = current else { return nil }
            guard credential.expiresAt.timeIntervalSince(now()) <= minimum else { return nil }
            return .oauth(
              try await Self.refreshed(
                credential, providerID: providerID, clock: clock, refresh: refresh))
          }
          guard case .oauth(let credential) = post else {
            result.finish(.success(nil))
            return
          }
          if minimumValidity != nil, credential.expiresAt.timeIntervalSince(now()) <= minimum {
            throw ProviderRuntimeFailure(
              code: .authorizationFailed,
              message: "OAuth refresh returned a token that expires too soon for \(providerID)",
              providerID: providerID, operation: "credential.refresh.validity",
              causeDescription: nil)
          }
          result.finish(.success(credential))
        } catch { result.finish(.failure(error)) }
      }
      ownership.install(task)
      return try await result.wait()
    } onCancel: {
      ownership.cancelWait()
      result.finish(.failure(CancellationError()))
    }
  }

  func logout(providerID: String) async throws {
    try await credentialStore.delete(providerID: providerID)
  }

  private static func refreshed(
    _ credential: OAuthCredential, providerID: String, clock: any ProviderOAuthClock,
    refresh: @escaping RefreshOperation
  ) async throws -> OAuthCredential {
    let operation = Task { try await refresh(credential) }
    let timeout = Task {
      do {
        try await clock.sleep(for: .seconds(15), purpose: .timeout)
        operation.cancel()
      } catch {}
    }
    let result = await operation.result
    timeout.cancel()
    _ = await timeout.result
    do { return try result.get() } catch is CancellationError {
      throw CancellationError()
    } catch let error as ProviderRuntimeFailure { throw error } catch {
      throw ProviderRuntimeFailure(
        code: .authorizationFailed, message: "OAuth credential refresh failed",
        providerID: providerID, operation: "credential.refresh",
        causeDescription: error.localizedDescription)
    }
  }
}

private final class ProviderRefreshOwnership: @unchecked Sendable {
  private enum Phase { case waiting, started, cancelled }
  private let lock = NSLock()
  private var phase = Phase.waiting
  private var task: Task<Void, Never>?

  func install(_ task: Task<Void, Never>) {
    let cancelled = lock.withLock {
      if phase == .cancelled { return true }
      if phase == .waiting { self.task = task }
      return false
    }
    if cancelled { task.cancel() }
  }

  func begin() -> Bool {
    lock.withLock {
      guard phase == .waiting else { return false }
      phase = .started
      task = nil
      return true
    }
  }

  func cancelWait() {
    let task = lock.withLock {
      guard phase == .waiting else { return nil as Task<Void, Never>? }
      phase = .cancelled
      let pending = self.task
      self.task = nil
      return pending
    }
    task?.cancel()
  }
}
