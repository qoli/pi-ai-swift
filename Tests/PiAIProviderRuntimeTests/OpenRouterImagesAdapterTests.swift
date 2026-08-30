import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct OpenRouterImagesAdapterTests {
  @Test
  func encodesImageRequestAndNormalizesTextAssetsUsageAndTerminal() async throws {
    let response = Data(
      #"{"id":"image-response-1","model":"google/gemini-image","choices":[{"message":{"content":"created","images":[{"image_url":"data:image/png;base64,iVA="},{"image_url":{"url":"data:image/jpeg;base64,/9g="}},{"image_url":"https://example.invalid/not-returned"}]}}],"usage":{"prompt_tokens":10,"completion_tokens":4,"prompt_tokens_details":{"cached_tokens":3,"cache_write_tokens":1}}}"#
        .utf8
    )
    let transport = OpenRouterImageFixtureTransport(
      chunks: [Data(response.prefix(51)), Data(response.dropFirst(51))]
    )
    var events: [ProviderEvent] = []
    for try await event in OpenRouterImagesAdapter().stream(
      openRouterImageRequest(),
      context: openRouterImageContext(),
      transport: transport
    ) {
      events.append(event)
    }

    #expect(events.count == 6)
    #expect(events[1] == .textDelta("created"))
    guard case .asset(let first) = events[2], case .asset(let second) = events[3] else {
      Issue.record("expected two image assets")
      return
    }
    #expect(first.id == "image-response-1-image-0")
    #expect(first.mimeType == "image/png")
    #expect(first.data == Data([0x89, 0x50]))
    #expect(second.mimeType == "image/jpeg")
    #expect(second.data == Data([0xff, 0xd8]))
    #expect(
      events[4]
        == .usage(
          ProviderUsage(
            inputTokens: 7,
            outputTokens: 4,
            reasoningTokens: nil,
            cachedInputTokens: 2,
            providerMetadata: [
              "prompt_tokens": .integer(10),
              "completion_tokens": .integer(4),
              "prompt_tokens_details": .object([
                "cached_tokens": .integer(3),
                "cache_write_tokens": .integer(1),
              ]),
            ]
          )
        )
    )
    #expect(events[5] == .completed(.stop))

    let sent = try #require(await transport.request())
    #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(body.array("modalities") == [.string("image"), .string("text")])
    #expect(body.bool("stream") == false)
    #expect(body.object("provider")?.array("order") == [.string("google")])
    let content = body.array("messages")?.first?.objectValue?.array("content")
    #expect(content?.count == 2)
    #expect(
      content?[1].objectValue?.object("image_url")?.string("url")
        == "data:image/png;base64,AQI="
    )
  }

  @Test
  func rejectsConversationShapeReservedOverridesAndMalformedImageBytes() async {
    let adapter = OpenRouterImagesAdapter()
    var request = openRouterImageRequest(messages: [.system("not an image input")])
    await expectOpenRouterImageFailure(
      adapter,
      request: request,
      context: openRouterImageContext(),
      transport: OpenRouterImageFixtureTransport(chunks: []),
      code: .invalidRequest
    )

    request = openRouterImageRequest(providerOptions: ["model": .string("override")])
    await expectOpenRouterImageFailure(
      adapter,
      request: request,
      context: openRouterImageContext(),
      transport: OpenRouterImageFixtureTransport(chunks: []),
      code: .invalidRequest
    )

    let malformed = Data(
      #"{"id":"bad-image","choices":[{"message":{"images":[{"image_url":"data:image/png;base64,%%%"}]}}]}"#
        .utf8
    )
    request = openRouterImageRequest()
    await expectOpenRouterImageFailure(
      adapter,
      request: request,
      context: openRouterImageContext(),
      transport: OpenRouterImageFixtureTransport(chunks: [malformed]),
      code: .invalidResponse
    )
  }

  @Test
  func imageOnlyModelRequestsOnlyImageModality() async throws {
    let response = Data(
      #"{"id":"image-only-response","choices":[{"message":{"content":null,"images":[]}}]}"#
        .utf8
    )
    let transport = OpenRouterImageFixtureTransport(chunks: [response])
    for try await _ in OpenRouterImagesAdapter().stream(
      openRouterImageRequest(),
      context: openRouterImageContext(output: ["image"]),
      transport: transport
    ) {}

    let sent = try #require(await transport.request())
    let body = try decodeJSONObject(
      try #require(sent.httpBody),
      providerID: "fixture",
      operation: "fixture"
    )
    #expect(body.array("modalities") == [.string("image")])
  }
}

private actor OpenRouterImageFixtureTransport: ProviderHTTPStreamingTransport {
  private let chunks: [Data]
  private var captured: URLRequest?

  init<S: Sequence>(chunks: S) where S.Element == Data {
    self.chunks = Array(chunks)
  }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    let chunks = chunks
    return ProviderHTTPStreamingResponse(
      statusCode: 200,
      headers: [:],
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      }
    )
  }

  func request() -> URLRequest? { captured }
}

private func openRouterImageRequest(
  messages: [ProviderMessage] = [
    .user([.text("draw a mark"), .image(.data(Data([1, 2]), mimeType: "image/png"))])
  ],
  providerOptions: [String: JSONValue] = [
    "provider": .object(["order": .array([.string("google")])])
  ]
) -> ProviderRequest {
  ProviderRequest(
    id: "image-request",
    providerID: "openrouter",
    modelID: "google/gemini-image",
    messages: messages,
    tools: [],
    options: ProviderGenerationOptions(
      maximumOutputTokens: nil,
      temperature: nil,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: providerOptions
    )
  )
}

private func openRouterImageContext(
  output: [String] = ["text", "image"]
) -> WireProtocolContext {
  let model = ProviderModel(
    id: "google/gemini-image",
    providerID: "openrouter",
    name: "Gemini Image",
    protocolID: "openrouter-images",
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: false,
      reasoning: false,
      structuredOutput: false,
      imageGeneration: true
    ),
    contextWindow: nil,
    maximumOutputTokens: nil
  )
  return WireProtocolContext(
    provider: ProviderDescriptor(
      id: "openrouter",
      name: "OpenRouter",
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: URL(string: "https://openrouter.ai/api/v1")!,
    headers: [:],
    credential: .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:])),
    modelConfiguration: ProviderModelConfiguration(
      baseURL: nil,
      headers: [:],
      metadata: ["output": .array(output.map(JSONValue.string))]
    )
  )
}

private func expectOpenRouterImageFailure(
  _ adapter: OpenRouterImagesAdapter,
  request: ProviderRequest,
  context: WireProtocolContext,
  transport: OpenRouterImageFixtureTransport,
  code: ProviderRuntimeFailure.Code
) async {
  do {
    for try await _ in adapter.stream(request, context: context, transport: transport) {}
    Issue.record("expected OpenRouter image failure")
  } catch let error as ProviderRuntimeFailure {
    #expect(error.code == code)
  } catch {
    Issue.record("unexpected error: \(error)")
  }
}
