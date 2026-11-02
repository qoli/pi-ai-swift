import Foundation

struct ProviderPrimaryAuthorization: Sendable {
  let credential: ProviderCredential?
  let headers: [String: String?]
  let environment: [String: String]?
  let source: String
  let connectionEnvironment: [String: String]

  var projected: JSONValue {
    var auth: [String: JSONValue] = [:]
    if !headers.isEmpty {
      auth["headers"] = .object(headers.mapValues { $0.map(JSONValue.string) ?? .null })
    } else if case .apiKey(let value) = credential, let key = value.configuredKey {
      auth["apiKey"] = .string(key)
    }
    var output: [String: JSONValue] = ["auth": .object(auth), "source": .string(source)]
    if let environment { output["env"] = .object(environment.mapValues(JSONValue.string)) }
    return .object(output)
  }

  static func resolve(
    providerID: String, credential: ProviderCredential?, context: ProviderAuthenticationContext,
    variables: [String]? = nil
  ) async throws -> Self? {
    try Task.checkCancellation()
    if case .oauth = credential {
      return .init(
        credential: credential, headers: [:], environment: nil,
        source: "stored credential", connectionEnvironment: [:])
    }
    let stored: APIKeyCredential?
    if case .apiKey(let value) = credential { stored = value } else { stored = nil }
    let storedEnvironment =
      stored?.environment
      ?? (CloudflareAuthorizationAdapter.providerIDs.contains(providerID)
        && stored?.metadata.isEmpty == false
        ? stored?.metadata : nil)
    var observed: [String: String] = [:]
    func env(_ name: String) async throws -> String? {
      try Task.checkCancellation()
      let value = try await context.environment(name)
      try Task.checkCancellation()
      observed[name] = value
      return value
    }
    func preferred(_ value: String?, _ names: [String]) async throws -> String? {
      if let value { return value }
      for name in names { if let value = try await env(name) { return value } }
      return nil
    }
    func result(
      key: String? = nil, headers: [String: String?] = [:],
      environment: [String: String]? = nil, source: String, preserveStored: Bool = false
    ) -> Self {
      let resolved: ProviderCredential?
      if preserveStored {
        resolved = credential
      } else if let key {
        resolved = .apiKey(.init(key: key, metadata: [:], environment: environment))
      } else {
        resolved = nil
      }
      return .init(
        credential: resolved, headers: headers, environment: environment, source: source,
        connectionEnvironment: observed.merging(environment ?? [:]) { _, stored in stored })
    }
    if CloudflareAuthorizationAdapter.providerIDs.contains(providerID) {
      let key = try await preferred(stored?.configuredKey, ["CLOUDFLARE_API_KEY"])
      let account = try await preferred(
        storedEnvironment?["CLOUDFLARE_ACCOUNT_ID"], ["CLOUDFLARE_ACCOUNT_ID"])
      let gateway =
        providerID == "cloudflare-ai-gateway"
        ? try await preferred(
          storedEnvironment?["CLOUDFLARE_GATEWAY_ID"], ["CLOUDFLARE_GATEWAY_ID"]) : nil
      guard let key, !key.isEmpty, let account, !account.isEmpty,
        providerID != "cloudflare-ai-gateway" || gateway?.isEmpty == false
      else { return nil }
      var values = ["CLOUDFLARE_ACCOUNT_ID": account]
      if let gateway, !gateway.isEmpty { values["CLOUDFLARE_GATEWAY_ID"] = gateway }
      var resolved = result(
        key: key, environment: values,
        source: stored == nil ? "CLOUDFLARE_API_KEY" : "stored credential")
      if providerID == "cloudflare-ai-gateway" {
        resolved = .init(
          credential: resolved.credential,
          headers: [
            "cf-aig-authorization": "Bearer " + key, "Authorization": nil, "x-api-key": nil,
          ],
          environment: values, source: resolved.source,
          connectionEnvironment: resolved.connectionEnvironment)
      }
      return resolved
    }
    if providerID != "google-vertex", let key = stored?.configuredKey, !key.isEmpty {
      return result(
        environment: storedEnvironment, source: "stored credential", preserveStored: true)
    }
    switch providerID {
    case "anthropic":
      if let token = try await env("ANTHROPIC_AUTH_TOKEN"), !token.isEmpty {
        return result(headers: ["Authorization": "Bearer " + token], source: "ANTHROPIC_AUTH_TOKEN")
      }
      if let key = try await ProviderEnvironmentKeys.firstAPIKey(
        providerID: providerID, environment: env)
      {
        return result(key: key.value, source: key.name)
      }
      var federation: [String: String] = [:]
      for name in [
        "ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID",
        "ANTHROPIC_IDENTITY_TOKEN_FILE",
      ] {
        guard let value = try await env(name), !value.isEmpty else { return nil }
        federation[name] = value
      }
      for name in ["ANTHROPIC_SERVICE_ACCOUNT_ID", "ANTHROPIC_WORKSPACE_ID"] {
        if let value = try await env(name), !value.isEmpty { federation[name] = value }
      }
      return result(environment: federation, source: "workload identity federation")
    case "amazon-bedrock":
      if let token = try await env("AWS_BEARER_TOKEN_BEDROCK"), !token.isEmpty {
        return result(source: "AWS_BEARER_TOKEN_BEDROCK")
      }
      let profile = try await preferred(storedEnvironment?["AWS_PROFILE"], ["AWS_PROFILE"])
      if let profile, !profile.isEmpty {
        return result(
          environment: storedEnvironment,
          source: storedEnvironment?["AWS_PROFILE"]?.isEmpty == false
            ? "stored credential" : "AWS_PROFILE")
      }
      if let access = try await env("AWS_ACCESS_KEY_ID"), !access.isEmpty,
        let secret = try await env("AWS_SECRET_ACCESS_KEY"), !secret.isEmpty
      {
        return result(source: "AWS access keys")
      }
      for (name, source) in [
        ("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "ECS task role"),
        ("AWS_CONTAINER_CREDENTIALS_FULL_URI", "ECS task role"),
        ("AWS_WEB_IDENTITY_TOKEN_FILE", "web identity token"),
      ] {
        if let value = try await env(name), !value.isEmpty { return result(source: source) }
      }
      return nil
    case "google-vertex":
      if let key = try await preferred(stored?.configuredKey, ["GOOGLE_CLOUD_API_KEY"]),
        !key.isEmpty
      {
        return result(
          key: key,
          source: stored?.configuredKey == nil ? "GOOGLE_CLOUD_API_KEY" : "stored credential")
      }
      let path = try await preferred(
        storedEnvironment?["GOOGLE_APPLICATION_CREDENTIALS"], ["GOOGLE_APPLICATION_CREDENTIALS"])
      try Task.checkCancellation()
      let exists = try await context.fileExists(
        path ?? "~/.config/gcloud/application_default_credentials.json")
      try Task.checkCancellation()
      let project = try await preferred(
        storedEnvironment?["GOOGLE_CLOUD_PROJECT"], ["GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT"])
      let location = try await preferred(
        storedEnvironment?["GOOGLE_CLOUD_LOCATION"], ["GOOGLE_CLOUD_LOCATION"])
      guard exists, project?.isEmpty == false, location?.isEmpty == false else { return nil }
      return result(
        environment: storedEnvironment,
        source: stored == nil ? "gcloud application default credentials" : "stored credential")
    default:
      if let key = try await ProviderEnvironmentKeys.firstAPIKey(
        providerID: providerID, variables: variables,
        environment: env)
      {
        return result(key: key.value, source: key.name)
      }
      return nil
    }
  }

  static func availableModels(
    _ models: [ProviderAvailableModel], providerID: String, credential: ProviderCredential?
  ) -> [ProviderAvailableModel] {
    guard case .oauth(let oauth) = credential else { return models }
    if providerID == "openai" { return models.filter { $0.outputModality != .classification } }
    guard providerID == "github-copilot" else { return models }
    let ids: [String]
    if let raw = oauth.metadata["availableModelIDsJSON"] {
      guard let value = try? JSONValue(jsonData: Data(raw.utf8)), let values = value.arrayValue,
        values.allSatisfy({ $0.stringValue != nil })
      else { return models }
      ids = values.compactMap(\.stringValue)
    } else if let raw = oauth.metadata["availableModelIDs"] {
      ids = raw.isEmpty ? [] : raw.components(separatedBy: ",")
    } else {
      return models
    }
    return models.filter { ids.contains($0.modelID) }
  }
}
