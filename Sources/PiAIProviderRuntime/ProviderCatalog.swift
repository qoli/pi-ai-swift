import Foundation

public struct ProviderCatalog: Sendable, Equatable, Codable {
  public let revision: String
  public let providers: [ProviderDescriptor]

  public init(revision: String, providers: [ProviderDescriptor]) {
    self.revision = revision
    self.providers = providers
  }
}

public struct ProviderDescriptor: Sendable, Equatable, Codable {
  public let id: String
  public let name: String
  public let authorizationMethods: [AuthorizationMethodDescriptor]
  public let models: [ProviderModel]

  public init(
    id: String,
    name: String,
    authorizationMethods: [AuthorizationMethodDescriptor],
    models: [ProviderModel]
  ) {
    self.id = id
    self.name = name
    self.authorizationMethods = authorizationMethods
    self.models = models
  }
}

public struct AuthorizationMethodDescriptor: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Equatable, Codable {
    case apiKey
    case oauth
  }

  public let id: String
  public let kind: Kind
  public let label: String

  public init(id: String, kind: Kind, label: String) {
    self.id = id
    self.kind = kind
    self.label = label
  }
}

public struct ProviderModel: Sendable, Equatable, Codable {
  public let id: String
  public let providerID: String
  public let name: String
  public let protocolID: String
  public let capabilities: ProviderCapabilities
  public let contextWindow: Int?
  public let maximumOutputTokens: Int?
  /// Supported explicit selections in increasing effort order. An empty list
  /// means only the provider default (nil) is available.
  public let supportedReasoningEfforts: [ProviderReasoningEffort]

  public init(
    id: String,
    providerID: String,
    name: String,
    protocolID: String,
    capabilities: ProviderCapabilities,
    contextWindow: Int?,
    maximumOutputTokens: Int?,
    supportedReasoningEfforts: [ProviderReasoningEffort] = []
  ) {
    self.id = id
    self.providerID = providerID
    self.name = name
    self.protocolID = protocolID
    self.capabilities = capabilities
    self.contextWindow = contextWindow
    self.maximumOutputTokens = maximumOutputTokens
    self.supportedReasoningEfforts = supportedReasoningEfforts
  }
}

public struct ProviderCapabilities: Sendable, Equatable, Codable {
  public let textInput: Bool
  public let imageInput: Bool
  public let toolCalling: Bool
  public let reasoning: Bool
  public let structuredOutput: Bool
  public let imageGeneration: Bool

  public init(
    textInput: Bool,
    imageInput: Bool,
    toolCalling: Bool,
    reasoning: Bool,
    structuredOutput: Bool,
    imageGeneration: Bool
  ) {
    self.textInput = textInput
    self.imageInput = imageInput
    self.toolCalling = toolCalling
    self.reasoning = reasoning
    self.structuredOutput = structuredOutput
    self.imageGeneration = imageGeneration
  }
}
