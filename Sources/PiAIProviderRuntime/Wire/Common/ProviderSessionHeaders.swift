import Foundation

enum ProviderSessionHeaders {
  static func applyOpenCode(request: ProviderRequest, to urlRequest: inout URLRequest) {
    guard ["opencode", "opencode-go"].contains(request.providerID),
      let sessionID = request.options.sessionID, !sessionID.isEmpty
    else { return }
    urlRequest.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
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
    urlRequest.setValue(
      sessionID,
      forHTTPHeaderField: format == "openrouter" ? "x-session-id" : "x-session-affinity"
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
      urlRequest.setValue(sessionID, forHTTPHeaderField: "x-session-id")
      return
    }
    if format == "openai" { urlRequest.setValue(sessionID, forHTTPHeaderField: "session_id") }
    urlRequest.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
    urlRequest.setValue(sessionID, forHTTPHeaderField: "x-session-affinity")
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
      urlRequest.setValue(sessionID, forHTTPHeaderField: "x-session-id")
      return
    }
    if format == "openai" { urlRequest.setValue(sessionID, forHTTPHeaderField: "session_id") }
    urlRequest.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
  }
}
