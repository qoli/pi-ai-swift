import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct DifferentialFixtureTests {
  @Test
  func validatesPinnedProvenanceDigestRedactionAndExactComparison() throws {
    let payload = fixturePayload()
    let fixture = DifferentialFixture(
      schemaVersion: 1,
      fixtureID: "openai-responses-text-v1",
      areaIDs: ["wire-openai-responses", "provider-openai"],
      providerID: "openai",
      protocolID: "openai-responses",
      provenance: DifferentialFixtureProvenance(
        repository: "https://github.com/earendil-works/pi.git",
        revision: fixtureRevision,
        sourcePaths: ["packages/ai/src/api/openai-responses.ts"],
        testPaths: ["packages/ai/test/stream.test.ts"],
        oracleVersion: "pi-ai@0.84.4",
        sanitization: ["authorization -> <redacted>"]
      ),
      payload: payload,
      payloadSHA256: try DifferentialFixtureValidator.payloadDigest(payload)
    )
    try DifferentialFixtureValidator.validate(
      fixture,
      expectedRevision: fixtureRevision
    )
    var request = URLRequest(url: URL(string: fixture.payload.expectedRequest.url)!)
    request.httpMethod = "POST"
    request.setValue("<redacted>", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(fixture.payload.expectedRequest.body)
    try DifferentialFixtureValidator.compare(
      request: request,
      events: fixture.payload.expectedEvents,
      with: fixture
    )
  }

  @Test
  func rejectsStaleTamperedSecretAndContradictoryFixtures() throws {
    let payload = fixturePayload()
    let validDigest = try DifferentialFixtureValidator.payloadDigest(payload)
    let base = DifferentialFixture(
      schemaVersion: 1,
      fixtureID: "fixture",
      areaIDs: ["wire-openai-responses"],
      providerID: "openai",
      protocolID: "openai-responses",
      provenance: DifferentialFixtureProvenance(
        repository: "repo",
        revision: fixtureRevision,
        sourcePaths: ["source"],
        testPaths: ["test"],
        oracleVersion: "oracle",
        sanitization: []
      ),
      payload: payload,
      payloadSHA256: validDigest
    )
    #expect(throws: ProviderRuntimeFailure.self) {
      try DifferentialFixtureValidator.validate(base, expectedRevision: "other")
    }
    let secretPayload = DifferentialFixturePayload(
      request: payload.request,
      expectedRequest: DifferentialExpectedRequest(
        method: "POST",
        url: "https://fixture.invalid",
        headers: [
          "Authorization": "Bearer " + "sk-"
            + String(repeating: "x", count: 20)
        ],
        body: .object([:])
      ),
      responseChunksBase64: [],
      expectedEvents: [],
      expectedFailure: nil
    )
    let tampered = DifferentialFixture(
      schemaVersion: base.schemaVersion,
      fixtureID: base.fixtureID,
      areaIDs: base.areaIDs,
      providerID: base.providerID,
      protocolID: base.protocolID,
      provenance: base.provenance,
      payload: secretPayload,
      payloadSHA256: try DifferentialFixtureValidator.payloadDigest(
        secretPayload
      )
    )
    #expect(throws: ProviderRuntimeFailure.self) {
      try DifferentialFixtureValidator.validate(
        tampered,
        expectedRevision: fixtureRevision
      )
    }
  }
}

private let fixtureRevision = "853a80d26c90a14c1886f0ebb8ffaae133ca2185"

private func fixturePayload() -> DifferentialFixturePayload {
  let request = ProviderRequest(
    id: "request",
    providerID: "openai",
    modelID: "gpt-fixture",
    messages: [.user([.text("hello")])],
    tools: [],
    options: ProviderGenerationOptions(
      maximumOutputTokens: 32,
      temperature: nil,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: [:]
    )
  )
  return DifferentialFixturePayload(
    request: request,
    expectedRequest: DifferentialExpectedRequest(
      method: "POST",
      url: "https://api.openai.com/v1/responses",
      headers: ["Authorization": "<redacted>"],
      body: .object(["model": .string("gpt-fixture")])
    ),
    responseChunksBase64: [Data("data: fixture\n\n".utf8).base64EncodedString()],
    expectedEvents: [.textDelta("hello")],
    expectedFailure: nil
  )
}
