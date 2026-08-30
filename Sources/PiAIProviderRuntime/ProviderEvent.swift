import Foundation

public enum ProviderEvent: Sendable, Equatable, Codable {
  case responseStarted(ProviderResponseMetadata)
  case textDelta(String)
  case reasoningDelta(String)
  case toolCallStarted(id: String, name: String)
  case toolInputDelta(id: String, delta: String)
  case toolCallCompleted(ProviderToolCall)
  case asset(ProviderAsset)
  case usage(ProviderUsage)
  case completed(ProviderFinishReason)
}

public struct ProviderResponseMetadata: Sendable, Equatable, Codable {
  public let responseID: String
  public let providerID: String
  public let modelID: String
  public let providerMetadata: [String: JSONValue]

  public init(
    responseID: String,
    providerID: String,
    modelID: String,
    providerMetadata: [String: JSONValue]
  ) {
    self.responseID = responseID
    self.providerID = providerID
    self.modelID = modelID
    self.providerMetadata = providerMetadata
  }
}

public struct ProviderAsset: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Equatable, Codable {
    case image
    case file
  }

  public let id: String
  public let kind: Kind
  public let mimeType: String
  public let data: Data
  public let providerMetadata: [String: JSONValue]

  public init(
    id: String,
    kind: Kind,
    mimeType: String,
    data: Data,
    providerMetadata: [String: JSONValue]
  ) {
    self.id = id
    self.kind = kind
    self.mimeType = mimeType
    self.data = data
    self.providerMetadata = providerMetadata
  }
}

public struct ProviderUsage: Sendable, Equatable, Codable {
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let reasoningTokens: Int?
  public let cachedInputTokens: Int?
  public let providerMetadata: [String: JSONValue]

  public init(
    inputTokens: Int?,
    outputTokens: Int?,
    reasoningTokens: Int?,
    cachedInputTokens: Int?,
    providerMetadata: [String: JSONValue]
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.reasoningTokens = reasoningTokens
    self.cachedInputTokens = cachedInputTokens
    self.providerMetadata = providerMetadata
  }
}

public enum ProviderFinishReason: String, Sendable, Equatable, Codable {
  case stop
  case length
  case toolCalls
  case contentFilter
  case cancelled
}
