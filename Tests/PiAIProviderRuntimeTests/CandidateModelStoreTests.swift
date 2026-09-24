import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct CandidateModelStoreTests {
  private let revision = "d5629e20489ccf770ed90b5a33941cb3b7ef24d0"
  private var root: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  @Test
  func frozenSchema6RoutesPreserveStoreMetadata() async throws {
    let data = try Data(contentsOf: root.appending(path: "Fixtures/Catalog/Schema6/routing.json"))
    try await verifyProjection(data)
  }

  @Test
  func explicitTypesOwnRoutesAndUnknownTypesStayOutsideSupportedStore() async throws {
    let data = try Data(contentsOf: root.appending(path: "Fixtures/Catalog/Schema6/routing.json"))
    var fixture = try JSONDecoder().decode(CandidateStoreFixture.self, from: data)
    var provider = try #require(fixture.providers.first { $0.id == "openrouter" })
    let chat = try #require(provider.models.first { $0.string("type") == "chat" })
    var image = chat
    image["type"] = .string("image")
    var unknown = chat
    unknown["type"] = .string("future-operation")
    unknown["id"] = .string("future-model")
    unknown.removeValue(forKey: "input")
    var legacy = chat
    legacy.removeValue(forKey: "type")
    legacy["id"] = .string("legacy-chat")
    provider.models = [chat, image, unknown, legacy]
    fixture.providers = [provider]
    try await verifyProjection(JSONEncoder().encode(fixture))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SCHEMA6_CATALOG_PATH"] != nil))
  func completeExactSourceCatalogPreservesEverySupportedRecord() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["SCHEMA6_CATALOG_PATH"])
    try await verifyProjection(Data(contentsOf: URL(fileURLWithPath: path)))
  }

  private func verifyProjection(_ data: Data) async throws {
    let fixture = try JSONDecoder().decode(CandidateStoreFixture.self, from: data)
    #expect(fixture.upstreamRevision == revision)
    let store = try ProviderModelStore(bundledData: data, expectedRevision: revision)
    for provider in fixture.providers {
      let expected = provider.models.filter {
        [nil, "chat", "image"].contains($0.string("type"))
      }
      let records = await store.records(providerID: provider.id)
      #expect(records.count == expected.count)
      for object in expected {
        let image =
          object.string("type") == "image"
          || (object.string("type") == nil && object.string("api") == "openrouter-images")
        let record = try #require(
          records.first {
            $0.model.id == object.string("id") && $0.model.capabilities.imageGeneration == image
          })
        #expect(record.metadata == object)
        #expect(record.model.protocolID == object.string("api"))
        let baseURL = object.string("baseUrl") ?? provider.baseURL
        #expect(record.baseURL == (baseURL?.isEmpty == true ? nil : baseURL))
        #expect(record.model.capabilities.toolCalling == !image)
        if image { #expect(!record.model.capabilities.structuredOutput) }
        #expect(record.model.contextWindow == object.int("contextWindow"))
        #expect(record.model.maximumOutputTokens == object.int("maxTokens"))
      }
    }
  }
}

private struct CandidateStoreFixture: Codable {
  let schemaVersion: Int
  let upstreamRevision: String
  var providers: [Provider]

  struct Provider: Codable {
    let id: String
    let baseURL: String?
    var models: [[String: JSONValue]]
  }
}
