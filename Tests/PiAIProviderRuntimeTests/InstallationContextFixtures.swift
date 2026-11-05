import Foundation

@testable import PiAIProviderRuntime

enum InstallationContextFixtures {
  static let existingID = "11111111-2222-4333-8444-555555555555"

  static func observePersistentLogin() async throws -> [String] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fresh = root.appendingPathComponent("fresh")
    let existing = root.appendingPathComponent("existing")
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    try existingID.write(
      to: existing.appendingPathComponent("ProviderInstallationID"),
      atomically: true, encoding: .utf8)
    return try await [
      hostID(at: fresh), hostID(at: fresh), hostID(at: existing),
      hostID(at: root.appendingPathComponent("separate")),
    ]
  }

  private static func hostID(at root: URL) async throws -> String {
    let runtime = try BuiltinProviderRuntime(
      installation: .persistent(at: root), credentialStore: InMemoryProviderCredentialStore(),
      authorizationTransport: InstallationUnusedTransport())
    let capture = InstallationChallengeCapture()
    do {
      _ = try await runtime.authorize(.login(providerID: "openai", methodID: "oauth")) {
        challenge in
        if case .openURL(_, let url, _) = challenge {
          await capture.record(url)
        }
        throw CancellationError()
      }
    } catch is CancellationError {}
    guard let result = await capture.hostID else {
      throw ProviderRuntimeFailure(
        code: .invalidResponse, message: "Missing installation host ID",
        providerID: "openai", operation: "fixture.installation", causeDescription: nil)
    }
    return result
  }
}

private actor InstallationChallengeCapture {
  private(set) var hostID: String?

  func record(_ url: URL) {
    hostID =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "ext_agent_host_id" }?.value
  }
}

private struct InstallationUnusedTransport: ProviderHTTPTransport {
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    throw CancellationError()
  }
}
