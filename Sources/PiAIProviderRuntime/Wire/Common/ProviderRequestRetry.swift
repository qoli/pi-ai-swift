import Foundation

struct RetryingProviderHTTPTransport: ProviderHTTPStreamingTransport {
  let request: ProviderRequest
  let context: WireProtocolContext
  let transport: any ProviderHTTPStreamingTransport

  func stream(_ urlRequest: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    try await ProviderRequestRetry.stream(
      urlRequest, request: request, context: context, transport: transport)
  }
}

protocol ProviderRetryableError: Error {
  var retryStatus: Int? { get }
  var retryHeaders: [String: String]? { get }
  var retryMessage: String { get }
}

enum ProviderRequestRetry {
  static func run<Value>(
    maximumRetries: Int?, maximumDelayMilliseconds: Double?, noRetryStatuses: [Int] = [],
    clock: any ProviderOAuthClock,
    random: @Sendable () -> Double = { Double.random(in: 0..<1) },
    request: () async throws -> Value
  ) async throws -> Value {
    let maximumRetries = maximumRetries ?? 0
    var remaining = maximumRetries
    while true {
      do { return try await request() } catch {
        try Task.checkCancellation()
        guard remaining > 0, let providerError = error as? any ProviderRetryableError,
          isRetryable(providerError),
          providerError.retryStatus.map({ !noRetryStatuses.contains($0) }) ?? true
        else { throw error }
        let index = maximumRetries - remaining
        remaining -= 1
        let delay = try delayMilliseconds(
          providerError, index: index,
          maximum: maximumDelayMilliseconds, now: clock.now(), random: random())
        try await clock.sleep(for: .milliseconds(max(0, delay)))
      }
    }
  }

  static func stream(
    _ urlRequest: URLRequest, request: ProviderRequest, context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport, noRetryStatuses: [Int] = []
  ) async throws -> ProviderHTTPStreamingResponse {
    do {
      return try await run(
        maximumRetries: request.connectionOptions.maximumRetries,
        maximumDelayMilliseconds: request.connectionOptions.maximumRetryDelayMilliseconds,
        noRetryStatuses: noRetryStatuses, clock: context.clock
      ) {
        let response: ProviderHTTPStreamingResponse
        do { response = try await transport.stream(urlRequest) } catch let error as URLError
          where error.code != .cancelled
        {
          throw HTTPError(
            retryStatus: nil, retryHeaders: nil, retryMessage: error.localizedDescription,
            response: nil, underlying: error)
        }
        guard !(200..<300).contains(response.statusCode) else { return response }
        let body = try await collectErrorBody(from: response.body)
        let saved = ProviderHTTPStreamingResponse(
          statusCode: response.statusCode, headers: response.headers,
          body: AsyncThrowingStream { continuation in
            if let body { continuation.yield(Data(body.utf8)) }
            continuation.finish()
          })
        throw HTTPError(
          retryStatus: response.statusCode, retryHeaders: response.headers,
          retryMessage: ProviderErrorText.http(
            status: response.statusCode, body: body,
            emptyMessage: "Provider request failed (HTTP \(response.statusCode))"),
          response: saved, underlying: nil)
      }
    } catch let error as HTTPError {
      if let response = error.response { return response }
      throw error.underlying ?? error
    }
  }

  private static func header(_ name: String, _ error: any ProviderRetryableError) -> String? {
    error.retryHeaders?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private static func isRetryable(_ error: any ProviderRetryableError) -> Bool {
    if let value = header("x-should-retry", error) {
      if value == "true" { return true }
      if value == "false" { return false }
    }
    guard let status = error.retryStatus else { return true }
    return [408, 409, 429].contains(status) || status >= 500
  }

  private static func delayMilliseconds(
    _ error: any ProviderRetryableError, index: Int, maximum: Double?, now: Date, random: Double
  ) throws -> Double {
    var delay: Double?
    if let text = header("retry-after-ms", error), !text.isEmpty,
      let value = parseFloat(text), value.isFinite
    {
      delay = value
    }
    if delay == nil, let text = header("retry-after", error), !text.isEmpty {
      if let seconds = parseFloat(text) {
        delay = seconds * 1_000
      } else {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
          delay = date.timeIntervalSince(now) * 1_000
        }
      }
    }
    if let delay, delay.isFinite {
      let maximum = maximum ?? 60_000
      if maximum > 0, delay > maximum {
        throw ProviderRuntimeFailure(
          code: .transportFailed,
          message:
            "Server requested \(Int(ceil(delay / 1_000)))s retry delay (max: \(Int(ceil(maximum / 1_000)))s). \(error.retryMessage)",
          providerID: nil, operation: "provider.retry.delay", causeDescription: nil)
      }
      return delay
    }
    return min(0.5 * pow(2, Double(index)), 8) * 1_000 * (1 - random * 0.25)
  }

  private static func parseFloat(_ text: String) -> Double? {
    guard
      let range = text.range(
        of: #"^\s*[+-]?(?:Infinity|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)"#,
        options: .regularExpression)
    else { return nil }
    return Double(text[range].trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private struct HTTPError: ProviderRetryableError {
    let retryStatus: Int?
    let retryHeaders: [String: String]?
    let retryMessage: String
    let response: ProviderHTTPStreamingResponse?
    let underlying: (any Error)?
  }
}
