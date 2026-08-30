import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ProviderModelStoreTests {
  @Test
  func loadsValidatedBundledSnapshotAtPinnedRevision() async throws {
    let store = try ProviderModelStore(expectedRevision: pinnedRevision)

    let providerIDs = await store.providerIDs()
    #expect(providerIDs.contains("google"))
    #expect(providerIDs.contains("radius"))
    let google = await store.records(providerID: "google")
    #expect(google.contains { $0.model.id == "gemini-2.5-flash" })
    #expect(
      google.allSatisfy {
        $0.model.providerID == "google" && $0.baseURL?.hasPrefix("https://") == true
      }
    )
  }

  @Test
  func radiusRefreshPersistsAtomicallyAndReloadsValidators() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistenceURL = directory.appendingPathComponent("catalog/models.json")
    let checkedAt = Date(timeIntervalSince1970: 2_000_000_000)
    let store = try ProviderModelStore(
      bundledData: fixtureBundle(),
      expectedRevision: pinnedRevision,
      persistenceURL: persistenceURL
    )

    let published = try await store.refreshRadius {
      ProviderModelRefreshPayload(
        data: radiusConfig(modelID: "radius-new"),
        lastModified: Date(timeIntervalSince1970: 1_999_999_000),
        checkedAt: checkedAt,
        etag: #""radius-etag""#
      )
    }

    #expect(published)
    #expect(FileManager.default.fileExists(atPath: persistenceURL.path))
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: persistenceURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
      ).map(\.lastPathComponent) == ["models.json"]
    )
    let entry = try #require(await store.entry(providerID: "radius"))
    #expect(entry.records.map(\.model.id) == ["radius-new"])
    #expect(entry.etag == #""radius-etag""#)
    #expect(entry.checkedAt == checkedAt)
    #expect(entry.records[0].model.protocolID == "pi-messages")
    #expect(entry.records[0].model.capabilities.imageInput)
    #expect(entry.records[0].baseURL == "https://radius.example")

    let reloaded = try ProviderModelStore(
      bundledData: fixtureBundle(),
      expectedRevision: pinnedRevision,
      persistenceURL: persistenceURL,
      now: checkedAt.addingTimeInterval(60),
      maximumPersistedAge: 120
    )
    #expect(await reloaded.records(providerID: "radius").map(\.model.id) == ["radius-new"])
  }

  @Test
  func corruptSchemaRevisionAndStalePersistenceFailExplicitly() async throws {
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try ProviderModelStore(
        bundledData: Data("not-json".utf8),
        expectedRevision: pinnedRevision
      )
    }
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try ProviderModelStore(
        bundledData: fixtureBundle(schemaVersion: 2),
        expectedRevision: pinnedRevision
      )
    }
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try ProviderModelStore(
        bundledData: fixtureBundle(revision: String(repeating: "b", count: 40)),
        expectedRevision: pinnedRevision
      )
    }

    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistenceURL = directory.appendingPathComponent("models.json")
    try Data("corrupt".utf8).write(to: persistenceURL)
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try ProviderModelStore(
        bundledData: fixtureBundle(),
        expectedRevision: pinnedRevision,
        persistenceURL: persistenceURL
      )
    }

    try FileManager.default.removeItem(at: persistenceURL)
    let initial = try ProviderModelStore(
      bundledData: fixtureBundle(),
      expectedRevision: pinnedRevision,
      persistenceURL: persistenceURL
    )
    let oldCheck = Date(timeIntervalSince1970: 1_000)
    _ = try await initial.refreshRadius {
      ProviderModelRefreshPayload(
        data: radiusConfig(modelID: "stale"),
        checkedAt: oldCheck
      )
    }
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try ProviderModelStore(
        bundledData: fixtureBundle(),
        expectedRevision: pinnedRevision,
        persistenceURL: persistenceURL,
        now: oldCheck.addingTimeInterval(61),
        maximumPersistedAge: 60
      )
    }

    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: persistenceURL))
        as? [String: Any]
    )
    var staleRevision = object
    staleRevision["upstreamRevision"] = String(repeating: "c", count: 40)
    try JSONSerialization.data(withJSONObject: staleRevision).write(to: persistenceURL)
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try ProviderModelStore(
        bundledData: fixtureBundle(),
        expectedRevision: pinnedRevision,
        persistenceURL: persistenceURL
      )
    }
  }

  @Test
  func newerRadiusRefreshOwnsPublicationWhileReadersSeeImmutableSnapshot() async throws {
    let store = try ProviderModelStore(
      bundledData: fixtureBundle(),
      expectedRevision: pinnedRevision
    )
    _ = try await store.refreshRadius {
      ProviderModelRefreshPayload(
        data: radiusConfig(modelID: "old"),
        checkedAt: Date(timeIntervalSince1970: 100)
      )
    }

    let gate = RadiusRefreshGate(
      payload: ProviderModelRefreshPayload(
        data: radiusConfig(modelID: "superseded"),
        checkedAt: Date(timeIntervalSince1970: 101)
      )
    )
    let older = Task {
      try await store.refreshRadius { try await gate.load() }
    }
    while await !gate.didStart() { await Task.yield() }

    let readerResults = await withTaskGroup(
      of: [String].self,
      returning: [[String]].self
    ) { group in
      for _ in 0..<32 {
        group.addTask {
          await store.records(providerID: "radius").map(\.model.id)
        }
      }
      var results: [[String]] = []
      for await result in group { results.append(result) }
      return results
    }
    #expect(readerResults.allSatisfy { $0 == ["old"] })

    let newerPublished = try await store.refreshRadius {
      ProviderModelRefreshPayload(
        data: radiusConfig(modelID: "new-owner"),
        checkedAt: Date(timeIntervalSince1970: 102)
      )
    }
    #expect(newerPublished)
    await gate.release()
    #expect(try await older.value == false)
    #expect(await store.records(providerID: "radius").map(\.model.id) == ["new-owner"])
  }

  @Test
  func cancellationDoesNotPublishRadiusSnapshot() async throws {
    let store = try ProviderModelStore(
      bundledData: fixtureBundle(),
      expectedRevision: pinnedRevision
    )
    _ = try await store.refreshRadius {
      ProviderModelRefreshPayload(
        data: radiusConfig(modelID: "retained"),
        checkedAt: Date(timeIntervalSince1970: 100)
      )
    }
    let marker = RefreshStartMarker()
    let refresh = Task {
      try await store.refreshRadius {
        await marker.markStarted()
        try await Task.sleep(for: .seconds(30))
        return ProviderModelRefreshPayload(
          data: radiusConfig(modelID: "cancelled"),
          checkedAt: Date(timeIntervalSince1970: 101)
        )
      }
    }
    while await !marker.didStart() { await Task.yield() }
    refresh.cancel()
    do {
      _ = try await refresh.value
      Issue.record("cancelled Radius refresh completed successfully")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("unexpected Radius cancellation error: \(error)")
    }
    #expect(await store.records(providerID: "radius").map(\.model.id) == ["retained"])
  }
}

private actor RadiusRefreshGate {
  private let payload: ProviderModelRefreshPayload
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?

  init(payload: ProviderModelRefreshPayload) {
    self.payload = payload
  }

  func load() async throws -> ProviderModelRefreshPayload {
    started = true
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
    try Task.checkCancellation()
    return payload
  }

  func didStart() -> Bool { started }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor RefreshStartMarker {
  private var started = false
  func markStarted() { started = true }
  func didStart() -> Bool { started }
}

private let pinnedRevision = "853a80d26c90a14c1886f0ebb8ffaae133ca2185"

private func fixtureBundle(
  schemaVersion: Int = 1,
  revision: String = pinnedRevision
) -> Data {
  Data(
    """
    {
      "schemaVersion": \(schemaVersion),
      "upstreamRevision": "\(revision)",
      "providers": [
        {
          "id": "fixture",
          "baseURL": "https://fixture.example/v1",
          "models": [
            {
              "id": "fixture-model",
              "name": "Fixture",
              "api": "openai-completions",
              "provider": "fixture",
              "reasoning": false,
              "input": ["text"],
              "contextWindow": 1000,
              "maxTokens": 100
            }
          ]
        },
        {
          "id": "radius",
          "baseURL": null,
          "models": []
        }
      ]
    }
    """.utf8
  )
}

private func radiusConfig(modelID: String) -> Data {
  Data(
    """
    {
      "baseUrl": "https://radius.example",
      "models": [
        {
          "id": "\(modelID)",
          "name": "Radius \(modelID)",
          "reasoning": true,
          "thinkingLevelMap": {"off": null, "high": "high"},
          "input": ["text", "image"],
          "cost": {"input": 1, "output": 2, "cacheRead": 0.1, "cacheWrite": 0},
          "contextWindow": 200000,
          "maxTokens": 32000
        }
      ]
    }
    """.utf8
  )
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
