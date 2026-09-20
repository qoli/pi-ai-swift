import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct AzureOpenAIConfigurationDifferentialTests {
  @Test
  func pinnedSourceOracleIsReproducible() throws {
    let root = repositoryRootForAzureConfiguration()
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "node",
      root.appending(path: "Scripts/pi-ai-azure-configuration-oracle.mjs").path,
      root.appending(path: ".build/upstreams/pi").path,
      root.appending(path: "Fixtures/AzureOpenAIConfiguration/Cases/configuration.json").path,
    ]
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let stderr =
      String(
        data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, Comment(rawValue: stderr))
    let generated = try #require(
      JSONSerialization.jsonObject(
        with: output.fileHandleForReading.readDataToEndOfFile()) as? NSDictionary)
    let expectedData = try Data(
      contentsOf: root.appending(
        path: "Fixtures/AzureOpenAIConfiguration/Oracle/configuration.json"))
    let expected = try #require(
      JSONSerialization.jsonObject(with: expectedData) as? NSDictionary)
    #expect(generated == expected)
  }

  @Test
  func pinnedSourceConfigurationCasesMatchSwiftResolverAndAdapter() async throws {
    let fixture: AzureConfigurationFixture = try decodeFixture(
      "Fixtures/AzureOpenAIConfiguration/Cases/configuration.json")
    let oracle: AzureConfigurationOracle = try decodeFixture(
      "Fixtures/AzureOpenAIConfiguration/Oracle/configuration.json")

    #expect(oracle.upstreamRevision == "19451accdeec671c1f4da9eafac8fc270f510ef4")
    for testCase in fixture.cases {
      let expected = try #require(oracle.cases[testCase.id])
      let request = azureRequest(testCase)
      if let expectedError = expected.errorMessage {
        do {
          _ = try ResolvedAzureOpenAIResponsesConfiguration.resolve(
            request: request, modelBaseURL: testCase.modelBaseURL)
          Issue.record("\(testCase.id) resolved invalid configuration")
        } catch let failure as ProviderRuntimeFailure {
          #expect(failure.code == .invalidRequest)
          #expect(failure.operation == "azure-openai-responses.request.configuration")
          #expect(failure.message == expectedError)
        }
        continue
      }

      let resolved = try ResolvedAzureOpenAIResponsesConfiguration.resolve(
        request: request, modelBaseURL: testCase.modelBaseURL)
      let transport = AzureConfigurationCaptureTransport()
      let context = azureContext(
        modelID: testCase.modelID,
        baseURL: testCase.modelBaseURL ?? resolved.baseURL)
      do {
        for try await _ in OpenAIResponsesAdapter(
          protocolID: "azure-openai-responses", flavor: .azure
        ).stream(request, context: context, transport: transport) {}
      } catch let failure as ProviderRuntimeFailure {
        #expect(failure.code == .transportFailed)
      }
      let captured = try #require(await transport.request())
      #expect(captured.url?.absoluteString == expected.url)
      let body = try decodeJSONObject(
        try #require(captured.httpBody),
        providerID: "azure-openai-responses",
        operation: "azure-configuration.fixture"
      )
      #expect(body.string("model") == expected.model)
      #expect(body["azureBaseUrl"] == nil)
      #expect(body["azureResourceName"] == nil)
      #expect(body["azureApiVersion"] == nil)
      #expect(body["azureDeploymentName"] == nil)
      #expect(body["env"] == nil)
    }
  }

  @Test
  func connectionOptionsRemainBackwardCompatibleAndRejectUnknownOrWrongTypes() throws {
    let legacy = ProviderRequest(
      id: "legacy", providerID: "openai", modelID: "gpt",
      messages: [.user([.text("hello")])], tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: nil, temperature: nil, reasoningEffort: nil,
        responseSchema: nil, providerOptions: [:]))
    let encodedLegacy = try JSONEncoder().encode(legacy)
    let object = try #require(
      JSONSerialization.jsonObject(with: encodedLegacy) as? [String: Any])
    #expect(object["connectionOptions"] == nil)
    #expect(try JSONDecoder().decode(ProviderRequest.self, from: encodedLegacy) == legacy)

    let legacyWithoutField = try JSONSerialization.data(withJSONObject: object)
    #expect(
      try JSONDecoder().decode(ProviderRequest.self, from: legacyWithoutField).connectionOptions
        == .init())

    var unknown = object
    unknown["connectionOptions"] = ["unknownProvider": [:]]
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(
        ProviderRequest.self, from: JSONSerialization.data(withJSONObject: unknown))
    }

    var wrongType = object
    wrongType["connectionOptions"] = [
      "azureOpenAIResponses": ["azureApiVersion": 42]
    ]
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(
        ProviderRequest.self, from: JSONSerialization.data(withJSONObject: wrongType))
    }
  }

  @Test
  func misplacedAzureConnectionKeysFailBeforeTransportInsteadOfEnteringBody() async throws {
    let fixture = AzureConfigurationCase(
      id: "misplaced", modelID: "source-model",
      modelBaseURL: "https://fixture.openai.azure.com/openai/v1",
      options: .init())
    let base = azureRequest(fixture)
    let request = ProviderRequest(
      id: base.id, providerID: base.providerID, modelID: base.modelID,
      messages: base.messages, tools: base.tools,
      options: ProviderGenerationOptions(
        maximumOutputTokens: nil, temperature: nil, reasoningEffort: nil,
        responseSchema: nil,
        providerOptions: ["azureBaseUrl": .string("https://leak.invalid")]),
      connectionOptions: base.connectionOptions)
    let transport = AzureConfigurationCaptureTransport()
    do {
      for try await _ in OpenAIResponsesAdapter(
        protocolID: "azure-openai-responses", flavor: .azure
      ).stream(
        request,
        context: azureContext(modelID: request.modelID, baseURL: fixture.modelBaseURL!),
        transport: transport)
      {}
      Issue.record("misplaced Azure configuration completed successfully")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .invalidRequest)
      #expect(failure.operation == "azure-openai-responses.request.configuration")
    }
    #expect(await transport.request() == nil)
  }

  @Test
  func kernelResolvesRequestScopedAzureConfigurationAndFailsWhenBaseIsMissing() async throws {
    let transport = AzureConfigurationCaptureTransport()
    let runtime = try azureRuntime(transport: transport)
    let configured = azureRequest(
      AzureConfigurationCase(
        id: "kernel-resource", modelID: "source-model", modelBaseURL: nil,
        options: SourceAzureOptions(
          azureResourceName: "kernel-resource",
          azureApiVersion: "kernel-version",
          azureDeploymentName: "kernel-deployment")))
    do {
      for try await _ in runtime.stream(configured) {}
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .transportFailed)
    }
    let captured = try #require(await transport.request())
    #expect(
      captured.url?.absoluteString
        == "https://kernel-resource.openai.azure.com/openai/v1/responses?api-version=kernel-version"
    )

    let missingTransport = AzureConfigurationCaptureTransport()
    let missingRuntime = try azureRuntime(transport: missingTransport)
    let missing = azureRequest(
      AzureConfigurationCase(
        id: "kernel-missing", modelID: "source-model", modelBaseURL: nil,
        options: .init()))
    do {
      for try await _ in missingRuntime.stream(missing) {}
      Issue.record("missing Azure base URL completed successfully")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .invalidRequest)
      #expect(failure.operation == "azure-openai-responses.request.configuration")
    }
    #expect(await missingTransport.request() == nil)
  }
}

private struct AzureConfigurationFixture: Decodable {
  let schemaVersion: Int
  let cases: [AzureConfigurationCase]
}

private struct AzureConfigurationCase: Decodable {
  let id: String
  let modelID: String
  let modelBaseURL: String?
  let options: SourceAzureOptions
}

private struct SourceAzureOptions: Decodable {
  let azureBaseUrl: String?
  let azureResourceName: String?
  let azureApiVersion: String?
  let azureDeploymentName: String?
  let env: [String: String]?

  init(
    azureBaseUrl: String? = nil,
    azureResourceName: String? = nil,
    azureApiVersion: String? = nil,
    azureDeploymentName: String? = nil,
    env: [String: String]? = nil
  ) {
    self.azureBaseUrl = azureBaseUrl
    self.azureResourceName = azureResourceName
    self.azureApiVersion = azureApiVersion
    self.azureDeploymentName = azureDeploymentName
    self.env = env
  }
}

private struct AzureConfigurationOracle: Decodable {
  let schemaVersion: Int
  let upstreamRevision: String
  let cases: [String: AzureConfigurationExpected]
}

private struct AzureConfigurationExpected: Decodable {
  let url: String?
  let model: String?
  let errorMessage: String?
}

private func azureRequest(_ testCase: AzureConfigurationCase) -> ProviderRequest {
  ProviderRequest(
    id: testCase.id,
    providerID: "azure-openai-responses",
    modelID: testCase.modelID,
    messages: [.system("Azure source fixture"), .user([.text("hello")])],
    tools: [],
    options: ProviderGenerationOptions(
      maximumOutputTokens: nil, temperature: nil, reasoningEffort: nil,
      responseSchema: nil, providerOptions: [:]),
    connectionOptions: ProviderConnectionOptions(
      azureOpenAIResponses: AzureOpenAIResponsesConnectionOptions(
        azureBaseURL: testCase.options.azureBaseUrl,
        azureResourceName: testCase.options.azureResourceName,
        azureAPIVersion: testCase.options.azureApiVersion,
        azureDeploymentName: testCase.options.azureDeploymentName,
        environment: testCase.options.env ?? [:])))
}

private func azureContext(modelID: String, baseURL: String) -> WireProtocolContext {
  let model = ProviderModel(
    id: modelID, providerID: "azure-openai-responses", name: modelID,
    protocolID: "azure-openai-responses",
    capabilities: ProviderCapabilities(
      textInput: true, imageInput: false, toolCalling: true, reasoning: false,
      structuredOutput: true, imageGeneration: false),
    contextWindow: 32_768, maximumOutputTokens: 4_096)
  return WireProtocolContext(
    provider: ProviderDescriptor(
      id: "azure-openai-responses", name: "Azure OpenAI",
      authorizationMethods: [], models: [model]),
    model: model, baseURL: URL(string: baseURL)!, headers: [:],
    credential: .apiKey(APIKeyCredential(key: "sanitized-fixture-key", metadata: [:])),
    modelConfiguration: ProviderModelConfiguration(
      protocolID: "azure-openai-responses", baseURL: baseURL,
      headers: [:], metadata: [:]))
}

private actor AzureConfigurationCaptureTransport: ProviderHTTPStreamingTransport {
  private var captured: URLRequest?

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    return ProviderHTTPStreamingResponse(
      statusCode: 418, headers: [:],
      body: AsyncThrowingStream { continuation in continuation.finish() })
  }

  func request() -> URLRequest? { captured }
}

private actor AzureConfigurationCredentialStore: ProviderCredentialStore {
  private var credential: ProviderCredential? = .apiKey(
    APIKeyCredential(key: "sanitized-fixture-key", metadata: [:]))

  func read(providerID: String) -> ProviderCredential? { credential }
  func list() -> [ProviderCredentialInfo] { [] }
  func modify(
    providerID: String,
    _ transform: @escaping @Sendable (ProviderCredential?) async throws -> ProviderCredential?
  ) async throws -> ProviderCredential? {
    credential = try await transform(credential)
    return credential
  }
  func delete(providerID: String) { credential = nil }
}

private struct AzureConfigurationAuthorization: ProviderAuthorizationAdapter {
  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    throw ProviderRuntimeFailure(
      code: .unsupportedCapability, message: "fixture authorization is unavailable",
      providerID: "azure-openai-responses", operation: "fixture.authorize", causeDescription: nil)
  }
}

private func azureRuntime(
  transport: AzureConfigurationCaptureTransport
) throws -> ProviderRuntimeKernel {
  let model = ProviderModel(
    id: "source-model", providerID: "azure-openai-responses", name: "Source Model",
    protocolID: "azure-openai-responses",
    capabilities: ProviderCapabilities(
      textInput: true, imageInput: false, toolCalling: true, reasoning: false,
      structuredOutput: true, imageGeneration: false),
    contextWindow: 32_768, maximumOutputTokens: 4_096)
  return try ProviderRuntimeKernel(
    catalogRevision: "fixture",
    providers: [
      ProviderDefinition(
        descriptor: ProviderDescriptor(
          id: "azure-openai-responses", name: "Azure OpenAI",
          authorizationMethods: [], models: [model]),
        baseURL: nil, headers: [:],
        modelConfigurations: [
          ProviderModelRoute(modelID: model.id, outputModality: .text):
            ProviderModelConfiguration(
              protocolID: "azure-openai-responses", baseURL: nil,
              headers: [:], metadata: [:])
        ],
        credentialRequirement: .required,
        authorization: AzureConfigurationAuthorization())
    ],
    wireProtocols: [
      OpenAIResponsesAdapter(protocolID: "azure-openai-responses", flavor: .azure)
    ],
    credentialStore: AzureConfigurationCredentialStore(),
    transport: transport)
}

private func decodeFixture<T: Decodable>(_ relativePath: String) throws -> T {
  let root = repositoryRootForAzureConfiguration()
  return try JSONDecoder().decode(
    T.self, from: Data(contentsOf: root.appending(path: relativePath)))
}

private func repositoryRootForAzureConfiguration() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
