import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite struct OpenRouterPersonalizationTests {
  @Test func personalizationMatchesPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func cases(_ folder: String) throws -> [JSONValue] {
      try JSONValue(
        jsonData: Data(
          contentsOf: root.appending(
            path: "Fixtures/Differential/\(folder)/openrouter-personalization.json"))
      )
      .objectValue!.array("cases")!
    }
    let inputs = try cases("Cases")
    let expected = try cases("Oracle")
    #expect(inputs.count == expected.count)
    for (input, oracle) in zip(inputs, expected) {
      let spec = input.objectValue!
      #expect(
        try await OpenRouterPersonalizationFixtures.replay(spec) == oracle,
        Comment(rawValue: spec.string("id")!))
      if let catalog = oracle.objectValue?.array("catalog") {
        #expect(
          try await OpenRouterPersonalizationFixtures.publicCatalog(spec) == catalog,
          Comment(rawValue: spec.string("id")!))
      }
    }
  }
}
