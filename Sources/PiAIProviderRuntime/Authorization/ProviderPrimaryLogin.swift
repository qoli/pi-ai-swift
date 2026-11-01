import Foundation

enum ProviderPrimaryLogin {
  static func credential(providerID: String, label: String, interaction: AuthorizationInteraction)
    async throws -> APIKeyCredential
  {
    func value(_ challenge: AuthorizationChallenge) async throws -> String {
      guard case .value(let value) = try await interaction(challenge) else {
        throw ProviderRuntimeFailure(
          code: .authorizationFailed,
          message: "API-key authorization was not completed", providerID: providerID,
          operation: "api-key.login", causeDescription: nil)
      }
      return value
    }
    func prompt(_ message: String, kind: AuthorizationPromptKind = .text) async throws -> String {
      try await value(.prompt(providerID: providerID, id: "api-key", message: message, kind: kind))
    }
    try Task.checkCancellation()
    if providerID == "amazon-bedrock" {
      let method = try await value(
        .choice(
          providerID: providerID, id: "bedrock-authentication-method",
          message: "Select Amazon Bedrock authentication method:",
          options: [
            .init(id: "bearer-token", label: "Bearer token"),
            .init(id: "aws-profile", label: "AWS profile"),
            .init(id: "credential-chain", label: "Existing AWS credential chain"),
          ]))
      try Task.checkCancellation()
      if method == "bearer-token" {
        return .init(
          key: try await prompt("Enter Amazon Bedrock bearer token", kind: .secret), metadata: [:])
      }
      _ = try await interaction(
        .information(
          providerID: providerID,
          message:
            "Amazon Bedrock supports AWS profiles, IAM credentials, and role-based credentials.",
          links: [
            .init(
              label: "AWS credential provider chain",
              url: URL(
                string:
                  "https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html")!)
          ]))
      if method == "aws-profile" {
        return .init(environment: ["AWS_PROFILE": try await prompt("Enter AWS profile name")])
      }
      guard method == "credential-chain" else { throw unknown(providerID, method) }
      _ = try await prompt("Configure AWS credentials, then press Enter to continue")
      return .init(environment: nil)
    }
    if providerID == "google-vertex" {
      let method = try await value(
        .choice(
          providerID: providerID, id: "vertex-authentication-method",
          message: "Select Google Vertex AI authentication method:",
          options: [
            .init(id: "api-key", label: "Google Cloud API key"),
            .init(id: "adc", label: "Application Default Credentials"),
            .init(id: "service-account", label: "Service account credentials file"),
          ]))
      try Task.checkCancellation()
      if method == "api-key" {
        return .init(
          key: try await prompt("Enter Google Cloud API key", kind: .secret), metadata: [:])
      }
      guard method == "adc" || method == "service-account" else {
        throw unknown(providerID, method)
      }
      _ = try await interaction(
        .information(
          providerID: providerID,
          message: method == "adc"
            ? "Run `gcloud auth application-default login`, then provide the project and location."
            : "Provide a service account credentials file, project, and location.",
          links: [
            .init(
              label: "Application Default Credentials",
              url: URL(
                string: "https://cloud.google.com/docs/authentication/provide-credentials-adc")!)
          ]))
      let project = try await prompt("Enter Google Cloud project ID")
      let location = try await prompt("Enter Google Cloud location")
      let path =
        method == "service-account"
        ? try await prompt("Enter service account credentials file path") : nil
      var environment = ["GOOGLE_CLOUD_PROJECT": project, "GOOGLE_CLOUD_LOCATION": location]
      if let path, !path.isEmpty { environment["GOOGLE_APPLICATION_CREDENTIALS"] = path }
      return .init(environment: environment)
    }
    let key = try await prompt(label, kind: .secret)
    try Task.checkCancellation()
    return .init(key: key, metadata: [:])
  }

  private static func unknown(_ providerID: String, _ method: String) -> ProviderRuntimeFailure {
    .init(
      code: .authorizationFailed,
      message:
        "Unknown \(providerID == "amazon-bedrock" ? "Amazon Bedrock" : "Google Vertex AI") auth method: \(method)",
      providerID: providerID, operation: "api-key.login", causeDescription: nil)
  }
}
