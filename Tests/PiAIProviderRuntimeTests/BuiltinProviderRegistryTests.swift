import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct BuiltinProviderRegistryTests {
  @Test
  func bundledCatalogPreservesPinnedProviderAndModelInventory() throws {
    let registry = try BuiltinProviderRegistry.load()
    #expect(registry.upstreamRevision == "853a80d26c90a14c1886f0ebb8ffaae133ca2185")
    #expect(registry.providers.count == 40)
    #expect(registry.providers.flatMap(\.models).count == 1_290)

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

    let radius = try #require(registry.providers.first { $0.id == "radius" })
    #expect(radius.models.isEmpty)
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
      "pi-messages",
    ]
    for provider in registry.providers {
      #expect(Set(provider.models.map(\.id)) == Set(provider.modelConfigurations.keys))
      for model in provider.models {
        #expect(knownProtocols.contains(model.protocolID))
      }
    }
  }
}
