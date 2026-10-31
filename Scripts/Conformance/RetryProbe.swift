import Foundation

@testable import PiAIProviderRuntime

enum RetryConformanceProbe {
  static func run(
    _ input: [String: JSONValue], incoming: AsyncStream<[String: JSONValue]>,
    server: WireConformanceServer
  ) async {
    let channel = RetryChannel()
    let execution = Task {
      do {
        let value: JSONValue
        if input.string("operation") == "oauth.device-poll" {
          value = try await ProviderDeviceCodePolling.poll(
            intervalSeconds: double(input["intervalSeconds"]),
            expiresInSeconds: double(input["expiresInSeconds"]),
            waitBeforeFirstPoll: input.bool("waitBeforeFirstPoll") ?? false, clock: server.clock
          ) {
            let result = try await channel.request().objectValue ?? [:]
            switch result.string("status") {
            case "complete": return .complete(result["value"] ?? .null)
            case "slow_down": return .slowDown(intervalSeconds: double(result["intervalSeconds"]))
            case "failed": return .failed(result.string("message") ?? "")
            default: return .pending
            }
          }
        } else {
          value = try await ProviderRequestRetry.run(
            maximumRetries: input.int("maximumRetries"),
            maximumDelayMilliseconds: double(input["maximumDelay"]),
            noRetryStatuses: (input.array("noRetryStatuses") ?? []).compactMap(\.integerValue),
            clock: server.clock
          ) {
            try await channel.request()
          }
        }
        try ProbeChannel().write("retryResult", ["value": value])
      } catch let error as any RetryReferencedError {
        try? ProbeChannel().write("retryResult", ["errorReference": error.reference])
      } catch {
        let device = input.string("operation") == "oauth.device-poll"
        let message =
          error is CancellationError
          ? (device ? "Login cancelled" : "Request aborted")
          : (error as? ProviderRuntimeFailure)?.message ?? String(describing: error)
        try? ProbeChannel().write(
          "retryResult",
          [
            "error": message,
            "name": error is CancellationError && !device ? "AbortError" : "Error",
          ])
      }
      try? ProbeChannel().write("finished", [String: String]())
    }
    let receiver = Task {
      for await frame in incoming {
        if frame.string("kind") == "cancel" {
          execution.cancel()
          await channel.fail(CancellationError())
        } else {
          await channel.receive(frame)
        }
      }
    }
    await execution.value
    receiver.cancel()
  }

  private static func double(_ value: JSONValue?) -> Double? {
    switch value {
    case .integer(let value): Double(value)
    case .number(let value): value
    default: nil
    }
  }

  private actor RetryChannel {
    private var pending: CheckedContinuation<JSONValue, any Error>?
    func request() async throws -> JSONValue {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          pending = continuation
          do { try ProbeChannel().write("retryRequest", [String: String]()) } catch { fail(error) }
        }
      } onCancel: {
        Task { await self.fail(CancellationError()) }
      }
    }
    func receive(_ frame: [String: JSONValue]) {
      if let error = frame.object("error") {
        if error.bool("providerError") != true {
          fail(OtherFixtureError(reference: error.string("reference")!))
          return
        }
        fail(
          RetryFixtureError(
            reference: error.string("reference")!,
            retryStatus: error.int("status"),
            retryHeaders: error.object("headers")?.compactMapValues(\.stringValue),
            retryMessage: error.string("message") ?? ""))
      } else {
        pending?.resume(returning: frame["value"] ?? .null)
        pending = nil
      }
    }
    func fail(_ error: any Error) {
      pending?.resume(throwing: error)
      pending = nil
    }
  }

  private protocol RetryReferencedError: Error { var reference: String { get } }
  private struct OtherFixtureError: RetryReferencedError { let reference: String }
  private struct RetryFixtureError: ProviderRetryableError, RetryReferencedError {
    let reference: String
    let retryStatus: Int?
    let retryHeaders: [String: String]?
    let retryMessage: String
  }
}
