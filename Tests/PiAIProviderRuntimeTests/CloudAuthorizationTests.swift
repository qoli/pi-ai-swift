import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct CloudAuthorizationTests {
  @Test
  func federationReusesOnlyTheCurrentCredentialSource() async throws {
    let sources = ProviderCloudCredentialSources()
    let created = CloudSourceFactoryCalls()
    let resolver: ProviderCloudAuthorizationResolver = { request in
      let index = await created.append(request)
      return .init { .bearerToken("source-\(index)") }
    }
    let first = ProviderCloudAuthorizationRequest.anthropicFederation(
      .init(
        baseURL: "https://api.anthropic.com",
        organizationID: "fixture-org", federationRuleID: "first-rule",
        identityTokenFile: "/fixture/identity.jwt"))
    let second = ProviderCloudAuthorizationRequest.anthropicFederation(
      .init(
        baseURL: "https://api.anthropic.com",
        organizationID: "fixture-org", federationRuleID: "second-rule",
        identityTokenFile: "/fixture/identity.jwt"))
    var credentials: [ProviderCloudCredential] = []
    for request in [first, first, second, first] {
      let source = try await sources.source(for: request, resolver: resolver)
      credentials.append(try await source.credential())
    }
    #expect(
      credentials == [
        .bearerToken("source-1"), .bearerToken("source-1"), .bearerToken("source-2"),
        .bearerToken("source-3"),
      ])
    #expect(await created.requests == [first, second, first])
  }

  @Test
  func primarySelectionMatchesPinnedSource() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func load(_ directory: String) throws -> [JSONValue] {
      try decodeJSONObject(
        Data(
          contentsOf: root.appending(
            path: "Fixtures/Differential/\(directory)/cloud-authorization.json")),
        providerID: "fixture", operation: "cloud.fixture"
      ).array("cases")!
    }
    let cases = try load("Cases")
    let expected = try load("Oracle")
    #expect(cases.count == expected.count)
    for (item, expected) in zip(cases, expected) {
      let spec = try #require(item.objectValue)
      let config = try #require(expected.objectValue?.object("configuration"))
      #expect(
        try CloudAuthorizationFixtures.differences(spec, expected: config).isEmpty,
        Comment(rawValue: spec.string("id")!))
    }
  }

  @Test
  func resolverResultsDriveNativeWireWithoutChangingAuthModes() async throws {
    let vertex = try await CloudAuthorizationFixtures.replay(
      api: "google-vertex",
      baseURL: "https://proxy.invalid/v1/projects/fixture-project/locations/global",
      cloud: .init(project: "fixture-project", location: "global"))
    let google = try #require(vertex.requests.first)
    #expect(
      google.url?.path
        == "/v1/projects/fixture-project/locations/global/publishers/google/models/fixture-model:streamGenerateContent"
    )
    #expect(google.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-cloud-token")
    #expect(
      vertex.resolutions == [
        .googleApplicationDefaultCredentials(
          project: "fixture-project", location: "global", keyFilename: nil)
      ])
    let aws = try await CloudAuthorizationFixtures.replay(
      api: "bedrock-converse-stream", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
      cloud: .init(ambientEnvironment: ["AWS_PROFILE": "fixture-profile"]))
    let bedrock = try #require(aws.requests.first)
    #expect(bedrock.url?.host == "bedrock-runtime.eu-west-1.amazonaws.com")
    #expect(
      bedrock.value(forHTTPHeaderField: "Authorization")?.contains(
        "/eu-west-1/bedrock/aws4_request") == true)
    #expect(aws.resolutions == [.awsCredentials(profile: "fixture-profile", region: nil)])
    let federation = try await CloudAuthorizationFixtures.replay(
      api: "anthropic-messages", baseURL: "https://api.anthropic.com",
      cloud: .init(environment: [
        "ANTHROPIC_FEDERATION_RULE_ID": "fixture-rule", "ANTHROPIC_ORGANIZATION_ID": "fixture-org",
        "ANTHROPIC_IDENTITY_TOKEN_FILE": "/fixture/identity.jwt",
      ]))
    let anthropic = try #require(
      federation.requests.first, Comment(rawValue: federation.failure?.message ?? "missing request")
    )
    #expect(anthropic.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-cloud-token")
    #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == nil)
    #expect(
      anthropic.value(forHTTPHeaderField: "anthropic-beta")?.contains("oauth-2025-04-20") == true)
    #expect(
      federation.payloads.first?.array("betas")?.contains(.string("oauth-2025-04-20")) != true)
  }

  @Test
  func absentOrFailingResolverNeverUsesAnotherCredentialSource() async throws {
    for mode in [CloudAuthorizationFixtures.ResolverMode.absent, .failure] {
      let result = try await CloudAuthorizationFixtures.replay(
        api: "google-vertex", baseURL: "https://proxy.invalid",
        cloud: .init(project: "fixture-project", location: "global"), mode: mode)
      #expect(result.requests.isEmpty)
      #expect(
        result.failure?.operation
          == (mode == .absent ? "cloud.resolve-credential" : "fixture.resolver"))
    }
  }
}

private actor CloudSourceFactoryCalls {
  var requests: [ProviderCloudAuthorizationRequest] = []
  func append(_ value: ProviderCloudAuthorizationRequest) -> Int {
    requests.append(value)
    return requests.count
  }
}
