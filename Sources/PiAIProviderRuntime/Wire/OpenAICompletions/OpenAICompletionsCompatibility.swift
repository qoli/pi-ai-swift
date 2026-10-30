enum OpenAICompletionsCompatibility {
  static func resolve(_ context: WireProtocolContext) -> [String: JSONValue] {
    let provider = context.model.providerID
    let baseURL = context.baseURL.absoluteString
    let isZai =
      provider == "zai" || provider == "zai-coding-cn"
      || baseURL.contains("api.z.ai") || baseURL.contains("open.bigmodel.cn")
    let isTogether =
      provider == "together" || baseURL.contains("api.together.ai")
      || baseURL.contains("api.together.xyz")
    let isMoonshot =
      provider == "moonshotai" || provider == "moonshotai-cn"
      || baseURL.contains("api.moonshot.")
    let isOpenRouter = provider == "openrouter" || baseURL.contains("openrouter.ai")
    let isCloudflareWorkers =
      provider == "cloudflare-workers-ai" || baseURL.contains("api.cloudflare.com")
    let isCloudflareGateway =
      provider == "cloudflare-ai-gateway" || baseURL.contains("gateway.ai.cloudflare.com")
    let isNvidia = provider == "nvidia" || baseURL.contains("integrate.api.nvidia.com")
    let isAntLing = provider == "ant-ling" || baseURL.contains("api.ant-ling.com")
    let isCerebras = provider == "cerebras" || baseURL.contains("cerebras.ai")
    let isDeepSeek = provider == "deepseek" || baseURL.lowercased().contains("deepseek.com")
    let isGrok = provider == "xai" || baseURL.contains("api.x.ai")
    let isNonStandard =
      isNvidia || isCerebras || isGrok || isTogether
      || baseURL.contains("chutes.ai") || isDeepSeek || isZai || isMoonshot
      || provider == "opencode" || baseURL.contains("opencode.ai")
      || isCloudflareWorkers || isCloudflareGateway || isAntLing
    let useMaxTokens =
      baseURL.contains("chutes.ai") || isDeepSeek || isMoonshot
      || isCloudflareGateway || isTogether || isNvidia || isAntLing || isZai
    let developerRole =
      isOpenRouter
      && (context.model.id.hasPrefix("anthropic/") || context.model.id.hasPrefix("openai/"))
    let thinkingFormat =
      isDeepSeek
      ? "deepseek"
      : isZai
        ? "zai"
        : isTogether
          ? "together"
          : isAntLing ? "ant-ling" : isOpenRouter ? "openrouter" : "openai"
    var result: [String: JSONValue] = [
      "supportsStore": .bool(!isNonStandard),
      "supportsDeveloperRole": .bool(developerRole || (!isNonStandard && !isOpenRouter)),
      "supportsReasoningEffort": .bool(
        !isGrok && !isZai && !isMoonshot && !isTogether
          && !isCloudflareGateway && !isNvidia && !isAntLing),
      "supportsUsageInStreaming": .bool(true),
      "supportsFinishReason": .bool(true),
      "maxTokensField": .string(useMaxTokens ? "max_tokens" : "max_completion_tokens"),
      "requiresToolResultName": .bool(false),
      "requiresAssistantAfterToolResult": .bool(false),
      "requiresThinkingAsText": .bool(false),
      "requiresReasoningContentOnAssistantMessages": .bool(isDeepSeek),
      "thinkingFormat": .string(thinkingFormat),
      "openRouterRouting": .object([:]),
      "vercelGatewayRouting": .object([:]),
      "chatTemplateKwargs": .object([:]),
      "chatTemplateArgs": .object([:]),
      "zaiToolStream": .bool(false),
      "supportsThinkingTokenBudget": .bool(false),
      "supportsStrictMode": .bool(false),
      "supportsOpenAIGrammarTools": .bool(false),
      "supportsMidConvoSystemMessages": .bool(false),
      "supportsMidConvoToolAdditions": .bool(false),
      "sendSessionAffinityHeaders": .bool(isOpenRouter),
      "sessionAffinityFormat": .string(isOpenRouter ? "openrouter" : "openai"),
      "supportsLongCacheRetention": .bool(
        !(isTogether || isCloudflareWorkers || isCloudflareGateway
          || isNvidia || isAntLing)),
    ]
    if provider == "openrouter", context.model.id.hasPrefix("anthropic/") {
      result["cacheControlFormat"] = .string("anthropic")
    }
    for (key, value) in context.modelConfiguration.metadata.object("compat") ?? [:]
    where value != .null || key == "vllmPriority" {
      result[key] = value
    }
    return result
  }
}
