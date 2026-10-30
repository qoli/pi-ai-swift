enum ProviderSamplingParameters {
  static func resolve(
    request: ProviderRequest, context: WireProtocolContext
  ) -> [String: JSONValue] {
    let metadata = context.modelConfiguration.metadata
    let levels = ProviderReasoningEffort.allCases.filter { level in
      guard context.model.capabilities.reasoning else { return level == .off }
      let mapped = metadata.object("thinkingLevelMap")?[level.rawValue]
      if mapped == .null { return false }
      if level == .xhigh || level == .max { return mapped != nil }
      return true
    }
    let requested =
      request.options.reasoningEffort ?? (request.options.reasoningSummary == nil ? .off : .medium)
    let order = ProviderReasoningEffort.allCases
    let index = order.firstIndex(of: requested)!
    let effective =
      levels.contains(requested)
      ? requested
      : (order[index...].first(where: levels.contains)
        ?? order[..<index].reversed().first(where: levels.contains) ?? .off)
    var result = metadata.object("samplingParams") ?? [:]
    for (key, value) in metadata.object("samplingParamsByThinkingLevel")?.object(effective.rawValue)
      ?? [:]
    {
      result[key] = value
    }
    for (key, value) in request.options.providerOptions["samplingParams"]?.objectValue ?? [:] {
      result[key] = value
    }
    return result
  }
}
