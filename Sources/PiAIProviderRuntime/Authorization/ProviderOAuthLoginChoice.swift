import Foundation

enum ProviderOAuthLoginChoice {
  static func select(providerID: String, interaction: @escaping AuthorizationInteraction)
    async throws -> String
  {
    try Task.checkCancellation()
    let name = providerID == "anthropic" ? "Anthropic" : "OpenAI Codex"
    let secondID = providerID == "anthropic" ? "copy_code" : "device_code"
    let secondLabel =
      providerID == "anthropic" ? "Copy code login (headless)" : "Device code login (headless)"
    let response = try await interaction(
      .choice(
        providerID: providerID, id: "oauth-login-method",
        message: "Select \(name) login method:",
        options: [
          .init(id: "browser", label: "Browser login (default)"),
          .init(id: secondID, label: secondLabel),
        ]))
    try Task.checkCancellation()
    guard case .value(let method) = response, ["browser", secondID].contains(method) else {
      let method = if case .value(let value) = response { value } else { "" }
      throw ProviderRuntimeFailure(
        code: .authorizationFailed, message: "Unknown \(name) login method: \(method)",
        providerID: providerID, operation: "oauth.login.select-method", causeDescription: nil)
    }
    return method
  }
}
