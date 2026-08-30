import Foundation

struct BuiltinProviderRegistry: Sendable {
  let upstreamRevision: String
  let providers: [BuiltinProviderRecord]

  static func load() throws -> BuiltinProviderRegistry {
    guard
      let url = Bundle.module.url(
        forResource: "BuiltinCatalog",
        withExtension: "json"
      )
    else {
      throw failure("bundled provider catalog is missing")
    }
    let data = try Data(contentsOf: url)
    let document = try JSONDecoder().decode(BuiltinCatalogDocument.self, from: data)
    guard document.schemaVersion == 1 else {
      throw failure(
        "unsupported bundled provider catalog schema: \(document.schemaVersion)"
      )
    }
    return BuiltinProviderRegistry(
      upstreamRevision: document.upstreamRevision,
      providers: try document.providers.map(BuiltinProviderRecord.init(document:))
    )
  }

  private static func failure(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .upstreamDrift,
      message: message,
      providerID: nil,
      operation: "catalog.load",
      causeDescription: nil
    )
  }
}

struct BuiltinProviderRecord: Sendable {
  let id: String
  let name: String
  let baseURL: String?
  let headers: [String: String]
  let authorizationMethodIDs: [String]
  let models: [ProviderModel]
  let modelConfigurations: [ProviderModelRoute: ProviderModelConfiguration]

  fileprivate init(document: BuiltinProviderDocument) throws {
    id = document.id
    name = document.name
    baseURL = try Self.parseOptionalURLTemplate(document.baseURL)
    headers = document.headers
    authorizationMethodIDs = document.authorizationMethods

    var parsedModels: [String: ProviderModel] = [:]
    var configurations: [ProviderModelRoute: ProviderModelConfiguration] = [:]
    for value in document.models {
      guard case .object(let object) = value else {
        throw Self.failure(document.id, "model catalog entry is not an object")
      }
      let modelID = try object.requiredString("id", providerID: document.id)
      let providerID = try object.requiredString(
        "provider",
        providerID: document.id
      )
      guard providerID == document.id else {
        throw Self.failure(
          document.id,
          "model \(modelID) belongs to unexpected provider \(providerID)"
        )
      }
      let protocolID = try object.requiredString(
        "api",
        providerID: document.id
      )
      let inputs = object.stringArray("input")
      let reasoning = object.bool("reasoning") ?? false
      let outputModality: ProviderOutputModality =
        protocolID == "openrouter-images" ? .image : .text
      let incoming = ProviderModel(
        id: modelID,
        providerID: providerID,
        name: object.string("name") ?? modelID,
        protocolID: protocolID,
        capabilities: ProviderCapabilities(
          textInput: inputs.contains("text"),
          imageInput: inputs.contains("image"),
          toolCalling: protocolID != "openrouter-images",
          reasoning: reasoning,
          structuredOutput: Self.supportsStructuredOutput(protocolID),
          imageGeneration: protocolID == "openrouter-images"
        ),
        contextWindow: object.int("contextWindow"),
        maximumOutputTokens: object.int("maxTokens")
      )
      let route = ProviderModelRoute(
        modelID: modelID,
        outputModality: outputModality
      )
      guard configurations[route] == nil else {
        throw Self.failure(
          document.id,
          "duplicate model route: \(modelID)/\(outputModality.rawValue)"
        )
      }
      if let existing = parsedModels[modelID] {
        parsedModels[modelID] = Self.merge(
          existing,
          incoming,
          preferIncomingProtocol: outputModality == .text
        )
      } else {
        parsedModels[modelID] = incoming
      }
      configurations[route] = ProviderModelConfiguration(
        protocolID: protocolID,
        baseURL: try Self.parseOptionalURLTemplate(object.string("baseUrl")),
        headers: object.stringDictionary("headers"),
        metadata: object
      )
    }
    models = parsedModels.values.sorted { $0.id < $1.id }
    modelConfigurations = configurations
  }

  private static func merge(
    _ existing: ProviderModel,
    _ incoming: ProviderModel,
    preferIncomingProtocol: Bool
  ) -> ProviderModel {
    let lhs = existing.capabilities
    let rhs = incoming.capabilities
    return ProviderModel(
      id: existing.id,
      providerID: existing.providerID,
      name: existing.name,
      protocolID: preferIncomingProtocol ? incoming.protocolID : existing.protocolID,
      capabilities: ProviderCapabilities(
        textInput: lhs.textInput || rhs.textInput,
        imageInput: lhs.imageInput || rhs.imageInput,
        toolCalling: lhs.toolCalling || rhs.toolCalling,
        reasoning: lhs.reasoning || rhs.reasoning,
        structuredOutput: lhs.structuredOutput || rhs.structuredOutput,
        imageGeneration: lhs.imageGeneration || rhs.imageGeneration
      ),
      contextWindow: existing.contextWindow ?? incoming.contextWindow,
      maximumOutputTokens: existing.maximumOutputTokens
        ?? incoming.maximumOutputTokens
    )
  }

  private static func supportsStructuredOutput(_ protocolID: String) -> Bool {
    switch protocolID {
    case "openai-completions", "openai-responses",
      "azure-openai-responses", "google-generative-ai", "google-vertex":
      true
    default:
      false
    }
  }

  private static func parseOptionalURLTemplate(_ value: String?) throws -> String? {
    guard let value, !value.isEmpty else { return nil }
    let validationValue = value.replacingOccurrences(
      of: #"\{[^}]+\}"#,
      with: "placeholder",
      options: .regularExpression
    )
    guard let url = URL(string: validationValue), url.scheme == "https" else {
      throw failure(nil, "invalid provider base URL: \(value)")
    }
    return value
  }

  private static func failure(
    _ providerID: String?,
    _ message: String
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .upstreamDrift,
      message: message,
      providerID: providerID,
      operation: "catalog.decode",
      causeDescription: nil
    )
  }
}

private struct BuiltinCatalogDocument: Decodable {
  let schemaVersion: Int
  let upstreamRevision: String
  let providers: [BuiltinProviderDocument]
}

private struct BuiltinProviderDocument: Decodable {
  let id: String
  let name: String
  let baseURL: String?
  let headers: [String: String]
  let authorizationMethods: [String]
  let models: [JSONValue]
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func requiredString(
    _ key: String,
    providerID: String
  ) throws -> String {
    guard let value = string(key), !value.isEmpty else {
      throw ProviderRuntimeFailure(
        code: .upstreamDrift,
        message: "catalog entry is missing \(key)",
        providerID: providerID,
        operation: "catalog.decode",
        causeDescription: nil
      )
    }
    return value
  }

  fileprivate func stringArray(_ key: String) -> [String] {
    guard case .array(let values) = self[key] else { return [] }
    return values.compactMap {
      guard case .string(let value) = $0 else { return nil }
      return value
    }
  }

  fileprivate func stringDictionary(_ key: String) -> [String: String] {
    guard case .object(let values) = self[key] else { return [:] }
    return values.reduce(into: [:]) { result, element in
      guard case .string(let value) = element.value else { return }
      result[element.key] = value
    }
  }
}
