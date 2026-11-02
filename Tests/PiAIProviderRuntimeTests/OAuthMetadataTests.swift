import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite struct OAuthMetadataTests {
  @Test func catalogMatchesPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let input = try JSONValue(
      jsonData: Data(
        contentsOf:
          root.appending(path: "Fixtures/Differential/Cases/oauth-metadata.json"))
    ).objectValue!
    let expected = try JSONValue(
      jsonData: Data(
        contentsOf:
          root.appending(path: "Fixtures/Differential/Oracle/oauth-metadata.json"))
    ).objectValue!.array("cases")!
    #expect(try await OAuthMetadataFixtures.project(input.array("providers")!) == expected)
  }

  @Test func existingDescriptorsDecodeWithoutMetadata() throws {
    let descriptor = try JSONDecoder().decode(
      AuthorizationMethodDescriptor.self,
      from: Data(#"{"id":"oauth","kind":"oauth","label":"Sign in"}"#.utf8))
    #expect(descriptor.oauthMetadata == nil)
  }
}
