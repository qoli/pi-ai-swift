import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ProviderInstallationContextTests {
  @Test
  func persistentContextSurvivesRecreationPreservesExistingIdentityAndSeparatesInstallations()
    async throws
  {
    let ids = try await InstallationContextFixtures.observePersistentLogin()
    #expect(ids.count == 4)
    #expect(ids[0] == ids[1])
    #expect(ids[2] == "urn:uuid:" + InstallationContextFixtures.existingID)
    #expect(ids[0] != ids[2])
    #expect(ids[0] != ids[3])
    #expect(ids.allSatisfy { $0.hasPrefix("urn:uuid:") })
    #expect(ids.allSatisfy { UUID(uuidString: String($0.dropFirst("urn:uuid:".count))) != nil })
  }

  @Test
  func unreadableStoredIdentityFailsWithoutReplacingIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stored = root.appendingPathComponent("ProviderInstallationID")
    try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) {
      try ProviderInstallationContext.persistent(at: root)
    }
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: stored.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }
}
