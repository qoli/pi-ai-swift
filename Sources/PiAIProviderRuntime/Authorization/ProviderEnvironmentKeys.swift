import Foundation

enum ProviderEnvironmentKeys {
  static func configuredNames(
    providerID: String, context: ProviderAuthenticationContext
  ) async throws -> [String] {
    var found: [String] = []
    for name in names[providerID] ?? [] {
      if let value = try await context.environment(name), !value.isEmpty { found.append(name) }
    }
    return found
  }

  static func firstAPIKey(
    providerID: String, variables: [String]? = nil,
    environment: (String) async throws -> String?
  ) async throws -> (name: String, value: String)? {
    for name in variables ?? names[providerID] ?? [] {
      if providerID == "anthropic", name == "ANTHROPIC_AUTH_TOKEN" { continue }
      if let value = try await environment(name), !value.isEmpty { return (name, value) }
    }
    return nil
  }

  static let names: [String: [String]] = [
    "ant-ling": ["ANT_LING_API_KEY"],
    "qwen-token-plan": ["QWEN_TOKEN_PLAN_API_KEY"],
    "qwen-token-plan-cn": ["QWEN_TOKEN_PLAN_CN_API_KEY"],
    "qwen-token-plan-individual": ["QWEN_TOKEN_PLAN_API_KEY"],
    "openai": ["OPENAI_API_KEY"],
    "azure": ["AZURE_OPENAI_API_KEY"],
    "nvidia": ["NVIDIA_API_KEY"],
    "deepseek": ["DEEPSEEK_API_KEY"],
    "google": ["GEMINI_API_KEY"],
    "google-vertex": ["GOOGLE_CLOUD_API_KEY"],
    "groq": ["GROQ_API_KEY"],
    "cerebras": ["CEREBRAS_API_KEY"],
    "xai": ["XAI_API_KEY"],
    "typesafe": ["TYPESAFE_API_KEY"],
    "radius": ["RADIUS_API_KEY"],
    "openrouter": ["OPENROUTER_API_KEY"],
    "vercel-ai-gateway": ["AI_GATEWAY_API_KEY"],
    "zai": ["ZAI_API_KEY"],
    "zai-coding-cn": ["ZAI_CODING_CN_API_KEY"],
    "mistral": ["MISTRAL_API_KEY"],
    "minimax": ["MINIMAX_API_KEY"],
    "minimax-cn": ["MINIMAX_CN_API_KEY"],
    "moonshotai": ["MOONSHOT_API_KEY"],
    "moonshotai-cn": ["MOONSHOT_API_KEY"],
    "huggingface": ["HF_TOKEN"],
    "fireworks": ["FIREWORKS_API_KEY"],
    "together": ["TOGETHER_API_KEY"],
    "baseten": ["BASETEN_API_KEY"],
    "opencode": ["OPENCODE_API_KEY"],
    "opencode-go": ["OPENCODE_API_KEY"],
    "kimi-coding": ["KIMI_API_KEY"],
    "meta": ["META_API_KEY"],
    "cloudflare-workers-ai": ["CLOUDFLARE_API_KEY"],
    "cloudflare-ai-gateway": ["CLOUDFLARE_API_KEY"],
    "xiaomi": ["XIAOMI_API_KEY"],
    "xiaomi-token-plan-cn": ["XIAOMI_TOKEN_PLAN_CN_API_KEY"],
    "xiaomi-token-plan-ams": ["XIAOMI_TOKEN_PLAN_AMS_API_KEY"],
    "xiaomi-token-plan-sgp": ["XIAOMI_TOKEN_PLAN_SGP_API_KEY"],
    "github-copilot": ["COPILOT_GITHUB_TOKEN"],
    "anthropic": ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"],
  ]
}
