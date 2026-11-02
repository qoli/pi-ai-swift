import Foundation

@testable import PiAIProviderRuntime

enum PrimaryAuthorizationFixtures {
  static func environmentKeys(_ spec: [String: JSONValue]) async throws -> JSONValue {
    let values = spec.object("environment") ?? [:]
    let scoped = spec.object("scoped") ?? [:]
    let context = ProviderAuthenticationContext(
      environment: { name in
        if let value = scoped[name]?.stringValue, !value.isEmpty { return value }
        return values[name]?.stringValue
      }, fileExists: { _ in false })
    let providerID = spec.string("provider")!
    let names = try await ProviderEnvironmentKeys.configuredNames(
      providerID: providerID, context: context)
    let key = try await ProviderEnvironmentKeys.firstAPIKey(
      providerID: providerID, environment: context.environment)
    return .object([
      "id": spec["id"]!,
      "names": names.isEmpty ? .null : .array(names.map(JSONValue.string)),
      "key": key.map { .string($0.value) } ?? .null,
    ])
  }

  static func replay(_ spec: [String: JSONValue]) async throws -> JSONValue {
    let recorder = PrimaryAuthorizationRecorder(spec)
    let context = ProviderAuthenticationContext(
      environment: { await recorder.environment($0) },
      fileExists: { await recorder.fileExists($0) })
    let provider = spec.string("provider")!
    let result: JSONValue
    if spec.string("action") == "login" {
      let store = InMemoryProviderCredentialStore()
      let adapter = APIKeyAuthorizationAdapter(
        providerID: provider, methodID: "api-key",
        label: "Enter " + (spec.string("name") ?? "Fixture key"))
      _ = try await adapter.authorize(
        .login(providerID: provider, methodID: "api-key"),
        interaction: { try await recorder.interact($0) }, credentialStore: store)
      guard case .apiKey(let key) = try await store.read(providerID: provider) else {
        throw fixtureFailure("Missing primary credential")
      }
      var raw: [String: JSONValue] = ["type": .string("api_key")]
      raw["key"] = key.configuredKey.map(JSONValue.string)
      raw["env"] = key.environment.map { .object($0.mapValues(JSONValue.string)) }
      result = .object(raw)
    } else {
      let credential: ProviderCredential?
      if let raw = spec.object("credential") {
        let environment = raw.object("env")?.compactMapValues(\.stringValue)
        if let key = raw.string("key") {
          credential = .apiKey(.init(key: key, metadata: [:], environment: environment))
        } else {
          credential = .apiKey(.init(environment: environment))
        }
      } else {
        credential = nil
      }
      result =
        try await ProviderPrimaryAuthorization.resolve(
          providerID: provider, credential: credential, context: context,
          variables: spec.array("variables")?.compactMap(\.stringValue))?.projected ?? .null
    }
    return await recorder.output(result: result)
  }

  private static func fixtureFailure(_ message: String) -> ProviderRuntimeFailure {
    .init(
      code: .invalidResponse, message: message, providerID: nil,
      operation: "fixture.primary-authorization", causeDescription: nil)
  }
}

private actor PrimaryAuthorizationRecorder {
  let spec: [String: JSONValue]
  var environmentReads: [JSONValue] = []
  var fileReads: [JSONValue] = []
  var prompts: [JSONValue] = []
  var notices: [JSONValue] = []
  var responses: [JSONValue]
  init(_ spec: [String: JSONValue]) {
    self.spec = spec
    responses = spec.array("responses") ?? []
  }
  func environment(_ name: String) -> String? {
    environmentReads.append(.string(name))
    return spec.object("environment")?.string(name)
  }
  func fileExists(_ name: String) -> Bool {
    fileReads.append(.string(name))
    return spec.array("files")?.contains(.string(name)) == true
  }
  func interact(_ challenge: AuthorizationChallenge) throws -> AuthorizationResponse {
    switch challenge {
    case .prompt(_, _, let message, let kind):
      prompts.append(.object(["type": .string(kind.rawValue), "message": .string(message)]))
    case .choice(_, _, let message, let options):
      prompts.append(
        .object([
          "type": .string("select"), "message": .string(message),
          "options": .array(
            options.map { .object(["id": .string($0.id), "label": .string($0.label)]) }),
        ]))
    case .information(_, let message, let links):
      notices.append(
        .object([
          "type": .string("info"), "message": .string(message),
          "links": .array(
            links.map {
              .object(["label": .string($0.label), "url": .string($0.url.absoluteString)])
            }),
        ]))
      return .acknowledged
    default:
      throw ProviderRuntimeFailure(
        code: .invalidResponse, message: "Unexpected primary challenge",
        providerID: nil, operation: "fixture.primary-authorization", causeDescription: nil)
    }
    guard !responses.isEmpty, let response = responses.removeFirst().stringValue else {
      throw ProviderRuntimeFailure(
        code: .invalidResponse, message: "Primary fixture lacks a response",
        providerID: nil, operation: "fixture.primary-authorization", causeDescription: nil)
    }
    return .value(response)
  }
  func output(result: JSONValue) -> JSONValue {
    .object([
      "id": .string(spec.string("id")!), "result": result,
      "environmentReads": .array(environmentReads), "fileReads": .array(fileReads),
      "prompts": .array(prompts), "notices": .array(notices),
    ])
  }
}
