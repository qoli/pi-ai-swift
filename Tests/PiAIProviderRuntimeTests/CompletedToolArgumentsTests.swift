import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct CompletedToolArgumentsTests {
  @Test
  func finalArgumentsMatchSourceAcceptanceAndPreserveFailureInput() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode(
      Input.self,
      from: Data(
        contentsOf:
          root.appending(path: "Fixtures/Differential/Cases/tool-arguments.json")))
    let oracle = try JSONDecoder().decode(
      Oracle.self,
      from: Data(
        contentsOf:
          root.appending(path: "Fixtures/Differential/Oracle/tool-arguments.json")))
    #expect(fixture.upstreamRevision == oracle.upstreamRevision)
    for (input, expected) in zip(fixture.cases, oracle.cases) {
      #expect(input.id == expected.id)
      let call = ProviderToolCall.parsing(id: input.id, name: "fixture", input: input.input)
      #expect(call.arguments == expected.arguments, Comment(rawValue: input.id))
      #expect((call.argumentsError != nil) == expected.hasError, Comment(rawValue: input.id))
      #expect(
        (call.argumentsError?.contains("Received arguments:\n\(input.input)") ?? false)
          == expected.preservesReceivedInput)
      #expect(
        try JSONDecoder().decode(ProviderToolCall.self, from: JSONEncoder().encode(call)) == call)
    }
  }
  private struct Input: Decodable {
    let upstreamRevision: String
    let cases: [Case]
    struct Case: Decodable {
      let id: String
      let input: String
    }
  }
  private struct Oracle: Decodable {
    let upstreamRevision: String
    let cases: [Case]
    struct Case: Decodable {
      let id: String
      let arguments: JSONValue
      let hasError: Bool
      let preservesReceivedInput: Bool
    }
  }
}
