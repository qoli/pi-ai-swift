import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct BedrockConverseStreamAdapterTests {
  @Test
  func bearerRequestAndAWSEventStreamNormalizeTextToolsUsageAndStop() async throws {
    let stream = try bedrockFrames()
    let bytes = Array(stream)
    let transport = BedrockFixtureTransport(
      chunks: [
        Data(bytes[0..<11]),
        Data(bytes[11..<117]),
        Data(bytes[117..<501]),
        Data(bytes[501...]),
      ],
      headers: ["x-amzn-requestid": "aws-request-1"]
    )
    let adapter = BedrockConverseStreamAdapter()
    var events: [ProviderEvent] = []
    for try await event in adapter.stream(
      bedrockRequest(),
      context: bedrockContext(),
      transport: transport
    ) {
      events.append(event)
    }

    #expect(events.count == 8)
    #expect(
      events[0]
        == .responseStarted(
          ProviderResponseMetadata(
            responseID: "aws-request-1",
            providerID: "amazon-bedrock",
            modelID: "amazon.nova-lite-v1:0",
            providerMetadata: [:]
          )
        )
    )
    #expect(events[1] == .textDelta("Checking"))
    #expect(events[2] == .toolCallStarted(id: "tool-1", name: "weather"))
    #expect(events[3] == .toolInputDelta(id: "tool-1", delta: #"{"city":"Tai"#))
    #expect(events[4] == .toolInputDelta(id: "tool-1", delta: #"pei"}"#))
    #expect(
      events[5]
        == .toolCallCompleted(
          ProviderToolCall(
            id: "tool-1",
            name: "weather",
            arguments: .object(["city": .string("Taipei")])
          )
        )
    )
    #expect(
      events[6]
        == .usage(
          ProviderUsage(
            inputTokens: 12,
            outputTokens: 8,
            reasoningTokens: nil,
            cachedInputTokens: 2,
            providerMetadata: [
              "inputTokens": .integer(12),
              "outputTokens": .integer(8),
              "cacheReadInputTokens": .integer(2),
              "totalTokens": .integer(20),
            ]
          )
        )
    )
    #expect(events[7] == .completed(.toolCalls))

    let sent = try #require(await transport.request())
    #expect(
      sent.url?.absoluteString
        == "https://bedrock-runtime.us-east-1.amazonaws.com/model/amazon.nova-lite-v1%3A0/converse-stream"
    )
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-bearer")
    #expect(sent.value(forHTTPHeaderField: "Accept") == "application/vnd.amazon.eventstream")
    #expect(sent.value(forHTTPHeaderField: "X-Amz-Unsafe") == nil)
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(body.object("inferenceConfig")?.int("maxTokens") == 512)
    #expect(body.object("inferenceConfig")?["temperature"] == .number(0.2))
    #expect(body.object("toolConfig")?.array("tools")?.count == 1)
  }

  @Test
  func corruptEventStreamCRCAndUnsupportedSigV4ShapeFailExplicitly() async {
    var corrupt = try! bedrockFrames()
    corrupt[corrupt.index(before: corrupt.endIndex)] ^= 0xff
    await #expect(throws: ProviderRuntimeFailure.self) {
      for try await _ in BedrockConverseStreamAdapter().stream(
        bedrockRequest(),
        context: bedrockContext(),
        transport: BedrockFixtureTransport(
          chunks: [corrupt],
          headers: ["x-amzn-requestid": "aws-request-1"]
        )
      ) {}
    }

    let oauthContext = bedrockContext(
      credential: .oauth(
        OAuthCredential(
          accessToken: "access",
          refreshToken: "refresh",
          expiresAt: Date().addingTimeInterval(3_600),
          metadata: [:]
        )
      )
    )
    do {
      for try await _ in BedrockConverseStreamAdapter().stream(
        bedrockRequest(),
        context: oauthContext,
        transport: BedrockFixtureTransport(chunks: [], headers: [:])
      ) {}
      Issue.record("OAuth credential unexpectedly selected a Bedrock auth fallback")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .unsupportedCapability)
      #expect(error.operation == "bedrock.request.auth")
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test
  func sigV4SignsExactBodyHeadersRegionAndSessionCredential() async throws {
    let transport = BedrockFixtureTransport(
      chunks: [try bedrockFrames()],
      headers: ["x-amzn-requestid": "aws-request-signed"]
    )
    let date = Date(timeIntervalSince1970: 1_735_787_045)
    for try await _ in BedrockConverseStreamAdapter(signingDate: date).stream(
      bedrockRequest(),
      context: bedrockContext(
        credential: .apiKey(
          APIKeyCredential(
            key: "fixture-secret-access-key",
            metadata: [
              "authentication": "sigv4",
              "accessKeyID": "AKIDEXAMPLE",
              "region": "us-east-1",
              "sessionToken": "fixture-session-token",
            ]
          )
        )
      ),
      transport: transport
    ) {}

    let sent = try #require(await transport.request())
    #expect(sent.value(forHTTPHeaderField: "x-amz-date") == "20250102T030405Z")
    #expect(
      sent.value(forHTTPHeaderField: "x-amz-security-token")
        == "fixture-session-token"
    )
    #expect(
      sent.value(forHTTPHeaderField: "x-amz-content-sha256")
        == "feb8ea8cbfbeba6f29eb3a869528bc7fab403db9525afd074103472daa1f4f86"
    )
    let authorization = try #require(
      sent.value(forHTTPHeaderField: "Authorization")
    )
    #expect(
      authorization
        == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20250102/us-east-1/bedrock/aws4_request, SignedHeaders=accept;content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token;x-amzn-bedrock-accept;x-fixture, Signature=661c2919a783854ccfcf7544248e6cd5e8c9df9eef99533f67bdbafa606826d7"
    )
  }

  @Test
  func explicitOffRejectsReasoningModelBeforeTransport() async throws {
    let context = bedrockReasoningContext()
    let request = ProviderRequest(
      id: "reasoning-off", providerID: "amazon-bedrock", modelID: context.model.id,
      messages: [.user([.text("hello")])], tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: nil, temperature: nil, reasoningEffort: .off,
        responseSchema: nil, providerOptions: [:]))
    let transport = BedrockFixtureTransport(chunks: [], headers: [:])
    do {
      for try await _ in BedrockConverseStreamAdapter().stream(
        request, context: context, transport: transport)
      {}
      Issue.record("expected unsupported reasoning off")
    } catch let error as ProviderRuntimeFailure {
      #expect(error.code == .unsupportedCapability)
    }
    #expect(await transport.request() == nil)
  }

  @Test(arguments: [ProviderReasoningEffort.high, .max])
  func adaptiveClaudeReasoningRequestAndSignatureRoundTrip(effort: ProviderReasoningEffort)
    async throws
  {
    let request = ProviderRequest(
      id: "bedrock-reasoning",
      providerID: "amazon-bedrock",
      modelID: "anthropic.claude-sonnet-4-6",
      messages: [.user([.text("reason")])],
      tools: [],
      options: ProviderGenerationOptions(
        maximumOutputTokens: 8_192,
        temperature: nil,
        reasoningEffort: effort,
        responseSchema: nil,
        providerOptions: [:]
      )
    )
    let transport = BedrockFixtureTransport(
      chunks: [try bedrockReasoningFrames()],
      headers: ["x-amzn-requestid": "aws-reasoning"]
    )
    var events: [ProviderEvent] = []
    for try await event in BedrockConverseStreamAdapter().stream(
      request,
      context: bedrockReasoningContext(),
      transport: transport
    ) {
      events.append(event)
    }

    #expect(events.contains(.reasoningDelta("inspect")))
    #expect(events.contains(.reasoningSignatureDelta("opaque-signature")))
    let sent = try #require(await transport.request())
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    let additional = try #require(body.object("additionalModelRequestFields"))
    #expect(additional.object("thinking")?.string("type") == "adaptive")
    #expect(additional.object("thinking")?.string("display") == "summarized")
    #expect(additional.object("output_config")?.string("effort") == effort.rawValue)
  }
}

private actor BedrockFixtureTransport: ProviderHTTPStreamingTransport {
  let chunks: [Data]
  let headers: [String: String]
  private var captured: URLRequest?

  init(chunks: [Data], headers: [String: String]) {
    self.chunks = chunks
    self.headers = headers
  }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    let chunks = chunks
    return ProviderHTTPStreamingResponse(
      statusCode: 200,
      headers: headers,
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      }
    )
  }

  func request() -> URLRequest? { captured }
}

private func bedrockRequest() -> ProviderRequest {
  ProviderRequest(
    id: "bedrock-request",
    providerID: "amazon-bedrock",
    modelID: "amazon.nova-lite-v1:0",
    messages: [
      .system("Be concise"),
      .user([.text("Use weather")]),
    ],
    tools: [
      ProviderToolDefinition(
        name: "weather",
        description: "Read weather",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "city": .object(["type": .string("string")])
          ]),
        ])
      )
    ],
    options: ProviderGenerationOptions(
      maximumOutputTokens: 512,
      temperature: 0.2,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: [:]
    )
  )
}

private func bedrockContext(
  credential: ProviderCredential = .apiKey(
    APIKeyCredential(key: "fixture-bearer", metadata: [:])
  )
) -> WireProtocolContext {
  let model = ProviderModel(
    id: "amazon.nova-lite-v1:0",
    providerID: "amazon-bedrock",
    name: "Nova Lite",
    protocolID: "bedrock-converse-stream",
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: true,
      reasoning: false,
      structuredOutput: false,
      imageGeneration: false
    ),
    contextWindow: 300_000,
    maximumOutputTokens: 8_192
  )
  return WireProtocolContext(
    provider: ProviderDescriptor(
      id: "amazon-bedrock",
      name: "Amazon Bedrock",
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com")!,
    headers: [
      "X-Fixture": "true",
      "X-Amz-Unsafe": "must-not-override",
      "Authorization": "must-not-override",
    ],
    credential: credential,
    modelConfiguration: ProviderModelConfiguration(
      protocolID: model.protocolID,
      baseURL: nil,
      headers: [:],
      metadata: [:]
    )
  )
}

private func bedrockReasoningContext() -> WireProtocolContext {
  let model = ProviderModel(
    id: "anthropic.claude-sonnet-4-6",
    providerID: "amazon-bedrock",
    name: "Claude Sonnet 4.6",
    protocolID: "bedrock-converse-stream",
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: true,
      reasoning: true,
      structuredOutput: false,
      imageGeneration: false
    ),
    contextWindow: 1_000_000,
    maximumOutputTokens: 64_000
  )
  return WireProtocolContext(
    provider: ProviderDescriptor(
      id: "amazon-bedrock",
      name: "Amazon Bedrock",
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com")!,
    headers: [:],
    credential: .apiKey(
      APIKeyCredential(key: "fixture-bearer", metadata: [:])
    ),
    modelConfiguration: ProviderModelConfiguration(
      protocolID: model.protocolID,
      baseURL: nil,
      headers: [:],
      metadata: [
        "thinkingLevelMap": .object(["max": .string("max")])
      ]
    )
  )
}

private func bedrockReasoningFrames() throws -> Data {
  let events: [(String, String)] = [
    ("messageStart", #"{"role":"assistant"}"#),
    (
      "contentBlockDelta",
      #"{"contentBlockIndex":0,"delta":{"reasoningContent":{"text":"inspect"}}}"#
    ),
    (
      "contentBlockDelta",
      #"{"contentBlockIndex":0,"delta":{"reasoningContent":{"signature":"opaque-signature"}}}"#
    ),
    ("messageStop", #"{"stopReason":"end_turn"}"#),
    ("metadata", #"{"usage":{"inputTokens":2,"outputTokens":3}}"#),
  ]
  return try events.reduce(into: Data()) { data, event in
    data.append(
      try AWSEventStreamDecoder.encode(
        headers: [
          ":message-type": "event",
          ":event-type": event.0,
          ":content-type": "application/json",
        ],
        payload: Data(event.1.utf8)
      )
    )
  }
}

private func bedrockFrames() throws -> Data {
  let events: [(String, String)] = [
    ("messageStart", #"{"role":"assistant"}"#),
    ("contentBlockStart", #"{"contentBlockIndex":0,"start":{}}"#),
    ("contentBlockDelta", #"{"contentBlockIndex":0,"delta":{"text":"Checking"}}"#),
    ("contentBlockStop", #"{"contentBlockIndex":0}"#),
    (
      "contentBlockStart",
      #"{"contentBlockIndex":1,"start":{"toolUse":{"toolUseId":"tool-1","name":"weather"}}}"#
    ),
    (
      "contentBlockDelta",
      #"{"contentBlockIndex":1,"delta":{"toolUse":{"input":"{\"city\":\"Tai"}}}"#
    ),
    (
      "contentBlockDelta",
      #"{"contentBlockIndex":1,"delta":{"toolUse":{"input":"pei\"}"}}}"#
    ),
    ("contentBlockStop", #"{"contentBlockIndex":1}"#),
    ("messageStop", #"{"stopReason":"tool_use"}"#),
    (
      "metadata",
      #"{"usage":{"inputTokens":12,"outputTokens":8,"cacheReadInputTokens":2,"totalTokens":20}}"#
    ),
  ]
  return try events.reduce(into: Data()) { data, event in
    data.append(
      try AWSEventStreamDecoder.encode(
        headers: [
          ":message-type": "event",
          ":event-type": event.0,
          ":content-type": "application/json",
        ],
        payload: Data(event.1.utf8)
      )
    )
  }
}
