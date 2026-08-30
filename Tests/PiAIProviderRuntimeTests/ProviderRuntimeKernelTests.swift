import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ProviderRuntimeKernelTests {
  @Test
  func catalogAuthorizationAndStreamUseTheRegisteredProviderAndWireProtocol()
    async throws
  {
    let store = KernelCredentialStore()
    let recorder = WireRecorder()
    let runtime = try makeRuntime(
      credentialStore: store,
      wireProtocols: [FixtureWireProtocol(recorder: recorder)]
    )

    let catalog = try await runtime.catalog()
    #expect(catalog.revision == "fixture-revision")
    #expect(catalog.providers.map(\.id) == ["fixture-provider"])

    let state = try await runtime.authorize(
      .login(providerID: "fixture-provider", methodID: "api-key")
    ) { challenge in
      guard case .prompt(_, _, _, .secret) = challenge else {
        Issue.record("fixture login emitted the wrong challenge")
        return .acknowledged
      }
      return .value("fixture-key")
    }
    #expect(
      state
        == .connected(
          ProviderAccount(
            providerID: "fixture-provider",
            accountID: nil,
            authorizationKind: .apiKey,
            expiresAt: nil
          )
        ))

    let request = fixtureRequest()
    var events: [ProviderEvent] = []
    for try await event in runtime.stream(request) {
      events.append(event)
    }

    #expect(
      events == [
        .responseStarted(
          ProviderResponseMetadata(
            responseID: "fixture-response",
            providerID: "fixture-provider",
            modelID: "fixture-model",
            providerMetadata: [:]
          )
        ),
        .textDelta("ok"),
        .usage(
          ProviderUsage(
            inputTokens: 1,
            outputTokens: 1,
            reasoningTokens: nil,
            cachedInputTokens: nil,
            providerMetadata: [:]
          )
        ),
        .completed(.stop),
      ])
    let context = try #require(await recorder.context)
    #expect(context.baseURL.absoluteString == "https://fixture.invalid/v1")
    #expect(context.model.protocolID == "fixture-wire")
    #expect(
      context.credential
        == .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:])))
  }

  @Test
  func missingProviderModelProtocolAndCredentialFailExplicitly() async throws {
    let store = KernelCredentialStore()
    let runtime = try makeRuntime(
      credentialStore: store,
      wireProtocols: [FixtureWireProtocol(recorder: WireRecorder())]
    )

    await expectFailure(
      runtime,
      request: request(providerID: "unknown", modelID: "fixture-model"),
      code: .unsupportedProvider,
      operation: "stream.resolve-provider"
    )
    await expectFailure(
      runtime,
      request: request(providerID: "fixture-provider", modelID: "unknown"),
      code: .unsupportedModel,
      operation: "stream.resolve-model"
    )
    await expectFailure(
      runtime,
      request: fixtureRequest(),
      code: .missingCredential,
      operation: "stream.resolve-credential"
    )

    let missingProtocolRuntime = try makeRuntime(
      credentialStore: KernelCredentialStore(apiKey: "fixture-key"),
      wireProtocols: []
    )
    await expectFailure(
      missingProtocolRuntime,
      request: fixtureRequest(),
      code: .unsupportedCapability,
      operation: "stream.resolve-protocol"
    )
  }

  @Test
  func duplicateProviderModelAndWireIdentifiersAreRejectedAtConfiguration()
    async
  {
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try ProviderRuntimeKernel(
        catalogRevision: "fixture",
        providers: [fixtureProvider(), fixtureProvider()],
        wireProtocols: [],
        credentialStore: KernelCredentialStore(),
        transport: UnusedStreamingTransport()
      )
    }

    #expect(throws: ProviderRuntimeFailure.self) {
      let duplicateModels = ProviderDescriptor(
        id: "fixture-provider",
        name: "Fixture",
        authorizationMethods: [],
        models: [fixtureModel(), fixtureModel()]
      )
      _ = try ProviderRuntimeKernel(
        catalogRevision: "fixture",
        providers: [
          ProviderDefinition(
            descriptor: duplicateModels,
            baseURL: "https://fixture.invalid/v1",
            headers: [:],
            modelConfigurations: [
              "fixture-model": fixtureModelConfiguration()
            ],
            credentialRequirement: .required,
            authorization: fixtureAuthorization()
          )
        ],
        wireProtocols: [],
        credentialStore: KernelCredentialStore(),
        transport: UnusedStreamingTransport()
      )
    }

    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try makeRuntime(
        credentialStore: KernelCredentialStore(),
        wireProtocols: [
          FixtureWireProtocol(recorder: WireRecorder()),
          FixtureWireProtocol(recorder: WireRecorder()),
        ]
      )
    }
  }
}

private actor KernelCredentialStore: ProviderCredentialStore {
  private var values: [String: ProviderCredential] = [:]

  init(apiKey: String? = nil) {
    if let apiKey {
      values["fixture-provider"] = .apiKey(
        APIKeyCredential(key: apiKey, metadata: [:])
      )
    }
  }

  func read(providerID: String) -> ProviderCredential? {
    values[providerID]
  }

  func list() -> [ProviderCredentialInfo] {
    values.compactMap { providerID, credential in
      let kind: AuthorizationMethodDescriptor.Kind
      switch credential {
      case .apiKey: kind = .apiKey
      case .oauth: kind = .oauth
      }
      return ProviderCredentialInfo(providerID: providerID, kind: kind)
    }
  }

  func modify(
    providerID: String,
    _ transform:
      @escaping @Sendable (ProviderCredential?) async throws
      -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    let next = try await transform(values[providerID])
    values[providerID] = next
    return next
  }

  func delete(providerID: String) {
    values[providerID] = nil
  }
}

private actor WireRecorder {
  private(set) var context: WireProtocolContext?

  func record(_ context: WireProtocolContext) {
    self.context = context
  }
}

private struct FixtureWireProtocol: WireProtocolAdapter {
  let protocolID = "fixture-wire"
  let recorder: WireRecorder

  func stream(
    _ request: ProviderRequest,
    context: WireProtocolContext,
    transport: any ProviderHTTPStreamingTransport
  ) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await recorder.record(context)
        continuation.yield(
          .responseStarted(
            ProviderResponseMetadata(
              responseID: "fixture-response",
              providerID: request.providerID,
              modelID: request.modelID,
              providerMetadata: [:]
            )
          )
        )
        continuation.yield(.textDelta("ok"))
        continuation.yield(
          .usage(
            ProviderUsage(
              inputTokens: 1,
              outputTokens: 1,
              reasoningTokens: nil,
              cachedInputTokens: nil,
              providerMetadata: [:]
            )
          )
        )
        continuation.yield(.completed(.stop))
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private struct UnusedStreamingTransport: ProviderHTTPStreamingTransport {
  func stream(_ request: URLRequest) async throws
    -> ProviderHTTPStreamingResponse
  {
    throw fixtureFailure(.transportFailed, operation: "fixture.transport")
  }
}

private func makeRuntime(
  credentialStore: KernelCredentialStore,
  wireProtocols: [any WireProtocolAdapter]
) throws -> ProviderRuntimeKernel {
  try ProviderRuntimeKernel(
    catalogRevision: "fixture-revision",
    providers: [fixtureProvider()],
    wireProtocols: wireProtocols,
    credentialStore: credentialStore,
    transport: UnusedStreamingTransport()
  )
}

private func fixtureProvider() -> ProviderDefinition {
  ProviderDefinition(
    descriptor: ProviderDescriptor(
      id: "fixture-provider",
      name: "Fixture",
      authorizationMethods: [
        AuthorizationMethodDescriptor(
          id: "api-key",
          kind: .apiKey,
          label: "Fixture key"
        )
      ],
      models: [fixtureModel()]
    ),
    baseURL: "https://fixture.invalid/v1",
    headers: ["X-Fixture": "true"],
    modelConfigurations: [
      "fixture-model": fixtureModelConfiguration()
    ],
    credentialRequirement: .required,
    authorization: fixtureAuthorization()
  )
}

private func fixtureModelConfiguration() -> ProviderModelConfiguration {
  ProviderModelConfiguration(baseURL: nil, headers: [:], metadata: [:])
}

private func fixtureAuthorization() -> APIKeyAuthorizationAdapter {
  APIKeyAuthorizationAdapter(
    providerID: "fixture-provider",
    methodID: "api-key",
    label: "Fixture key"
  )
}

private func fixtureModel() -> ProviderModel {
  ProviderModel(
    id: "fixture-model",
    providerID: "fixture-provider",
    name: "Fixture Model",
    protocolID: "fixture-wire",
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: false,
      toolCalling: false,
      reasoning: false,
      structuredOutput: false,
      imageGeneration: false
    ),
    contextWindow: 1_024,
    maximumOutputTokens: 128
  )
}

private func fixtureRequest() -> ProviderRequest {
  request(providerID: "fixture-provider", modelID: "fixture-model")
}

private func request(providerID: String, modelID: String) -> ProviderRequest {
  ProviderRequest(
    id: "fixture-request",
    providerID: providerID,
    modelID: modelID,
    messages: [.user([.text("hello")])],
    tools: [],
    options: ProviderGenerationOptions(
      maximumOutputTokens: nil,
      temperature: nil,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: [:]
    )
  )
}

private func expectFailure(
  _ runtime: ProviderRuntimeKernel,
  request: ProviderRequest,
  code: ProviderRuntimeFailure.Code,
  operation: String
) async {
  do {
    for try await _ in runtime.stream(request) {
      Issue.record("invalid request emitted a valid-looking event")
    }
    Issue.record("invalid request completed successfully")
  } catch let error as ProviderRuntimeFailure {
    #expect(error.code == code)
    #expect(error.operation == operation)
  } catch {
    Issue.record("unexpected error type: \(error)")
  }
}

private func fixtureFailure(
  _ code: ProviderRuntimeFailure.Code,
  operation: String
) -> ProviderRuntimeFailure {
  ProviderRuntimeFailure(
    code: code,
    message: "fixture failure",
    providerID: "fixture-provider",
    operation: operation,
    causeDescription: nil
  )
}
