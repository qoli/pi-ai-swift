import Foundation

public struct ProviderRequest: Sendable, Equatable, Codable {
  public let id: String
  public let providerID: String
  public let modelID: String
  public let messages: [ProviderMessage]
  public let tools: [ProviderToolDefinition]
  public let options: ProviderGenerationOptions

  public init(
    id: String,
    providerID: String,
    modelID: String,
    messages: [ProviderMessage],
    tools: [ProviderToolDefinition],
    options: ProviderGenerationOptions
  ) {
    self.id = id
    self.providerID = providerID
    self.modelID = modelID
    self.messages = messages
    self.tools = tools
    self.options = options
  }
}

public enum ProviderMessage: Sendable, Equatable, Codable {
  case system(String)
  case user([ProviderUserContent])
  case assistant([ProviderAssistantContent])
  case toolResult(ProviderToolResult)
}

public enum ProviderUserContent: Sendable, Equatable, Codable {
  case text(String)
  case image(ProviderImage)
}

public enum ProviderAssistantContent: Sendable, Equatable, Codable {
  case text(String)
  case reasoning(ProviderReasoningContent)
  case toolCall(ProviderToolCall)
}

public struct ProviderReasoningContent: Sendable, Equatable, Codable {
  public let text: String
  public let signature: String?
  public let providerMetadata: [String: JSONValue]

  public init(
    text: String,
    signature: String?,
    providerMetadata: [String: JSONValue]
  ) {
    self.text = text
    self.signature = signature
    self.providerMetadata = providerMetadata
  }
}

public enum ProviderImage: Sendable, Equatable, Codable {
  case data(Data, mimeType: String)
  case remoteURL(URL, mimeType: String?)
}

public struct ProviderToolDefinition: Sendable, Equatable, Codable {
  public let name: String
  public let description: String
  public let inputSchema: JSONValue

  public init(name: String, description: String, inputSchema: JSONValue) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}

public struct ProviderToolCall: Sendable, Equatable, Codable {
  public let id: String
  public let name: String
  public let arguments: JSONValue

  public init(id: String, name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

public struct ProviderToolResult: Sendable, Equatable, Codable {
  public let toolCallID: String
  public let toolName: String
  public let content: [ProviderToolResultContent]
  public let isError: Bool

  public init(
    toolCallID: String,
    toolName: String,
    content: [ProviderToolResultContent],
    isError: Bool
  ) {
    self.toolCallID = toolCallID
    self.toolName = toolName
    self.content = content
    self.isError = isError
  }
}

public enum ProviderToolResultContent: Sendable, Equatable, Codable {
  case text(String)
  case image(ProviderImage)
}

public struct ProviderGenerationOptions: Sendable, Equatable, Codable {
  public let maximumOutputTokens: Int?
  public let temperature: Double?
  public let reasoningEffort: ProviderReasoningEffort?
  public let responseSchema: JSONValue?
  public let providerOptions: [String: JSONValue]
  public let outputModality: ProviderOutputModality
  public let sessionID: String?
  public let cacheRetention: ProviderCacheRetention
  public let serviceTier: String?
  public let toolChoice: JSONValue?

  public init(
    maximumOutputTokens: Int?,
    temperature: Double?,
    reasoningEffort: ProviderReasoningEffort?,
    responseSchema: JSONValue?,
    providerOptions: [String: JSONValue],
    outputModality: ProviderOutputModality = .text,
    sessionID: String? = nil,
    cacheRetention: ProviderCacheRetention = .short,
    serviceTier: String? = nil,
    toolChoice: JSONValue? = nil
  ) {
    self.maximumOutputTokens = maximumOutputTokens
    self.temperature = temperature
    self.reasoningEffort = reasoningEffort
    self.responseSchema = responseSchema
    self.providerOptions = providerOptions
    self.outputModality = outputModality
    self.sessionID = sessionID
    self.cacheRetention = cacheRetention
    self.serviceTier = serviceTier
    self.toolChoice = toolChoice
  }
}

public enum ProviderCacheRetention: String, Sendable, Equatable, Codable {
  case none
  case short
  case long
}

public enum ProviderOutputModality: String, Sendable, Equatable, Codable {
  case text
  case image
}
