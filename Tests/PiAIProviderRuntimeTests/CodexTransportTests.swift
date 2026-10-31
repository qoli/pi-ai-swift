import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct CodexTransportTests {
  @Test
  func toolCallbackFailureNeverSelectsAnotherTransport() async throws {
    let output = try await CodexTransportFixtures.replay(
      ["id": .string("reject-tool-callback")],
      rejectToolCallback: true)
    let result = try #require(output.objectValue)
    #expect(result.string("stopReason") == "error")
    #expect(result.string("errorMessage") == "fixture callback failure")
    let requests = try #require(result.array("requests"))
    #expect(requests.count == 1)
    #expect(requests.first?.objectValue?.string("transport") == "websocket")
  }

  @Test
  func transportEdgesMatchPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func load(_ directory: String) throws -> [String: JSONValue] {
      try decodeJSONObject(
        Data(
          contentsOf: root.appending(
            path: "Fixtures/Differential/\(directory)/codex-transport.json")),
        providerID: "fixture", operation: "codex.fixture")
    }
    let input = try load("Cases")
    let oracle = try load("Oracle")
    let cases = try #require(input.array("cases"))
    let expected = try #require(oracle.array("cases"))
    #expect(cases.count == expected.count)
    for (value, expected) in zip(cases, expected) {
      let spec = try #require(value.objectValue)
      let actual = try await CodexTransportFixtures.replay(spec)
      #expect(actual == expected, Comment(rawValue: spec.string("id")!))
    }
  }
}
