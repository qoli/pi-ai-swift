import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ProviderVerticalSliceTests {
  @Test
  func everyCompletedAuthorizationProviderRoutesARealTextVerticalSlice() async throws {
    let excludedForLaterOAuthOrDynamicWork: Set<String> = [
      "anthropic", "github-copilot", "openrouter", "radius", "xai", "typesafe",
    ]
    let runtimeCatalog = try await BuiltinProviderRuntime(
      installation: .init(deviceID: nil),
      credentialStore: InMemoryProviderCredentialStore()
    ).catalog()
    let providerIDs = Set(runtimeCatalog.providers.map(\.id))
      .subtracting(excludedForLaterOAuthOrDynamicWork)
    #expect(providerIDs.count == 36)

    for providerID in providerIDs.sorted() {
      let provider = try #require(
        runtimeCatalog.providers.first { $0.id == providerID }
      )
      let model = try #require(
        provider.models.first {
          $0.capabilities.textInput && !$0.capabilities.imageGeneration
            && !ProviderClassifierAdapter.protocolIDs.contains($0.protocolID)
        } ?? provider.models.first { $0.capabilities.textInput }
      )
      let store = InMemoryProviderCredentialStore(
        credentials: [providerID: providerCredential(providerID)]
      )
      let transport = ProviderVerticalTransport()
      let runtime = try BuiltinProviderRuntime(
        installation: .init(deviceID: nil),
        credentialStore: store,
        streamingTransport: transport,
        authorizationTransport: ProviderVerticalUnusedHTTPTransport(),
        webSocketTransport: ProviderVerticalUnavailableWebSocketTransport()
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
        ),
        connectionOptions: providerID == "azure"
          ? ProviderConnectionOptions(
            azureOpenAIResponses: AzureOpenAIResponsesConnectionOptions(
              azureBaseURL: "https://fixture.openai.azure.com/openai/v1",
              azureAPIVersion: "v1",
              azureDeploymentName: "fixture-deployment"))
          : .init()
      )
      var events: [ProviderEvent] = []
      for try await event in runtime.stream(request) { events.append(event) }
      #expect(
        events.contains { event in
          if case .responseStarted = event { return true }
          return false
        })
      #expect(events.contains(.completed(.stop)))
      #expect(events.contains(.textDelta("ok")), Comment(rawValue: providerID))
      let sent = try #require(await transport.request())
      #expect(sent.url?.scheme == "https")
      #expect(sent.url?.absoluteString.contains("{") == false)
      #expect(sent.httpMethod == "POST")
    }
  }
}

private struct ProviderVerticalUnavailableWebSocketTransport: ProviderWebSocketTransport {
  func connect(_ request: URLRequest) async throws -> any ProviderWebSocketConnection {
    throw URLError(.notConnectedToInternet)
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
        sse(
          [
            #"{"type":"message_start","message":{"id":"vertical-anthropic","model":"fixture","usage":{"input_tokens":1,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
            #"{"type":"message_stop"}"#,
          ], named: true)
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
      try fixtureHTTPBody(request),
      providerID: "vertical",
      operation: "vertical.decode"
    )
    if body["input"] != nil {
      return (
        [:],
        sse([
          #"{"type":"response.created","response":{"id":"vertical-response","model":"fixture"}}"#,
          #"{"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"vertical-message","role":"assistant","status":"in_progress","content":[]}}"#,
          #"{"type":"response.output_text.delta","output_index":0,"item_id":"vertical-message","content_index":0,"delta":"ok"}"#,
          #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"vertical-message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"ok","annotations":[]}]}}"#,
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

  private func sse(_ payloads: [String], done: Bool = false, named: Bool = false) -> Data {
    var values = payloads.map { payload in
      let prefix: String
      if named {
        let object = try! JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        prefix = "event: \(object.objectValue!.string("type")!)\n"
      } else {
        prefix = ""
      }
      return "\(prefix)data: \(payload)"
    }
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
