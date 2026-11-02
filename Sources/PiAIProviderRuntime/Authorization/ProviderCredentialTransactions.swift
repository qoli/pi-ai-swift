import Foundation

actor ProviderCredentialTransactions {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
  }
  private var locked: Set<String> = []
  private var waiters: [String: [Waiter]] = [:]

  func withLock<Value: Sendable>(
    _ providerID: String, operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await acquire(providerID)
    defer { release(providerID) }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquire(_ providerID: String) async throws {
    try Task.checkCancellation()
    if locked.insert(providerID).inserted { return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters[providerID, default: []].append(.init(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancel(providerID, id: id) }
    }
  }

  private func cancel(_ providerID: String, id: UUID) {
    guard let index = waiters[providerID]?.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters[providerID]!.remove(at: index)
    if waiters[providerID]!.isEmpty { waiters[providerID] = nil }
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func release(_ providerID: String) {
    guard var pending = waiters[providerID], !pending.isEmpty else {
      locked.remove(providerID)
      return
    }
    let next = pending.removeFirst()
    waiters[providerID] = pending.isEmpty ? nil : pending
    next.continuation.resume()
  }
}

enum ProviderCancellableOperation {
  @TaskLocal static var workObservation: (@Sendable (Bool) -> Void)?

  static func run<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    let result = ProviderOperationResult<Value>()
    let observation = workObservation
    observation?(true)
    let task = Task {
      defer { observation?(false) }
      do { result.finish(.success(try await operation())) } catch { result.finish(.failure(error)) }
    }
    return try await withTaskCancellationHandler {
      try await result.wait()
    } onCancel: {
      task.cancel()
      result.finish(.failure(CancellationError()))
    }
  }
}

final class ProviderOperationResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, any Error>?
  private var continuation: CheckedContinuation<Value, any Error>?

  func finish(_ result: Result<Value, any Error>) {
    let pending = lock.withLock {
      guard self.result == nil else { return nil as CheckedContinuation<Value, any Error>? }
      self.result = result
      let pending = continuation
      continuation = nil
      return pending
    }
    pending?.resume(with: result)
  }

  func wait() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      let completed: Result<Value, any Error>? = lock.withLock {
        () -> Result<Value, any Error>? in
        if let result { return result }
        self.continuation = continuation
        return nil as Result<Value, any Error>?
      }
      if let completed { continuation.resume(with: completed) }
    }
  }
}
