import Foundation

@testable import PiAIProviderRuntime

enum RadiusCatalogFixtures {
  static func replay(_ spec: [String: JSONValue]) async throws -> JSONValue {
    let store = InMemoryProviderCredentialStore()
    let transport = RadiusCatalogFixtureTransport(config: spec["config"])
    let runtime = try BuiltinProviderRuntime(
      credentialStore: store, authorizationTransport: transport,
      authorizationConfiguration: .init(radiusGateway: spec.string("gateway")))
    let before = try await project(runtime)
    if spec["config"] != nil {
      _ = try await store.modify(providerID: "radius") { _ in
        .apiKey(.init(key: "fixture-key", metadata: [:]))
      }
    }
    let after = try await project(runtime)
    return .object([
      "id": spec["id"]!, "before": .array(before), "after": .array(after),
      "requests": .array(await transport.requests),
    ])
  }

  private static func project(_ runtime: BuiltinProviderRuntime) async throws -> [JSONValue] {
    let models = try await runtime.catalog().providers.first { $0.id == "radius" }!.models
    return models.sorted { $0.id < $1.id }.map { model in
      var value: [String: JSONValue] = [
        "id": .string(model.id), "provider": .string(model.providerID),
        "api": .string(model.protocolID), "name": .string(model.name),
      ]
      value["contextWindow"] = model.contextWindow.map { .integer(Int64($0)) }
      return .object(value)
    }
  }
}

private actor RadiusCatalogFixtureTransport: ProviderHTTPTransport {
  let config: JSONValue?
  private(set) var requests: [JSONValue] = []
  init(config: JSONValue?) { self.config = config }
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    requests.append(
      .object(["url": .string(request.url!.absoluteString), "method": .string(request.httpMethod!)])
    )
    guard let config else { throw RadiusCatalogFixtureFailure() }
    return .init(statusCode: 200, headers: [:], body: try JSONEncoder().encode(config))
  }
}
private struct RadiusCatalogFixtureFailure: LocalizedError {
  var errorDescription: String? { "Unexpected Radius catalog request" }
}
