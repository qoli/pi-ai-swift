import Foundation

@testable import PiAIProviderRuntime

enum CloudAuthorizationFixtures {
  static func repeatedFederationSourceCount() async throws -> Int {
    let sources = ProviderCloudCredentialSources()
    let capture = CloudFixtureCapture()
    let request = ProviderCloudAuthorizationRequest.anthropicFederation(
      .init(
        baseURL: "https://api.anthropic.com",
        organizationID: "fixture-org", federationRuleID: "fixture-rule",
        identityTokenFile: "/fixture/identity.jwt"))
    let resolver: ProviderCloudAuthorizationResolver = { value in
      await capture.resolved(value)
      return .init { .bearerToken("fixture-cloud-token") }
    }
    for _ in 0..<3 {
      let source = try await sources.source(for: request, resolver: resolver)
      _ = try await source.credential()
    }
    return await capture.resolutions.count
  }

  static func options(_ raw: [String: JSONValue], ambient: [String: JSONValue])
    -> ProviderCloudConnectionOptions
  {
    .init(
      environment: (raw.object("env") ?? [:]).compactMapValues(\.stringValue),
      ambientEnvironment: ambient.compactMapValues(\.stringValue), region: raw.string("region"),
      profile: raw.string("profile"), bearerToken: raw.string("bearerToken"),
      project: raw.string("project"), location: raw.string("location"))
  }

  static func differences(_ spec: [String: JSONValue], expected: [String: JSONValue]) throws
    -> [String]
  {
    let api = spec.string("api")!
    let raw = spec.object("options") ?? [:]
    let provider =
      spec.string("providerID")
      ?? (api == "anthropic-messages"
        ? "anthropic" : api == "google-vertex" ? "google-vertex" : "amazon-bedrock")
    let base =
      spec.string("baseURL")
      ?? (api == "anthropic-messages"
        ? "https://api.anthropic.com"
        : api == "google-vertex"
          ? "https://{location}-aiplatform.googleapis.com/v1/projects/{project}/locations/{location}"
          : "https://bedrock-runtime.us-east-1.amazonaws.com")
    let credential = raw.string("apiKey").map {
      ProviderCredential.apiKey(.init(key: $0, metadata: [:]))
    }
    let plan = try ProviderCloudPlan.resolve(
      protocolID: api, providerID: provider,
      modelID: spec.string("modelID") ?? "fixture-model", baseURL: base, credential: credential,
      headers: raw.object("headers")?.mapValues(\.stringValue) ?? [:],
      options: options(raw, ambient: spec.object("ambient") ?? [:]))
    var mismatches: [String] = []
    func equal(_ label: String, _ actual: String?, _ expected: String?) {
      if actual != expected { mismatches.append(label) }
    }
    switch plan {
    case .vertex(let value):
      equal("apiKey", value.apiKey, expected.string("apiKey"))
      equal("project", value.project, expected.string("project"))
      equal("location", value.location, expected.string("location"))
      equal(
        "keyFilename", value.keyFilename,
        expected.object("googleAuthOptions")?.string("keyFilename"))
      equal("baseURL", value.customBaseURL, expected.object("httpOptions")?.string("baseUrl"))
      if value.baseURLIncludesVersion
        != (expected.object("httpOptions")?.string("apiVersion") == "")
      {
        mismatches.append("version override")
      }
    case .bedrock(let value):
      equal("endpoint", value.endpoint, expected.string("endpoint"))
      equal("region", value.region, expected.string("region"))
      equal("profile", value.profile, expected.string("profile"))
      equal("accessKeyID", value.accessKeyID, expected.object("credentials")?.string("accessKeyId"))
      equal(
        "secretAccessKey", value.secretAccessKey,
        expected.object("credentials")?.string("secretAccessKey"))
      equal(
        "sessionToken", value.sessionToken, expected.object("credentials")?.string("sessionToken"))
      equal("bearerToken", value.bearerToken, expected.object("token")?.string("token"))
    case .federation(let value):
      let config = expected.object("config") ?? [:]
      equal("organizationID", value.organizationID, config.string("organization_id"))
      equal("workspaceID", value.workspaceID, config.string("workspace_id"))
      equal(
        "federationRuleID", value.federationRuleID,
        config.object("authentication")?.string("federation_rule_id"))
      equal(
        "serviceAccountID", value.serviceAccountID,
        config.object("authentication")?.string("service_account_id"))
      equal(
        "identityTokenFile", value.identityTokenFile,
        config.object("authentication")?.object("identity_token")?.string("path"))
    case nil:
      if expected["config"] != nil { mismatches.append("missing federation plan") }
    }
    return mismatches
  }

  struct Result {
    let requests: [URLRequest]
    let resolutions: [ProviderCloudAuthorizationRequest]
    let failure: ProviderRuntimeFailure?
    let payloads: [[String: JSONValue]]
  }

  enum ResolverMode { case success, absent, failure }

  static func replay(
    api: String, baseURL: String, credential: ProviderCredential? = nil,
    cloud: ProviderCloudConnectionOptions, mode: ResolverMode = .success
  ) async throws -> Result {
    let provider =
      api == "anthropic-messages"
      ? "anthropic" : api == "google-vertex" ? "google-vertex" : "amazon-bedrock"
    let capture = CloudFixtureCapture()
    let resolver: ProviderCloudAuthorizationResolver?
    if mode == .absent {
      resolver = nil
    } else {
      resolver = { request in
        await capture.resolved(request)
        if mode == .failure {
          throw ProviderRuntimeFailure(
            code: .authorizationFailed, message: "fixture resolver failure",
            providerID: provider, operation: "fixture.resolver", causeDescription: nil)
        }
        return .init {
          switch request {
          case .awsCredentials(_, let region):
            return .aws(
              .init(
                accessKeyID: "FIXTURE_ACCESS", secretAccessKey: "fixture-secret",
                region: region ?? "eu-west-1"))
          default: return .bearerToken("fixture-cloud-token")
          }
        }
      }
    }
    let runtime = try CustomProviderRuntime(
      providers: [
        .init(
          id: provider, baseURL: URL(string: baseURL), api: api,
          models: [
            .init(
              id: "fixture-model",
              capabilities: .init(
                textInput: true, imageInput: false,
                toolCalling: false, reasoning: false, structuredOutput: false,
                imageGeneration: false),
              maximumOutputTokens: 4096)
          ])
      ],
      credentialStore: InMemoryProviderCredentialStore(
        credentials: credential.map { [provider: $0] } ?? [:]),
      streamingTransport: capture,
      wireObserver: .init(onPayload: { payload, _ in
        await capture.payload(payload)
        return nil
      }), cloudAuthorizationResolver: resolver)
    var failure: ProviderRuntimeFailure?
    do {
      for try await _ in runtime.stream(
        .init(
          id: "cloud-fixture", providerID: provider,
          modelID: "fixture-model", messages: [.user([.text("synthetic question")])], tools: [],
          options: .init(
            maximumOutputTokens: nil, temperature: nil, reasoningEffort: nil,
            responseSchema: nil, providerOptions: [:]), connectionOptions: .init(cloud: cloud)))
      {}
    } catch let error as ProviderRuntimeFailure { failure = error }
    return await Result(
      requests: capture.requests, resolutions: capture.resolutions,
      failure: failure, payloads: capture.payloads)
  }
}

private actor CloudFixtureCapture: ProviderHTTPStreamingTransport {
  var requests: [URLRequest] = []
  var resolutions: [ProviderCloudAuthorizationRequest] = []
  var payloads: [[String: JSONValue]] = []
  func resolved(_ request: ProviderCloudAuthorizationRequest) { resolutions.append(request) }
  func payload(_ value: [String: JSONValue]) { payloads.append(value) }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    requests.append(request)
    return .init(statusCode: 403, headers: [:], body: AsyncThrowingStream { $0.finish() })
  }
}
