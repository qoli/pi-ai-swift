import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct BuiltinProviderRegistryTests {
  @Test
  func bundledCatalogPreservesPinnedProviderAndModelInventory() throws {
    let registry = try BuiltinProviderRegistry.load()
    #expect(registry.upstreamRevision == "86dc686cf2fd795b2b24af3d614bb0e1307bcd76")
    #expect(registry.providers.count == 42)
    #expect(registry.providers.flatMap(\.models).count == 1_710)

    let kimi = try #require(
      registry.providers.first { $0.id == "kimi-coding" }
    )
    #expect(kimi.authorizationMethodIDs == ["apiKey", "oauth"])
    #expect(kimi.models.count == 6)
    #expect(Set(kimi.models.map(\.protocolID)) == ["openai-completions"])
    let k3 = try #require(kimi.models.first { $0.id == "k3-256k" })
    #expect(k3.contextWindow == 262_144)
    #expect(k3.capabilities.imageInput)
    #expect(k3.capabilities.reasoning)

    let anthropic = try #require(registry.providers.first { $0.id == "anthropic" })
    let fable = try #require(anthropic.models.first { $0.id == "claude-fable-5" })
    #expect(fable.promptCache?.shortLifetimeSeconds == 300)
    #expect(fable.promptCache?.longLifetimeSeconds == 3_600)

    let radius = try #require(registry.providers.first { $0.id == "radius" })
    #expect(radius.models.count == 28)
    #expect(Set(radius.models.map(\.protocolID)) == ["pi-messages"])

    let meta = try #require(registry.providers.first { $0.id == "meta" })
    #expect(meta.authorizationMethodIDs == ["apiKey", "oauth"])
    #expect(meta.models.count == 6)
    #expect(Set(meta.models.map(\.protocolID)) == ["openai-responses"])

    let openRouter = try #require(
      registry.providers.first { $0.id == "openrouter" }
    )
    #expect(openRouter.models.count == 484)
    #expect(openRouter.modelConfigurations.count == 488)
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
  func schema6PreservesChatImageAndClassifierRoutes() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appending(path: "Fixtures/Catalog/Schema6/routing.json"))
    let fixture = try JSONDecoder().decode(Schema6RoutingFixture.self, from: data)
    let registry = try BuiltinProviderRegistry.load(data: data)
    #expect(registry.upstreamRevision == "86dc686cf2fd795b2b24af3d614bb0e1307bcd76")

    for source in fixture.providers {
      let provider = try #require(registry.providers.first { $0.id == source.id })
      let supported = source.models
      #expect(provider.modelConfigurations.count == supported.count)
      #expect(Set(provider.models.map(\.id)) == Set(supported.compactMap { $0.string("id") }))
      for object in source.models {
        let id = try #require(object.string("id"))
        let modality: ProviderOutputModality =
          object.string("type") == "classifier"
          ? .classification : object.string("type") == "image" ? .image : .text
        let route = ProviderModelRoute(modelID: id, outputModality: modality)
        let configuration = try #require(provider.modelConfigurations[route])
        #expect(configuration.metadata == object)
        #expect(configuration.protocolID == object.string("api"))
        #expect(configuration.baseURL == object.string("baseUrl").flatMap { $0.isEmpty ? nil : $0 })
        let model = try #require(provider.models.first { $0.id == id })
        let sameID = supported.filter { $0.string("id") == id }
        let chat = sameID.first { $0.string("type") == "chat" }
        #expect(
          model.capabilities.imageGeneration == sameID.contains { $0.string("type") == "image" })
        #expect(model.capabilities.toolCalling == (chat != nil))
        #expect(
          model.capabilities.classification == sameID.contains { $0.string("type") == "classifier" }
        )
        #expect(model.protocolID == (chat ?? object).string("api"))

        // Project each original record alone as well: merging equal IDs must
        // not conceal image records accidentally acquiring chat capabilities.
        var isolatedSource = source
        isolatedSource.models = [object]
        let isolatedFixture = Schema6RoutingFixture(
          schemaVersion: fixture.schemaVersion,
          upstreamRevision: fixture.upstreamRevision,
          providers: [isolatedSource]
        )
        let isolatedRegistry = try BuiltinProviderRegistry.load(
          data: JSONEncoder().encode(isolatedFixture))
        let isolated = try #require(isolatedRegistry.providers.first?.models.first)
        #expect(isolated.capabilities.imageGeneration == (modality == .image))
        #expect(isolated.capabilities.classification == (modality == .classification))
        #expect(isolated.capabilities.toolCalling == (modality == .text))
        #expect(isolated.capabilities.structuredOutput == (modality == .text))
        #expect(isolated.contextWindow == object.int("contextWindow"))
        #expect(isolated.maximumOutputTokens == object.int("maxTokens"))
      }
    }
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
      "typesafe-system-one", "cloudflare-workers-ai-system-one", "openai-decisions",
      "llama-cpp-classify",
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

private struct Schema6RoutingFixture: Codable {
  let schemaVersion: Int
  let upstreamRevision: String
  let providers: [Provider]

  struct Provider: Codable {
    let id: String
    let name: String
    let baseURL: String?
    let headers: [String: String]
    let authorizationMethods: [String]
    var models: [[String: JSONValue]]
  }
}
