#if os(iOS)
  import Foundation
  import XCTest

  @testable import PiAIProviderRuntime

  final class OpenAICodexSimulatorLiveTests: XCTestCase {
    func testDeviceCodeLogin() async throws {
      try XCTSkipUnless(
        ProcessInfo.processInfo.environment["PI_AI_LIVE_CODEX_AUTH"] == "1",
        "set PI_AI_LIVE_CODEX_AUTH=1 in the simulator to run live OAuth"
      )

      emit("IOS_SIMULATOR_CODEX_AUTH_START")
      emit("runtime=\(ProcessInfo.processInfo.operatingSystemVersionString)")

      let client = OpenAICodexOAuthClient()
      let authorization = try await client.startDeviceAuthorization()
      emit("IOS_SIMULATOR_CODEX_AUTH_READY")
      emit("verification_url=\(authorization.verificationURL.absoluteString)")
      emit("user_code=\(authorization.userCode)")
      emit("expires_at=\(authorization.expiresAt.ISO8601Format())")

      let credential = try await client.waitForCredential(authorization)
      let result = SimulatorProbeResult(
        status: "succeeded",
        runtime: ProcessInfo.processInfo.operatingSystemVersionString,
        accountIDPresent: credential.metadata["accountID"] != nil,
        accessTokenPresent: !credential.accessToken.isEmpty,
        refreshTokenPresent: !credential.refreshToken.isEmpty,
        expiresAt: credential.expiresAt
      )
      let resultURL = FileManager.default.temporaryDirectory.appending(
        path: "pi-ai-swift-codex-auth-result.json"
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(result).write(to: resultURL, options: .atomic)

      XCTAssertTrue(result.accountIDPresent)
      XCTAssertTrue(result.accessTokenPresent)
      XCTAssertTrue(result.refreshTokenPresent)
      emit("IOS_SIMULATOR_CODEX_AUTH_SUCCEEDED")
      emit("account_id_present=\(result.accountIDPresent)")
      emit("access_token_present=\(result.accessTokenPresent)")
      emit("refresh_token_present=\(result.refreshTokenPresent)")
      emit("expires_at=\(credential.expiresAt.ISO8601Format())")
      emit("credential_persisted=false")
      emit("safe_result_path=\(resultURL.path)")
    }

    private func emit(_ message: String) {
      FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }
  }

  private struct SimulatorProbeResult: Encodable {
    let status: String
    let runtime: String
    let accountIDPresent: Bool
    let accessTokenPresent: Bool
    let refreshTokenPresent: Bool
    let expiresAt: Date
  }
#endif
