import CryptoKit
import Foundation

enum ProviderSessionHeaders {
  static func openCodeHeaders(sessionID: String?, headers: [String: String?]?) -> (
    headers: [String: String?]?, changed: Bool
  ) {
    guard let sessionID, !sessionID.isEmpty,
      headers?.keys.contains(where: {
        $0.caseInsensitiveCompare("x-opencode-session") == .orderedSame
      }) != true
    else { return (headers, false) }
    var headers = headers ?? [:]
    headers["x-opencode-session"] = sessionID
    return (headers, true)
  }

  static func applyOpenCode(request: ProviderRequest, to urlRequest: inout URLRequest) {
    guard ["opencode", "opencode-go"].contains(request.providerID) else { return }
    var sessionID = request.options.sessionID
    if request.providerID == "opencode-go", sessionID?.isEmpty != false {
      // Go requires a routing ID. Keep it scoped to the request without sending the host's raw ID.
      sessionID =
        request.id.isEmpty
        ? UUID().uuidString
        : SHA256.hash(data: Data(request.id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    guard let sessionID,
      openCodeHeaders(sessionID: sessionID, headers: request.connectionOptions.headers).changed
    else { return }
    setDefault(sessionID, forHTTPHeaderField: "x-opencode-session", to: &urlRequest)
  }

  static func applyAnthropicAffinity(
    request: ProviderRequest,
    context: WireProtocolContext,
    compat: [String: JSONValue],
    to urlRequest: inout URLRequest
  ) {
    guard request.options.cacheRetention != .none,
      let sessionID = request.options.sessionID, !sessionID.isEmpty
    else { return }
    let isOpenRouter =
      request.providerID == "openrouter"
      || context.baseURL.host?.contains("openrouter.ai") == true
    guard compat.bool("sendSessionAffinityHeaders") ?? isOpenRouter else { return }
    let format = compat.string("sessionAffinityFormat") ?? (isOpenRouter ? "openrouter" : nil)
    setDefault(
      sessionID,
      forHTTPHeaderField: format == "openrouter" ? "x-session-id" : "x-session-affinity",
      to: &urlRequest
    )
  }

  static func applyOpenAICompletionsAffinity(
    request: ProviderRequest,
    context: WireProtocolContext,
    compat: [String: JSONValue],
    to urlRequest: inout URLRequest
  ) {
    guard request.options.cacheRetention != .none,
      let sessionID = request.options.sessionID, !sessionID.isEmpty
    else { return }
    let isOpenRouter =
      request.providerID == "openrouter"
      || context.baseURL.host?.contains("openrouter.ai") == true
    guard compat.bool("sendSessionAffinityHeaders") ?? isOpenRouter else { return }
    let format = compat.string("sessionAffinityFormat") ?? (isOpenRouter ? "openrouter" : "openai")
    if format == "openrouter" {
      setDefault(sessionID, forHTTPHeaderField: "x-session-id", to: &urlRequest)
      return
    }
    if format == "openai" {
      setDefault(sessionID, forHTTPHeaderField: "session_id", to: &urlRequest)
    }
    setDefault(sessionID, forHTTPHeaderField: "x-client-request-id", to: &urlRequest)
    setDefault(sessionID, forHTTPHeaderField: "x-session-affinity", to: &urlRequest)
  }

  static func applyOpenAIResponsesAffinity(
    request: ProviderRequest,
    context: WireProtocolContext,
    compat: [String: JSONValue],
    to urlRequest: inout URLRequest
  ) {
    guard request.options.cacheRetention != .none,
      let sessionID = request.options.sessionID, !sessionID.isEmpty
    else { return }
    let isOpenRouter =
      request.providerID == "openrouter"
      || context.baseURL.host?.contains("openrouter.ai") == true
    let format = compat.string("sessionAffinityFormat") ?? (isOpenRouter ? "openrouter" : "openai")
    if format == "openrouter" {
      setDefault(sessionID, forHTTPHeaderField: "x-session-id", to: &urlRequest)
      return
    }
    if format == "openai" {
      setDefault(sessionID, forHTTPHeaderField: "session_id", to: &urlRequest)
    }
    setDefault(sessionID, forHTTPHeaderField: "x-client-request-id", to: &urlRequest)
  }

  private static func setDefault(
    _ value: String, forHTTPHeaderField field: String, to request: inout URLRequest
  ) {
    if request.value(forHTTPHeaderField: field) == nil {
      request.setValue(value, forHTTPHeaderField: field)
    }
  }
}
