import Foundation

public struct ProviderCloudConnectionOptions: Sendable, Equatable, Codable {
  public let environment: [String: String]
  public let ambientEnvironment: [String: String]
  public let region: String?
  public let profile: String?
  public let bearerToken: String?
  public let project: String?
  public let location: String?

  public init(
    environment: [String: String] = [:], ambientEnvironment: [String: String] = [:],
    region: String? = nil, profile: String? = nil, bearerToken: String? = nil,
    project: String? = nil, location: String? = nil
  ) {
    self.environment = environment
    self.ambientEnvironment = ambientEnvironment
    self.region = region
    self.profile = profile
    self.bearerToken = bearerToken
    self.project = project
    self.location = location
  }

  private enum CodingKeys: String, CodingKey {
    case environment, ambientEnvironment, region, profile, bearerToken, project, location
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      environment: try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:],
      ambientEnvironment: try values.decodeIfPresent(
        [String: String].self, forKey: .ambientEnvironment) ?? [:],
      region: try values.decodeIfPresent(String.self, forKey: .region),
      profile: try values.decodeIfPresent(String.self, forKey: .profile),
      bearerToken: try values.decodeIfPresent(String.self, forKey: .bearerToken),
      project: try values.decodeIfPresent(String.self, forKey: .project),
      location: try values.decodeIfPresent(String.self, forKey: .location))
  }

  func value(_ name: String) -> String? {
    nonempty(environment[name]) ?? nonempty(ambientEnvironment[name])
  }
}

public struct ProviderAnthropicFederation: Sendable, Equatable, Codable {
  public let baseURL: String
  public let organizationID: String
  public let workspaceID: String?
  public let federationRuleID: String
  public let serviceAccountID: String?
  public let identityTokenFile: String

  public init(
    baseURL: String, organizationID: String, workspaceID: String? = nil,
    federationRuleID: String, serviceAccountID: String? = nil, identityTokenFile: String
  ) {
    self.baseURL = baseURL
    self.organizationID = organizationID
    self.workspaceID = workspaceID
    self.federationRuleID = federationRuleID
    self.serviceAccountID = serviceAccountID
    self.identityTokenFile = identityTokenFile
  }
}

public enum ProviderCloudAuthorizationRequest: Sendable, Equatable, Codable {
  case googleApplicationDefaultCredentials(project: String, location: String, keyFilename: String?)
  case awsCredentials(profile: String?, region: String?)
  case anthropicFederation(ProviderAnthropicFederation)
}

public struct ProviderAWSCredentials: Sendable, Equatable, Codable {
  public let accessKeyID: String
  public let secretAccessKey: String
  public let sessionToken: String?
  public let region: String

  public init(
    accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil, region: String
  ) {
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    self.sessionToken = sessionToken
    self.region = region
  }
}

public enum ProviderCloudCredential: Sendable, Equatable, Codable {
  case bearerToken(String)
  case aws(ProviderAWSCredentials)
}

public struct ProviderCloudCredentialSource: Sendable {
  private let resolve: @Sendable () async throws -> ProviderCloudCredential

  public init(resolve: @escaping @Sendable () async throws -> ProviderCloudCredential) {
    self.resolve = resolve
  }

  public func credential() async throws -> ProviderCloudCredential { try await resolve() }
}

/// The host owns cloud SDK/config-file access; Native controls source reuse.
public typealias ProviderCloudAuthorizationResolver =
  @Sendable (ProviderCloudAuthorizationRequest) async throws -> ProviderCloudCredentialSource

actor ProviderCloudCredentialSources {
  private struct Entry {
    let id: UUID
    let request: ProviderCloudAuthorizationRequest
    let source: Task<ProviderCloudCredentialSource, any Error>
  }
  private var federation: Entry?

  func source(
    for request: ProviderCloudAuthorizationRequest,
    resolver: @escaping ProviderCloudAuthorizationResolver
  ) async throws -> ProviderCloudCredentialSource {
    guard case .anthropicFederation = request else { return try await resolver(request) }
    if let federation, federation.request == request { return try await federation.source.value }
    let previous = federation
    let entry = Entry(id: UUID(), request: request, source: Task { try await resolver(request) })
    federation = entry
    do { return try await entry.source.value } catch {
      if federation?.id == entry.id { federation = previous }
      throw error
    }
  }
}

private func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }

enum ProviderCloudPlan: Sendable {
  struct Vertex: Sendable {
    let apiKey: String?
    let project: String?
    let location: String?
    let keyFilename: String?
    let customBaseURL: String?
    let baseURLIncludesVersion: Bool

    var baseURL: String {
      customBaseURL
        ?? (location == nil || location == "global"
          ? "https://aiplatform.googleapis.com" : "https://\(location!)-aiplatform.googleapis.com")
    }
  }

  struct Bedrock: Sendable {
    let endpoint: String?
    let region: String?
    let profile: String?
    let accessKeyID: String?
    let secretAccessKey: String?
    let sessionToken: String?
    let bearerToken: String?
    let forceHTTP1: Bool
  }

  case vertex(Vertex)
  case bedrock(Bedrock)
  case federation(ProviderAnthropicFederation)

  static func resolve(
    protocolID: String, providerID: String, modelID: String, baseURL: String,
    credential: ProviderCredential?, headers: [String: String?],
    options: ProviderCloudConnectionOptions
  ) throws -> Self? {
    let key: String?
    if case .apiKey(let value) = credential, value.metadata["authentication"] != "sigv4" {
      key = nonempty(value.key)
    } else {
      key = nil
    }
    switch protocolID {
    case "google-vertex":
      let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
      let apiKey = trimmed.flatMap { value -> String? in
        guard !value.isEmpty, value != "gcp-vertex-credentials",
          value.range(of: #"^<[^>]+>$"#, options: .regularExpression) == nil
        else { return nil }
        return value
      }
      let project =
        apiKey == nil
        ? nonempty(options.project) ?? options.value("GOOGLE_CLOUD_PROJECT")
          ?? options.value("GCLOUD_PROJECT") : nil
      let location =
        apiKey == nil ? nonempty(options.location) ?? options.value("GOOGLE_CLOUD_LOCATION") : nil
      if apiKey == nil, project == nil {
        throw invalid(
          providerID,
          "Vertex AI requires a project ID. Set GOOGLE_CLOUD_PROJECT/GCLOUD_PROJECT or pass project in options."
        )
      }
      if apiKey == nil, location == nil {
        throw invalid(
          providerID,
          "Vertex AI requires a location. Set GOOGLE_CLOUD_LOCATION or pass location in options.")
      }
      let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      let custom = base.isEmpty || base.contains("{location}") ? nil : base
      let path = custom.flatMap { URL(string: $0)?.path } ?? custom ?? ""
      let versioned =
        path.range(of: #"(?:^|/)v[0-9]+(?:beta[0-9]*)?(?:/|$)"#, options: .regularExpression) != nil
      return .vertex(
        .init(
          apiKey: apiKey, project: project, location: location,
          keyFilename: apiKey == nil ? options.value("GOOGLE_APPLICATION_CREDENTIALS") : nil,
          customBaseURL: custom, baseURLIncludesVersion: versioned))
    case "bedrock-converse-stream":
      let configuredRegion =
        nonempty(options.region) ?? options.value("AWS_REGION")
        ?? options.value("AWS_DEFAULT_REGION")
      let explicitProfile =
        nonempty(options.profile) ?? nonempty(options.environment["AWS_PROFILE"])
      let profile = explicitProfile ?? options.value("AWS_PROFILE")
      let ambientProfile = nonempty(options.ambientEnvironment["AWS_PROFILE"]) != nil
      let endpointRegion = standardBedrockRegion(baseURL)
      let explicitEndpoint = endpointRegion == nil || (configuredRegion == nil && !ambientProfile)
      let region =
        arnRegion(modelID) ?? configuredRegion ?? (explicitEndpoint ? endpointRegion : nil)
        ?? (ambientProfile ? nil : "us-east-1")
      let skipAuth = options.value("AWS_BEDROCK_SKIP_AUTH") == "1"
      let token =
        skipAuth
        ? nil : nonempty(options.bearerToken) ?? key ?? options.value("AWS_BEARER_TOKEN_BEDROCK")
      let access = options.value("AWS_ACCESS_KEY_ID")
      let secret = options.value("AWS_SECRET_ACCESS_KEY")
      let staticKeys = explicitProfile == nil && access != nil && secret != nil
      return .bedrock(
        .init(
          endpoint: explicitEndpoint ? baseURL : nil, region: region, profile: profile,
          accessKeyID: skipAuth ? "dummy-access-key" : staticKeys ? access : nil,
          secretAccessKey: skipAuth ? "dummy-secret-key" : staticKeys ? secret : nil,
          sessionToken: !skipAuth && staticKeys ? options.value("AWS_SESSION_TOKEN") : nil,
          bearerToken: token, forceHTTP1: options.value("AWS_BEDROCK_FORCE_HTTP1") == "1"))
    case "anthropic-messages":
      let hasHeader = headers.contains { name, value in
        ["authorization", "x-api-key", "cf-aig-authorization"].contains(name.lowercased())
          && value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      }
      guard providerID == "anthropic", key == nil, !hasHeader,
        let rule = options.value("ANTHROPIC_FEDERATION_RULE_ID"),
        let organization = options.value("ANTHROPIC_ORGANIZATION_ID"),
        let file = options.value("ANTHROPIC_IDENTITY_TOKEN_FILE")
      else { return nil }
      return .federation(
        .init(
          baseURL: baseURL, organizationID: organization,
          workspaceID: options.value("ANTHROPIC_WORKSPACE_ID"), federationRuleID: rule,
          serviceAccountID: options.value("ANTHROPIC_SERVICE_ACCOUNT_ID"), identityTokenFile: file))
    default: return nil
    }
  }

  struct Authorization: Sendable {
    let credential: ProviderCredential?
    let headers: [String: String]
    let baseURL: String
    var federated = false
    var vertexCollectionScope = false
  }

  func authorization(
    providerID: String, resolver: ProviderCloudAuthorizationResolver?,
    sources: ProviderCloudCredentialSources
  ) async throws
    -> Authorization
  {
    func resolve(_ request: ProviderCloudAuthorizationRequest) async throws
      -> ProviderCloudCredential
    {
      guard let resolver else {
        throw ProviderRuntimeFailure(
          code: .missingCredential, message: "Cloud authorization requires an explicit resolver",
          providerID: providerID, operation: "cloud.resolve-credential", causeDescription: nil)
      }
      let source = try await sources.source(for: request, resolver: resolver)
      return try await source.credential()
    }
    switch self {
    case .vertex(let value):
      if let key = value.apiKey {
        return .init(
          credential: .apiKey(.init(key: key, metadata: [:])), headers: [:], baseURL: value.baseURL,
          vertexCollectionScope: value.customBaseURL != nil)
      }
      let result = try await resolve(
        .googleApplicationDefaultCredentials(
          project: value.project!, location: value.location!, keyFilename: value.keyFilename))
      guard case .bearerToken(let token) = result else {
        throw Self.invalid(providerID, "Google ADC resolver must return a bearer token")
      }
      return .init(
        credential: .oauth(
          .init(
            accessToken: token, refreshToken: "", expiresAt: .distantFuture,
            metadata: ["projectID": value.project!, "location": value.location!])), headers: [:],
        baseURL: value.baseURL,
        vertexCollectionScope: value.customBaseURL != nil)
    case .bedrock(let value):
      let resolved: ProviderAWSCredentials?
      if value.region == nil || (value.bearerToken == nil && value.accessKeyID == nil) {
        let result = try await resolve(
          .awsCredentials(profile: value.profile, region: value.region))
        guard case .aws(let credential) = result else {
          throw Self.invalid(providerID, "AWS resolver must return AWS credentials and region")
        }
        resolved = credential
      } else {
        resolved = nil
      }
      let region = value.region ?? resolved!.region
      let baseURL =
        value.endpoint
        ?? "https://bedrock-runtime.\(region).amazonaws.com\(region.hasPrefix("cn-") ? ".cn" : "")"
      if let token = value.bearerToken {
        return .init(
          credential: .apiKey(.init(key: token, metadata: [:])), headers: [:], baseURL: baseURL)
      }
      var metadata = [
        "authentication": "sigv4", "region": region,
        "accessKeyID": value.accessKeyID ?? resolved!.accessKeyID,
      ]
      if let token = value.sessionToken ?? (value.accessKeyID == nil ? resolved?.sessionToken : nil)
      {
        metadata["sessionToken"] = token
      }
      return .init(
        credential: .apiKey(
          .init(key: value.secretAccessKey ?? resolved!.secretAccessKey, metadata: metadata)),
        headers: [:], baseURL: baseURL)
    case .federation(let value):
      let result = try await resolve(.anthropicFederation(value))
      guard case .bearerToken(let token) = result else {
        throw Self.invalid(providerID, "Anthropic federation resolver must return a bearer token")
      }
      return .init(
        credential: nil, headers: ["Authorization": "Bearer " + token], baseURL: value.baseURL,
        federated: true)
    }
  }

  static func arnRegion(_ model: String) -> String? {
    let parts = model.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count > 4, parts[0] == "arn", parts[2] == "bedrock",
      parts[1].range(of: "^aws(?:-[a-z0-9-]+)?$", options: .regularExpression) != nil,
      parts[3].range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil
    else { return nil }
    return String(parts[3])
  }

  private static func standardBedrockRegion(_ base: String) -> String? {
    guard let host = URL(string: base)?.host?.lowercased(),
      host.range(
        of: #"^bedrock-runtime(?:-fips)?\.[a-z0-9-]+\.amazonaws\.com(?:\.cn)?$"#,
        options: .regularExpression) != nil
    else { return nil }
    return host.split(separator: ".").dropFirst().first.map(String.init)
  }

  private static func invalid(_ provider: String, _ message: String) -> ProviderRuntimeFailure {
    .init(
      code: .invalidRequest, message: message, providerID: provider,
      operation: "cloud.resolve-configuration", causeDescription: nil)
  }
}
