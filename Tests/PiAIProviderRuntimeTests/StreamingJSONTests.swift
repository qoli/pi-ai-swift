import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct StreamingJSONTests {
  @Test
  func incrementalChangesAndSnapshotsMatchPinnedSource() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let input = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Cases/streaming-json.json")),
      providerID: "fixture", operation: "streaming-json.input")
    let oracle = try decodeJSONObject(
      Data(contentsOf: root.appending(path: "Fixtures/Differential/Oracle/streaming-json.json")),
      providerID: "fixture", operation: "streaming-json.oracle")
    let cases = try #require(input.array("cases"))
    let expected = try #require(oracle.array("cases"))
    #expect(cases.count == expected.count)
    for (value, expected) in zip(cases, expected) {
      let spec = try #require(value.objectValue)
      let observations = try #require(expected.objectValue?.array("observations"))
      let parser = ProviderStreamingJSONParser()
      var kept: [(ProviderJSONNode, JSONValue)] = []
      for (chunk, observation) in zip(try #require(spec.array("chunks")), observations) {
        let changes = parser.append(try #require(chunk.stringValue))
        let projected: [JSONValue] = changes.map { change in
          let path = change.path.map { component -> JSONValue in
            switch component {
            case .key(let key): .string(String(decoding: key, as: UTF16.self))
            case .index(let index): .integer(Int64(index))
            }
          }
          return .object([
            "kind": .string(change.isAppend ? "append" : "set"), "path": .array(path),
            change.isAppend ? "text" : "value": change.value.jsonValue,
          ])
        }
        let expected = try #require(observation.objectValue)
        #expect(
          try canonical(.array(projected)) == expected["changes"],
          Comment(rawValue: spec.string("id")!))
        let snapshot = parser.snapshot()
        #expect(
          try snapshot.map { try canonical($0.jsonValue) } == expected["snapshot"],
          Comment(rawValue: spec.string("id")!))
        if let snapshot { kept.append((snapshot, snapshot.jsonValue)) }
      }
      for (snapshot, frozen) in kept { #expect(snapshot.jsonValue == frozen) }
    }
  }

  private func canonical(_ value: JSONValue) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }
}
