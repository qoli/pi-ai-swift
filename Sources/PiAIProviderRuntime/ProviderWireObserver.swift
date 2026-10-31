import Foundation

struct CodexStreamCallbackError: Error {
  let underlying: any Error
}

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
  public typealias ToolArgumentsCallback =
    @Sendable (ProviderToolArgumentsUpdate, Context) async throws -> Void

  /// Mutate in place or return a replacement; `nil` preserves in-place edits.
  public let onPayload: PayloadCallback?
  public let onResponse: ResponseCallback?
  /// Awaited after protocol parsing and before response normalization.
  public let onProviderStreamEvent: StreamEventCallback?
  /// Decoded partial arguments, awaited before the corresponding tool event.
  public let onToolArguments: ToolArgumentsCallback?

  public init(
    onPayload: PayloadCallback? = nil,
    onResponse: ResponseCallback? = nil,
    onProviderStreamEvent: StreamEventCallback? = nil,
    onToolArguments: ToolArgumentsCallback? = nil
  ) {
    self.onPayload = onPayload
    self.onResponse = onResponse
    self.onProviderStreamEvent = onProviderStreamEvent
    self.onToolArguments = onToolArguments
  }
}

struct ProviderWireObservation: Sendable {
  let observer: ProviderWireObserver?
  let context: ProviderWireObserver.Context
  private let toolArguments: ProviderToolArgumentObservation?

  init(request: ProviderRequest, wire: WireProtocolContext) {
    observer = wire.wireObserver
    context = .init(requestID: request.id, model: wire.model)
    toolArguments = wire.wireObserver?.onToolArguments == nil ? nil : .init()
  }

  func payload(_ original: URLRequest, forceStreamingReplacement: Bool = false) async throws
    -> URLRequest
  {
    guard observer?.onPayload != nil, let data = original.httpBody else { return original }
    let payload = try decodeJSONObject(
      data, providerID: context.model.providerID, operation: "wire-observer.payload")
    var request = original
    request.httpBody = try encodeJSONObject(
      try await self.payload(payload, forceStreamingReplacement: forceStreamingReplacement),
      providerID: context.model.providerID, operation: "wire-observer.payload")
    return request
  }

  func payload(_ original: ProviderWireObserver.Payload, forceStreamingReplacement: Bool = false)
    async throws -> ProviderWireObserver.Payload
  {
    guard let callback = observer?.onPayload else { return original }
    var payload = original
    if let replacement = try await callback(&payload, context) {
      payload = replacement
      if forceStreamingReplacement { payload["stream"] = .bool(true) }
    }
    return payload
  }

  func response(_ response: ProviderHTTPStreamingResponse) async throws {
    try await observer?.onResponse?(
      .init(status: response.statusCode, headers: response.headers), context)
  }

  func streamEvent(_ event: JSONValue) async throws {
    do { try await observer?.onProviderStreamEvent?(event, context) } catch {
      if context.model.protocolID == "openai-codex-responses" {
        throw CodexStreamCallbackError(underlying: error)
      }
      throw error
    }
  }

  func startToolArguments(id: String, initial: JSONValue = .object([:]), seedText: String? = nil)
    async throws
  {
    guard let callback = observer?.onToolArguments,
      let update = await toolArguments?.start(id: id, initial: initial, seedText: seedText)
    else { return }
    try await toolUpdate(update, callback: callback)
  }

  func toolEvent(_ event: ProviderEvent) async throws {
    guard let callback = observer?.onToolArguments else { return }
    switch event {
    case .toolCallStarted(let id, _): try await startToolArguments(id: id)
    case .toolInputDelta(let id, let delta):
      if let update = await toolArguments?.append(id: id, text: delta) {
        try await toolUpdate(update, callback: callback)
      }
    case .toolCallCompleted(let call): await toolArguments?.finish(id: call.id)
    default: break
    }
  }

  private func toolUpdate(
    _ update: ProviderToolArgumentsUpdate,
    callback: ProviderWireObserver.ToolArgumentsCallback
  ) async throws {
    do { try await callback(update, context) } catch {
      if context.model.protocolID == "openai-codex-responses" {
        throw CodexStreamCallbackError(underlying: error)
      }
      throw error
    }
  }
}
