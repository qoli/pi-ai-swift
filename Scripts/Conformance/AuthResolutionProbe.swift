import Foundation

@testable import PiAIProviderRuntime

actor AuthResolutionProbeService {
  private struct Reply {
    let callID: String
    let continuation: CheckedContinuation<JSONValue, any Error>
  }
  private struct Transform {
    let callID: String
    let operation: @Sendable (ProviderCredential?) async throws -> ProviderCredential?
  }
  private struct Context {
    let callID: String
    let value: ProviderAuthenticationContext
  }
  private var replies: [String: Reply] = [:]
  private var transforms: [String: Transform] = [:]
  private var contexts: [String: Context] = [:]
  private var drain: [String: [CheckedContinuation<Void, Never>]] = [:]

  func exchange(_ stage: String, _ value: [String: JSONValue] = [:]) async throws -> JSONValue {
    let requestID = UUID().uuidString
    let callID = WireProbeContext.id!
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        replies[requestID] = .init(callID: callID, continuation: continuation)
        do {
          try ProbeChannel().write(
            "authorizationCallback",
            [
              "requestID": JSONValue.string(requestID), "stage": .string(stage),
              "value": .object(value),
            ])
        } catch {
          replies.removeValue(forKey: requestID)?.continuation.resume(throwing: error)
          drained(callID)
        }
      }
    } onCancel: {
      Task { await self.cancel(requestID) }
    }
  }

  private func cancel(_ requestID: String) {
    guard let reply = replies.removeValue(forKey: requestID) else { return }
    WireProbeContext.$id.withValue(reply.callID) {
      try? ProbeChannel().write("authorizationCallbackCancel", ["requestID": requestID])
    }
    reply.continuation.resume(throwing: CancellationError())
    drained(reply.callID)
  }

  func primary(
    _ credential: APIKeyCredential?, context: ProviderAuthenticationContext
  ) async throws -> ProviderResolvedAuthorization<AuthResolutionProbeValue>? {
    let id = UUID().uuidString
    contexts[id] = .init(callID: WireProbeContext.id!, value: context)
    defer { contexts.removeValue(forKey: id) }
    let result = try await exchange(
      "primary",
      [
        "credential": CredentialProbeCodec.packet(credential.map(ProviderCredential.apiKey)),
        "contextID": .string(id),
      ])
    guard let value = result.objectValue else { return nil }
    return .init(
      authorization: .init(auth: value["auth"]!, hasSource: value["source"] != nil),
      source: value.string("source") ?? "",
      environment: value.object("env")?.compactMapValues(\.stringValue))
  }

  func modify(
    providerID: String,
    transform: @escaping @Sendable (ProviderCredential?) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    let id = UUID().uuidString
    transforms[id] = .init(callID: WireProbeContext.id!, operation: transform)
    defer { transforms.removeValue(forKey: id) }
    return try await CredentialProbeCodec.credential(
      exchange("store.modify", ["provider": .string(providerID), "transformID": .string(id)]))
  }

  func receive(_ frame: [String: JSONValue]) {
    let requestID = frame.string("requestID")!
    if frame.string("kind") == "authorizationReply" {
      guard let reply = replies.removeValue(forKey: requestID) else { return }
      if let error = frame.object("error") {
        reply.continuation.resume(throwing: AuthResolutionProbeCodec.error(error))
      } else {
        reply.continuation.resume(returning: frame["value"] ?? .null)
      }
      drained(reply.callID)
      return
    }
    if frame.string("kind") == "authorizationTransform",
      let transform = transforms[frame.string("transformID")!]
    {
      Task {
        await WireProbeContext.$id.withValue(transform.callID) {
          do {
            let value = try await transform.operation(
              CredentialProbeCodec.credential(frame["credential"] ?? .null))
            try ProbeChannel().write(
              "authorizationTransformResult",
              [
                "requestID": JSONValue.string(requestID),
                "value": CredentialProbeCodec.packet(value),
              ])
          } catch {
            try? ProbeChannel().write(
              "authorizationTransformResult",
              [
                "requestID": JSONValue.string(requestID),
                "error": .object(AuthResolutionProbeCodec.error(error)),
              ])
          }
        }
      }
    } else if frame.string("kind") == "authorizationContext",
      let context = contexts[frame.string("contextID")!]
    {
      Task {
        await WireProbeContext.$id.withValue(context.callID) {
          do {
            let value: JSONValue
            if frame.string("action") == "env" {
              value =
                try await context.value.environment(frame.string("argument")!).map(JSONValue.string)
                ?? .null
            } else {
              value = .bool(try await context.value.fileExists(frame.string("argument")!))
            }
            try ProbeChannel().write(
              "authorizationContextResult",
              ["requestID": JSONValue.string(requestID), "value": value])
          } catch {
            try? ProbeChannel().write(
              "authorizationContextResult",
              [
                "requestID": JSONValue.string(requestID),
                "error": .object(AuthResolutionProbeCodec.error(error)),
              ])
          }
        }
      }
    }
  }

  func waitForDrain(_ callID: String) async {
    if !replies.values.contains(where: { $0.callID == callID }) { return }
    await withCheckedContinuation { drain[callID, default: []].append($0) }
  }
  private func drained(_ callID: String) {
    guard !replies.values.contains(where: { $0.callID == callID }) else { return }
    for waiter in drain.removeValue(forKey: callID) ?? [] { waiter.resume() }
  }
}

struct AuthResolutionProbeValue: Sendable {
  let auth: JSONValue
  let hasSource: Bool
}

private struct AuthResolutionProbeStore: ProviderCredentialStore {
  let service: AuthResolutionProbeService
  func read(providerID: String) async throws -> ProviderCredential? {
    try await CredentialProbeCodec.credential(
      service.exchange("store.read", ["provider": .string(providerID)]))
  }
  func modify(
    providerID: String,
    _ transform: @escaping @Sendable (ProviderCredential?) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    try await service.modify(providerID: providerID, transform: transform)
  }
  func delete(providerID: String) async throws {
    _ = try await service.exchange("store.delete", ["provider": .string(providerID)])
  }
  func list() async throws -> [ProviderCredentialInfo] {
    let values = try await service.exchange("store.list").arrayValue!
    return values.map {
      .init(
        providerID: $0.objectValue!.string("providerId")!,
        kind: $0.objectValue!.string("type") == "oauth" ? .oauth : .apiKey)
    }
  }
}

enum AuthResolutionConformanceProbe {
  static func run(
    _ input: [String: JSONValue], server: WireConformanceServer,
    incoming: AsyncStream<[String: JSONValue]>
  ) async throws {
    let service = server.authorization
    let store = AuthResolutionProbeStore(service: service)
    let context = ProviderAuthenticationContext(
      environment: {
        try await service.exchange("context.env", ["argument": .string($0)]).stringValue
      },
      fileExists: {
        let value = try await service.exchange("context.fileExists", ["argument": .string($0)])
        guard case .bool(let result) = value else { throw AuthResolutionProbeRepresentationError() }
        return result
      })
    typealias Bindings = ProviderAuthorizationBindings<AuthResolutionProbeValue>
    let primary: Bindings.Primary?
    if input.bool("primary") == true {
      primary = { try await service.primary($0, context: $1) }
    } else {
      primary = nil
    }
    let oauth: Bindings.OAuth?
    if input.bool("oauth") == true {
      oauth = .init(
        refresh: { current in
          let value = try await service.exchange(
            "oauth.refresh", ["credential": CredentialProbeCodec.packet(.oauth(current))])
          guard case .oauth(let result) = try CredentialProbeCodec.credential(value) else {
            throw AuthResolutionProbeRepresentationError()
          }
          return result
        },
        derive: { current in
          .init(
            auth: try await service.exchange(
              "oauth.toAuth", ["credential": CredentialProbeCodec.packet(.oauth(current))]),
            hasSource: true)
        }, now: { server.clock.now() })
    } else {
      oauth = nil
    }
    let raw = input.object("overrides") ?? [:]
    let overrides = ProviderAuthorizationOverrides(
      apiKey: raw.string("apiKey"), environment: raw.object("env")?.compactMapValues(\.stringValue),
      minimumOAuthValidityMilliseconds: raw["minOAuthValidityMs"].flatMap { value in
        if case .number(let number) = value { return number }
        if case .integer(let number) = value { return Double(number) }
        return nil
      })
    var capabilities: [String] = []
    if !raw.isEmpty {
      var authentication: [String: JSONValue] = [:]
      authentication["apiKey"] = raw["apiKey"]
      authentication["environment"] = raw["env"]
      authentication["minimumOAuthValidityMilliseconds"] = raw["minOAuthValidityMs"]
      do {
        _ = try JSONDecoder().decode(
          ProviderConnectionOptions.self,
          from: JSONEncoder().encode(JSONValue.object(["authentication": .object(authentication)])))
      } catch { capabilities = raw.keys.sorted().map { "request authentication override: " + $0 } }
    }
    let execution = Task<JSONValue, any Error> {
      if input.bool("aborted") == true { withUnsafeCurrentTask { $0?.cancel() } }
      if input.string("operation") == "authorization.refresh-stored" {
        let credential = try await ProviderAuthorizationResolution.refreshStored(
          providerID: input.string("provider")!,
          coordinator: CredentialRefreshCoordinator(credentialStore: store, clock: server.clock),
          needsRefresh: { current in
            let value = try await service.exchange(
              "oauth.needsRefresh", ["credential": CredentialProbeCodec.packet(.oauth(current))])
            guard case .bool(let result) = value else {
              throw AuthResolutionProbeRepresentationError()
            }
            return result
          }, refresh: oauth!.refresh)
        return try CredentialProbeCodec.packet(credential.map(ProviderCredential.oauth))
      }
      let resolved = try await ProviderAuthorizationResolution.resolve(
        providerID: input.string("provider")!, store: store, context: context,
        bindings: .init(primary: primary, oauth: oauth),
        coordinator: CredentialRefreshCoordinator(credentialStore: store, clock: server.clock),
        overrides: overrides)
      guard let resolved else { return .null }
      var value: [String: JSONValue] = ["auth": resolved.authorization.auth]
      if resolved.authorization.hasSource { value["source"] = .string(resolved.source) }
      value["env"] = resolved.environment.map { .object($0.mapValues(JSONValue.string)) }
      return .object(value)
    }
    let cancellation = Task {
      for await frame in incoming {
        if frame.string("kind") == "cancel" { execution.cancel() }
      }
    }
    defer { cancellation.cancel() }
    var result: [String: JSONValue] = [
      "unrepresentedCapabilities": .array(capabilities.map(JSONValue.string))
    ]
    switch await execution.result {
    case .success(let value): result["value"] = value
    case .failure(let error): result["error"] = .object(AuthResolutionProbeCodec.error(error))
    }
    try ProbeChannel().write("authorizationResult", result)
    await service.waitForDrain(WireProbeContext.id!)
  }
}

enum AuthResolutionProbeCodec {
  static func error(_ error: any Error) -> [String: JSONValue] {
    if error is CancellationError { return ["cancelled": .bool(true)] }
    if let error = error as? AuthResolutionProbeHostError { return error.value }
    if let error = error as? ProviderAuthorizationResolutionFailure {
      var value: [String: JSONValue] = [
        "kind": .string(error.kind.rawValue),
        "provider": .string(error.providerID), "message": .string(error.message),
      ]
      if let cause = error.cause { value["cause"] = .object(self.error(cause)) }
      return ["nativeResolutionFailure": .object(value), "message": .string(error.message)]
    }
    return ["message": .string(error.localizedDescription)]
  }
  static func error(_ value: [String: JSONValue]) -> any Error {
    if value.bool("cancelled") == true { return CancellationError() }
    if let native = value.object("nativeResolutionFailure") {
      return ProviderAuthorizationResolutionFailure(
        .init(rawValue: native.string("kind")!)!, providerID: native.string("provider")!,
        message: native.string("message")!, cause: native.object("cause").map(error))
    }
    return AuthResolutionProbeHostError(value: value)
  }
}
private struct AuthResolutionProbeHostError: LocalizedError {
  let value: [String: JSONValue]
  var errorDescription: String? { value.string("message") }
}

private struct AuthResolutionProbeRepresentationError: LocalizedError {
  var errorDescription: String? { "Unrepresented authorization callback value" }
}
