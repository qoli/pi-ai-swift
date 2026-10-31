import Foundation

final class ProbeStreamLifetime: @unchecked Sendable {
  struct Observation: Encodable, Sendable {
    let observed: Int
    let live: Int
  }

  final class Marker: Sendable {
    private let owner: ProbeStreamLifetime
    init(owner: ProbeStreamLifetime) { self.owner = owner }
    deinit { owner.released() }
  }

  static let shared = ProbeStreamLifetime()
  private let lock = NSLock()
  private var observed = 0
  private var live = 0
  private var waiting: CheckedContinuation<Observation?, Never>?

  func marker() -> Marker {
    lock.withLock {
      observed += 1
      live += 1
    }
    return Marker(owner: self)
  }

  private func released() {
    let result = lock.withLock { () -> (CheckedContinuation<Observation?, Never>?, Observation) in
      live -= 1
      let continuation = live == 0 ? waiting : nil
      if continuation != nil { waiting = nil }
      return (continuation, .init(observed: observed, live: live))
    }
    result.0?.resume(returning: result.1)
  }

  func afterScope() async -> Observation? {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if observed == 0 {
          continuation.resume(returning: nil)
        } else if live == 0 {
          continuation.resume(returning: .init(observed: observed, live: live))
        } else {
          waiting = continuation
        }
      }
    }
  }
}
