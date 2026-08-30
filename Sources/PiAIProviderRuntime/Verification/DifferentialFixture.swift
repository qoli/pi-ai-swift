import CryptoKit
import Foundation

struct DifferentialFixture: Sendable, Equatable, Codable {
  let schemaVersion: Int
  let fixtureID: String
  let areaIDs: [String]
  let providerID: String
  let protocolID: String
  let provenance: DifferentialFixtureProvenance
  let payload: DifferentialFixturePayload
  let payloadSHA256: String
}

struct DifferentialFixtureProvenance: Sendable, Equatable, Codable {
  let repository: String
  let revision: String
  let sourcePaths: [String]
  let testPaths: [String]
  let oracleVersion: String
  let sanitization: [String]
}

struct DifferentialFixturePayload: Sendable, Equatable, Codable {
  let request: ProviderRequest
  let expectedRequest: DifferentialExpectedRequest
  let responseChunksBase64: [String]
  let expectedEvents: [ProviderEvent]
  let expectedFailure: ProviderRuntimeFailure?
}

struct DifferentialExpectedRequest: Sendable, Equatable, Codable {
  let method: String
  let url: String
  let headers: [String: String]
  let body: JSONValue
}

enum DifferentialFixtureValidator {
  static func validate(
    _ fixture: DifferentialFixture,
    expectedRevision: String
  ) throws {
    guard fixture.schemaVersion == 1 else {
      throw failure("unsupported differential fixture schema")
    }
    guard !fixture.fixtureID.isEmpty, !fixture.areaIDs.isEmpty,
      !fixture.providerID.isEmpty, !fixture.protocolID.isEmpty
    else {
      throw failure("differential fixture identity is incomplete")
    }
    guard fixture.provenance.revision == expectedRevision else {
      throw failure(
        "differential fixture revision mismatch: expected \(expectedRevision), found \(fixture.provenance.revision)"
      )
    }
    guard !fixture.provenance.sourcePaths.isEmpty,
      !fixture.provenance.testPaths.isEmpty,
      !fixture.provenance.oracleVersion.isEmpty
    else {
      throw failure("differential fixture provenance is incomplete")
    }
    let digest = try payloadDigest(fixture.payload)
    guard digest == fixture.payloadSHA256 else {
      throw failure(
        "differential fixture payload digest mismatch: expected \(fixture.payloadSHA256), found \(digest)"
      )
    }
    let encoded = try JSONEncoder.canonical.encode(fixture)
    guard let text = String(data: encoded, encoding: .utf8) else {
      throw failure("differential fixture is not UTF-8 JSON")
    }
    for pattern in secretPatterns where text.range(of: pattern, options: .regularExpression) != nil
    {
      throw failure("differential fixture contains credential-shaped data")
    }
    guard fixture.payload.expectedFailure == nil || fixture.payload.expectedEvents.isEmpty else {
      throw failure("failure fixture must not contain valid-looking expected events")
    }
    for chunk in fixture.payload.responseChunksBase64 {
      guard Data(base64Encoded: chunk) != nil else {
        throw failure("differential fixture contains malformed response chunk base64")
      }
    }
  }

  static func payloadDigest(
    _ payload: DifferentialFixturePayload
  ) throws -> String {
    let data = try JSONEncoder.canonical.encode(payload)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func compare(
    request: URLRequest,
    events: [ProviderEvent],
    with fixture: DifferentialFixture
  ) throws {
    let expected = fixture.payload.expectedRequest
    guard request.httpMethod == expected.method else {
      throw failure("differential request method mismatch")
    }
    guard request.url?.absoluteString == expected.url else {
      throw failure("differential request URL mismatch")
    }
    for (name, value) in expected.headers {
      guard request.value(forHTTPHeaderField: name) == value else {
        throw failure("differential request header mismatch: \(name)")
      }
    }
    guard let body = request.httpBody else {
      throw failure("differential request body is missing")
    }
    let actualBody = try JSONDecoder().decode(JSONValue.self, from: body)
    guard actualBody == expected.body else {
      throw failure("differential request body mismatch")
    }
    guard events == fixture.payload.expectedEvents else {
      throw failure("differential normalized event sequence mismatch")
    }
  }

  private static let secretPatterns = [
    #"sk-[A-Za-z0-9_-]{12,}"#,
    #"(?i)bearer\s+[A-Za-z0-9._-]{12,}"#,
    #"(?i)\"(?:access_token|refresh_token|api_key)\"\s*:\s*\"(?!<redacted>)[^\"]+\""#,
  ]

  private static func failure(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .upstreamDrift,
      message: message,
      providerID: nil,
      operation: "fixture.validate",
      causeDescription: nil
    )
  }
}

extension JSONEncoder {
  fileprivate static var canonical: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
