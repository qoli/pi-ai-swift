import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ProviderVerticalSliceTests {
  @Test
  func everyCompletedAuthorizationProviderRoutesARealTextVerticalSlice() async throws {
    let excludedForLaterOAuthOrDynamicWork: Set<String> = [
      "anthropic", "github-copilot", "openrouter", "radius", "xai",
    ]
    let runtimeCatalog = try await BuiltinProviderRuntime(
      credentialStore: InMemoryProviderCredentialStore()
    ).catalog()
    let providerIDs = Set(runtimeCatalog.providers.map(\.id))
      .subtracting(excludedForLaterOAuthOrDynamicWork)
    #expect(providerIDs.count == 35)

    for providerID in providerIDs.sorted() {
      let provider = try #require(
        runtimeCatalog.providers.first { $0.id == providerID }
      )
      let model = try #require(
        provider.models.first {
          $0.capabilities.textInput && !$0.capabilities.imageGeneration
        } ?? provider.models.first { $0.capabilities.textInput }
      )
      let store = InMemoryProviderCredentialStore(
        credentials: [providerID: providerCredential(providerID)]
      )
      let transport = ProviderVerticalTransport()
      let runtime = try BuiltinProviderRuntime(
        credentialStore: store,
        streamingTransport: transport,
        authorizationTransport: ProviderVerticalUnusedHTTPTransport()
      )
      let request = ProviderRequest(
        id: "vertical-\(providerID)",
        providerID: providerID,
        modelID: model.id,
        messages: [.user([.text("reply with ok")])],
        tools: [],
        options: ProviderGenerationOptions(
          maximumOutputTokens: 32,
          temperature: nil,
          reasoningEffort: nil,
          responseSchema: nil,
          providerOptions: [:]
        )
      )
      var events: [ProviderEvent] = []
      for try await event in runtime.stream(request) { events.append(event) }
      #expect(
        events.contains { event in
          if case .responseStarted = event { return true }
          return false
        })
      #expect(events.contains(.completed(.stop)))
      let sent = try #require(await transport.request())
      #expect(sent.url?.scheme == "https")
      #expect(sent.url?.absoluteString.contains("{") == false)
      #expect(sent.httpMethod == "POST")
    }
  }
}

private func providerCredential(_ providerID: String) -> ProviderCredential {
  if providerID == "openai-codex" {
    return .oauth(
      OAuthCredential(
        accessToken: "fixture-access",
        refreshToken: "fixture-refresh",
        expiresAt: .distantFuture,
        metadata: ["accountID": "fixture-account"]
      )
    )
  }
  return .apiKey(
    APIKeyCredential(
      key: "fixture-key",
      metadata: [
        "baseURL": "https://fixture.openai.azure.com/openai/v1",
        "deploymentName": "fixture-deployment",
        "apiVersion": "v1",
        "CLOUDFLARE_ACCOUNT_ID": "fixture-account",
        "CLOUDFLARE_GATEWAY_ID": "fixture-gateway",
        "location": "us-central1",
        "projectID": "fixture-project",
      ]
    )
  )
}

private actor ProviderVerticalTransport: ProviderHTTPStreamingTransport {
  private var captured: URLRequest?

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    let fixture = try responseFixture(for: request)
    return ProviderHTTPStreamingResponse(
      statusCode: 200,
      headers: fixture.headers,
      body: AsyncThrowingStream { continuation in
        continuation.yield(fixture.body)
        continuation.finish()
      }
    )
  }

  func request() -> URLRequest? { captured }

  private func responseFixture(
    for request: URLRequest
  ) throws -> (headers: [String: String], body: Data) {
    if request.value(forHTTPHeaderField: "x-amzn-bedrock-accept") != nil {
      return (
        ["x-amzn-requestid": "vertical-bedrock"],
        try bedrockVerticalBody()
      )
    }
    if request.value(forHTTPHeaderField: "anthropic-version") != nil {
      return (
        [:],
        sse([
          #"{"type":"message_start","message":{"id":"vertical-anthropic","model":"fixture","usage":{"input_tokens":1,"output_tokens":0}}}"#,
          #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
          #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
          #"{"type":"content_block_stop","index":0}"#,
          #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
          #"{"type":"message_stop"}"#,
        ])
      )
    }
    if request.url?.absoluteString.contains("streamGenerateContent") == true {
      return (
        [:],
        sse([
          #"{"responseId":"vertical-google","candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1,"candidatesTokenCount":1,"totalTokenCount":2}}"#
        ])
      )
    }
    if request.url?.path.contains("conversations") == true {
      return (
        [:],
        sse(
          [
            #"{"id":"vertical-mistral","model":"fixture","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
          ], done: true)
      )
    }
    let body = try decodeJSONObject(
      request.httpBody ?? Data(),
      providerID: "vertical",
      operation: "vertical.decode"
    )
    if body["input"] != nil {
      return (
        [:],
        sse([
          #"{"type":"response.created","response":{"id":"vertical-response","model":"fixture"}}"#,
          #"{"type":"response.output_text.delta","delta":"ok"}"#,
          #"{"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}"#,
        ])
      )
    }
    return (
      [:],
      sse(
        [
          #"{"id":"vertical-chat","model":"fixture","choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
        ], done: true)
    )
  }

  private func sse(_ payloads: [String], done: Bool = false) -> Data {
    var values = payloads.map { "data: \($0)" }
    if done { values.append("data: [DONE]") }
    return Data((values.joined(separator: "\n\n") + "\n\n").utf8)
  }

  private func bedrockVerticalBody() throws -> Data {
    let events: [(String, String)] = [
      ("messageStart", #"{"role":"assistant"}"#),
      (
        "contentBlockDelta",
        #"{"contentBlockIndex":0,"delta":{"text":"ok"}}"#
      ),
      ("messageStop", #"{"stopReason":"end_turn"}"#),
      ("metadata", #"{"usage":{"inputTokens":1,"outputTokens":1}}"#),
    ]
    return try events.reduce(into: Data()) { result, event in
      result.append(
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
}

private struct ProviderVerticalUnusedHTTPTransport: ProviderHTTPTransport {
  func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
    throw ProviderRuntimeFailure(
      code: .transportFailed,
      message: "unused",
      providerID: nil,
      operation: "vertical.unused",
      causeDescription: nil
    )
  }
}
