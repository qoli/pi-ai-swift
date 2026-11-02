import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite struct ContextOverflowTests {
  @Test func contextOverflowMatchesPinnedSource() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func cases(_ folder: String) throws -> [JSONValue] {
      try JSONValue(
        jsonData: Data(
          contentsOf: root.appending(
            path: "Fixtures/Differential/\(folder)/context-overflow.json"))
      )
      .objectValue!.array("cases")!
    }
    let inputs = try cases("Cases")
    let expected = try cases("Oracle")
    #expect(inputs.count == expected.count)
    for (input, oracle) in zip(inputs, expected) {
      #expect(
        ContextOverflowFixtures.replay(input.objectValue!) == oracle,
        Comment(rawValue: input.objectValue!.string("id")!))
    }
  }
}
