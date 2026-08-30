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
  public let key: String
  public let metadata: [String: String]

  public init(key: String, metadata: [String: String]) {
    self.key = key
    self.metadata = metadata
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
