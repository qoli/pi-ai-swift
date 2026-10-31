import Foundation

public struct ProviderAuthorizationConfiguration: Sendable {
  public let callbackURLs: [String: URL]
  public let agentName: String
  public let deviceID: String?
  let chatGPTAgentName: String

  public init(callbackURLs: [String: URL] = [:], agentName: String? = nil, deviceID: String? = nil)
  {
    self.callbackURLs = callbackURLs
    self.agentName = agentName ?? "pi"
    self.chatGPTAgentName = agentName ?? "Pi"
    self.deviceID = deviceID
  }
}
