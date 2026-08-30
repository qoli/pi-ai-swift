import Foundation

struct ProviderModelStoreRecord: Sendable, Equatable, Codable {
  let model: ProviderModel
  let baseURL: String?
  let metadata: [String: JSONValue]
}

struct ProviderModelStoreEntry: Sendable, Equatable, Codable {
  let records: [ProviderModelStoreRecord]
  let lastModified: Date?
  let checkedAt: Date?
  let etag: String?
}

struct ProviderModelRefreshPayload: Sendable {
  let data: Data
  let lastModified: Date?
  let checkedAt: Date
  let etag: String?

  init(
    data: Data,
    lastModified: Date? = nil,
    checkedAt: Date,
    etag: String? = nil
  ) {
    self.data = data
    self.lastModified = lastModified
    self.checkedAt = checkedAt
    self.etag = etag
  }
}

actor ProviderModelStore {
  static let persistenceSchemaVersion = 1

  private let expectedRevision: String
  private let persistenceURL: URL?
  private let bundledEntries: [String: ProviderModelStoreEntry]
  private var persistedEntries: [String: ProviderModelStoreEntry]
  private var refreshGenerations: [String: UInt64] = [:]

  init(
    bundledData: Data,
    expectedRevision: String,
    persistenceURL: URL? = nil,
    now: Date = Date(),
    maximumPersistedAge: TimeInterval? = nil
  ) throws {
    guard Self.isFullRevision(expectedRevision) else {
      throw Self.failure(
        .upstreamDrift,
        operation: "catalog.store.configure",
        message: "expected catalog revision is malformed"
      )
    }
    self.expectedRevision = expectedRevision
    self.persistenceURL = persistenceURL
    bundledEntries = try Self.decodeBundled(
      bundledData,
      expectedRevision: expectedRevision
    )
    persistedEntries = try Self.loadPersisted(
      from: persistenceURL,
      expectedRevision: expectedRevision,
      now: now,
      maximumAge: maximumPersistedAge
    )
  }

  init(
    expectedRevision: String,
    persistenceURL: URL? = nil,
    now: Date = Date(),
    maximumPersistedAge: TimeInterval? = nil
  ) throws {
    guard
      let url = Bundle.module.url(
        forResource: "BuiltinCatalog",
        withExtension: "json"
      )
    else {
      throw Self.failure(
        .upstreamDrift,
        operation: "catalog.store.bundle",
        message: "bundled model snapshot is missing"
      )
    }
    try self.init(
      bundledData: Data(contentsOf: url),
      expectedRevision: expectedRevision,
      persistenceURL: persistenceURL,
      now: now,
      maximumPersistedAge: maximumPersistedAge
    )
  }

  func entry(providerID: String) -> ProviderModelStoreEntry? {
    persistedEntries[providerID] ?? bundledEntries[providerID]
  }

  func records(providerID: String) -> [ProviderModelStoreRecord] {
    entry(providerID: providerID)?.records ?? []
  }

  func providerIDs() -> [String] {
    Set(bundledEntries.keys).union(persistedEntries.keys).sorted()
  }

  @discardableResult
  func refreshRadius(
    providerID: String = "radius",
    load: @escaping @Sendable () async throws -> ProviderModelRefreshPayload
  ) async throws -> Bool {
    guard providerID == "radius" else {
      throw Self.failure(
        .invalidRequest,
        providerID: providerID,
        operation: "catalog.radius.refresh",
        message: "dynamic Radius refresh owns only the radius provider"
      )
    }
    let generation = (refreshGenerations[providerID] ?? 0) &+ 1
    refreshGenerations[providerID] = generation

    let payload = try await load()
    try Task.checkCancellation()
    guard refreshGenerations[providerID] == generation else { return false }

    let entry = try Self.decodeRadius(
      payload,
      providerID: providerID
    )
    var candidate = persistedEntries
    candidate[providerID] = entry
    try Task.checkCancellation()
    try persist(candidate)
    persistedEntries = candidate
    return true
  }

  private func persist(
    _ entries: [String: ProviderModelStoreEntry]
  ) throws {
    guard let persistenceURL else { return }
    let document = ProviderModelStorePersistenceDocument(
      schemaVersion: Self.persistenceSchemaVersion,
      upstreamRevision: expectedRevision,
      providers: entries
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(document)
    } catch {
      throw Self.failure(
        .invalidRequest,
        operation: "catalog.store.persist.encode",
        message: "provider model snapshot could not be encoded",
        cause: String(describing: error)
      )
    }

    let directory = persistenceURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      try data.write(to: persistenceURL, options: .atomic)
    } catch {
      throw Self.failure(
        .transportFailed,
        operation: "catalog.store.persist.write",
        message: "provider model snapshot could not be persisted atomically",
        cause: String(describing: error)
      )
    }
  }

  private static func decodeBundled(
    _ data: Data,
    expectedRevision: String
  ) throws -> [String: ProviderModelStoreEntry] {
    let document: BundledCatalogDocument
    do {
      document = try JSONDecoder().decode(BundledCatalogDocument.self, from: data)
    } catch {
      throw failure(
        .upstreamDrift,
        operation: "catalog.store.bundle.decode",
        message: "bundled model snapshot is corrupt",
        cause: String(describing: error)
      )
    }
    guard document.schemaVersion == 1 else {
      throw failure(
        .upstreamDrift,
        operation: "catalog.store.bundle.schema",
        message: "unsupported bundled model snapshot schema: \(document.schemaVersion)"
      )
    }
    guard document.upstreamRevision == expectedRevision else {
      throw failure(
        .upstreamDrift,
        operation: "catalog.store.bundle.revision",
        message: "bundled model snapshot revision is stale"
      )
    }
    guard isFullRevision(document.upstreamRevision) else {
      throw failure(
        .upstreamDrift,
        operation: "catalog.store.bundle.revision",
        message: "bundled model snapshot revision is malformed"
      )
    }

    var result: [String: ProviderModelStoreEntry] = [:]
    for provider in document.providers {
      guard !provider.id.isEmpty, result[provider.id] == nil else {
        throw failure(
          .upstreamDrift,
          providerID: provider.id,
          operation: "catalog.store.bundle.provider",
          message: "bundled model snapshot contains an invalid or duplicate provider"
        )
      }
      let records = try provider.models.map {
        try decodeBundledRecord(
          $0,
          providerID: provider.id,
          providerBaseURL: provider.baseURL
        )
      }
      try validateUnique(records, providerID: provider.id)
      result[provider.id] = ProviderModelStoreEntry(
        records: records.sorted(by: recordOrder),
        lastModified: nil,
        checkedAt: nil,
        etag: nil
      )
    }
    return result
  }

  private static func decodeBundledRecord(
    _ value: JSONValue,
    providerID: String,
    providerBaseURL: String?
  ) throws -> ProviderModelStoreRecord {
    guard case .object(let object) = value,
      let modelID = object.string("id"),
      !modelID.isEmpty,
      let owner = object.string("provider"),
      owner == providerID,
      let protocolID = object.string("api"),
      !protocolID.isEmpty
    else {
      throw failure(
        .upstreamDrift,
        providerID: providerID,
        operation: "catalog.store.bundle.model",
        message: "bundled model snapshot contains an invalid model"
      )
    }
    let inputs = object.modelStoreStringArray("input")
    guard !inputs.isEmpty, Set(inputs).isSubset(of: ["text", "image"]) else {
      throw failure(
        .upstreamDrift,
        providerID: providerID,
        operation: "catalog.store.bundle.model",
        message: "bundled model has invalid input capabilities: \(modelID)"
      )
    }
    let rawBaseURL = object.string("baseUrl") ?? providerBaseURL
    let baseURL = rawBaseURL.flatMap { $0.isEmpty ? nil : $0 }
    try validateBaseURL(baseURL, providerID: providerID)
    let contextWindow = object.int("contextWindow")
    let maximumOutputTokens = object.int("maxTokens")
    try validatePositiveLimits(
      contextWindow: contextWindow,
      maximumOutputTokens: maximumOutputTokens,
      providerID: providerID,
      modelID: modelID
    )
    let imageGeneration = protocolID == "openrouter-images"
    return ProviderModelStoreRecord(
      model: ProviderModel(
        id: modelID,
        providerID: providerID,
        name: object.string("name") ?? modelID,
        protocolID: protocolID,
        capabilities: ProviderCapabilities(
          textInput: inputs.contains("text"),
          imageInput: inputs.contains("image"),
          toolCalling: !imageGeneration,
          reasoning: object.bool("reasoning") ?? false,
          structuredOutput: supportsStructuredOutput(protocolID),
          imageGeneration: imageGeneration
        ),
        contextWindow: contextWindow,
        maximumOutputTokens: maximumOutputTokens
      ),
      baseURL: baseURL,
      metadata: object
    )
  }

  private static func decodeRadius(
    _ payload: ProviderModelRefreshPayload,
    providerID: String
  ) throws -> ProviderModelStoreEntry {
    try Task.checkCancellation()
    let config: RadiusGatewayConfigDocument
    do {
      config = try JSONDecoder().decode(
        RadiusGatewayConfigDocument.self,
        from: payload.data
      )
    } catch {
      throw failure(
        .invalidResponse,
        providerID: providerID,
        operation: "catalog.radius.decode",
        message: "Radius gateway config is corrupt",
        cause: String(describing: error)
      )
    }
    try validateBaseURL(
      config.baseUrl,
      providerID: providerID,
      allowsHTTP: true
    )
    guard !config.models.isEmpty else {
      throw failure(
        .invalidResponse,
        providerID: providerID,
        operation: "catalog.radius.models",
        message: "Radius gateway config contains no models"
      )
    }
    let records = try config.models.map { raw in
      guard !raw.id.isEmpty, !raw.name.isEmpty,
        !raw.input.isEmpty,
        Set(raw.input).isSubset(of: ["text", "image"])
      else {
        throw failure(
          .invalidResponse,
          providerID: providerID,
          operation: "catalog.radius.model",
          message: "Radius gateway config contains an invalid model"
        )
      }
      try validatePositiveLimits(
        contextWindow: raw.contextWindow,
        maximumOutputTokens: raw.maxTokens,
        providerID: providerID,
        modelID: raw.id
      )
      return ProviderModelStoreRecord(
        model: ProviderModel(
          id: raw.id,
          providerID: providerID,
          name: raw.name,
          protocolID: "pi-messages",
          capabilities: ProviderCapabilities(
            textInput: raw.input.contains("text"),
            imageInput: raw.input.contains("image"),
            toolCalling: true,
            reasoning: raw.reasoning,
            structuredOutput: false,
            imageGeneration: false
          ),
          contextWindow: raw.contextWindow,
          maximumOutputTokens: raw.maxTokens
        ),
        baseURL: config.baseUrl,
        metadata: raw.metadata
      )
    }
    try validateUnique(records, providerID: providerID)
    return ProviderModelStoreEntry(
      records: records.sorted(by: recordOrder),
      lastModified: payload.lastModified,
      checkedAt: payload.checkedAt,
      etag: payload.etag
    )
  }

  private static func loadPersisted(
    from url: URL?,
    expectedRevision: String,
    now: Date,
    maximumAge: TimeInterval?
  ) throws -> [String: ProviderModelStoreEntry] {
    guard let url, FileManager.default.fileExists(atPath: url.path) else {
      return [:]
    }
    let document: ProviderModelStorePersistenceDocument
    do {
      let data = try Data(contentsOf: url)
      document = try JSONDecoder().decode(
        ProviderModelStorePersistenceDocument.self,
        from: data
      )
    } catch {
      throw failure(
        .upstreamDrift,
        operation: "catalog.store.persist.decode",
        message: "persisted provider model snapshot is corrupt",
        cause: String(describing: error)
      )
    }
    guard document.schemaVersion == persistenceSchemaVersion else {
      throw failure(
        .upstreamDrift,
        operation: "catalog.store.persist.schema",
        message: "unsupported persisted provider model snapshot schema"
      )
    }
    guard document.upstreamRevision == expectedRevision else {
      throw failure(
        .upstreamDrift,
        operation: "catalog.store.persist.revision",
        message: "persisted provider model snapshot revision is stale"
      )
    }
    for (providerID, entry) in document.providers {
      try validateUnique(entry.records, providerID: providerID)
      guard entry.records.allSatisfy({ $0.model.providerID == providerID }) else {
        throw failure(
          .upstreamDrift,
          providerID: providerID,
          operation: "catalog.store.persist.provider",
          message: "persisted provider model snapshot has mismatched ownership"
        )
      }
      for record in entry.records {
        try validatePersistedRecord(record, providerID: providerID)
      }
      if let maximumAge {
        guard let checkedAt = entry.checkedAt,
          checkedAt <= now,
          now.timeIntervalSince(checkedAt) <= maximumAge
        else {
          throw failure(
            .upstreamDrift,
            providerID: providerID,
            operation: "catalog.store.persist.freshness",
            message: "persisted provider model snapshot is stale"
          )
        }
      }
    }
    return document.providers
  }

  private static func validatePersistedRecord(
    _ record: ProviderModelStoreRecord,
    providerID: String
  ) throws {
    let model = record.model
    guard !model.id.isEmpty, !model.name.isEmpty, !model.protocolID.isEmpty,
      model.providerID == providerID,
      model.capabilities.textInput || model.capabilities.imageInput
        || model.capabilities.imageGeneration
    else {
      throw failure(
        .upstreamDrift,
        providerID: providerID,
        operation: "catalog.store.persist.model",
        message: "persisted provider model snapshot contains an invalid model"
      )
    }
    if providerID == "radius", record.baseURL == nil {
      throw failure(
        .upstreamDrift,
        providerID: providerID,
        operation: "catalog.store.persist.model",
        message: "persisted Radius model is missing its gateway URL"
      )
    }
    try validateBaseURL(record.baseURL, providerID: providerID)
    try validatePositiveLimits(
      contextWindow: model.contextWindow,
      maximumOutputTokens: model.maximumOutputTokens,
      providerID: providerID,
      modelID: model.id
    )
  }

  private static func validateUnique(
    _ records: [ProviderModelStoreRecord],
    providerID: String
  ) throws {
    var routes = Set<String>()
    for record in records {
      let route = "\(record.model.id)\u{0}\(record.model.protocolID)"
      guard routes.insert(route).inserted else {
        throw failure(
          .upstreamDrift,
          providerID: providerID,
          operation: "catalog.store.routes",
          message: "provider model snapshot contains a duplicate route"
        )
      }
    }
  }

  private static func validateBaseURL(
    _ value: String?,
    providerID: String,
    allowsHTTP: Bool = false
  ) throws {
    guard let value else { return }
    let validationValue = value.replacingOccurrences(
      of: #"\{[^}]+\}"#,
      with: "placeholder",
      options: .regularExpression
    )
    let allowedSchemes = allowsHTTP ? ["http", "https"] : ["https"]
    guard let url = URL(string: validationValue),
      let scheme = url.scheme?.lowercased(),
      allowedSchemes.contains(scheme)
    else {
      throw failure(
        .upstreamDrift,
        providerID: providerID,
        operation: "catalog.store.base-url",
        message: "provider model snapshot contains an invalid base URL"
      )
    }
  }

  private static func validatePositiveLimits(
    contextWindow: Int?,
    maximumOutputTokens: Int?,
    providerID: String,
    modelID: String
  ) throws {
    guard contextWindow.map({ $0 > 0 }) ?? true,
      maximumOutputTokens.map({ $0 > 0 }) ?? true
    else {
      throw failure(
        .upstreamDrift,
        providerID: providerID,
        operation: "catalog.store.model-limits",
        message: "provider model has invalid limits: \(modelID)"
      )
    }
  }

  private static func supportsStructuredOutput(_ protocolID: String) -> Bool {
    switch protocolID {
    case "openai-completions", "openai-responses", "azure-openai-responses",
      "google-generative-ai", "google-vertex":
      true
    default:
      false
    }
  }

  private static func recordOrder(
    _ lhs: ProviderModelStoreRecord,
    _ rhs: ProviderModelStoreRecord
  ) -> Bool {
    (lhs.model.id, lhs.model.protocolID) < (rhs.model.id, rhs.model.protocolID)
  }

  private static func isFullRevision(_ value: String) -> Bool {
    value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
  }

  private static func failure(
    _ code: ProviderRuntimeFailure.Code,
    providerID: String? = nil,
    operation: String,
    message: String,
    cause: String? = nil
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: code,
      message: message,
      providerID: providerID,
      operation: operation,
      causeDescription: cause
    )
  }
}

private struct ProviderModelStorePersistenceDocument: Sendable, Codable {
  let schemaVersion: Int
  let upstreamRevision: String
  let providers: [String: ProviderModelStoreEntry]
}

private struct BundledCatalogDocument: Decodable {
  let schemaVersion: Int
  let upstreamRevision: String
  let providers: [BundledProviderDocument]
}

private struct BundledProviderDocument: Decodable {
  let id: String
  let baseURL: String?
  let models: [JSONValue]
}

private struct RadiusGatewayConfigDocument: Decodable {
  let baseUrl: String
  let models: [RadiusGatewayModelDocument]
}

private struct RadiusGatewayModelDocument: Decodable {
  let id: String
  let name: String
  let reasoning: Bool
  let input: [String]
  let contextWindow: Int
  let maxTokens: Int
  let metadata: [String: JSONValue]

  init(from decoder: any Decoder) throws {
    let value = try JSONValue(from: decoder)
    guard case .object(let object) = value,
      let id = object.string("id"),
      let name = object.string("name"),
      let reasoning = object.bool("reasoning"),
      let contextWindow = object.int("contextWindow"),
      let maxTokens = object.int("maxTokens"),
      object.object("cost") != nil
    else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "invalid Radius model"
        )
      )
    }
    self.id = id
    self.name = name
    self.reasoning = reasoning
    input = object.modelStoreStringArray("input")
    self.contextWindow = contextWindow
    self.maxTokens = maxTokens
    metadata = object
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func modelStoreStringArray(_ key: String) -> [String] {
    guard case .array(let values) = self[key] else { return [] }
    return values.compactMap(\.stringValue)
  }
}
