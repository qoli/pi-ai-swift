import Foundation

public struct ProviderAuthorizationConfiguration: Sendable {
  public let callbackURLs: [String: URL]
  public let agentName: String

  public init(callbackURLs: [String: URL] = [:], agentName: String = "pi") {
    self.callbackURLs = callbackURLs
    self.agentName = agentName
  }
}
