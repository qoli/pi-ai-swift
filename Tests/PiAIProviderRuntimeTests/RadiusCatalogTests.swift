import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite struct RadiusCatalogTests {
  @Test func baselineAndDynamicReplacementMatchPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func cases(_ directory: String) throws -> [JSONValue] {
      try JSONValue(
        jsonData: Data(
          contentsOf:
            root.appending(path: "Fixtures/Differential/\(directory)/radius-catalog.json"))
      )
      .objectValue!.array("cases")!
    }
    let inputs = try cases("Cases")
    let expected = try cases("Oracle")
    #expect(inputs.count == expected.count)
    for (input, oracle) in zip(inputs, expected) {
      #expect(
        try await RadiusCatalogFixtures.replay(input.objectValue!) == oracle,
        Comment(rawValue: input.objectValue!.string("id")!))
    }
  }
}
