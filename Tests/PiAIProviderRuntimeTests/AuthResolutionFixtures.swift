import Foundation

@testable import PiAIProviderRuntime

enum AuthResolutionFixtures {
  static func replay(_ spec: [String: JSONValue]) async throws -> JSONValue {
    let recorder = AuthResolutionRecorder()
    let store = AuthResolutionStore(spec: spec, recorder: recorder)
    let context = ProviderAuthenticationContext(
      environment: { name in
        await recorder.append(.object(["env": .string(name)]))
        return spec.object("environment")?.string(name)
      }, fileExists: { _ in false })
    typealias Bindings = ProviderAuthorizationBindings<JSONValue>
    let primary: Bindings.Primary?
    if spec.bool("primary") == true {
      primary = { credential, context in
        await recorder.append(
          .object(["primary": project(credential.map(ProviderCredential.apiKey))]))
        if let message = spec.string("primaryError") { throw AuthResolutionFixtureError(message) }
        guard
          let result = try await ProviderPrimaryAuthorization.resolve(
            providerID: "fixture",
            credential: credential.map(ProviderCredential.apiKey), context: context,
            variables: ["FIXTURE_API_KEY"])
        else { return nil }
        return .init(
          authorization: result.projected.objectValue!["auth"]!,
          source: result.source, environment: result.environment)
      }
    } else {
      primary = nil
    }
    let oauth: Bindings.OAuth? =
      spec.bool("oauth") == true
      ? .init(
        refresh: { current in
          await recorder.append(.object(["refresh": .string(current.accessToken)]))
          if let message = spec.string("refreshError") { throw AuthResolutionFixtureError(message) }
          return .init(
            accessToken: "fresh-access", refreshToken: "fresh-refresh",
            expiresAt: Date(
              timeIntervalSince1970: Double(
                spec.int("refreshedExpires") ?? spec.int("now")! + 3_600_000) / 1_000),
            metadata: [:])
        },
        derive: { current in
          await recorder.append(.object(["derive": .string(current.accessToken)]))
          if let message = spec.string("derivationError") {
            throw AuthResolutionFixtureError(message)
          }
          return .object(["apiKey": .string(current.accessToken)])
        }, now: { Date(timeIntervalSince1970: Double(spec.int("now")!) / 1_000) }) : nil
    let rawOverrides = spec.object("overrides") ?? [:]
    let overrides = ProviderAuthorizationOverrides(
      apiKey: rawOverrides.string("apiKey"),
      environment: rawOverrides.object("env")?.compactMapValues(\.stringValue),
      minimumOAuthValidityMilliseconds: rawOverrides.int("minOAuthValidityMs").map(Double.init))
    let task = Task<JSONValue, any Error> {
      if spec.bool("aborted") == true { withUnsafeCurrentTask { $0?.cancel() } }
      if spec.bool("rawRefresh") == true {
        let value = try await ProviderAuthorizationResolution.refreshStored(
          providerID: "fixture", coordinator: CredentialRefreshCoordinator(credentialStore: store),
          needsRefresh: { current in
            await recorder.append(.object(["needsRefresh": .string(current.accessToken)]))
            if let message = spec.string("needsRefreshError") {
              throw AuthResolutionFixtureError(message)
            }
            return spec.bool("needsRefresh")!
          }, refresh: oauth!.refresh)
        return project(value.map(ProviderCredential.oauth))
      }
      let resolved = try await ProviderAuthorizationResolution.resolve(
        providerID: "fixture", store: store,
        context: context, bindings: .init(primary: primary, oauth: oauth),
        coordinator: CredentialRefreshCoordinator(credentialStore: store), overrides: overrides)
      guard let value = resolved else { return .null }
      var fields: [String: JSONValue] = [
        "auth": value.authorization, "source": .string(value.source),
      ]
      fields["env"] = value.environment.map { .object($0.mapValues(JSONValue.string)) }
      return .object(fields)
    }
    let result: JSONValue
    do {
      result = try await task.value
    } catch is CancellationError { result = .object(["error": .string("AbortError")]) } catch let
      error as ProviderAuthorizationResolutionFailure
    {
      result = .object(["error": .string(error.kind.rawValue), "message": .string(error.message)])
    }
    return .object([
      "id": spec["id"]!, "result": result, "calls": .array(await recorder.calls),
      "stored": project(try await store.memory.read(providerID: "fixture")),
    ])
  }

  static func credential(_ raw: [String: JSONValue]?) -> ProviderCredential? {
    guard let raw else { return nil }
    if raw.string("type") == "oauth" {
      return .oauth(
        .init(
          accessToken: raw.string("access")!, refreshToken: raw.string("refresh")!,
          expiresAt: Date(timeIntervalSince1970: Double(raw.int("expires")!) / 1_000), metadata: [:]
        ))
    }
    let environment = raw.object("env")?.compactMapValues(\.stringValue)
    if let key = raw.string("key") {
      return .apiKey(.init(key: key, metadata: [:], environment: environment))
    }
    return .apiKey(.init(environment: environment))
  }
  static func project(_ credential: ProviderCredential?) -> JSONValue {
    switch credential {
    case .none: .null
    case .apiKey(let value):
      .object(
        ["type": .string("api_key")].merging(
          [
            "key": value.configuredKey.map(JSONValue.string),
            "env": value.environment.map { .object($0.mapValues(JSONValue.string)) },
          ].compactMapValues { $0 }
        ) { _, rhs in rhs })
    case .oauth(let value):
      .object([
        "type": .string("oauth"), "access": .string(value.accessToken),
        "refresh": .string(value.refreshToken),
        "expires": .integer(Int64((value.expiresAt.timeIntervalSince1970 * 1_000).rounded())),
      ])
    }
  }
}

private actor AuthResolutionRecorder {
  var calls: [JSONValue] = []
  func append(_ value: JSONValue) { calls.append(value) }
}
private actor AuthResolutionStore: ProviderCredentialStore {
  let spec: [String: JSONValue]
  let recorder: AuthResolutionRecorder
  let memory: InMemoryProviderCredentialStore
  init(spec: [String: JSONValue], recorder: AuthResolutionRecorder) {
    self.spec = spec
    self.recorder = recorder
    memory = .init(
      credentials: AuthResolutionFixtures.credential(spec.object("credential")).map {
        ["fixture": $0]
      } ?? [:])
  }
  func read(providerID: String) async throws -> ProviderCredential? {
    await recorder.append(.string("read"))
    if let message = spec.string("readError") { throw AuthResolutionFixtureError(message) }
    return try await memory.read(providerID: providerID)
  }
  func modify(
    providerID: String,
    _ transform: @escaping @Sendable (ProviderCredential?) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    await recorder.append(.string("modify"))
    if let message = spec.string("modifyError") { throw AuthResolutionFixtureError(message) }
    return try await memory.modify(providerID: providerID, transform)
  }
  func list() async throws -> [ProviderCredentialInfo] { try await memory.list() }
  func delete(providerID: String) async throws { try await memory.delete(providerID: providerID) }
}
private struct AuthResolutionFixtureError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
