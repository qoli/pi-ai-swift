import Foundation
import Network
import Testing

@testable import PiAIProviderRuntime

@Suite(.serialized)
struct ProviderHTTPTransportTests {
  @Test
  func bufferedTransportPreservesStatusHeadersAndBody() async throws {
    TransportURLProtocolState.shared.reset()
    let (session, transport) = makeBufferedTransport()
    defer { session.invalidateAndCancel() }

    let response = try await transport.send(request(path: "buffered"))

    #expect(response.statusCode == 207)
    #expect(response.headers["X-Fixture"] == "buffered")
    #expect(response.body == Data("buffered-body".utf8))
    #expect(TransportURLProtocolState.shared.requestCount(path: "/buffered") == 1)
  }

  @Test
  func bufferedAndStreamingTransportsRejectNonHTTPResponses() async {
    TransportURLProtocolState.shared.reset()
    let configuration = fixtureConfiguration()
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    do {
      _ = try await URLSessionProviderHTTPTransport(session: session).send(
        request(path: "non-http")
      )
      Issue.record("buffered transport accepted a non-HTTP response")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .invalidResponse)
      #expect(error.operation == "http.send")
    } catch {
      Issue.record("unexpected buffered error: \(error)")
    }

    do {
      _ = try await URLSessionProviderHTTPStreamingTransport(session: session).stream(
        request(path: "non-http")
      )
      Issue.record("streaming transport accepted a non-HTTP response")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .invalidResponse)
      #expect(error.operation == "http.stream")
    } catch {
      Issue.record("unexpected streaming error: \(error)")
    }

    #expect(TransportURLProtocolState.shared.requestCount(path: "/non-http") == 2)
  }

  @Test
  func streamingTransportPreservesStatusHeadersAndAllArbitrarilyFragmentedBytes() async throws {
    TransportURLProtocolState.shared.reset()
    let (session, transport) = makeStreamingTransport()
    defer { session.invalidateAndCancel() }

    let response = try await transport.stream(request(path: "fragmented"))
    var chunks: [Data] = []
    for try await chunk in response.body { chunks.append(chunk) }

    #expect(response.statusCode == 206)
    #expect(response.headers["X-Fixture"] == "fragmented")
    #expect(!chunks.isEmpty)
    #expect(chunks.reduce(into: Data(), { $0.append($1) }) == Data("alpha\nbeta\ntrailing".utf8))
    #expect(TransportURLProtocolState.shared.requestCount(path: "/fragmented") == 1)
  }

  @Test
  func cancellingBodyConsumerCancelsTheUnderlyingURLSessionTask() async throws {
    let server = try LoopbackStreamingServer()
    try await server.start()
    let session = URLSession(configuration: .ephemeral)
    let transport = URLSessionProviderHTTPStreamingTransport(session: session)
    defer {
      session.invalidateAndCancel()
      server.stop()
    }

    let response = try await transport.stream(server.request())
    let consumer = Task {
      for try await _ in response.body {
        server.recordConsumerChunk()
      }
    }
    defer { consumer.cancel() }
    try await server.waitUntilConsumerChunk()
    consumer.cancel()
    try await server.waitUntilClientClosed()
    _ = await consumer.result

    #expect(server.acceptedConnectionCount() == 1)
  }

  @Test
  func urlSessionErrorsRemainTheThrownCauseAndAreNotRetried() async {
    TransportURLProtocolState.shared.reset()
    let configuration = fixtureConfiguration()
    let bufferedSession = URLSession(configuration: configuration)
    defer { bufferedSession.invalidateAndCancel() }

    do {
      _ = try await URLSessionProviderHTTPTransport(session: bufferedSession).send(
        request(path: "transport-error")
      )
      Issue.record("buffered transport swallowed its URL loading error")
    } catch {
      expectFixtureTransportCause(error)
    }
    #expect(TransportURLProtocolState.shared.requestCount(path: "/transport-error") == 1)

    let streamingSession = URLSession(configuration: configuration)
    defer { streamingSession.invalidateAndCancel() }
    do {
      let response = try await URLSessionProviderHTTPStreamingTransport(
        session: streamingSession
      ).stream(request(path: "stream-error"))
      for try await _ in response.body {}
      Issue.record("streaming transport swallowed its URL loading error")
    } catch {
      expectFixtureTransportCause(error)
    }
    #expect(TransportURLProtocolState.shared.requestCount(path: "/stream-error") == 1)
  }
}

private func makeBufferedTransport() -> (
  URLSession, URLSessionProviderHTTPTransport
) {
  let session = URLSession(configuration: fixtureConfiguration())
  return (session, URLSessionProviderHTTPTransport(session: session))
}

private func makeStreamingTransport() -> (
  URLSession, URLSessionProviderHTTPStreamingTransport
) {
  let session = URLSession(configuration: fixtureConfiguration())
  return (session, URLSessionProviderHTTPStreamingTransport(session: session))
}

private func fixtureConfiguration() -> URLSessionConfiguration {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [TransportFixtureURLProtocol.self]
  return configuration
}

private func request(path: String) -> URLRequest {
  URLRequest(url: URL(string: "https://transport-fixture.invalid/\(path)")!)
}

private func expectFixtureTransportCause(_ error: any Error) {
  let value = error as NSError
  if value.domain == TransportFixtureURLProtocol.errorDomain {
    #expect(value.code == TransportFixtureURLProtocol.errorCode)
    return
  }
  let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
  #expect(underlying?.domain == TransportFixtureURLProtocol.errorDomain)
  #expect(underlying?.code == TransportFixtureURLProtocol.errorCode)
}

private final class TransportFixtureURLProtocol: URLProtocol, @unchecked Sendable {
  static let errorDomain = "PiAIProviderRuntimeTests.Transport"
  static let errorCode = 77

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "transport-fixture.invalid"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let path = request.url?.path ?? ""
    TransportURLProtocolState.shared.recordStarted(path: path)
    switch path {
    case "/buffered":
      respondHTTP(status: 207, headers: ["X-Fixture": "buffered"])
      client?.urlProtocol(self, didLoad: Data("buffered-body".utf8))
      client?.urlProtocolDidFinishLoading(self)
    case "/non-http":
      let response = URLResponse(
        url: request.url!,
        mimeType: "application/octet-stream",
        expectedContentLength: 4,
        textEncodingName: nil
      )
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data("body".utf8))
      client?.urlProtocolDidFinishLoading(self)
    case "/fragmented":
      respondHTTP(status: 206, headers: ["X-Fixture": "fragmented"])
      for value in ["al", "pha\nb", "et", "a\ntr", "ailing"] {
        client?.urlProtocol(self, didLoad: Data(value.utf8))
      }
      client?.urlProtocolDidFinishLoading(self)
    case "/transport-error":
      fail()
    case "/stream-error":
      respondHTTP(status: 200, headers: [:])
      client?.urlProtocol(self, didLoad: Data("partial".utf8))
      fail()
    default:
      respondHTTP(status: 404, headers: [:])
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}

  private func respondHTTP(status: Int, headers: [String: String]) {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }

  private func fail() {
    client?.urlProtocol(
      self,
      didFailWithError: NSError(
        domain: Self.errorDomain,
        code: Self.errorCode,
        userInfo: [NSLocalizedDescriptionKey: "fixture transport failed"]
      )
    )
  }
}

private final class TransportURLProtocolState: @unchecked Sendable {
  static let shared = TransportURLProtocolState()

  private let lock = NSLock()
  private var counts: [String: Int] = [:]

  func reset() {
    lock.withLock {
      counts = [:]
    }
  }

  func recordStarted(path: String) {
    lock.withLock { counts[path, default: 0] += 1 }
  }

  func requestCount(path: String) -> Int {
    lock.withLock { counts[path, default: 0] }
  }

}

private struct TransportFixtureTimeout: Error {
  let message: String
}

private final class LoopbackStreamingServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "PiAIProviderRuntimeTests.LoopbackStreamingServer")
  private let lock = NSLock()
  private let listener: NWListener
  private var connection: NWConnection?
  private var port: UInt16?
  private var connections = 0
  private var consumerChunks = 0
  private var clientClosed = false
  private var startupError: (any Error)?

  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.lock.withLock { self.port = self.listener.port?.rawValue }
      case .failed(let error):
        self.lock.withLock { self.startupError = error }
      default:
        break
      }
    }
  }

  func start() async throws {
    listener.start(queue: queue)
    try await waitUntil("loopback listener did not start") {
      self.lock.withLock { self.port != nil || self.startupError != nil }
    }
    if let error = lock.withLock({ startupError }) { throw error }
  }

  func stop() {
    let connection = lock.withLock { self.connection }
    connection?.cancel()
    listener.cancel()
  }

  func request() -> URLRequest {
    let port = lock.withLock { self.port! }
    return URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream")!)
  }

  func recordConsumerChunk() {
    lock.withLock { consumerChunks += 1 }
  }

  func acceptedConnectionCount() -> Int {
    lock.withLock { connections }
  }

  func waitUntilConsumerChunk() async throws {
    try await waitUntil("stream consumer received no loopback chunk") {
      self.lock.withLock { self.consumerChunks > 0 }
    }
  }

  func waitUntilClientClosed() async throws {
    try await waitUntil("cancelling the body consumer did not close the URLSession connection") {
      self.lock.withLock { self.clientClosed }
    }
  }

  private func accept(_ connection: NWConnection) {
    lock.withLock {
      self.connection = connection
      connections += 1
    }
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self, weak connection] _, _, _, error in
      guard let self, let connection, error == nil else { return }
      let response = Data(
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nready\r\n"
          .utf8
      )
      connection.send(
        content: response,
        completion: .contentProcessed { [weak self] error in
          guard let self, error == nil else { return }
          self.observeClientClosure(connection)
        })
    }
  }

  private func observeClientClosure(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
      [weak self, weak connection] data, _, complete, error in
      guard let self else { return }
      if complete || error != nil {
        self.lock.withLock { self.clientClosed = true }
      } else if data?.isEmpty == false, let connection {
        self.observeClientClosure(connection)
      } else if let connection {
        self.observeClientClosure(connection)
      }
    }
  }

  private func waitUntil(
    _ message: String,
    predicate: @escaping @Sendable () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !predicate() {
      guard clock.now < deadline else { throw TransportFixtureTimeout(message: message) }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
