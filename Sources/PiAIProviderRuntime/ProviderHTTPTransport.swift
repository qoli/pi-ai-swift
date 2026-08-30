import Foundation

public struct ProviderHTTPResponse: Sendable, Equatable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String], body: Data) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
}

public protocol ProviderHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse
}

public struct URLSessionProviderHTTPTransport: ProviderHTTPTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw ProviderRuntimeFailure(
        code: .invalidResponse,
        message: "provider transport returned a non-HTTP response",
        providerID: nil,
        operation: "http.send",
        causeDescription: nil
      )
    }

    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      headers[String(describing: key)] = String(describing: value)
    }
    return ProviderHTTPResponse(
      statusCode: response.statusCode,
      headers: headers,
      body: data
    )
  }
}

public struct ProviderHTTPStreamingResponse: Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: AsyncThrowingStream<Data, any Error>

  public init(
    statusCode: Int,
    headers: [String: String],
    body: AsyncThrowingStream<Data, any Error>
  ) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
}

public protocol ProviderHTTPStreamingTransport: Sendable {
  func stream(_ request: URLRequest) async throws
    -> ProviderHTTPStreamingResponse
}

public struct URLSessionProviderHTTPStreamingTransport:
  ProviderHTTPStreamingTransport
{
  private let configuration: URLSessionConfiguration

  public init(session: URLSession = .shared) {
    configuration = session.configuration
  }

  public func stream(_ request: URLRequest) async throws
    -> ProviderHTTPStreamingResponse
  {
    let delegate = StreamingDataDelegate()
    let response = try await withTaskCancellationHandler {
      try await delegate.start(request: request, configuration: configuration)
    } onCancel: {
      delegate.cancel()
    }

    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      headers[String(describing: key)] = String(describing: value)
    }

    return ProviderHTTPStreamingResponse(
      statusCode: response.statusCode,
      headers: headers,
      body: delegate.body
    )
  }
}

private final class StreamingDataDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  let body: AsyncThrowingStream<Data, any Error>

  private let bodyContinuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var responseContinuation: CheckedContinuation<HTTPURLResponse, any Error>?
  private var task: URLSessionDataTask?
  private var session: URLSession?
  private var terminated = false

  override init() {
    let pair = AsyncThrowingStream<Data, any Error>.makeStream(of: Data.self)
    body = pair.stream
    bodyContinuation = pair.continuation
    super.init()
    bodyContinuation.onTermination = { [weak self] _ in
      self?.cancel()
    }
  }

  func start(
    request: URLRequest,
    configuration: URLSessionConfiguration
  ) async throws -> HTTPURLResponse {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      guard !terminated else {
        lock.unlock()
        continuation.resume(throwing: CancellationError())
        return
      }
      responseContinuation = continuation
      let session = URLSession(
        configuration: configuration,
        delegate: self,
        delegateQueue: nil
      )
      self.session = session
      let task = session.dataTask(with: request)
      self.task = task
      lock.unlock()
      task.resume()
    }
  }

  func cancel() {
    let response: CheckedContinuation<HTTPURLResponse, any Error>?
    let task: URLSessionDataTask?
    let session: URLSession?
    lock.lock()
    guard !terminated else {
      lock.unlock()
      return
    }
    terminated = true
    response = responseContinuation
    responseContinuation = nil
    task = self.task
    session = self.session
    self.task = nil
    self.session = nil
    lock.unlock()

    task?.cancel()
    session?.invalidateAndCancel()
    response?.resume(throwing: CancellationError())
    bodyContinuation.finish(throwing: CancellationError())
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      finish(
        throwing: ProviderRuntimeFailure(
          code: .invalidResponse,
          message: "provider transport returned a non-HTTP response",
          providerID: nil,
          operation: "http.stream",
          causeDescription: nil
        )
      )
      return
    }
    let continuation: CheckedContinuation<HTTPURLResponse, any Error>?
    lock.lock()
    continuation = responseContinuation
    responseContinuation = nil
    lock.unlock()
    continuation?.resume(returning: response)
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    bodyContinuation.yield(data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    finish(throwing: error)
  }

  private func finish(throwing error: (any Error)?) {
    let response: CheckedContinuation<HTTPURLResponse, any Error>?
    let session: URLSession?
    lock.lock()
    guard !terminated else {
      lock.unlock()
      return
    }
    terminated = true
    response = responseContinuation
    responseContinuation = nil
    session = self.session
    task = nil
    self.session = nil
    lock.unlock()

    if let error {
      response?.resume(throwing: error)
      bodyContinuation.finish(throwing: error)
    } else if let response {
      let failure = ProviderRuntimeFailure(
        code: .invalidResponse,
        message: "provider transport completed before receiving HTTP headers",
        providerID: nil,
        operation: "http.stream",
        causeDescription: nil
      )
      response.resume(throwing: failure)
      bodyContinuation.finish(throwing: failure)
    } else {
      bodyContinuation.finish()
    }
    session?.finishTasksAndInvalidate()
  }
}
