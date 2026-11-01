import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite struct PrimaryAuthorizationTests {
  @Test func primaryAuthorizationMatchesPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func cases(_ folder: String) throws -> [JSONValue] {
      try JSONValue(
        jsonData: Data(
          contentsOf: root.appending(
            path: "Fixtures/Differential/\(folder)/primary-authorization.json"))
      ).objectValue!.array("cases")!
    }
    let inputs = try cases("Cases")
    let oracle = try cases("Oracle")
    #expect(inputs.count == oracle.count)
    for (input, expected) in zip(inputs, oracle) {
      let result = try await PrimaryAuthorizationFixtures.replay(input.objectValue!)
      #expect(result == expected, Comment(rawValue: input.objectValue!.string("id")!))
    }
  }
}
