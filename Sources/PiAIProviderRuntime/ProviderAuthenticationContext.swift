import Foundation

public struct ProviderAuthenticationContext: Sendable {
  public let environment: @Sendable (String) async throws -> String?
  public let fileExists: @Sendable (String) async throws -> Bool

  public init(
    environment: @escaping @Sendable (String) async throws -> String?,
    fileExists: @escaping @Sendable (String) async throws -> Bool
  ) {
    self.environment = environment
    self.fileExists = fileExists
  }
}

public struct ProviderAvailableModel: Sendable, Equatable, Codable {
  public let modelID: String
  public let outputModality: ProviderOutputModality

  public init(modelID: String, outputModality: ProviderOutputModality) {
    self.modelID = modelID
    self.outputModality = outputModality
  }
}

public struct ProviderAvailability: Sendable, Equatable, Codable {
  public let configured: Bool
  public let source: String?
  public let models: [ProviderAvailableModel]

  public init(configured: Bool, source: String?, models: [ProviderAvailableModel]) {
    self.configured = configured
    self.source = source
    self.models = models
  }
}
