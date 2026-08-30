import Foundation
import PiAIProviderRuntime

@main
struct PiAIAuthProbe {
  static func main() async {
    let client = OpenAICodexOAuthClient()
    do {
      let authorization = try await client.startDeviceAuthorization()
      print("OPENAI_CODEX_DEVICE_AUTH_READY")
      print("verification_url=\(authorization.verificationURL.absoluteString)")
      print("user_code=\(authorization.userCode)")
      print("expires_at=\(authorization.expiresAt.ISO8601Format())")
      print("Complete authorization in the browser. Waiting for approval...")

      let credential = try await client.waitForCredential(authorization)
      print("OPENAI_CODEX_DEVICE_AUTH_SUCCEEDED")
      print("account_id_present=\(credential.metadata["accountID"] != nil)")
      print("access_token_present=\(!credential.accessToken.isEmpty)")
      print("refresh_token_present=\(!credential.refreshToken.isEmpty)")
      print("expires_at=\(credential.expiresAt.ISO8601Format())")
      print("credential_persisted=false")
      persistResult(
        ProbeResult(
          status: "succeeded",
          failureCode: nil,
          failureOperation: nil,
          accountIDPresent: credential.metadata["accountID"] != nil,
          accessTokenPresent: !credential.accessToken.isEmpty,
          refreshTokenPresent: !credential.refreshToken.isEmpty,
          expiresAt: credential.expiresAt
        )
      )
    } catch is CancellationError {
      print("OPENAI_CODEX_DEVICE_AUTH_CANCELLED")
      persistResult(
        ProbeResult(
          status: "cancelled",
          failureCode: nil,
          failureOperation: nil,
          accountIDPresent: false,
          accessTokenPresent: false,
          refreshTokenPresent: false,
          expiresAt: nil
        )
      )
      Foundation.exit(EXIT_FAILURE)
    } catch let error as ProviderRuntimeFailure {
      print("OPENAI_CODEX_DEVICE_AUTH_FAILED")
      print("code=\(error.code.rawValue)")
      print("operation=\(error.operation ?? "unknown")")
      print("message=\(error.message)")
      if let cause = error.causeDescription {
        print("cause=\(cause)")
      }
      persistResult(
        ProbeResult(
          status: "failed",
          failureCode: error.code.rawValue,
          failureOperation: error.operation,
          accountIDPresent: false,
          accessTokenPresent: false,
          refreshTokenPresent: false,
          expiresAt: nil
        )
      )
      Foundation.exit(EXIT_FAILURE)
    } catch {
      print("OPENAI_CODEX_DEVICE_AUTH_FAILED")
      print("error=\(error)")
      persistResult(
        ProbeResult(
          status: "failed",
          failureCode: "unexpected",
          failureOperation: nil,
          accountIDPresent: false,
          accessTokenPresent: false,
          refreshTokenPresent: false,
          expiresAt: nil
        )
      )
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func persistResult(_ result: ProbeResult) {
    guard
      let path = ProcessInfo.processInfo.environment[
        "PI_AI_AUTH_PROBE_RESULT_PATH"
      ]
    else { return }

    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(result).write(
        to: URL(fileURLWithPath: path),
        options: .atomic
      )
      print("safe_result_persisted=true")
    } catch {
      print("safe_result_persisted=false")
      print("safe_result_error=\(error)")
    }
  }
}

private struct ProbeResult: Encodable {
  let status: String
  let failureCode: String?
  let failureOperation: String?
  let accountIDPresent: Bool
  let accessTokenPresent: Bool
  let refreshTokenPresent: Bool
  let expiresAt: Date?
}
