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
    /// The transport reached EOF before the protocol confirmed completion.
    case incompleteStream
    case transportFailed
    case upstreamDrift
  }

  public let code: Code
  public let message: String
  public let providerID: String?
  public let operation: String?
  public let causeDescription: String?
  public let providerMetadata: [String: JSONValue]?
  /// The URL loading error code retained when a provider adds transport context.
  public let underlyingURLErrorCode: Int?

  public init(
    code: Code,
    message: String,
    providerID: String?,
    operation: String?,
    causeDescription: String?,
    providerMetadata: [String: JSONValue]? = nil,
    underlyingURLErrorCode: Int? = nil
  ) {
    self.code = code
    self.message = message
    self.providerID = providerID
    self.operation = operation
    self.causeDescription = causeDescription
    self.providerMetadata = providerMetadata
    self.underlyingURLErrorCode = underlyingURLErrorCode
  }

  init(
    transportError: any Error, message: String, providerID: String,
    operation: String, providerMetadata: [String: JSONValue]? = nil
  ) {
    self.init(
      code: .transportFailed, message: message, providerID: providerID,
      operation: operation, causeDescription: String(describing: transportError),
      providerMetadata: providerMetadata,
      underlyingURLErrorCode: (transportError as? URLError)?.code.rawValue)
  }

  public var errorDescription: String? { message }
}
