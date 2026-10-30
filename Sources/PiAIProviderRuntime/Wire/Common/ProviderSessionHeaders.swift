import Foundation

enum ProviderSessionHeaders {
  static func applyOpenCode(request: ProviderRequest, to urlRequest: inout URLRequest) {
    guard
      ["opencode", "opencode-go"].contains(request.providerID)
        || urlRequest.url?.host == "opencode.ai",
      let sessionID = request.options.sessionID, !sessionID.isEmpty
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
