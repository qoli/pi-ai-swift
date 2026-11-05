import Foundation

@testable import PiAIProviderRuntime

enum OAuthMetadataFixtures {
  static func project(_ providers: [JSONValue]) async throws -> [JSONValue] {
    let runtime = try BuiltinProviderRuntime(
      installation: .init(deviceID: nil), credentialStore: InMemoryProviderCredentialStore())
    let catalog = try await runtime.catalog()
    return try providers.map { provider in
      let providerID = provider.stringValue!
      let method = catalog.providers
        .first { $0.id == (providerID == "openai-chatgpt" ? "openai" : providerID) }?
        .authorizationMethods.first { $0.kind == .oauth }
      let encoded = try method.map { try JSONValue(jsonData: JSONEncoder().encode($0)) }
      return .object([
        "provider": provider, "metadata": encoded?.objectValue?["oauthMetadata"] ?? .null,
      ])
    }
  }
}
