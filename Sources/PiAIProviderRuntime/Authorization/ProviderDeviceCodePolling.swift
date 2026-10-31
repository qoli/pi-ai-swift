import Foundation

enum ProviderDeviceCodePollResult<Value> {
  case pending
  case slowDown(intervalSeconds: Double?)
  case failed(String)
  case complete(Value)
}

enum ProviderDeviceCodePolling {
  static func poll<Value>(
    intervalSeconds: Double?, expiresInSeconds: Double?, waitBeforeFirstPoll: Bool,
    clock: any ProviderOAuthClock,
    poll: () async throws -> ProviderDeviceCodePollResult<Value>
  ) async throws -> Value {
    let deadline = expiresInSeconds.map { clock.now().timeIntervalSince1970 + $0 } ?? .infinity
    var interval = max(1_000, floor((intervalSeconds ?? 5) * 1_000))
    var slowDownResponses = 0
    func remaining() -> Double { (deadline - clock.now().timeIntervalSince1970) * 1_000 }
    if waitBeforeFirstPoll, remaining() > 0 {
      try await clock.sleep(for: .milliseconds(min(interval, remaining())))
    }
    while remaining() > 0 {
      try Task.checkCancellation()
      switch try await poll() {
      case .complete(let value): return value
      case .failed(let message):
        throw oauthFailure(
          .authorizationFailed, providerID: nil, operation: "oauth.device.poll", message: message)
      case .pending: break
      case .slowDown(let reported):
        slowDownResponses += 1
        interval =
          reported.map {
            $0.isFinite && $0 > 0 ? max(1_000, floor($0 * 1_000)) : max(1_000, interval + 5_000)
          }
          ?? max(1_000, interval + 5_000)
      }
      if remaining() <= 0 { break }
      try await clock.sleep(for: .milliseconds(min(interval, remaining())))
    }
    throw oauthFailure(
      .authorizationFailed, providerID: nil, operation: "oauth.device.poll",
      message: slowDownResponses > 0
        ? "Device flow timed out after one or more slow_down responses. This is often caused by clock drift in WSL or VM environments. Please sync or restart the VM clock and try again."
        : "Device flow timed out")
  }
}
