import Foundation

@testable import PiAIProviderRuntime

enum CodexTransportFixtures {
  static func replay(_ spec: [String: JSONValue], rejectToolCallback: Bool = false) async throws
    -> JSONValue
  {
    let transport = CodexFixtureTransport(
      captureInstructions: spec.bool("captureInstructions") ?? false, toolStart: rejectToolCallback)
    let sessions = CodexWebSocketSessions()
    let model = ProviderModel(
      id: "gpt-5.1-codex", providerID: "openai-codex", name: "Codex",
      protocolID: "openai-codex-responses",
      capabilities: .init(
        textInput: true,
        imageInput: false, toolCalling: false, reasoning: false, structuredOutput: false,
        imageGeneration: false),
      contextWindow: 400_000, maximumOutputTokens: 128_000)
    let runtime = try ProviderRuntimeKernel(
      catalogRevision: "fixture",
      providers: [
        .init(
          descriptor: .init(
            id: "openai-codex", name: "Codex", authorizationMethods: [], models: [model]),
          baseURL: "https://chatgpt.com/backend-api", headers: [:],
          modelConfigurations: [
            .init(modelID: model.id, outputModality: .text): .init(
              protocolID: model.protocolID, baseURL: nil, headers: [:],
              metadata: [
                "compat": .object(spec.object("compat") ?? [:]),
                "cost": .object([
                  "input": .integer(0), "output": .integer(0),
                  "cacheRead": .integer(0), "cacheWrite": .integer(0),
                ]),
              ])
          ],
          credentialRequirement: .required, authorization: CodexFixtureAuthorization())
      ],
      wireProtocols: StandardWireProtocols.make(),
      credentialStore: InMemoryProviderCredentialStore(
        credentials: [
          "openai-codex": .oauth(
            .init(
              accessToken: "fixture", refreshToken: "",
              expiresAt: .distantFuture, metadata: ["accountID": "fixture"]))
        ]),
      transport: transport,
      wireObserver: .init(
        onPayload: { body, _ in
          body.merge(spec.object("payload") ?? [:]) { _, value in value }
          return nil
        },
        onToolArguments: rejectToolCallback
          ? { @Sendable _, _ in
            throw ProviderRuntimeFailure(
              code: .transportFailed, message: "fixture callback failure",
              providerID: nil, operation: "fixture.callback", causeDescription: nil)
          } : nil), webSocketTransport: transport, codexSessions: sessions)
    let messages = (spec.array("messages") ?? []).map { value -> ProviderMessage in
      let raw = value.objectValue ?? [:]
      return raw.string("role") == "system"
        ? .system(raw.string("content") ?? "") : .user([.text(raw.string("content") ?? "")])
    }
    let request = ProviderRequest(
      id: "fixture", providerID: model.providerID, modelID: model.id, messages: messages, tools: [],
      options: .init(
        maximumOutputTokens: nil, temperature: nil, reasoningEffort: nil,
        responseSchema: nil, providerOptions: [:], sessionID: "fixture"),
      connectionOptions: .init(
        headers: spec.object("headers")?.mapValues(\.stringValue),
        transport: spec.string("transport").flatMap(
          ProviderConnectionOptions.Transport.init(rawValue:)),
        maximumRetries: spec.int("maxRetries")))
    var result: [String: JSONValue] = [
      "id": .string(spec.string("id")!), "stopReason": .string("stop"),
    ]
    do {
      for try await _ in runtime.stream(request) {}
    } catch let error as ProviderRuntimeFailure {
      result["stopReason"] = .string("error")
      result["errorMessage"] = .string(error.message)
    }
    result["requests"] = .array(await transport.requests)
    await sessions.close()
    return .object(result)
  }
}

private let codexFixtureTerminal =
  #"{"type":"response.completed","response":{"id":"fixture","status":"completed","usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0}}}"#

private actor CodexFixtureTransport: ProviderHTTPStreamingTransport, ProviderWebSocketTransport {
  var requests: [JSONValue] = []
  let captureInstructions: Bool
  let toolStart: Bool

  init(captureInstructions: Bool, toolStart: Bool) {
    self.captureInstructions = captureInstructions
    self.toolStart = toolStart
  }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    let body = try decodeJSONObject(
      fixtureHTTPBody(request), providerID: "fixture", operation: "codex.body")
    var captured: [String: JSONValue] = [
      "transport": .string("sse"), "headers": .object(headers(request)),
    ]
    if captureInstructions {
      captured["instructions"] = body["instructions"]
      captured["input"] = body["input"]
    }
    requests.append(.object(captured))
    return .init(
      statusCode: 200, headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.yield(Data("data: \(codexFixtureTerminal)\n\n".utf8))
        continuation.finish()
      })
  }

  func connect(_ request: URLRequest) async throws -> any ProviderWebSocketConnection {
    CodexFixtureSocket(transport: self, headers: headers(request), toolStart: toolStart)
  }

  func sent(_ text: String, headers: [String: JSONValue]) throws {
    let body = try decodeJSONObject(
      Data(text.utf8), providerID: "fixture", operation: "codex.socket.body")
    var request: [String: JSONValue] = [
      "transport": .string("websocket"), "headers": .object(headers),
    ]
    request["type"] = body["type"]
    requests.append(.object(request))
  }

  private func headers(_ request: URLRequest) -> [String: JSONValue] {
    Dictionary(
      uniqueKeysWithValues: ["originator", "accept", "content-type", "openai-beta"].compactMap {
        name in request.value(forHTTPHeaderField: name).map { (name, .string($0)) }
      })
  }
}

private struct CodexFixtureSocket: ProviderWebSocketConnection {
  let transport: CodexFixtureTransport
  let headers: [String: JSONValue]
  let toolStart: Bool
  func send(_ text: String) async throws { try await transport.sent(text, headers: headers) }
  func receive() async throws -> String {
    toolStart
      ? #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_fixture","call_id":"call_fixture","name":"fixture","arguments":""}}"#
      : codexFixtureTerminal
  }
  func close(code: Int, reason: String) async {}
}

private struct CodexFixtureAuthorization: ProviderAuthorizationAdapter {
  var oauthRefresh: CredentialRefreshCoordinator.RefreshOperation? { { $0 } }
  func authorize(
    _ operation: AuthorizationOperation, interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    throw CancellationError()
  }
}
