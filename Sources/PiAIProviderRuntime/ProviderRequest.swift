import Foundation

public struct ProviderRequest: Sendable, Equatable, Codable {
  public let id: String
  public let providerID: String
  public let modelID: String
  public let messages: [ProviderMessage]
  public let tools: [ProviderToolDefinition]
  public let options: ProviderGenerationOptions
  public let connectionOptions: ProviderConnectionOptions

  public init(
    id: String,
    providerID: String,
    modelID: String,
    messages: [ProviderMessage],
    tools: [ProviderToolDefinition],
    options: ProviderGenerationOptions,
    connectionOptions: ProviderConnectionOptions = .init()
  ) {
    self.id = id
    self.providerID = providerID
    self.modelID = modelID
    self.messages = messages
    self.tools = tools
    self.options = options
    self.connectionOptions = connectionOptions
  }

  private enum CodingKeys: String, CodingKey {
    case id, providerID, modelID, messages, tools, options, connectionOptions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    providerID = try container.decode(String.self, forKey: .providerID)
    modelID = try container.decode(String.self, forKey: .modelID)
    messages = try container.decode([ProviderMessage].self, forKey: .messages)
    tools = try container.decode([ProviderToolDefinition].self, forKey: .tools)
    options = try container.decode(ProviderGenerationOptions.self, forKey: .options)
    connectionOptions =
      try container.decodeIfPresent(ProviderConnectionOptions.self, forKey: .connectionOptions)
      ?? .init()
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(providerID, forKey: .providerID)
    try container.encode(modelID, forKey: .modelID)
    try container.encode(messages, forKey: .messages)
    try container.encode(tools, forKey: .tools)
    try container.encode(options, forKey: .options)
    if connectionOptions != .init() {
      try container.encode(connectionOptions, forKey: .connectionOptions)
    }
  }
}

public struct ProviderConnectionOptions: Sendable, Equatable, Codable {
  public let azureOpenAIResponses: AzureOpenAIResponsesConnectionOptions?

  public init(
    azureOpenAIResponses: AzureOpenAIResponsesConnectionOptions? = nil
  ) {
    self.azureOpenAIResponses = azureOpenAIResponses
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case azureOpenAIResponses
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
    let known = Set(CodingKeys.allCases.map(\.rawValue))
    if let unknown = dynamic.allKeys.map(\.stringValue).first(where: { !known.contains($0) }) {
      throw DecodingError.dataCorruptedError(
        forKey: DynamicCodingKey(stringValue: unknown), in: dynamic,
        debugDescription: "Unknown provider connection configuration: \(unknown)"
      )
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    azureOpenAIResponses = try container.decodeIfPresent(
      AzureOpenAIResponsesConnectionOptions.self, forKey: .azureOpenAIResponses)
  }
}

public struct AzureOpenAIResponsesConnectionOptions: Sendable, Equatable, Codable {
  public let azureBaseURL: String?
  public let azureResourceName: String?
  public let azureAPIVersion: String?
  public let azureDeploymentName: String?
  public let environment: [String: String]

  public init(
    azureBaseURL: String? = nil,
    azureResourceName: String? = nil,
    azureAPIVersion: String? = nil,
    azureDeploymentName: String? = nil,
    environment: [String: String] = [:]
  ) {
    self.azureBaseURL = azureBaseURL
    self.azureResourceName = azureResourceName
    self.azureAPIVersion = azureAPIVersion
    self.azureDeploymentName = azureDeploymentName
    self.environment = environment
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case azureBaseURL, azureResourceName, azureAPIVersion, azureDeploymentName, environment
  }

  public init(from decoder: any Decoder) throws {
    let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
    let known = Set(CodingKeys.allCases.map(\.rawValue))
    if let unknown = dynamic.allKeys.map(\.stringValue).first(where: { !known.contains($0) }) {
      throw DecodingError.dataCorruptedError(
        forKey: DynamicCodingKey(stringValue: unknown), in: dynamic,
        debugDescription: "Unknown Azure OpenAI connection configuration: \(unknown)"
      )
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    azureBaseURL = try container.decodeIfPresent(String.self, forKey: .azureBaseURL)
    azureResourceName = try container.decodeIfPresent(String.self, forKey: .azureResourceName)
    azureAPIVersion = try container.decodeIfPresent(String.self, forKey: .azureAPIVersion)
    azureDeploymentName = try container.decodeIfPresent(String.self, forKey: .azureDeploymentName)
    environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
  }
}

private struct DynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

extension ProviderRequest {
  func validateSingleSystemMessage(operation: String) throws {
    let systemMessageCount = messages.reduce(into: 0) { count, message in
      if case .system = message { count += 1 }
    }
    guard systemMessageCount <= 1 else {
      throw ProviderRuntimeFailure(
        code: .invalidRequest,
        message:
          "ProviderRequest accepts one caller-assembled current system prompt; multiple system messages are not representable at this seam.",
        providerID: providerID,
        operation: operation,
        causeDescription: nil
      )
    }
  }
}

public enum ProviderMessage: Sendable, Equatable, Codable {
  case system(String)
  case user([ProviderUserContent])
  case userMessage(ProviderUserMessage)
  case assistant([ProviderAssistantContent])
  case assistantMessage(ProviderAssistantMessage)
  case toolResult(ProviderToolResult)
}

public struct ProviderUserMessage: Sendable, Equatable, Codable {
  public let content: [ProviderUserContent]
  public let timestampMilliseconds: Int64

  public init(content: [ProviderUserContent], timestampMilliseconds: Int64) {
    self.content = content
    self.timestampMilliseconds = timestampMilliseconds
  }
}

public struct ProviderAssistantMessage: Sendable, Equatable, Codable {
  public let content: [ProviderAssistantContent]
  public let source: ProviderMessageSource
  public let responseID: String?
  public let responseModelID: String?
  public let usage: ProviderUsage
  public let stopReason: ProviderAssistantStopReason
  public let rawStopReason: String?
  public let timestampMilliseconds: Int64
  public let providerMetadata: [String: JSONValue]

  public init(
    content: [ProviderAssistantContent],
    source: ProviderMessageSource,
    responseID: String? = nil,
    responseModelID: String? = nil,
    usage: ProviderUsage,
    stopReason: ProviderAssistantStopReason,
    rawStopReason: String? = nil,
    timestampMilliseconds: Int64,
    providerMetadata: [String: JSONValue] = [:]
  ) {
    self.content = content
    self.source = source
    self.responseID = responseID
    self.responseModelID = responseModelID
    self.usage = usage
    self.stopReason = stopReason
    self.rawStopReason = rawStopReason
    self.timestampMilliseconds = timestampMilliseconds
    self.providerMetadata = providerMetadata
  }
}

public enum ProviderAssistantStopReason: String, Sendable, Equatable, Codable {
  case pending
  case stop
  case length
  case toolUse
  case error
  case aborted
  case deferred
}

public struct ProviderMessageSource: Sendable, Equatable, Codable {
  public let api: String
  public let providerID: String
  public let modelID: String

  public init(api: String, providerID: String, modelID: String) {
    self.api = api
    self.providerID = providerID
    self.modelID = modelID
  }
}

extension ProviderAssistantMessage {
  func replayContent(for target: ProviderMessageSource) -> [ProviderAssistantContent]? {
    if stopReason == .error || stopReason == .aborted { return nil }
    guard source != target else { return content }
    return content.compactMap { item in
      switch item {
      case .text:
        return item
      case .signedText(let text):
        return .text(text.text)
      case .reasoning(let reasoning):
        if reasoning.isRedacted == true
          || reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return nil
        }
        return .text(reasoning.text)
      case .toolCall(let call):
        return .toolCall(
          ProviderToolCall(
            id: call.id,
            name: call.name,
            arguments: call.arguments,
            thoughtSignature: nil,
            namespace: call.namespace,
            providerMetadata: call.providerMetadata
          ))
      }
    }
  }
}

extension Array where Element == ProviderMessage {
  func insertingMissingToolResults() -> [ProviderMessage] {
    var result: [ProviderMessage] = []
    var pending: [ProviderToolCall] = []
    var completedIDs = Set<String>()

    func syntheticResults() -> [ProviderMessage] {
      pending.compactMap { call in
        guard !completedIDs.contains(call.id) else { return nil }
        return .toolResult(
          ProviderToolResult(
            toolCallID: call.id,
            toolName: call.name,
            content: [.text("No result provided")],
            isError: true,
            timestampMilliseconds: 0
          ))
      }
    }

    for message in self {
      switch message {
      case .assistant(let content):
        result.append(contentsOf: syntheticResults())
        pending = content.compactMap { item in
          guard case .toolCall(let call) = item else { return nil }
          return call
        }
        completedIDs = []
        result.append(message)
      case .assistantMessage(let assistant):
        result.append(contentsOf: syntheticResults())
        pending = []
        completedIDs = []
        guard assistant.stopReason != .error && assistant.stopReason != .aborted else { continue }
        pending = assistant.content.compactMap { item in
          guard case .toolCall(let call) = item else { return nil }
          return call
        }
        result.append(message)
      case .toolResult(let toolResult):
        completedIDs.insert(toolResult.toolCallID)
        result.append(message)
      case .user, .userMessage:
        result.append(contentsOf: syntheticResults())
        pending = []
        completedIDs = []
        result.append(message)
      case .system:
        result.append(message)
      }
    }
    result.append(contentsOf: syntheticResults())
    return result
  }
}

public enum ProviderUserContent: Sendable, Equatable, Codable {
  case text(String)
  case image(ProviderImage)
}

public enum ProviderAssistantContent: Sendable, Equatable, Codable {
  case text(String)
  case signedText(ProviderTextContent)
  case reasoning(ProviderReasoningContent)
  case toolCall(ProviderToolCall)
}

public struct ProviderReasoningContent: Sendable, Equatable, Codable {
  public let text: String
  public let signature: String?
  public let isRedacted: Bool?
  public let providerMetadata: [String: JSONValue]

  public init(
    text: String,
    signature: String?,
    isRedacted: Bool? = nil,
    providerMetadata: [String: JSONValue]
  ) {
    self.text = text
    self.signature = signature
    self.isRedacted = isRedacted
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
  public let constrainedSampling: ProviderConstrainedSampling?

  public init(
    name: String,
    description: String,
    inputSchema: JSONValue,
    constrainedSampling: ProviderConstrainedSampling? = nil
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.constrainedSampling = constrainedSampling
  }
}

public enum ProviderConstrainedSampling: Sendable, Equatable, Codable {
  case jsonSchema(strict: ProviderStrictPreference)
  case grammar(variants: [String: String])
}

public enum ProviderStrictPreference: String, Sendable, Equatable, Codable {
  case prefer
  case require
}

public struct ProviderToolCall: Sendable, Equatable, Codable {
  public let id: String
  public let name: String
  public let arguments: JSONValue
  public let thoughtSignature: String?
  public let namespace: String?
  public let providerMetadata: [String: JSONValue]?

  public init(
    id: String,
    name: String,
    arguments: JSONValue,
    thoughtSignature: String? = nil,
    namespace: String? = nil,
    providerMetadata: [String: JSONValue]? = nil
  ) {
    self.id = id
    self.name = name
    self.arguments = arguments
    self.thoughtSignature = thoughtSignature
    self.namespace = namespace
    self.providerMetadata = providerMetadata
  }
}

public struct ProviderToolResult: Sendable, Equatable, Codable {
  public let toolCallID: String
  public let toolName: String
  public let content: [ProviderToolResultContent]
  public let isError: Bool
  public let addedToolNames: [String]?
  public let timestampMilliseconds: Int64?

  public init(
    toolCallID: String,
    toolName: String,
    content: [ProviderToolResultContent],
    isError: Bool,
    addedToolNames: [String]? = nil,
    timestampMilliseconds: Int64? = nil
  ) {
    self.toolCallID = toolCallID
    self.toolName = toolName
    self.content = content
    self.isError = isError
    self.addedToolNames = addedToolNames
    self.timestampMilliseconds = timestampMilliseconds
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
  public let reasoningSummary: String?
  public let responseSchema: JSONValue?
  public let providerOptions: [String: JSONValue]
  public let outputModality: ProviderOutputModality
  public let sessionID: String?
  public let cacheRetention: ProviderCacheRetention
  public let serviceTier: String?
  public let toolChoice: JSONValue?
  public let thinkingBudgets: [ProviderReasoningEffort: Int]?
  public let textVerbosity: String?
  public let environment: [String: String]?

  public init(
    maximumOutputTokens: Int?,
    temperature: Double?,
    reasoningEffort: ProviderReasoningEffort?,
    reasoningSummary: String? = nil,
    responseSchema: JSONValue?,
    providerOptions: [String: JSONValue],
    outputModality: ProviderOutputModality = .text,
    sessionID: String? = nil,
    cacheRetention: ProviderCacheRetention = .short,
    serviceTier: String? = nil,
    toolChoice: JSONValue? = nil,
    thinkingBudgets: [ProviderReasoningEffort: Int]? = nil,
    textVerbosity: String? = nil,
    environment: [String: String]? = nil
  ) {
    self.maximumOutputTokens = maximumOutputTokens
    self.temperature = temperature
    self.reasoningEffort = reasoningEffort
    self.reasoningSummary = reasoningSummary
    self.responseSchema = responseSchema
    self.providerOptions = providerOptions
    self.outputModality = outputModality
    self.sessionID = sessionID
    self.cacheRetention = cacheRetention
    self.serviceTier = serviceTier
    self.toolChoice = toolChoice
    self.thinkingBudgets = thinkingBudgets
    self.textVerbosity = textVerbosity
    self.environment = environment
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
