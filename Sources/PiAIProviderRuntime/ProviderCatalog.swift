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
  public let promptCache: ProviderPromptCache?
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
    promptCache: ProviderPromptCache? = nil,
    supportedReasoningEfforts: [ProviderReasoningEffort] = []
  ) {
    self.id = id
    self.providerID = providerID
    self.name = name
    self.protocolID = protocolID
    self.capabilities = capabilities
    self.contextWindow = contextWindow
    self.maximumOutputTokens = maximumOutputTokens
    self.promptCache = promptCache
    self.supportedReasoningEfforts = supportedReasoningEfforts
  }
}

public struct ProviderPromptCache: Sendable, Equatable, Codable {
  public let shortLifetimeSeconds: Int?
  public let longLifetimeSeconds: Int?

  public init(shortLifetimeSeconds: Int?, longLifetimeSeconds: Int?) {
    self.shortLifetimeSeconds = shortLifetimeSeconds
    self.longLifetimeSeconds = longLifetimeSeconds
  }
}

public struct ProviderCapabilities: Sendable, Equatable, Codable {
  public let textInput: Bool
  public let imageInput: Bool
  public let toolCalling: Bool
  public let reasoning: Bool
  public let structuredOutput: Bool
  public let imageGeneration: Bool
  public let classification: Bool

  public init(
    textInput: Bool,
    imageInput: Bool,
    toolCalling: Bool,
    reasoning: Bool,
    structuredOutput: Bool,
    imageGeneration: Bool,
    classification: Bool = false
  ) {
    self.textInput = textInput
    self.imageInput = imageInput
    self.toolCalling = toolCalling
    self.reasoning = reasoning
    self.structuredOutput = structuredOutput
    self.imageGeneration = imageGeneration
    self.classification = classification
  }

  private enum CodingKeys: String, CodingKey {
    case textInput, imageInput, toolCalling, reasoning, structuredOutput, imageGeneration,
      classification
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      textInput: try c.decode(Bool.self, forKey: .textInput),
      imageInput: try c.decode(Bool.self, forKey: .imageInput),
      toolCalling: try c.decode(Bool.self, forKey: .toolCalling),
      reasoning: try c.decode(Bool.self, forKey: .reasoning),
      structuredOutput: try c.decode(Bool.self, forKey: .structuredOutput),
      imageGeneration: try c.decode(Bool.self, forKey: .imageGeneration),
      classification: try c.decodeIfPresent(Bool.self, forKey: .classification) ?? false)
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(textInput, forKey: .textInput)
    try c.encode(imageInput, forKey: .imageInput)
    try c.encode(toolCalling, forKey: .toolCalling)
    try c.encode(reasoning, forKey: .reasoning)
    try c.encode(structuredOutput, forKey: .structuredOutput)
    try c.encode(imageGeneration, forKey: .imageGeneration)
    if classification { try c.encode(true, forKey: .classification) }
  }
}

extension ProviderModel {
  static func merging(
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
        imageGeneration: lhs.imageGeneration || rhs.imageGeneration,
        classification: lhs.classification || rhs.classification
      ),
      contextWindow: existing.contextWindow ?? incoming.contextWindow,
      maximumOutputTokens: existing.maximumOutputTokens
        ?? incoming.maximumOutputTokens,
      promptCache: preferIncomingProtocol ? incoming.promptCache : existing.promptCache,
      supportedReasoningEfforts: preferIncomingProtocol
        ? incoming.supportedReasoningEfforts : existing.supportedReasoningEfforts
    )
  }

}
