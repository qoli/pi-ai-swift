import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct BuiltinProviderRegistryTests {
  @Test
  func bundledCatalogPreservesPinnedProviderAndModelInventory() throws {
    let registry = try BuiltinProviderRegistry.load()
    #expect(registry.upstreamRevision == "19451accdeec671c1f4da9eafac8fc270f510ef4")
    #expect(registry.providers.count == 41)
    #expect(registry.providers.flatMap(\.models).count == 1_494)

    let kimi = try #require(
      registry.providers.first { $0.id == "kimi-coding" }
    )
    #expect(kimi.authorizationMethodIDs == ["apiKey", "oauth"])
    #expect(kimi.models.count == 4)
    #expect(Set(kimi.models.map(\.protocolID)) == ["anthropic-messages"])
    let k3 = try #require(kimi.models.first { $0.id == "k3-256k" })
    #expect(k3.contextWindow == 262_144)
    #expect(k3.capabilities.imageInput)
    #expect(k3.capabilities.reasoning)

    let anthropic = try #require(registry.providers.first { $0.id == "anthropic" })
    let fable = try #require(anthropic.models.first { $0.id == "claude-fable-5" })
    #expect(fable.promptCache?.shortLifetimeSeconds == 300)
    #expect(fable.promptCache?.longLifetimeSeconds == 3_600)

    let radius = try #require(registry.providers.first { $0.id == "radius" })
    #expect(radius.models.count == 27)
    #expect(Set(radius.models.map(\.protocolID)) == ["pi-messages"])

    let meta = try #require(registry.providers.first { $0.id == "meta" })
    #expect(meta.authorizationMethodIDs == ["apiKey", "oauth"])
    #expect(meta.models.count == 5)
    #expect(Set(meta.models.map(\.protocolID)) == ["openai-responses"])

    let openRouter = try #require(
      registry.providers.first { $0.id == "openrouter" }
    )
    #expect(openRouter.models.count == 431)
    #expect(openRouter.modelConfigurations.count == 434)
    let overlapping = try #require(
      openRouter.models.first { $0.id == "google/gemini-3-pro-image" }
    )
    #expect(overlapping.capabilities.imageGeneration)
    #expect(
      openRouter.modelConfigurations[
        ProviderModelRoute(modelID: overlapping.id, outputModality: .text)
      ]?.protocolID == "openai-completions"
    )
    #expect(
      openRouter.modelConfigurations[
        ProviderModelRoute(modelID: overlapping.id, outputModality: .image)
      ]?.protocolID == "openrouter-images"
    )
  }

  @Test
  func everyCatalogModelHasConfigurationAndKnownWireProtocol() throws {
    let registry = try BuiltinProviderRegistry.load()
    let knownProtocols: Set<String> = [
      "anthropic-messages",
      "azure-openai-responses",
      "bedrock-converse-stream",
      "google-generative-ai",
      "google-vertex",
      "mistral-conversations",
      "openai-codex-responses",
      "openai-completions",
      "openai-responses",
      "openrouter-images",
      "pi-messages",
    ]
    for provider in registry.providers {
      #expect(
        Set(provider.models.map(\.id))
          == Set(provider.modelConfigurations.keys.map(\.modelID))
      )
      for configuration in provider.modelConfigurations.values {
        #expect(knownProtocols.contains(configuration.protocolID))
      }
      for model in provider.models {
        #expect(knownProtocols.contains(model.protocolID))
      }
    }
  }
}
