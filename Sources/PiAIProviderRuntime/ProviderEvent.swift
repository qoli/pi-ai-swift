import Foundation

public enum ProviderEvent: Sendable, Equatable, Codable {
  case responseStarted(ProviderResponseMetadata)
  case textDelta(String)
  case reasoningDelta(String)
  case reasoningSignatureDelta(String)
  case toolCallStarted(id: String, name: String)
  case toolInputDelta(id: String, delta: String)
  case toolCallCompleted(ProviderToolCall)
  case asset(ProviderAsset)
  case usage(ProviderUsage)
  case responseSnapshot(ProviderResponseSnapshot)
  case completed(ProviderFinishReason)
}

public struct ProviderResponseSnapshot: Sendable, Equatable, Codable {
  public let responseID: String?
  public let providerID: String
  public let protocolID: String
  public let modelID: String
  public let responseModelID: String?
  public let content: [ProviderResponseContent]
  public let usage: ProviderUsage?
  public let finishReason: ProviderFinishReason
  public let rawFinishReason: String?
  public let timestampMilliseconds: Int64
  public let providerMetadata: [String: JSONValue]

  public init(
    responseID: String?,
    providerID: String,
    protocolID: String,
    modelID: String,
    responseModelID: String?,
    content: [ProviderResponseContent],
    usage: ProviderUsage?,
    finishReason: ProviderFinishReason,
    rawFinishReason: String?,
    timestampMilliseconds: Int64,
    providerMetadata: [String: JSONValue] = [:]
  ) {
    self.responseID = responseID
    self.providerID = providerID
    self.protocolID = protocolID
    self.modelID = modelID
    self.responseModelID = responseModelID
    self.content = content
    self.usage = usage
    self.finishReason = finishReason
    self.rawFinishReason = rawFinishReason
    self.timestampMilliseconds = timestampMilliseconds
    self.providerMetadata = providerMetadata
  }

  public func replayAssistantMessage() throws -> ProviderAssistantMessage {
    guard let usage else {
      throw ProviderRuntimeFailure(
        code: .invalidResponse,
        message: "terminal response snapshot is missing usage",
        providerID: providerID,
        operation: "response-snapshot.replay",
        causeDescription: nil
      )
    }
    let stopReason: ProviderAssistantStopReason
    switch finishReason {
    case .stop: stopReason = .stop
    case .length: stopReason = .length
    case .toolCalls: stopReason = .toolUse
    case .contentFilter, .cancelled:
      throw ProviderRuntimeFailure(
        code: .invalidResponse,
        message:
          "terminal response snapshot has a non-replayable finish reason: \(finishReason.rawValue)",
        providerID: providerID,
        operation: "response-snapshot.replay",
        causeDescription: nil
      )
    }
    let replayContent = try content.map { item -> ProviderAssistantContent in
      switch item {
      case .text(let text): return .signedText(text)
      case .reasoning(let reasoning): return .reasoning(reasoning)
      case .toolCall(let call): return .toolCall(call)
      case .asset:
        throw ProviderRuntimeFailure(
          code: .unsupportedCapability,
          message: "image response snapshots cannot be replayed as assistant messages",
          providerID: providerID,
          operation: "response-snapshot.replay",
          causeDescription: nil
        )
      }
    }
    return ProviderAssistantMessage(
      content: replayContent,
      source: ProviderMessageSource(api: protocolID, providerID: providerID, modelID: modelID),
      responseID: responseID,
      responseModelID: responseModelID,
      usage: usage,
      stopReason: stopReason,
      rawStopReason: rawFinishReason,
      timestampMilliseconds: timestampMilliseconds,
      providerMetadata: providerMetadata
    )
  }
}

public enum ProviderResponseContent: Sendable, Equatable, Codable {
  case text(ProviderTextContent)
  case reasoning(ProviderReasoningContent)
  case toolCall(ProviderToolCall)
  case asset(ProviderAsset)
}

public struct ProviderTextContent: Sendable, Equatable, Codable {
  public let text: String
  public let signature: String?
  public let providerMetadata: [String: JSONValue]

  public init(
    text: String,
    signature: String?,
    providerMetadata: [String: JSONValue] = [:]
  ) {
    self.text = text
    self.signature = signature
    self.providerMetadata = providerMetadata
  }
}

public struct ProviderResponseMetadata: Sendable, Equatable, Codable {
  public let responseID: String?
  public let providerID: String
  public let modelID: String
  public let providerMetadata: [String: JSONValue]

  public init(
    responseID: String?,
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
  public let cacheWriteTokens: Int?
  public let totalTokens: Int?
  public let cost: ProviderUsageCost?
  public let providerMetadata: [String: JSONValue]

  public init(
    inputTokens: Int?,
    outputTokens: Int?,
    reasoningTokens: Int?,
    cachedInputTokens: Int?,
    cacheWriteTokens: Int? = nil,
    totalTokens: Int? = nil,
    providerMetadata: [String: JSONValue],
    cost: ProviderUsageCost? = nil
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.reasoningTokens = reasoningTokens
    self.cachedInputTokens = cachedInputTokens
    self.cacheWriteTokens = cacheWriteTokens
    self.totalTokens = totalTokens
    self.providerMetadata = providerMetadata
    self.cost = cost
  }
}

/// Monetary usage reported or calculated by the pinned provider runtime.
/// Values use the same currency unit as pi-ai (`USD`) and are not inferred
/// when the source protocol does not expose enough pricing information.
public struct ProviderUsageCost: Sendable, Equatable, Codable {
  public let input: Double
  public let output: Double
  public let cacheRead: Double
  public let cacheWrite: Double
  public let total: Double

  public init(
    input: Double,
    output: Double,
    cacheRead: Double,
    cacheWrite: Double,
    total: Double
  ) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.total = total
  }
}

struct ProviderUsagePricing: Sendable {
  struct Rates: Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
  }

  struct Tier: Sendable {
    let inputTokensAbove: Int
    let rates: Rates
  }

  let base: Rates
  let tiers: [Tier]

  static func parse(
    metadata: [String: JSONValue],
    providerID: String,
    operation: String
  ) throws -> ProviderUsagePricing? {
    guard let cost = metadata.object("cost") else { return nil }
    let base = try rates(cost, providerID: providerID, operation: operation)
    let tiers = try (cost.array("tiers") ?? []).map { value -> Tier in
      guard let object = value.objectValue, let threshold = object.int("inputTokensAbove") else {
        throw pricingFailure(
          providerID: providerID, operation: operation,
          message: "model cost tier is malformed")
      }
      return Tier(
        inputTokensAbove: threshold,
        rates: try rates(object, providerID: providerID, operation: operation))
    }
    return ProviderUsagePricing(base: base, tiers: tiers)
  }

  func cost(
    input: Int,
    output: Int,
    cacheRead: Int,
    cacheWrite: Int,
    cacheWrite1h: Int = 0,
    multiplier: Double = 1,
    useTiers: Bool = true
  ) -> ProviderUsageCost {
    let totalInput = input + cacheRead + cacheWrite
    var selected = base
    if useTiers {
      var matchedThreshold = -1
      for tier in tiers
      where totalInput > tier.inputTokensAbove
        && tier.inputTokensAbove > matchedThreshold
      {
        selected = tier.rates
        matchedThreshold = tier.inputTokensAbove
      }
    }
    let shortWrite = cacheWrite - cacheWrite1h
    let inputCost = selected.input / 1_000_000 * Double(input) * multiplier
    let outputCost = selected.output / 1_000_000 * Double(output) * multiplier
    let cacheReadCost = selected.cacheRead / 1_000_000 * Double(cacheRead) * multiplier
    let cacheWriteCost =
      (selected.cacheWrite * Double(shortWrite) + selected.input * 2 * Double(cacheWrite1h))
      / 1_000_000 * multiplier
    return ProviderUsageCost(
      input: inputCost,
      output: outputCost,
      cacheRead: cacheReadCost,
      cacheWrite: cacheWriteCost,
      total: inputCost + outputCost + cacheReadCost + cacheWriteCost)
  }

  static func directCost(
    _ object: [String: JSONValue],
    providerID: String,
    operation: String,
    failureCode: ProviderRuntimeFailure.Code = .upstreamDrift
  ) throws -> ProviderUsageCost {
    guard let input = number(object["input"]), let output = number(object["output"]),
      let cacheRead = number(object["cacheRead"]),
      let cacheWrite = number(object["cacheWrite"]), let total = number(object["total"])
    else {
      throw ProviderRuntimeFailure(
        code: failureCode,
        message: "provider usage cost is malformed",
        providerID: providerID,
        operation: operation,
        causeDescription: nil)
    }
    return ProviderUsageCost(
      input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
      total: total)
  }

  private static func rates(
    _ object: [String: JSONValue],
    providerID: String,
    operation: String
  ) throws -> Rates {
    guard let input = number(object["input"]), let output = number(object["output"]),
      let cacheRead = number(object["cacheRead"]),
      let cacheWrite = number(object["cacheWrite"])
    else {
      throw pricingFailure(
        providerID: providerID, operation: operation,
        message: "model cost rates are malformed")
    }
    return Rates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
  }

  private static func number(_ value: JSONValue?) -> Double? {
    switch value {
    case .integer(let value): return Double(value)
    case .number(let value): return value
    default: return nil
    }
  }

  private static func pricingFailure(
    providerID: String,
    operation: String,
    message: String
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .upstreamDrift,
      message: message,
      providerID: providerID,
      operation: operation,
      causeDescription: nil)
  }
}

public enum ProviderFinishReason: String, Sendable, Equatable, Codable {
  case stop
  case length
  case toolCalls
  case contentFilter
  case cancelled
}
