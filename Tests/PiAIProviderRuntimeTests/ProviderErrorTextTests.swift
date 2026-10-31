import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ProviderErrorTextTests {
  @Test
  func sdkShapePrioritiesMatchPinnedSource() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let input = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Cases/provider-errors.json")),
      providerID: "fixture", operation: "error.input")
    let oracle = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Oracle/provider-errors.json")),
      providerID: "fixture", operation: "error.oracle")
    let cases = try #require(input.array("cases"))
    let expected = try #require(oracle.array("cases"))
    #expect(cases.count == expected.count)
    for (value, expected) in zip(cases, expected) {
      let raw = try #require(value.objectValue)
      let expected = try #require(expected.objectValue)
      func candidate(_ value: JSONValue?) throws -> ProviderErrorText.BodyCandidate {
        if case .string(let text) = value { return .text(text) }
        guard let value, let object = value.objectValue else { return .other }
        return .plainObject(
          serialized: try ProviderOrderedJSON.scalar(value).encodedString(),
          isEmpty: object.isEmpty, isReadable: false)
      }
      let normalized = ProviderErrorText.normalize(
        isError: raw.bool("isError") == true, message: raw.string("message") ?? "",
        serializedValue: try raw["value"].map {
          try ProviderOrderedJSON.scalar($0).encodedString()
        },
        stringValue: "",
        statusCandidates: [
          raw["statusCode"], raw["status"],
          raw.object("$metadata")?["httpStatusCode"], raw.object("$response")?["statusCode"],
        ].map { $0 ?? .null },
        body: try candidate(raw["body"]), error: try candidate(raw["error"]),
        responseBody: try candidate(raw.object("$response")?["body"]))
      let actual = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(normalized))
      #expect(actual == expected["normalized"], Comment(rawValue: raw.string("id")!))
      #expect(
        ProviderErrorText.format(normalized, prefix: "Provider") == expected.string("formatted"))
    }
  }
}
