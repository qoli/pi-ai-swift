import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite struct OAuthRefreshLifecycleTests {
  @Test func lifecycleMatchesPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func cases(_ directory: String) throws -> [JSONValue] {
      try JSONValue(
        jsonData: Data(
          contentsOf:
            root.appending(path: "Fixtures/Differential/\(directory)/oauth-refresh-lifecycle.json"))
      )
      .objectValue!.array("cases")!
    }
    let inputs = try cases("Cases")
    let expected = try cases("Oracle")
    #expect(inputs.count == expected.count)
    for (input, oracle) in zip(inputs, expected) {
      let actual = try await OAuthRefreshLifecycleFixtures.replay(input.objectValue!)
      #expect(actual == oracle, Comment(rawValue: input.objectValue!.string("id")!))
    }
  }
}
