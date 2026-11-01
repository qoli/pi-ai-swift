import Foundation

@testable import PiAIProviderRuntime

enum ReasoningSelectionFixtures {
  static func replay(_ input: [String: JSONValue]) async throws -> JSONValue {
    let metadata = input.object("model")!
    let runtime = try CustomProviderRuntime(
      providers: [
        .init(
          id: "fixture", baseURL: URL(string: "https://fixture.invalid/v1")!,
          api: "openai-completions",
          models: [
            .init(
              id: "fixture",
              capabilities: .init(
                textInput: true, imageInput: false,
                toolCalling: false, reasoning: metadata.bool("reasoning")!, structuredOutput: false,
                imageGeneration: false), metadata: metadata)
          ])
      ], credentialStore: InMemoryProviderCredentialStore())
    let model = try await runtime.catalog().providers[0].models[0]
    let requested = ProviderReasoningEffort(rawValue: input.string("requested")!)!
    return .object([
      "id": input["id"]!,
      "supported": .array(model.supportedReasoningEfforts.map { .string($0.rawValue) }),
      "clamped": .string(model.clampReasoningEffort(requested).rawValue),
    ])
  }
}
