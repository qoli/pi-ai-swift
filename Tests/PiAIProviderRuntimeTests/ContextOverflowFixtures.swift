import Foundation

@testable import PiAIProviderRuntime

enum ContextOverflowFixtures {
  static func replay(_ input: [String: JSONValue]) -> JSONValue {
    let reason = input.string("finishReason")!
    let result: Bool
    if reason == "error" {
      result =
        ProviderRuntimeFailure(
          code: .invalidResponse, message: input.string("errorMessage")!,
          providerID: input.string("provider"), operation: nil, causeDescription: nil
        ).isContextOverflow
    } else {
      let snapshot = ProviderResponseSnapshot(
        responseID: nil, providerID: input.string("provider")!,
        protocolID: "openai-completions", modelID: "fixture", responseModelID: nil, content: [],
        usage: ProviderUsage(
          inputTokens: input.int("input"), outputTokens: input.int("output"), reasoningTokens: nil,
          cachedInputTokens: input.int("cacheRead"), providerMetadata: [:]),
        finishReason: reason == "toolUse"
          ? .toolCalls
          : reason == "aborted"
            ? .cancelled
            : ProviderFinishReason(rawValue: reason)!,
        rawFinishReason: nil, timestampMilliseconds: 0)
      result = snapshot.isContextOverflow(contextWindow: input.int("contextWindow"))
    }
    return .object(["id": input["id"]!, "overflow": .bool(result)])
  }
}
