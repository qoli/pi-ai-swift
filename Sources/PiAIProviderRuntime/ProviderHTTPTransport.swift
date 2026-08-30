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
