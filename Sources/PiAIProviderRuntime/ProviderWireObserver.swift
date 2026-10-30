import Foundation

/// Callbacks can run concurrently for different request IDs.
public struct ProviderWireObserver: Sendable {
  public struct Context: Sendable, Equatable, Codable {
    public let requestID: String
    public let model: ProviderModel

    public init(requestID: String, model: ProviderModel) {
      self.requestID = requestID
      self.model = model
    }
  }

  public struct Response: Sendable, Equatable, Codable {
    public let status: Int
    public let headers: [String: String]

    public init(status: Int, headers: [String: String]) {
      self.status = status
      self.headers = Dictionary(
        headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }
  }

  public typealias Payload = [String: JSONValue]
  public typealias PayloadCallback = @Sendable (inout Payload, Context) async throws -> Payload?
  public typealias ResponseCallback = @Sendable (Response, Context) async throws -> Void
  public typealias StreamEventCallback = @Sendable (JSONValue, Context) async throws -> Void

  /// Mutate in place or return a replacement; `nil` preserves in-place edits.
  public let onPayload: PayloadCallback?
  public let onResponse: ResponseCallback?
  /// Awaited after protocol parsing and before response normalization.
  public let onProviderStreamEvent: StreamEventCallback?

  public init(
    onPayload: PayloadCallback? = nil,
    onResponse: ResponseCallback? = nil,
    onProviderStreamEvent: StreamEventCallback? = nil
  ) {
    self.onPayload = onPayload
    self.onResponse = onResponse
    self.onProviderStreamEvent = onProviderStreamEvent
  }
}

struct ProviderWireObservation: Sendable {
  let observer: ProviderWireObserver?
  let context: ProviderWireObserver.Context

  init(request: ProviderRequest, wire: WireProtocolContext) {
    observer = wire.wireObserver
    context = .init(requestID: request.id, model: wire.model)
  }

  func payload(_ original: URLRequest, forceStreamingReplacement: Bool = false) async throws
    -> URLRequest
  {
    guard let callback = observer?.onPayload, let data = original.httpBody else { return original }
    var payload = try decodeJSONObject(
      data, providerID: context.model.providerID, operation: "wire-observer.payload")
    if let replacement = try await callback(&payload, context) {
      payload = replacement
      if forceStreamingReplacement { payload["stream"] = .bool(true) }
    }
    var request = original
    request.httpBody = try encodeJSONObject(
      payload, providerID: context.model.providerID, operation: "wire-observer.payload")
    return request
  }

  func response(_ response: ProviderHTTPStreamingResponse) async throws {
    try await observer?.onResponse?(
      .init(status: response.statusCode, headers: response.headers), context)
  }

  func streamEvent(_ event: JSONValue) async throws {
    try await observer?.onProviderStreamEvent?(event, context)
  }
}
