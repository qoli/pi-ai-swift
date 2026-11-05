import Foundation

public struct ProviderAuthorizationConfiguration: Sendable {
  public let callbackURLs: [String: URL]
  public let agentName: String
  public let authenticationContext: ProviderAuthenticationContext?
  public let radiusGateway: String?
  let chatGPTAgentName: String

  public init(
    callbackURLs: [String: URL] = [:], agentName: String? = nil,
    authenticationContext: ProviderAuthenticationContext? = nil,
    radiusGateway: String? = nil
  ) {
    self.callbackURLs = callbackURLs
    self.agentName = agentName ?? "pi"
    self.chatGPTAgentName = agentName ?? "Pi"
    self.authenticationContext = authenticationContext
    self.radiusGateway = radiusGateway
  }
}
