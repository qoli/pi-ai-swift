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
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func stream(_ request: URLRequest) async throws
    -> ProviderHTTPStreamingResponse
  {
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw ProviderRuntimeFailure(
        code: .invalidResponse,
        message: "provider transport returned a non-HTTP response",
        providerID: nil,
        operation: "http.stream",
        causeDescription: nil
      )
    }

    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      headers[String(describing: key)] = String(describing: value)
    }

    let body = AsyncThrowingStream<Data, any Error> { continuation in
      let task = Task {
        do {
          var line = Data()
          for try await byte in bytes {
            try Task.checkCancellation()
            line.append(byte)
            if byte == 0x0A {
              continuation.yield(line)
              line.removeAll(keepingCapacity: true)
            }
          }
          if !line.isEmpty {
            continuation.yield(line)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }

    return ProviderHTTPStreamingResponse(
      statusCode: response.statusCode,
      headers: headers,
      body: body
    )
  }
}
