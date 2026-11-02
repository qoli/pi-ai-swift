import Foundation

extension ProviderRuntimeFailure {
  public var isContextOverflow: Bool {
    guard !ProviderContextOverflow.matches(ProviderContextOverflow.nonOverflow, message) else {
      return false
    }
    return ProviderContextOverflow.matches(ProviderContextOverflow.overflow, message)
      || (providerID == "cerebras"
        && ProviderContextOverflow.matches(
          [#"^4(?:00|13)\s*(?:status code)?\s*\(no body\)"#], message))
  }
}

extension ProviderResponseSnapshot {
  public func isContextOverflow(contextWindow: Int?) -> Bool {
    guard let contextWindow, contextWindow != 0,
      let input = usage?.inputTokens, let cached = usage?.cachedInputTokens
    else { return false }
    let inputTokens = Double(input) + Double(cached)
    if finishReason == .stop { return inputTokens > Double(contextWindow) }
    return finishReason == .length && usage?.outputTokens == 0
      && inputTokens >= Double(contextWindow) * 0.99
  }
}

enum ProviderContextOverflow {
  static func matches(_ patterns: [String], _ message: String) -> Bool {
    patterns.contains {
      message.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
    }
  }

  static let nonOverflow = [
    #"^(Throttling error|Service unavailable):"#, #"rate limit"#, #"too many requests"#,
  ]
  static let overflow = [
    #"prompt (?:is )?too long"#,
    #"prompt exceeds max length"#,
    #"request_too_large"#,
    #"input is too long for requested model"#,
    #"exceeds the context window"#,
    #"exceeds (?:the )?(?:model'?s )?maximum context length(?: of [0-9,]+ tokens?|\s*\([0-9,]+\))"#,
    #"context window exceeded"#,
    #"input token count.*exceeds the maximum"#,
    #"maximum prompt length is [0-9]+"#,
    #"reduce the length of the messages"#,
    #"maximum context length is [0-9]+ tokens"#,
    #"exceeds (?:the )?maximum allowed input length of [0-9,]+ tokens?"#,
    #"input \([0-9]+ tokens\) is longer than the model'?s context length \([0-9]+ tokens\)"#,
    #"exceeds the limit of [0-9]+"#,
    #"exceeds the available context size"#,
    #"greater than the context length"#,
    #"context window exceeds limit"#,
    #"exceeded model token limit"#,
    #"too large for model with [0-9]+ maximum context length"#,
    #"prompt has [0-9,]+ tokens?, but the configured context size is [0-9,]+ tokens?"#,
    #"model_context_window_exceeded"#,
    #"prompt too long; exceeded (?:max )?context length"#,
    #"range of input length should be"#,
    #"context[_ ]length[_ ]exceeded"#,
    #"too many tokens"#,
    #"token limit exceeded"#,
    #"^(?:[A-Za-z0-9_ -]+ API error \(413\):|413(?:\s|:|$))"#,
  ]
}
