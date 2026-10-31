import Foundation

public struct ProviderClassifierRequest: Sendable, Equatable, Codable {
  public let state: JSONValue
  public let questions: [ProviderClassifierQuestion]
  public let images: [ProviderClassifierImage]

  public init(
    state: JSONValue, questions: [ProviderClassifierQuestion],
    images: [ProviderClassifierImage] = []
  ) {
    self.state = state
    self.questions = questions
    self.images = images
  }
}

public struct ProviderClassifierImage: Sendable, Equatable, Codable {
  public let data: String
  public let mimeType: String
  public init(data: String, mimeType: String) {
    self.data = data
    self.mimeType = mimeType
  }
}

public struct ProviderClassifierQuestion: Sendable, Equatable, Codable {
  public struct Choice: Sendable, Equatable, Codable {
    public let value: String
    public let description: String
    public init(value: String, description: String) {
      self.value = value
      self.description = description
    }
  }
  public enum Kind: Sendable, Equatable, Codable {
    case choice([Choice])
    case score([String])
    case bool(trueMeaning: String, falseMeaning: String)
  }
  public let id: String
  public let instructions: String
  public let kind: Kind

  public init(id: String, instructions: String, kind: Kind) {
    self.id = id
    self.instructions = instructions
    self.kind = kind
  }

  var systemOneQuestion: JSONValue {
    let type: String
    let criteria: JSONValue
    switch kind {
    case .choice(let choices):
      type = "choice"
      criteria = .orderedObject(choices.map { .init($0.value, .string($0.description)) })
    case .score(let values):
      type = "score"
      criteria = .array(values.map(JSONValue.string))
    case .bool(let yes, let no):
      type = "noul"
      criteria = .object(["true": .string(yes), "false": .string(no)])
    }
    return .object([
      "type": .string(type), "instructions": .string(instructions), "criteria": criteria,
    ])
  }
}

public enum ProviderClassifierAnswer: Sendable, Equatable, Codable {
  case choice(String, probabilities: [String: Double], confidence: Double)
  case score(Double, confidence: Double)
  case bool(probability: Double)

  var jsonValue: JSONValue {
    switch self {
    case .choice(let value, let probabilities, let confidence):
      .object([
        "type": .string("choice"), "choice": .string(value),
        "probabilities": .object(probabilities.mapValues(JSONValue.number)),
        "confidence": .number(confidence),
      ])
    case .score(let value, let confidence):
      .object([
        "type": .string("score"), "score": .number(value), "confidence": .number(confidence),
      ])
    case .bool(let probability):
      .object(["type": .string("bool"), "probability": .number(probability)])
    }
  }
}

public struct ProviderClassifierUsage: Sendable, Equatable, Codable {
  public let inputTokens: Double
  public let outputTokens: Double
  public let cost: ProviderUsageCost
  public init(inputTokens: Double, outputTokens: Double, cost: ProviderUsageCost) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cost = cost
  }
}

public struct ProviderClassifierResult: Sendable, Equatable, Codable {
  public let protocolID: String
  public let providerID: String
  public let modelID: String
  public let answers: [String: ProviderClassifierAnswer]
  public let usage: ProviderClassifierUsage?
  public let finishReason: ProviderFinishReason
  public let errorMessage: String?
  public let timestampMilliseconds: Int64

  public init(
    protocolID: String, providerID: String, modelID: String,
    answers: [String: ProviderClassifierAnswer], usage: ProviderClassifierUsage? = nil,
    finishReason: ProviderFinishReason, errorMessage: String? = nil, timestampMilliseconds: Int64
  ) {
    self.protocolID = protocolID
    self.providerID = providerID
    self.modelID = modelID
    self.answers = answers
    self.usage = usage
    self.finishReason = finishReason
    self.errorMessage = errorMessage
    self.timestampMilliseconds = timestampMilliseconds
  }
}
