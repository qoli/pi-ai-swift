import Foundation

@testable import PiAIProviderRuntime

actor CredentialStoreProbeService {
  private var stores: [String: InMemoryProviderCredentialStore] = [:]
  private var replies: [String: CheckedContinuation<JSONValue, any Error>] = [:]

  func store(_ id: String) -> InMemoryProviderCredentialStore {
    if let store = stores[id] { return store }
    let store = InMemoryProviderCredentialStore()
    stores[id] = store
    return store
  }

  func transform(_ current: ProviderCredential?) async throws -> ProviderCredential? {
    let requestID = UUID().uuidString
    let packet = try CredentialProbeCodec.packet(current)
    let response: JSONValue = try await withCheckedThrowingContinuation { continuation in
      replies[requestID] = continuation
      do {
        try ProbeChannel().write(
          "credentialTransform",
          [
            "requestID": JSONValue.string(requestID), "current": packet,
          ])
      } catch { replies.removeValue(forKey: requestID)?.resume(throwing: error) }
    }
    return try CredentialProbeCodec.credential(response)
  }

  func receive(_ frame: [String: JSONValue]) {
    guard let requestID = frame.string("requestID") else { return }
    let pending = replies.removeValue(forKey: requestID)
    if let error = frame.object("error") {
      pending?.resume(
        throwing: CredentialProbeHostError(
          id: error.string("id")!, message: error.string("message")!,
          resolutionFailure: error["nativeResolutionFailure"]))
    } else {
      pending?.resume(returning: frame["credential"] ?? .null)
    }
  }
}

enum CredentialStoreConformanceProbe {
  static func run(
    _ input: [String: JSONValue], service: CredentialStoreProbeService,
    incoming: AsyncStream<[String: JSONValue]>
  ) async throws {
    let store = await service.store(input.string("storeID")!)
    let work = CredentialProbeWork()
    try await ProviderCancellableOperation.$workObservation.withValue({ work.record($0) }) {
      let execution = Task<JSONValue, any Error> {
        if input.bool("aborted") == true { withUnsafeCurrentTask { $0?.cancel() } }
        switch input.string("action") {
        case "read":
          return try await CredentialProbeCodec.packet(
            store.read(providerID: input.string("provider")!))
        case "list":
          return .array(
            try await store.list().map {
              .object([
                "providerId": .string($0.providerID),
                "type": .string($0.kind == .apiKey ? "api_key" : "oauth"),
              ])
            })
        case "modify":
          let value = try await store.modify(providerID: input.string("provider")!) { current in
            try await service.transform(current)
          }
          return try CredentialProbeCodec.packet(value)
        case "delete":
          try await store.delete(providerID: input.string("provider")!)
          return .null
        default: throw CredentialProbeRepresentationError("credential store operation")
        }
      }
      let cancellation = Task {
        for await frame in incoming {
          if frame.string("kind") == "cancel" { execution.cancel() }
        }
      }
      defer { cancellation.cancel() }
      let payload: [String: JSONValue]
      switch await execution.result {
      case .success(let value): payload = ["value": value]
      case .failure(let error):
        var failure: [String: JSONValue] = ["message": .string(error.localizedDescription)]
        if error is CancellationError { failure["cancelled"] = .bool(true) }
        if let error = error as? CredentialProbeHostError {
          failure["id"] = .string(error.id)
          failure["message"] = .string(error.message)
          failure["nativeResolutionFailure"] = error.resolutionFailure
        }
        payload = ["error": .object(failure)]
      }
      try ProbeChannel().write("credentialResult", payload)
      await work.wait()
    }
  }
}

enum CredentialProbeCodec {
  static let raw = "conformance.credential-json"
  static let reference = "conformance.credential-reference"

  static func credential(_ packet: JSONValue) throws -> ProviderCredential? {
    guard packet != .null else { return nil }
    let envelope = packet.objectValue!
    let value = envelope.object("value")!
    let metadata = [
      raw: String(decoding: try JSONEncoder().encode(JSONValue.object(value)), as: UTF8.self),
      reference: envelope.string("referenceID")!,
    ]
    if value.string("type") == "api_key" {
      let environment = value.object("env")?.compactMapValues(\.stringValue)
      if let key = value.string("key") {
        return .apiKey(.init(key: key, metadata: metadata, environment: environment))
      }
      return .apiKey(.init(environment: environment, metadata: metadata))
    }
    guard value.string("type") == "oauth", let expires = value.int("expires") else {
      throw CredentialProbeRepresentationError("credential representation")
    }
    return .oauth(
      .init(
        accessToken: value.string("access")!, refreshToken: value.string("refresh")!,
        expiresAt: Date(timeIntervalSince1970: Double(expires) / 1_000), metadata: metadata))
  }

  static func packet(_ credential: ProviderCredential?) throws -> JSONValue {
    guard let credential else { return .null }
    let metadata: [String: String]
    switch credential {
    case .apiKey(let key): metadata = key.metadata
    case .oauth(let oauth): metadata = oauth.metadata
    }
    var value = try metadata[raw].map { try JSONValue(jsonData: Data($0.utf8)).objectValue! } ?? [:]
    switch credential {
    case .apiKey(let key):
      value["type"] = .string("api_key")
      value["key"] = key.configuredKey.map(JSONValue.string)
      value["env"] = key.environment.map { .object($0.mapValues(JSONValue.string)) }
    case .oauth(let oauth):
      value["type"] = .string("oauth")
      value["access"] = .string(oauth.accessToken)
      value["refresh"] = .string(oauth.refreshToken)
      if value.int("expires").map({ Date(timeIntervalSince1970: Double($0) / 1_000) })
        != oauth.expiresAt
      {
        value["expires"] = .integer(
          Int64((oauth.expiresAt.timeIntervalSince1970 * 1_000).rounded()))
      }
    }
    return .object([
      "referenceID": .string(metadata[reference] ?? UUID().uuidString),
      "value": .object(value),
    ])
  }
}

private struct CredentialProbeHostError: LocalizedError {
  let id: String
  let message: String
  let resolutionFailure: JSONValue?
  var errorDescription: String? { message }
}

private final class CredentialProbeWork: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func record(_ started: Bool) {
    let completed: [CheckedContinuation<Void, Never>] = lock.withLock {
      active += started ? 1 : -1
      guard active == 0 else { return [] }
      let completed = waiters
      waiters = []
      return completed
    }
    for waiter in completed { waiter.resume() }
  }
  func wait() async {
    await withCheckedContinuation { continuation in
      let finished = lock.withLock {
        if active == 0 { return true }
        waiters.append(continuation)
        return false
      }
      if finished { continuation.resume() }
    }
  }
}

private struct CredentialProbeRepresentationError: LocalizedError {
  let capability: String
  init(_ capability: String) { self.capability = capability }
  var errorDescription: String? { "Unrepresented credential capability: " + capability }
}
