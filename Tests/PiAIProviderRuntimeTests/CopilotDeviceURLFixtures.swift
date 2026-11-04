import Foundation

@testable import PiAIProviderRuntime

enum CopilotDeviceURLFixtures {
  // github-copilot-oauth.test.ts: normalizes verification_uri before onDeviceCode.
  static let verificationURI = "https://github.com/login/\u{1b}]8;;evil"

  static func verificationURL() async throws -> URL {
    let adapter = GitHubCopilotOAuthAuthorizationAdapter(transport: DeviceTransport())
    do {
      _ = try await adapter.authorize(
        .login(providerID: "github-copilot", methodID: "oauth"),
        interaction: { challenge in
          if case .deviceCode(_, _, let url, _, _) = challenge { throw ObservedURL(value: url) }
          return .value("")
        },
        credentialStore: InMemoryProviderCredentialStore())
    } catch let observation as ObservedURL {
      return observation.value
    }
    throw ProviderRuntimeFailure(
      code: .authorizationFailed, message: "Device fixture did not receive its URL",
      providerID: "github-copilot", operation: "fixture.copilot-url", causeDescription: nil)
  }

  private struct ObservedURL: Error { let value: URL }

  private struct DeviceTransport: ProviderHTTPTransport {
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
      .init(
        statusCode: 200, headers: [:],
        body: try JSONEncoder().encode([
          "device_code": JSONValue.string("device-code"), "user_code": .string("ABCD-EFGH"),
          "verification_uri": .string(verificationURI), "interval": .integer(1),
          "expires_in": .integer(900),
        ]))
    }
  }
}
