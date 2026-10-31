import Foundation

@testable import PiAIProviderRuntime

enum CloudConformanceProbe {
  static func options(_ options: [String: JSONValue], ambient: [String: JSONValue])
    -> ProviderCloudConnectionOptions
  {
    .init(
      environment: (options.object("env") ?? [:]).compactMapValues(\.stringValue),
      ambientEnvironment: ambient.compactMapValues(\.stringValue), region: options.string("region"),
      profile: options.string("profile"), bearerToken: options.string("bearerToken"),
      project: options.string("project"), location: options.string("location"))
  }

  static func configuration(_ plan: ProviderCloudPlan, headers: [String: String] = [:]) -> [String:
    JSONValue]
  {
    switch plan {
    case .vertex(let value):
      var result: [String: JSONValue] = ["vertexai": .bool(true), "apiVersion": .string("v1")]
      if let key = value.apiKey { result["apiKey"] = .string(key) }
      if let project = value.project { result["project"] = .string(project) }
      if let location = value.location { result["location"] = .string(location) }
      if let file = value.keyFilename {
        result["googleAuthOptions"] = .object(["keyFilename": .string(file)])
      }
      var http: [String: JSONValue] = [:]
      if let baseURL = value.customBaseURL {
        http["baseUrl"] = .string(baseURL)
        http["baseUrlResourceScope"] = .string("COLLECTION")
        if value.baseURLIncludesVersion { http["apiVersion"] = .string("") }
      }
      if !headers.isEmpty { http["headers"] = .object(headers.mapValues(JSONValue.string)) }
      if !http.isEmpty { result["httpOptions"] = .object(http) }
      return result
    case .bedrock(let value):
      var result: [String: JSONValue] = [:]
      if let endpoint = value.endpoint { result["endpoint"] = .string(endpoint) }
      if let region = value.region { result["region"] = .string(region) }
      if let profile = value.profile { result["profile"] = .string(profile) }
      if let access = value.accessKeyID, let secret = value.secretAccessKey {
        var keys: [String: JSONValue] = [
          "accessKeyId": .string(access), "secretAccessKey": .string(secret),
        ]
        if let token = value.sessionToken { keys["sessionToken"] = .string(token) }
        result["credentials"] = .object(keys)
      }
      if let token = value.bearerToken {
        result["token"] = .object(["token": .string(token)])
        result["authSchemePreference"] = .array([.string("httpBearerAuth")])
      }
      return result
    case .federation(let value):
      return [
        "apiKey": .null, "authToken": .null, "config": .object(federationConfiguration(value)),
      ]
    }
  }

  static func federationConfiguration(_ value: ProviderAnthropicFederation) -> [String: JSONValue] {
    var auth: [String: JSONValue] = [
      "type": .string("oidc_federation"),
      "federation_rule_id": .string(value.federationRuleID),
      "identity_token": .object([
        "source": .string("file"), "path": .string(value.identityTokenFile),
      ]),
    ]
    if let account = value.serviceAccountID { auth["service_account_id"] = .string(account) }
    var config: [String: JSONValue] = [
      "organization_id": .string(value.organizationID), "authentication": .object(auth),
    ]
    if let workspace = value.workspaceID { config["workspace_id"] = .string(workspace) }
    return config
  }
}
