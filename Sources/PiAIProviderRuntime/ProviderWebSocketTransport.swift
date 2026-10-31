import Foundation

public protocol ProviderWebSocketConnection: Sendable {
  func isOpen() async -> Bool
  func send(_ text: String) async throws
  func receive() async throws -> String
  func close(code: Int, reason: String) async
}

extension ProviderWebSocketConnection {
  public func isOpen() async -> Bool { true }
}

public protocol ProviderWebSocketTransport: Sendable {
  func connect(_ request: URLRequest) async throws -> any ProviderWebSocketConnection
}

public struct URLSessionProviderWebSocketTransport: ProviderWebSocketTransport {
  private let configuration: URLSessionConfiguration

  public init(session: URLSession = .shared) { configuration = session.configuration }

  public func connect(_ request: URLRequest) async throws -> any ProviderWebSocketConnection {
    let connection = URLSessionProviderWebSocketConnection()
    try await withTaskCancellationHandler {
      try await connection.start(request, configuration: configuration)
    } onCancel: {
      connection.cancel()
    }
    return connection
  }
}

private final class URLSessionProviderWebSocketConnection: NSObject,
  URLSessionWebSocketDelegate, ProviderWebSocketConnection, @unchecked Sendable
{
  private let lock = NSLock()
  private var session: URLSession?
  private var task: URLSessionWebSocketTask?
  private var opening: CheckedContinuation<Void, any Error>?
  private var cancelled = false

  func start(_ request: URLRequest, configuration: URLSessionConfiguration) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      lock.withLock {
        guard !cancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        opening = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
      }
    }
  }

  func send(_ text: String) async throws {
    guard let task = lock.withLock({ task }) else { throw CancellationError() }
    try await task.send(.string(text))
  }

  func isOpen() async -> Bool { lock.withLock { task?.state == .running } }

  func receive() async throws -> String {
    guard let task = lock.withLock({ task }) else { throw CancellationError() }
    return try await withTaskCancellationHandler {
      switch try await task.receive() {
      case .string(let value): return value
      case .data(let value): return String(decoding: value, as: UTF8.self)
      @unknown default:
        throw ProviderRuntimeFailure(
          code: .invalidResponse, message: "Unsupported WebSocket message",
          providerID: nil, operation: "websocket.receive", causeDescription: nil)
      }
    } onCancel: {
      self.cancel()
    }
  }

  func close(code: Int, reason: String) async {
    terminate(code: code, reason: reason)
  }

  func cancel() { terminate(code: 1000, reason: "aborted") }

  private func terminate(code: Int, reason: String) {
    let state = lock.withLock {
      cancelled = true
      let state = (opening, task, session)
      opening = nil
      task = nil
      session = nil
      return state
    }
    state.0?.resume(throwing: CancellationError())
    state.1?.cancel(with: .init(rawValue: code) ?? .normalClosure, reason: Data(reason.utf8))
    state.2?.invalidateAndCancel()
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    let continuation = lock.withLock {
      let value = opening
      opening = nil
      return value
    }
    continuation?.resume()
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let text = reason.map { String(decoding: $0, as: UTF8.self) }
    let detail =
      text.flatMap { $0.isEmpty ? nil : $0 }
      ?? (closeCode.rawValue == 1009 ? "message too big" : nil)
    let continuation = lock.withLock {
      let value = opening
      opening = nil
      return value
    }
    continuation?.resume(
      throwing: ProviderRuntimeFailure(
        code: .transportFailed,
        message: "WebSocket closed \(closeCode.rawValue)" + (detail.map { " " + $0 } ?? ""),
        providerID: nil, operation: "websocket.connect", causeDescription: nil))
    session.finishTasksAndInvalidate()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let continuation = lock.withLock {
      let value = opening
      opening = nil
      return value
    }
    continuation?.resume(throwing: error ?? CancellationError())
    session.finishTasksAndInvalidate()
  }
}
