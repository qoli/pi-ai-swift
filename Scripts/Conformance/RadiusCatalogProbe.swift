import Foundation

@testable import PiAIProviderRuntime

enum RadiusCatalogConformanceProbe {
  static func resolve(_ input: [String: JSONValue], transport: any ProviderHTTPTransport)
    async throws -> [String: JSONValue]
  {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "pi-ai-radius-probe-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = root.appending(path: "catalog.json")
    if let state = input.string("catalogState"), let bytes = Data(base64Encoded: state) {
      try bytes.write(to: persistence)
    }
    let revision = try BuiltinProviderRegistry.load().upstreamRevision
    let gateway = input.string("gateway")
    let owner = input.string("catalogProvider") ?? "radius"
    if let cached = input.array("cachedModels") {
      let models = cached.filter { $0.objectValue?.string("provider") == owner }
      let baseURL =
        models.first?.objectValue?.string("baseUrl")
        ?? RadiusOAuthAuthorizationAdapter.normalizeGateway(
          gateway ?? RadiusOAuthAuthorizationAdapter.defaultGateway)
      let data = try JSONEncoder().encode(
        JSONValue.object(["baseUrl": .string(baseURL), "models": .array(models)]))
      let store = try ProviderModelStore(
        expectedRevision: revision, radiusGateway: gateway, persistenceURL: persistence)
      _ = try await store.refreshRadius { .init(data: data, checkedAt: Date()) }
    }
    let credential = try AuthorizationConformanceProbe.primaryCredential(input.object("credential"))
    let runtime = try BuiltinProviderRuntime(
      installation: .init(deviceID: nil),
      credentialStore: InMemoryProviderCredentialStore(
        credentials: credential.map { ["radius": $0] } ?? [:]),
      authorizationTransport: transport, radiusCatalogPersistenceURL: persistence,
      authorizationConfiguration: .init(radiusGateway: gateway))
    let catalog = try await runtime.catalog()
    let visible = catalog.providers.first { $0.id == "radius" }!.models
    let store = try ProviderModelStore(
      expectedRevision: revision, radiusGateway: gateway, persistenceURL: persistence)
    let records = await store.records(providerID: "radius")
    let models = visible.map { model -> JSONValue in
      let record = records.first { $0.model.id == model.id }!
      var value = record.metadata
      value["id"] = .string(model.id)
      value["provider"] = .string(owner)
      value["api"] = .string(model.protocolID)
      value["name"] = .string(model.name)
      value["baseUrl"] = record.baseURL.map(JSONValue.string)
      return .object(value)
    }
    var result: [String: JSONValue] = ["models": .array(models)]
    if FileManager.default.fileExists(atPath: persistence.path) {
      result["state"] = .string(try Data(contentsOf: persistence).base64EncodedString())
    }
    return result
  }
}
