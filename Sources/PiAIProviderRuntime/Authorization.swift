import Foundation

public enum AuthorizationOperation: Sendable, Equatable {
  case login(providerID: String, methodID: String)
  case logout(providerID: String)
}

public enum AuthorizationChallenge: Sendable, Equatable {
  case openURL(
    providerID: String,
    url: URL,
    callbackScheme: String?
  )
  case deviceCode(
    providerID: String,
    userCode: String,
    verificationURL: URL,
    expiresAt: Date?,
    pollingInterval: Duration?
  )
  case prompt(
    providerID: String,
    id: String,
    message: String,
    kind: AuthorizationPromptKind
  )
  case progress(providerID: String, message: String)
  case choice(providerID: String, id: String, message: String, options: [AuthorizationChoice])
  case information(providerID: String, message: String, links: [AuthorizationLink])
}

public struct AuthorizationChoice: Sendable, Equatable, Codable {
  public let id: String
  public let label: String
  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }
}

public struct AuthorizationLink: Sendable, Equatable, Codable {
  public let label: String
  public let url: URL
  public init(label: String, url: URL) {
    self.label = label
    self.url = url
  }
}

public enum AuthorizationPromptKind: String, Sendable, Equatable, Codable {
  case text
  case secret
  case authorizationCode
}

public enum AuthorizationResponse: Sendable, Equatable {
  case callbackURL(URL)
  case value(String)
  case acknowledged
}

public enum AuthorizationState: Sendable, Equatable, Codable {
  case disconnected(providerID: String)
  case connected(ProviderAccount)
}

public struct ProviderAccount: Sendable, Equatable, Codable {
  public let providerID: String
  public let accountID: String?
  public let authorizationKind: AuthorizationMethodDescriptor.Kind
  public let expiresAt: Date?

  public init(
    providerID: String,
    accountID: String?,
    authorizationKind: AuthorizationMethodDescriptor.Kind,
    expiresAt: Date?
  ) {
    self.providerID = providerID
    self.accountID = accountID
    self.authorizationKind = authorizationKind
    self.expiresAt = expiresAt
  }
}

public typealias AuthorizationInteraction =
  @Sendable (
    AuthorizationChallenge
  ) async throws -> AuthorizationResponse

public enum ProviderCredential: Sendable, Equatable, Codable {
  case apiKey(APIKeyCredential)
  case oauth(OAuthCredential)
}

public struct APIKeyCredential: Sendable, Equatable, Codable {
  public let configuredKey: String?
  public var key: String { configuredKey ?? "" }
  public let environment: [String: String]?
  public let metadata: [String: String]

  public init(key: String, metadata: [String: String], environment: [String: String]? = nil) {
    self.configuredKey = key
    self.environment = environment
    self.metadata = metadata
  }

  public init(environment: [String: String]?, metadata: [String: String] = [:]) {
    self.configuredKey = nil
    self.environment = environment
    self.metadata = metadata
  }

  private enum CodingKeys: String, CodingKey { case key, metadata, environment }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    configuredKey = try values.decodeIfPresent(String.self, forKey: .key)
    metadata = try values.decode([String: String].self, forKey: .metadata)
    environment = try values.decodeIfPresent([String: String].self, forKey: .environment)
  }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(configuredKey, forKey: .key)
    try values.encode(metadata, forKey: .metadata)
    try values.encodeIfPresent(environment, forKey: .environment)
  }
}

extension APIKeyCredential {
  var routingMetadata: [String: String] {
    metadata.merging(environment ?? [:]) { _, value in value }
  }
}

public struct OAuthCredential: Sendable, Equatable, Codable {
  public let accessToken: String
  public let refreshToken: String
  public let expiresAt: Date
  public let metadata: [String: String]

  public init(
    accessToken: String,
    refreshToken: String,
    expiresAt: Date,
    metadata: [String: String]
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.metadata = metadata
  }
}

public struct ProviderCredentialInfo: Sendable, Equatable, Codable {
  public let providerID: String
  public let kind: AuthorizationMethodDescriptor.Kind

  public init(providerID: String, kind: AuthorizationMethodDescriptor.Kind) {
    self.providerID = providerID
    self.kind = kind
  }
}

public protocol ProviderCredentialStore: Sendable {
  func read(providerID: String) async throws -> ProviderCredential?
  func list() async throws -> [ProviderCredentialInfo]

  func modify(
    providerID: String,
    _ transform:
      @escaping @Sendable (
        ProviderCredential?
      ) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential?

  func delete(providerID: String) async throws
}
