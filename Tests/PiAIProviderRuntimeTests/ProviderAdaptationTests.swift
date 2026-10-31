import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite struct ProviderAdaptationTests {
  @Test func classifierRoutesCoverEveryNewProtocol() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONValue(
      jsonData: Data(
        contentsOf: root.appending(path: "Fixtures/Differential/Cases/provider-adaptation.json"))
    ).objectValue!
    let classifiers = Set(
      fixture.array("cases")!.compactMap { $0.objectValue?.object("model")?.string("api") })
    #expect(classifiers == ProviderClassifierAdapter.protocolIDs)
    let legacy = try JSONValue(
      jsonData: Data(
        contentsOf: root.appending(path: "Fixtures/Differential/Cases/request-rich.json"))
    ).objectValue!
    let existing = Set(
      legacy.array("protocols")!.compactMap { $0.objectValue?.string("protocolID") })
    #expect(existing.union(classifiers) == StandardWireProtocols.supportedProtocolIDs)
  }

  @Test func classifierAndChatRoutesShareAnIDWithoutChangingDispatch() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONValue(
      jsonData: Data(
        contentsOf: root.appending(path: "Fixtures/Differential/Cases/provider-adaptation.json"))
    ).objectValue!.array("cases")!.first!.objectValue!
    let expected = try JSONValue(
      jsonData: Data(
        contentsOf: root.appending(path: "Fixtures/Differential/Oracle/provider-adaptation.json"))
    ).objectValue!.array("cases")!.first!.objectValue!
    let actual = try await ProviderAdaptationFixtures.replay(fixture, addChatRoute: true)
    #expect(
      try ProviderAdaptationFixtures.canonical(actual)
        == ProviderAdaptationFixtures.canonical(expected))
  }

  @Test func nativeRuntimeMatchesPinnedAdaptationOracle() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    func load(_ kind: String) throws -> [JSONValue] {
      try JSONValue(
        jsonData: Data(
          contentsOf: root.appending(path: "Fixtures/Differential/\(kind)/provider-adaptation.json")
        )
      ).objectValue!.array("cases")!
    }
    let cases = try load("Cases")
    let expected = try load("Oracle")
    #expect(cases.count == expected.count)
    for (spec, oracle) in zip(cases, expected) {
      let actual = try await ProviderAdaptationFixtures.replay(spec.objectValue!)
      #expect(
        try ProviderAdaptationFixtures.canonical(actual)
          == ProviderAdaptationFixtures.canonical(oracle.objectValue!),
        Comment(rawValue: spec.objectValue!.string("id")!))
    }
  }
}
