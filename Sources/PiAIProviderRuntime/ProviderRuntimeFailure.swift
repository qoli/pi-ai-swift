import Foundation

public struct ProviderRuntimeFailure: Error, Sendable, Equatable, Codable,
  LocalizedError
{
  public enum Code: String, Sendable, Equatable, Codable {
    case unsupportedProvider
    case unsupportedModel
    case unsupportedCapability
    case missingCredential
    case invalidCredential
    case authorizationFailed
    case invalidRequest
    case invalidResponse
    case transportFailed
    case upstreamDrift
  }

  public let code: Code
  public let message: String
  public let providerID: String?
  public let operation: String?
  public let causeDescription: String?

  public init(
    code: Code,
    message: String,
    providerID: String?,
    operation: String?,
    causeDescription: String?
  ) {
    self.code = code
    self.message = message
    self.providerID = providerID
    self.operation = operation
    self.causeDescription = causeDescription
  }

  public var errorDescription: String? { message }
}
