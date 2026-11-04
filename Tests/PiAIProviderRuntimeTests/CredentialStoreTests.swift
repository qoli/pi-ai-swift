import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite struct CredentialStoreTests {
  @Test(.timeLimit(.minutes(1))) func keychainTransactionsMatchSourceMutationContract() async throws
  {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func cases(_ folder: String) throws -> [JSONValue] {
      try JSONValue(
        jsonData: Data(
          contentsOf: root.appending(path: "Fixtures/Differential/\(folder)/credential-store.json"))
      )
      .objectValue!.array("cases")!
    }
    for (input, expected) in zip(try cases("Cases"), try cases("Oracle")) {
      // Map insertion order is specific to the upstream in-memory implementation.
      if input.objectValue!.string("scenario") == "list-insertion-order" { continue }
      let store = try KeychainProviderCredentialStore(
        service: "pi-ai-swift.tests.transactions.\(UUID())")
      do {
        let actual = try await CredentialStoreFixtures.replay(input.objectValue!, store: store)
        #expect(actual == expected, Comment(rawValue: input.objectValue!.string("id")!))
      } catch {
        try await store.delete(providerID: "fixture")
        try await store.delete(providerID: "other")
        throw error
      }
      try await store.delete(providerID: "fixture")
      try await store.delete(providerID: "other")
    }
  }

  @Test(.timeLimit(.minutes(1))) func transactionsMatchPinnedSource() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func cases(_ folder: String) throws -> [JSONValue] {
      try JSONValue(
        jsonData: Data(
          contentsOf: root.appending(path: "Fixtures/Differential/\(folder)/credential-store.json"))
      )
      .objectValue!.array("cases")!
    }
    let inputs = try cases("Cases")
    let expected = try cases("Oracle")
    #expect(inputs.count == expected.count)
    for (input, oracle) in zip(inputs, expected) {
      let actual = try await CredentialStoreFixtures.replay(input.objectValue!)
      #expect(actual == oracle, Comment(rawValue: input.objectValue!.string("id")!))
    }
  }
}
