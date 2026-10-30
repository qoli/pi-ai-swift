import Foundation
import XCTest

@testable import PiAIProviderRuntime

@MainActor
final class ProviderRuntimeConformanceTests: XCTestCase {
  func testCompletionsTerminationMatchesPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    let cases = try XCTUnwrap(fixture.object("completionTransportCases"))
    let expectedCases = try XCTUnwrap(
      oracle.object("cases")?.object("completions.transport-termination"))
    for name in cases.keys.sorted() {
      let spec = try XCTUnwrap(cases[name]?.objectValue)
      let expected = try XCTUnwrap(expectedCases[name]?.objectValue?.object("output"))
      let (request, context) = inputs(
        api: "openai-completions",
        metadata: [
          "compat": .object(["supportsFinishReason": try XCTUnwrap(spec["supportsFinishReason"])])
        ])
      let result = try await replay(
        OpenAICompletionsAdapter(), request: request, context: context,
        chunks: [Data(try XCTUnwrap(spec.string("sse")).utf8)])
      XCTAssertEqual(result.starts, 1, name)
      if expected.string("stopReason") == "error" {
        XCTAssertEqual(result.failure?.message, expected.string("errorMessage"), name)
        XCTAssertNil(result.snapshot, name)
      } else {
        XCTAssertNil(result.failure, name)
        let snapshot = try XCTUnwrap(result.snapshot, name)
        XCTAssertEqual(snapshot.finishReason, .stop, name)
        XCTAssertEqual(snapshot.rawFinishReason, expected.string("rawStopReason"), name)
        XCTAssertEqual(snapshot.responseID, expected.string("responseId"), name)
        XCTAssertEqual(content(snapshot), expected.array("content"), name)
        XCTAssertEqual(
          snapshot.usage?.totalTokens, expected.object("usage")?.int("totalTokens"), name)
      }
    }
  }

  func testAnthropicSSEMatchesPinnedSource() async throws {
    let oracle = try load("Differential/Oracle/response-anthropic-bedrock-pi.json")
    let cases = try XCTUnwrap(oracle.object("scenarios"))
    for name in [
      "anthropic-ignored-sse-envelopes", "anthropic-repaired-sse-tool",
      "anthropic-raw-error", "anthropic-error-event",
    ] {
      let spec = try XCTUnwrap(cases[name]?.objectValue)
      let decoder = try XCTUnwrap(spec.object("decoderInput"))
      let expected = try XCTUnwrap(spec.object("terminal"))
      let chunks = try XCTUnwrap(decoder.array("chunksBase64")).map {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap($0.stringValue)))
      }
      let (request, context) = inputs(api: "anthropic-messages")
      let result = try await replay(
        AnthropicMessagesAdapter(), request: request, context: context, chunks: chunks)
      if spec.string("outcome") == "failure" {
        XCTAssertEqual(result.failure?.code, .transportFailed, name)
        XCTAssertEqual(result.failure?.message, expected.string("errorMessage"), name)
      } else {
        XCTAssertNil(result.failure, name)
        let snapshot = try XCTUnwrap(result.snapshot, name)
        XCTAssertEqual(snapshot.responseID, expected.string("responseID"), name)
        XCTAssertEqual(content(snapshot), expected.array("content"), name)
        XCTAssertEqual(
          snapshot.usage?.totalTokens, expected.object("usage")?.int("totalTokens"), name)
      }
    }
  }

  func testMistralHTTPMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/mistral-http.json")
    let oracle = try load("Differential/Oracle/mistral-http.json")
    for item in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(item.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      let expected = try XCTUnwrap(oracle.object("cases")?.object(name))
      let (request, context) = inputs(
        api: "mistral-conversations",
        headers: (spec.object("modelHeaders") ?? [:]).compactMapValues(\.stringValue),
        options: .init(
          maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: ["headers": .object(spec.object("headers") ?? [:])],
          sessionID: spec.string("sessionId"),
          cacheRetention: spec.string("cacheRetention").flatMap(
            ProviderCacheRetention.init(rawValue:)) ?? .short))
      let transport = IOSMistralHTTPFixture(
        status: try XCTUnwrap(spec.int("status")),
        body: Data(try XCTUnwrap(spec.string("body")).utf8))
      do {
        for try await _ in MistralConversationsAdapter().stream(
          request, context: context, transport: transport)
        {}
        XCTFail("expected fixture HTTP failure: \(name)")
      } catch let failure as ProviderRuntimeFailure {
        XCTAssertEqual(failure.code, .transportFailed, name)
        XCTAssertEqual(failure.message, expected.string("errorMessage"), name)
      }
      let captured = await transport.sent
      let sent = try XCTUnwrap(captured)
      let actual = Dictionary(
        uniqueKeysWithValues: (sent.allHTTPHeaderFields ?? [:]).map {
          ($0.key.lowercased(), JSONValue.string($0.value))
        })
      XCTAssertEqual(actual, expected.object("headers"), name)
    }
  }

  func testMistralHeaderTimeoutMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/mistral-timeout.json")
    let oracle = try load("Differential/Oracle/mistral-timeout.json")
    for item in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(item.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      let expected = try XCTUnwrap(oracle.object("cases")?.object(name))
      let (request, context) = inputs(
        api: "mistral-conversations",
        options: .init(
          maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: ["timeoutMs": try XCTUnwrap(spec["timeoutMs"])]))
      let transport = IOSMistralTimeoutFixture(spec: spec)
      var snapshot: ProviderResponseSnapshot?
      var failure: ProviderRuntimeFailure?
      do {
        for try await event in MistralConversationsAdapter().stream(
          request, context: context, transport: transport)
        {
          if case .responseSnapshot(let value) = event { snapshot = value }
        }
      } catch let error as ProviderRuntimeFailure {
        failure = error
      }
      let requested = await transport.requested
      XCTAssertEqual(requested, expected.bool("requested"), name)
      if expected.bool("requested") == false {
        XCTAssertEqual(failure?.code, .invalidRequest, name)
      } else if expected.string("stopReason") == "error" {
        XCTAssertEqual(failure?.message, expected.string("errorMessage"), name)
        XCTAssertNil(snapshot)
      } else {
        XCTAssertNil(failure, name)
        XCTAssertEqual(snapshot?.finishReason, .stop, name)
        let reasoning = snapshot?.content.compactMap { content -> String? in
          guard case .reasoning(let value) = content else { return nil }
          return value.text
        }.joined()
        XCTAssertEqual(reasoning, expected.string("reasoning"), name)
      }
    }
  }

  func testResponsesToolSlotsMatchPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    let cases = try XCTUnwrap(fixture.object("responseToolSlotEvents"))
    let expectedCases = try XCTUnwrap(
      oracle.object("cases")?.object("responses.tool-slot-lifecycle"))
    for api in ["openai-responses", "azure-openai-responses", "openai-codex-responses"] {
      for name in cases.keys.sorted() {
        let expected = try XCTUnwrap(expectedCases[name]?.objectValue)
        let events = try XCTUnwrap(cases[name]?.arrayValue)
        let chunks = try events.map { value in
          let data = try JSONEncoder().encode(value)
          return Data(("data: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8)
        }
        let (request, context) = inputs(api: api)
        let adapter = OpenAIResponsesAdapter(
          protocolID: api,
          flavor: api == "azure-openai-responses"
            ? .azure : (api == "openai-codex-responses" ? .codex : .standard))
        let result = try await replay(
          adapter, request: request, context: context, chunks: chunks)
        if let thrown = expected.string("thrown") {
          XCTAssertEqual(result.failure?.message, thrown, "\(api):\(name)")
          XCTAssertNil(result.snapshot, "\(api):\(name)")
        } else {
          XCTAssertNil(result.failure, "\(api):\(name)")
          XCTAssertEqual(
            content(try XCTUnwrap(result.snapshot, "\(api):\(name)")),
            expected.array("content"), "\(api):\(name)")
        }
      }
    }
  }

  func testGrammarHistoryMapMatchesPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let replay = try XCTUnwrap(fixture.object("responsesGrammarReplay"))
    let source = try XCTUnwrap(replay.object("source"))
    let call = try XCTUnwrap(replay.object("call"))
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    let expectedCases = try XCTUnwrap(
      oracle.object("cases")?.object("responses.grammar-history-replay"))
    for (name, value) in try XCTUnwrap(replay.object("cases")) {
      let spec = try XCTUnwrap(value.objectValue)
      let target = try XCTUnwrap(spec.object("target"))
      let api = try XCTUnwrap(target.string("api"))
      let (baseRequest, context) = inputs(
        api: api,
        providerID: target.string("provider"), modelID: try XCTUnwrap(target.string("id")))
      let toolCall = ProviderToolCall(
        id: try XCTUnwrap(call.string("id")), name: try XCTUnwrap(call.string("name")),
        arguments: try XCTUnwrap(spec["arguments"]), namespace: call.string("namespace"))
      let request = ProviderRequest(
        id: name, providerID: baseRequest.providerID, modelID: baseRequest.modelID,
        messages: [
          .assistantMessage(
            .init(
              content: [.toolCall(toolCall)],
              source: .init(
                api: try XCTUnwrap(source.string("api")),
                providerID: try XCTUnwrap(source.string("provider")),
                modelID: try XCTUnwrap(source.string("model"))),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: 0,
                cachedInputTokens: 0, providerMetadata: [:]),
              stopReason: .toolUse, timestampMilliseconds: 0)),
          .toolResult(
            .init(
              toolCallID: toolCall.id, toolName: toolCall.name,
              content: [.text(try XCTUnwrap(replay.string("result")))], isError: false)),
        ], tools: [],
        options: .init(
          maximumOutputTokens: 64, temperature: nil,
          reasoningEffort: nil, responseSchema: nil,
          providerOptions: [
            "grammarToolInputProperties": try XCTUnwrap(spec["grammarToolInputProperties"])
          ]))
      let adapter = OpenAIResponsesAdapter(
        protocolID: api,
        flavor: api == "azure-openai-responses"
          ? .azure : api == "openai-codex-responses" ? .codex : .standard)
      let transport = IOSMistralHTTPFixture(status: 418, body: Data())
      var failure: ProviderRuntimeFailure?
      do {
        for try await _ in adapter.stream(request, context: context, transport: transport) {}
      } catch let error as ProviderRuntimeFailure { failure = error }
      let sent = await transport.sent
      let expected = try XCTUnwrap(expectedCases.object(name))
      if let thrown = expected.string("thrown") {
        XCTAssertNil(sent, name)
        XCTAssertEqual(failure?.message, thrown, name)
      } else {
        let body = try decodeJSONObject(
          try XCTUnwrap(sent?.httpBody),
          providerID: "fixture", operation: "ios.grammar-history.body")
        XCTAssertEqual(body.array("input"), expected.array("input"), name)
        XCTAssertNil(body["grammarToolInputProperties"], name)
        XCTAssertNil(body["tools"], name)
      }
    }
  }

  func testCompletionsTemplateEffortsAndBudgetsMatchPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/request-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/request-branches.json")
    for value in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(value.objectValue)
      guard let name = spec.string("id"), name.hasPrefix("completions.template-") else { continue }
      let metadata: [String: JSONValue] = [
        "compat": try XCTUnwrap(spec["compat"]),
        "thinkingLevelMap": try XCTUnwrap(spec["thinkingLevelMap"]),
      ]
      let expected = try XCTUnwrap(oracle.object("cases")?.object(name))
      let levels = try ProviderReasoning.supportedEfforts(
        reasoning: true, metadata: metadata, protocolID: "openai-completions", providerID: "fixture"
      )
      XCTAssertEqual(
        levels.map { JSONValue.string($0.rawValue) }, expected.array("supportedThinkingLevels"),
        name)
      let rawOptions = try XCTUnwrap(spec.object("options"))
      let budgets = rawOptions.object("thinkingBudgets").map { raw in
        Dictionary(
          uniqueKeysWithValues: raw.compactMap { key, value -> (ProviderReasoningEffort, Int)? in
            guard let effort = ProviderReasoningEffort(rawValue: key),
              case .integer(let count) = value
            else { return nil }
            return (effort, Int(count))
          })
      }
      let (request, context) = inputs(
        api: "openai-completions", providerID: "fixture",
        modelID: "template-model", metadata: metadata,
        options: .init(
          maximumOutputTokens: rawOptions.int("maxTokens"), temperature: nil,
          reasoningEffort: rawOptions.string("reasoningEffort").flatMap(
            ProviderReasoningEffort.init(rawValue:)),
          responseSchema: nil, providerOptions: [:], thinkingBudgets: budgets))
      let transport = IOSMistralHTTPFixture(status: 418, body: Data())
      do {
        for try await _ in OpenAICompletionsAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch let failure as ProviderRuntimeFailure {
        XCTAssertEqual(failure.code, .transportFailed, name)
      }
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name),
        providerID: "fixture", operation: "ios.template.body")
      let projection = Dictionary(
        uniqueKeysWithValues:
          try XCTUnwrap(spec.array("projectFields")).compactMap { value -> (String, JSONValue)? in
            guard let key = value.stringValue, let value = body[key] else { return nil }
            return (key, value)
          })
      XCTAssertEqual(projection, expected.object("requestBody"), name)
    }
  }

  func testCompletionsDetectedCompatibilityMatchesPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/completions-compat.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/completions-compat.json")
    for value in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(value.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      let rawOptions = try XCTUnwrap(spec.object("options"))
      let (baseRequest, context) = inputs(
        api: "openai-completions",
        providerID: try XCTUnwrap(spec.string("providerID")),
        modelID: try XCTUnwrap(spec.string("modelID")),
        baseURL: try XCTUnwrap(spec.string("baseURL")),
        metadata: ["compat": try XCTUnwrap(spec["compat"])],
        options: .init(
          maximumOutputTokens: rawOptions.int("maxTokens"), temperature: nil,
          reasoningEffort: .low, responseSchema: nil, providerOptions: [:],
          sessionID: rawOptions.string("sessionId"), cacheRetention: .long))
      let request = ProviderRequest(
        id: name, providerID: baseRequest.providerID,
        modelID: baseRequest.modelID,
        messages: [.system("System branch fixture"), .user([.text("hello")])],
        tools: [
          .init(
            name: "sample_tool", description: "Sample tool",
            inputSchema: .object([
              "type": .string("object"),
              "properties": .object(["payload": .object(["type": .string("string")])]),
              "required": .array([.string("payload")]),
            ]))
        ],
        options: baseRequest.options)
      let transport = IOSMistralHTTPFixture(status: 418, body: Data())
      do {
        for try await _ in OpenAICompletionsAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch let failure as ProviderRuntimeFailure {
        XCTAssertEqual(failure.code, .transportFailed, name)
      }
      let sentRequest = await transport.sent
      let sent = try XCTUnwrap(sentRequest, name)
      let body = try decodeJSONObject(
        try XCTUnwrap(sent.httpBody, name),
        providerID: "fixture", operation: "ios.completions.compat.body")
      let projected = Dictionary(
        uniqueKeysWithValues:
          try XCTUnwrap(spec.array("projectFields")).compactMap { value -> (String, JSONValue)? in
            guard let key = value.stringValue, let value = body[key] else { return nil }
            return (key, value)
          })
      let headers = Dictionary(
        uniqueKeysWithValues:
          try XCTUnwrap(spec.array("headerKeys")).map { value -> (String, JSONValue) in
            let key = try XCTUnwrap(value.stringValue)
            return (key, sent.value(forHTTPHeaderField: key).map(JSONValue.string) ?? .null)
          })
      let expected = try XCTUnwrap(oracle.object("cases")?.object(name))
      XCTAssertEqual(projected, expected.object("requestBody"), name)
      XCTAssertEqual(headers, expected.object("requestHeaders"), name)
    }
  }

  func testMistralRawAndLogicalOptionsMatchPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/mistral-request-options.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/mistral-request-options.json")
    for value in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(value.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      let raw = spec.string("entrypoint") == "stream"
      let options = try XCTUnwrap(spec.object("options"))
      var metadata: [String: JSONValue] = [:]
      metadata["thinkingLevelMap"] = spec["thinkingLevelMap"]
      var providerOptions: [String: JSONValue] =
        raw ? ["reasoningEffort": options["reasoningEffort"] ?? .null] : [:]
      if let promptMode = options["promptMode"] { providerOptions["promptMode"] = promptMode }
      let (request, context) = inputs(
        api: "mistral-conversations", reasoning: spec.bool("reasoning"),
        metadata: metadata,
        options: .init(
          maximumOutputTokens: nil, temperature: nil,
          reasoningEffort: raw
            ? nil : options.string("reasoning").flatMap(ProviderReasoningEffort.init(rawValue:)),
          responseSchema: nil, providerOptions: providerOptions))
      let transport = IOSMistralHTTPFixture(status: 418, body: Data("fixture".utf8))
      do {
        for try await _ in MistralConversationsAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch let failure as ProviderRuntimeFailure {
        XCTAssertEqual(failure.code, .transportFailed, name)
      }
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name),
        providerID: "fixture", operation: "ios.mistral.options.body")
      let projected = Dictionary(
        uniqueKeysWithValues:
          try XCTUnwrap(spec.array("projectFields")).compactMap { value -> (String, JSONValue)? in
            guard let key = value.stringValue, let value = body[key] else { return nil }
            return (key, value)
          })
      XCTAssertEqual(projected, oracle.object("cases")?.object(name)?.object("requestBody"), name)
    }
  }

  func testCompletionsFailureMetadataMatchesPinnedSource() async throws {
    let legacy = Data(#"{"code":"transportFailed","message":"fixture error"}"#.utf8)
    XCTAssertNil(
      try JSONDecoder().decode(ProviderRuntimeFailure.self, from: legacy).providerMetadata)
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let branches = try XCTUnwrap(fixture.object("completionBranchChunks"))
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    let expectedCases = try XCTUnwrap(
      oracle.object("cases")?.object("completions.stop-reason-response-branches"))
    for name in [
      "contentFilter", "networkError", "unknownFinish", "lateErrorMetadata", "emptyFinish",
      "endAlias",
    ] {
      let expected = try XCTUnwrap(expectedCases.object(name))
      let chunks =
        try XCTUnwrap(branches[name]?.arrayValue).map { event in
          Data(
            ("data: " + String(decoding: try JSONEncoder().encode(event), as: UTF8.self) + "\n\n")
              .utf8)
        } + [Data("data: [DONE]\n\n".utf8)]
      let (request, context) = inputs(api: "openai-completions")
      let result = try await replay(
        OpenAICompletionsAdapter(), request: request,
        context: context, chunks: chunks)
      if expected.string("stopReason") == "error" {
        let failure = try XCTUnwrap(result.failure, name)
        XCTAssertNil(result.snapshot, name)
        XCTAssertEqual(failure.message, expected.string("errorMessage"), name)
        XCTAssertEqual(
          failure.providerMetadata?.string("rawStopReason"), expected.string("rawStopReason"), name)
        XCTAssertEqual(
          failure.providerMetadata?.string("responseId"), expected.string("responseId"), name)
        XCTAssertEqual(
          failure.providerMetadata?.string("responseModel"), expected.string("responseModel"), name)
      } else {
        XCTAssertNil(result.failure, name)
        XCTAssertEqual(result.snapshot?.finishReason.rawValue, expected.string("stopReason"), name)
        XCTAssertEqual(result.snapshot?.rawFinishReason, expected.string("rawStopReason"), name)
      }
    }
  }

  func testGoogleFailureMetadataMatchesPinnedSource() async throws {
    let oracle = try load("Differential/Oracle/failure-provider-declared.json")
    for api in ["google-generative-ai", "google-vertex"] {
      let source = try XCTUnwrap(oracle.object("protocols")?.object(api))
      let decoder = try XCTUnwrap(source.object("decoderInput"))
      let body = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(decoder.string("rawBodyBase64"))))
      let (request, context) = inputs(
        api: api, providerID: api == "google-vertex" ? "google-vertex" : "google")
      let result = try await replay(
        GoogleGenerativeAIAdapter(
          protocolID: api,
          flavor: api == "google-vertex" ? .vertex : .generativeAI),
        request: request, context: context, chunks: [body])
      XCTAssertEqual(result.failure?.code, .transportFailed, api)
      XCTAssertEqual(result.failure?.message, source.string("sourceErrorMessage"), api)
      XCTAssertEqual(
        result.failure?.providerMetadata?.string("rawStopReason"), source.string("rawStopReason"),
        api)
      XCTAssertNil(result.snapshot, api)
    }
  }

  func testBedrockFailureMetadataMatchesPinnedSource() async throws {
    let oracle = try load("Differential/Oracle/response-anthropic-bedrock-pi.json")
    let source = try XCTUnwrap(oracle.object("scenarios")?.object("bedrock-provider-stop-error"))
    let decoder = try XCTUnwrap(source.object("decoderInput"))
    let chunks = try XCTUnwrap(decoder.array("chunksBase64")).map {
      try XCTUnwrap(Data(base64Encoded: try XCTUnwrap($0.stringValue)))
    }
    let (request, context) = inputs(api: "bedrock-converse-stream", providerID: "amazon-bedrock")
    let result = try await replay(
      BedrockConverseStreamAdapter(), request: request,
      context: context, chunks: chunks)
    let expected = try XCTUnwrap(source.object("terminal"))
    XCTAssertEqual(result.failure?.code, .transportFailed)
    XCTAssertEqual(result.failure?.message, expected.string("errorMessage"))
    XCTAssertEqual(
      result.failure?.providerMetadata?.string("rawStopReason"), expected.string("rawStopReason"))
    XCTAssertNil(result.snapshot)
  }

  func testResponsesFailureMetadataMatchesPinnedSource() async throws {
    let oracle = try load("Differential/Oracle/failure-provider-declared.json")
    for api in ["openai-responses", "azure-openai-responses", "openai-codex-responses"] {
      let source = try XCTUnwrap(oracle.object("protocols")?.object(api))
      let decoder = try XCTUnwrap(source.object("decoderInput"))
      let body = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(decoder.string("rawBodyBase64"))))
      let (request, context) = inputs(api: api)
      let result = try await replay(
        OpenAIResponsesAdapter(
          protocolID: api,
          flavor: api == "azure-openai-responses"
            ? .azure : api == "openai-codex-responses" ? .codex : .standard),
        request: request, context: context, chunks: [body])
      XCTAssertEqual(result.failure?.code, .transportFailed, api)
      if let message = source.string("sourceErrorMessage") {
        XCTAssertEqual(result.failure?.message, message, api)
      }
      XCTAssertEqual(
        result.failure?.providerMetadata?.string("rawStopReason"), source.string("rawStopReason"),
        api)
      XCTAssertNil(result.snapshot, api)
    }
  }

  func testResponsesTerminalStatusesMatchPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    let cases = try XCTUnwrap(fixture.object("responsesTerminalStatusEvents"))
    let expectedCases = try XCTUnwrap(oracle.object("cases")?.object("responses.terminal-status"))
    for api in ["openai-responses", "azure-openai-responses"] {
      for name in cases.keys.sorted() {
        let expected = try XCTUnwrap(expectedCases.object(name))
        let chunks = try XCTUnwrap(cases.array(name)).map { event in
          Data(
            ("data: " + String(decoding: try JSONEncoder().encode(event), as: UTF8.self) + "\n\n")
              .utf8)
        }
        let (request, context) = inputs(api: api)
        let result = try await replay(
          OpenAIResponsesAdapter(
            protocolID: api, flavor: api == "azure-openai-responses" ? .azure : .standard),
          request: request, context: context, chunks: chunks)
        if let thrown = expected.string("thrown") {
          XCTAssertEqual(result.failure?.message, thrown, name)
          XCTAssertNil(result.snapshot, name)
        } else {
          XCTAssertNil(result.failure, name)
          let snapshot = try XCTUnwrap(result.snapshot, name)
          XCTAssertEqual(snapshot.finishReason.rawValue, expected.string("stopReason"), name)
          XCTAssertEqual(snapshot.rawFinishReason, expected.string("rawStopReason"), name)
          XCTAssertEqual(
            snapshot.providerMetadata.string("errorMessage"), expected.string("errorMessage"), name)
          XCTAssertEqual(snapshot.responseID, expected.string("responseId"), name)
          XCTAssertEqual(snapshot.usage?.inputTokens, expected.object("usage")?.int("input"), name)
          XCTAssertEqual(
            snapshot.usage?.outputTokens, expected.object("usage")?.int("output"), name)
          XCTAssertEqual(
            snapshot.usage?.reasoningTokens, expected.object("usage")?.int("reasoning"), name)
          XCTAssertEqual(
            snapshot.usage?.totalTokens, expected.object("usage")?.int("totalTokens"), name)
        }
      }
    }
  }

  func testMistralFailureMetadataMatchesPinnedSource() async throws {
    let oracle = try load("Differential/Oracle/failure-provider-declared.json")
    let source = try XCTUnwrap(oracle.object("protocols")?.object("mistral-conversations"))
    let decoder = try XCTUnwrap(source.object("decoderInput"))
    let body = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(decoder.string("rawBodyBase64"))))
    let (request, context) = inputs(api: "mistral-conversations")
    let result = try await replay(
      MistralConversationsAdapter(), request: request,
      context: context, chunks: [body])
    XCTAssertEqual(result.failure?.code, .transportFailed)
    XCTAssertEqual(result.failure?.message, source.string("sourceErrorMessage"))
    XCTAssertEqual(
      result.failure?.providerMetadata?.string("rawStopReason"), source.string("rawStopReason"))
    XCTAssertNil(result.snapshot)
    let branches = try load("Differential/Oracle/response-provider-branches.json")
    let unknown = try XCTUnwrap(
      branches.object("cases")?.object("mistral-unknown-stop")?.object("mistral-conversations"))
    let chunks = try XCTUnwrap(unknown.object("decoderInput")?.array("events")).map { event in
      Data(
        ("data: " + String(decoding: try JSONEncoder().encode(event), as: UTF8.self) + "\n\n").utf8)
    }
    let unknownResult = try await replay(
      MistralConversationsAdapter(), request: request,
      context: context, chunks: chunks)
    let expected = try XCTUnwrap(unknown.object("sourceOutcome"))
    XCTAssertEqual(unknownResult.failure?.code, .transportFailed)
    XCTAssertEqual(unknownResult.failure?.message, expected.string("errorMessage"))
    XCTAssertEqual(
      unknownResult.failure?.providerMetadata?.string("rawStopReason"),
      expected.string("rawStopReason"))
    XCTAssertNil(unknownResult.snapshot)
  }

  func testSignatureReplayMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("replay-signature.") == true }
    XCTAssertEqual(cases.count, 34)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let model = try XCTUnwrap(spec.object("model"))
      let api = try XCTUnwrap(model.string("api"))
      let provider = try XCTUnwrap(model.string("provider"))
      let modelID = try XCTUnwrap(model.string("id"))
      let blocks: [ProviderAssistantContent] = try XCTUnwrap(spec.array("assistantContent")).map {
        value in
        let block = try XCTUnwrap(value.objectValue)
        if block.string("type") == "toolCall" {
          return .toolCall(
            .init(
              id: try XCTUnwrap(block.string("id")), name: try XCTUnwrap(block.string("name")),
              arguments: try XCTUnwrap(block["arguments"]),
              thoughtSignature: block.string("thoughtSignature")))
        }
        if block.string("type") == "thinking" {
          return .reasoning(
            .init(
              text: block.string("thinking") ?? "", signature: block.string("thinkingSignature"),
              providerMetadata: [:]))
        }
        return .signedText(
          .init(text: block.string("text") ?? "", signature: block.string("textSignature")))
      }
      let (_, context) = inputs(
        api: api, providerID: provider, modelID: modelID,
        reasoning: true, metadata: model)
      let request = ProviderRequest(
        id: name, providerID: provider, modelID: modelID,
        messages: [
          .user([.text("hello")]),
          .assistantMessage(
            .init(
              content: blocks,
              source: .init(
                api: api, providerID: provider,
                modelID: spec.object("assistantSource")?.string("model") ?? modelID),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: nil, cachedInputTokens: 0,
                providerMetadata: [:]),
              stopReason: .stop, timestampMilliseconds: 1,
              providerMetadata: ["providerThinkingLevel": .string("low")])),
          .user([.text("again")]),
        ],
        tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: .off,
          responseSchema: nil, providerOptions: [:], cacheRetention: .none))
      let adapter = try XCTUnwrap(StandardWireProtocols.make().first { $0.protocolID == api })
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in adapter.stream(request, context: context, transport: transport) {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: provider, operation: "ios.signature.body")
      let fields = try XCTUnwrap(spec.array("projectFields"))
      let actual = Dictionary(
        uniqueKeysWithValues: fields.compactMap { value -> (String, JSONValue)? in
          guard let key = value.stringValue, let value = body[key] else { return nil }
          return (key, value)
        })
      XCTAssertEqual(actual, oracle.object("cases")?.object(name)?.object("requestBody"), name)
    }
  }

  func testAnthropicErrorStopReasonsMatchPinnedSource() async throws {
    let oracle = try load("Differential/Oracle/response-anthropic-bedrock-pi.json")
    for name in [
      "anthropic-refusal", "anthropic-refusal-no-details", "anthropic-refusal-empty-explanation",
      "anthropic-sensitive-explanation", "anthropic-unknown-stop",
    ] {
      let source = try XCTUnwrap(oracle.object("scenarios")?.object(name))
      let decoder = try XCTUnwrap(source.object("decoderInput"))
      let chunks = try XCTUnwrap(decoder.array("chunksBase64")).map {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap($0.stringValue)))
      }
      let (request, context) = inputs(
        api: "anthropic-messages", providerID: "anthropic", modelID: "fixture-model")
      let result = try await replay(
        AnthropicMessagesAdapter(), request: request, context: context, chunks: chunks)
      let expected = try XCTUnwrap(source.object("terminal"))
      XCTAssertEqual(result.failure?.code, .transportFailed, name)
      XCTAssertEqual(result.failure?.message, expected.string("errorMessage"), name)
      XCTAssertEqual(
        result.failure?.providerMetadata?.string("rawStopReason"), expected.string("rawStopReason"),
        name)
      XCTAssertNil(result.snapshot, name)
    }
  }

  func testAnthropicInputTransformationsMatchPinnedSource() async throws {
    let oracle = try load("Differential/Oracle/response-anthropic-bedrock-pi.json")
    for suffix in ["start", "delta", "cleared", "nonarray", "null", "after-stop"] {
      let name = "anthropic-transformations-" + suffix
      let source = try XCTUnwrap(oracle.object("scenarios")?.object(name))
      let decoder = try XCTUnwrap(source.object("decoderInput"))
      let chunks = try XCTUnwrap(decoder.array("chunksBase64")).map {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap($0.stringValue)))
      }
      let (request, context) = inputs(
        api: "anthropic-messages", providerID: "anthropic", modelID: "fixture-model")
      let before = Int64(Date().timeIntervalSince1970 * 1_000)
      let result = try await replay(
        AnthropicMessagesAdapter(), request: request, context: context, chunks: chunks)
      let after = Int64(Date().timeIntervalSince1970 * 1_000)
      XCTAssertNil(result.failure, name)
      let snapshot = try XCTUnwrap(result.snapshot, name)
      let diagnostics = try snapshot.providerMetadata.array("diagnostics")?.map {
        value -> JSONValue in
        var diagnostic = try XCTUnwrap(value.objectValue)
        let timestamp = try XCTUnwrap(diagnostic.int("timestamp"))
        XCTAssertTrue(Int64(timestamp) >= before && Int64(timestamp) <= after, name)
        diagnostic.removeValue(forKey: "timestamp")
        return .object(diagnostic)
      }
      XCTAssertEqual(diagnostics, source.object("terminal")?.array("diagnostics"), name)
    }
  }

  func testAnthropicRawOptionsMatchPinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("anthropic-raw-options.") == true }
    XCTAssertEqual(cases.count, 19)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let model = try XCTUnwrap(spec.object("model"))
      let modelID = try XCTUnwrap(model.string("id"))
      let sourceOptions = spec.object("options") ?? [:]
      let keys =
        spec.array("rawOptionKeys")?.compactMap(\.stringValue)
        ?? ["thinkingEnabled", "thinkingBudgetTokens", "effort"]
      let providerOptions = Dictionary(
        uniqueKeysWithValues: keys.map { ($0, sourceOptions[$0] ?? .null) })
      let (_, context) = inputs(
        api: "anthropic-messages", providerID: "anthropic", modelID: modelID,
        reasoning: true, metadata: model)
      let request = ProviderRequest(
        id: name, providerID: "anthropic", modelID: modelID,
        messages: [
          .user([.text("hello")]),
          .assistantMessage(
            .init(
              content: [.text("answer")],
              source: .init(api: "anthropic-messages", providerID: "anthropic", modelID: modelID),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: nil, cachedInputTokens: 0,
                providerMetadata: [:]),
              stopReason: .stop, timestampMilliseconds: 1,
              providerMetadata: ["providerThinkingLevel": .string("low")])),
          .user([.text("again")]),
        ],
        tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: providerOptions, cacheRetention: .none))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      var failure: ProviderRuntimeFailure?
      do {
        for try await _ in AnthropicMessagesAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch let value as ProviderRuntimeFailure { failure = value }
      let expected = try XCTUnwrap(oracle.object("cases")?.object(name))
      XCTAssertEqual(
        failure?.providerMetadata?.string("providerThinkingLevel"),
        expected.string("providerThinkingLevel"), name)
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: "anthropic",
        operation: "ios.anthropic.raw.body")
      let fields = try XCTUnwrap(spec.array("projectFields")).compactMap(\.stringValue)
      let actual = Dictionary(
        uniqueKeysWithValues: fields.compactMap { key in body[key].map { (key, $0) } })
      XCTAssertEqual(actual, expected.object("requestBody"), name)
    }
  }

  func testAzureStrictCompatibilityMatchesPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/request-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/request-branches.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("azure.strict-compat-") == true }
    XCTAssertEqual(cases.count, 9)
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object(["payload": .object(["type": .string("string")])]),
      "required": .array([.string("payload")]),
    ])
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let expected = try XCTUnwrap(oracle.object("cases")?.object(name))
      let preference = spec.object("toolConstraint")?.string("strict").flatMap(
        ProviderStrictPreference.init(rawValue:))
      let (_, context) = inputs(
        api: "azure-openai-responses", providerID: "azure-openai-responses",
        modelID: "source-model",
        baseURL: try XCTUnwrap(spec.string("baseURL")), reasoning: false,
        metadata: ["compat": .object(spec.object("compat") ?? [:])])
      let request = ProviderRequest(
        id: name, providerID: "azure-openai-responses", modelID: "source-model",
        messages: [.user([.text("hello")])],
        tools: [
          .init(
            name: "sample_tool", description: "Sample tool",
            inputSchema: schema, constrainedSampling: preference.map { .jsonSchema(strict: $0) })
        ],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil, responseSchema: nil,
          providerOptions: [:]))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      var failure: ProviderRuntimeFailure?
      do {
        for try await _ in OpenAIResponsesAdapter(
          protocolID: "azure-openai-responses", flavor: .azure
        )
        .stream(request, context: context, transport: transport) {}
      } catch let value as ProviderRuntimeFailure { failure = value }
      let sent = await transport.sent
      if let error = expected.string("errorMessage") {
        XCTAssertEqual(failure?.message, error, name)
        XCTAssertNil(sent, name)
      } else {
        let body = try decodeJSONObject(
          try XCTUnwrap(sent?.httpBody, name), providerID: "fixture",
          operation: "ios.azure.strict.body")
        XCTAssertEqual(body["tools"], expected.object("requestBody")?["tools"], name)
      }
    }
  }

  func testBedrockRawReasoningMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("bedrock-raw-options.") == true }
    XCTAssertEqual(cases.count, 29)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let model = try XCTUnwrap(spec.object("model"))
      let modelID = try XCTUnwrap(model.string("id"))
      let sourceOptions = spec.object("options") ?? [:]
      let budgets = sourceOptions.object("thinkingBudgets").map { values in
        Dictionary(
          uniqueKeysWithValues: values.compactMap { key, value -> (ProviderReasoningEffort, Int)? in
            guard let effort = ProviderReasoningEffort(rawValue: key),
              case .integer(let budget) = value
            else { return nil }
            return (effort, Int(budget))
          })
      }
      let (_, context) = inputs(
        api: "bedrock-converse-stream", providerID: "amazon-bedrock", modelID: modelID,
        baseURL: try XCTUnwrap(model.string("baseUrl")), reasoning: model.bool("reasoning"),
        metadata: model)
      let request = ProviderRequest(
        id: name, providerID: "amazon-bedrock", modelID: modelID,
        messages: [.user([.text("hello")])], tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: ["reasoning": sourceOptions["reasoning"] ?? .null],
          cacheRetention: .none, thinkingBudgets: budgets))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in BedrockConverseStreamAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: "fixture",
        operation: "ios.bedrock.raw.body")
      let fields = try XCTUnwrap(spec.array("projectFields")).compactMap(\.stringValue)
      let actual = Dictionary(
        uniqueKeysWithValues: fields.compactMap { key in body[key].map { (key, $0) } })
      XCTAssertEqual(actual, oracle.object("cases")?.object(name)?.object("requestBody"), name)
    }
  }

  func testCompletionsEmptyToolsMatchPinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter {
        $0.string("id")?.hasPrefix("completions-empty-tools.") == true
          || $0.string("id")?.hasPrefix("completions-message-helper.") == true
      }
    XCTAssertEqual(cases.count, 7)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let modelID = "fixture-chat"
      let (_, context) = inputs(
        api: "openai-completions", providerID: "fixture", modelID: modelID, reasoning: false,
        metadata: spec.object("model") ?? [:])
      var messages: [ProviderMessage] = [.user([.text("hello")])]
      if spec.bool("history") == true {
        let blocks: [ProviderAssistantContent] =
          spec.array("assistantContent")?.compactMap { value in
            guard let block = value.objectValue, block.string("type") == "toolCall" else {
              return nil
            }
            return .toolCall(.init(id: "call_1", name: "read", arguments: .object([:])))
          } ?? [.text("answer")]
        messages.append(
          .assistantMessage(
            .init(
              content: blocks,
              source: .init(api: "openai-completions", providerID: "fixture", modelID: modelID),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: nil, cachedInputTokens: 0,
                providerMetadata: [:]),
              stopReason: .stop, timestampMilliseconds: 1)))
        if let text = spec.string("toolResultText") {
          messages.append(
            .toolResult(
              .init(
                toolCallID: "call_1", toolName: "read", content: [.text(text)], isError: false,
                timestampMilliseconds: 2)))
        }
        if spec.bool("omitFollowup") != true { messages.append(.user([.text("again")])) }
      }
      let request = ProviderRequest(
        id: name, providerID: "fixture", modelID: modelID, messages: messages, tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: [:], cacheRetention: .none))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in OpenAICompletionsAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: "fixture",
        operation: "ios.completions.tools.body")
      let fields = try XCTUnwrap(spec.array("projectFields")).compactMap(\.stringValue)
      let actual = Dictionary(
        uniqueKeysWithValues: fields.compactMap { key in body[key].map { (key, $0) } })
      XCTAssertEqual(actual, oracle.object("cases")?.object(name)?.object("requestBody"), name)
    }
  }

  func testAnthropicIgnoresGenericSamplingParamsLikePinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("anthropic-ignored-sampling.") == true }
    XCTAssertEqual(cases.count, 4)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let model = try XCTUnwrap(spec.object("model"))
      let modelID = try XCTUnwrap(model.string("id"))
      let sourceOptions = spec.object("options") ?? [:]
      let temperature: Double?
      switch sourceOptions["temperature"] {
      case .number(let value): temperature = value
      case .integer(let value): temperature = Double(value)
      default: temperature = nil
      }
      let (_, context) = inputs(
        api: "anthropic-messages", providerID: "fixture", modelID: modelID,
        reasoning: false, metadata: model)
      let request = ProviderRequest(
        id: name, providerID: "fixture", modelID: modelID,
        messages: [.user([.text("hello")])], tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: temperature, reasoningEffort: nil,
          responseSchema: nil, providerOptions: sourceOptions.filter { $0.key == "samplingParams" },
          cacheRetention: .none))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in AnthropicMessagesAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: "fixture",
        operation: "ios.anthropic.sampling.body")
      XCTAssertEqual(body, oracle.object("cases")?.object(name)?.object("requestBody"), name)
    }
  }

  func testCompletionsRawReasoningMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("completions-raw-options.") == true }
    XCTAssertEqual(cases.count, 12)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let model = try XCTUnwrap(spec.object("model"))
      let modelID = try XCTUnwrap(model.string("id"))
      let sourceOptions = spec.object("options") ?? [:]
      var providerOptions = sourceOptions.filter { $0.key == "samplingParams" }
      providerOptions["reasoningEffort"] = sourceOptions["reasoningEffort"] ?? .null
      let (_, context) = inputs(
        api: "openai-completions", providerID: "fixture", modelID: modelID,
        reasoning: model.bool("reasoning"), metadata: model)
      let request = ProviderRequest(
        id: name, providerID: "fixture", modelID: modelID,
        messages: [.user([.text("hello")])], tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: providerOptions, cacheRetention: .none))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in OpenAICompletionsAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: "fixture",
        operation: "ios.completions.raw.body")
      XCTAssertEqual(body, oracle.object("cases")?.object(name)?.object("requestBody"), name)
    }
  }

  func testCompletionsReasoningReplayMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("completions-reasoning-replay.") == true }
    XCTAssertEqual(cases.count, 10)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let model = try XCTUnwrap(spec.object("model"))
      let modelID = try XCTUnwrap(model.string("id"))
      let provider = try XCTUnwrap(model.string("provider"))
      let blocks: [ProviderAssistantContent] = try XCTUnwrap(spec.array("assistantContent")).map {
        value in
        let block = try XCTUnwrap(value.objectValue)
        switch block.string("type") {
        case "thinking":
          return .reasoning(
            .init(
              text: block.string("thinking") ?? "", signature: block.string("thinkingSignature"),
              providerMetadata: [:]))
        case "toolCall":
          return .toolCall(
            .init(
              id: try XCTUnwrap(block.string("id")), name: try XCTUnwrap(block.string("name")),
              arguments: try XCTUnwrap(block["arguments"])))
        default: return .text(block.string("text") ?? "")
        }
      }
      let (_, context) = inputs(
        api: "openai-completions", providerID: provider, modelID: modelID,
        reasoning: true, metadata: model)
      let request = ProviderRequest(
        id: name, providerID: provider, modelID: modelID,
        messages: [
          .user([.text("hello")]),
          .assistantMessage(
            .init(
              content: blocks,
              source: .init(api: "openai-completions", providerID: provider, modelID: modelID),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: nil, cachedInputTokens: 0,
                providerMetadata: [:]),
              stopReason: .stop, timestampMilliseconds: 1)), .user([.text("again")]),
        ], tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: [:], cacheRetention: .none))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in OpenAICompletionsAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: provider,
        operation: "ios.completions.replay.body")
      XCTAssertEqual(
        body["messages"], oracle.object("cases")?.object(name)?.object("requestBody")?["messages"],
        name)
    }
  }

  func testAnthropicImageToolResultsMatchPinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("anthropic-tool-images.") == true }
    XCTAssertEqual(cases.count, 5)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let model = try XCTUnwrap(spec.object("model"))
      let modelID = try XCTUnwrap(model.string("id"))
      let resultContent: [ProviderToolResultContent] = try XCTUnwrap(
        spec.array("toolResultContent")
      ).map { value in
        let block = try XCTUnwrap(value.objectValue)
        if block.string("type") == "text" { return .text(block.string("text") ?? "") }
        return .image(
          .data(
            try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(block.string("data")))),
            mimeType: try XCTUnwrap(block.string("mimeType"))))
      }
      let (_, context) = inputs(
        api: "anthropic-messages", providerID: "anthropic", modelID: modelID,
        reasoning: false, metadata: model)
      let request = ProviderRequest(
        id: name, providerID: "anthropic", modelID: modelID,
        messages: [
          .user([.text("hello")]),
          .assistantMessage(
            .init(
              content: [.toolCall(.init(id: "call_1", name: "read", arguments: .object([:])))],
              source: .init(api: "anthropic-messages", providerID: "anthropic", modelID: modelID),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: nil, cachedInputTokens: 0,
                providerMetadata: [:]),
              stopReason: .stop, timestampMilliseconds: 1)),
          .toolResult(
            .init(
              toolCallID: "call_1", toolName: "read", content: resultContent,
              isError: spec.bool("toolResultIsError") ?? false, timestampMilliseconds: 2)),
        ], tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: [:], cacheRetention: .none))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in AnthropicMessagesAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: "anthropic",
        operation: "ios.anthropic.images.body")
      XCTAssertEqual(
        body["messages"], oracle.object("cases")?.object(name)?.object("requestBody")?["messages"],
        name)
    }
  }

  func testProviderHTTPErrorMessagesMatchPinnedSource() async throws {
    let fixture = try load("Differential/Cases/strict-fallback.json")
    let oracle = try load("Differential/Oracle/strict-fallback.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue).filter {
      $0.array("failures")?.count == 1
        && $0.array("preferences")?.contains(.string("prefer")) == false
    }
    XCTAssertEqual(cases.count, 14)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let api = try XCTUnwrap(spec.string("protocolID"))
      let bedrock = api == "bedrock-converse-stream"
      let provider = bedrock ? "amazon-bedrock" : "anthropic"
      let failure = try XCTUnwrap(spec.array("failures")?.first?.objectValue)
      let body =
        try failure.string("body").map { Data($0.utf8) }
        ?? JSONEncoder().encode(
          JSONValue.object([
            "__type": .string(try XCTUnwrap(failure.string("type"))),
            "message": .string(try XCTUnwrap(failure.string("message"))),
          ]))
      let (_, context) = inputs(
        api: api, providerID: provider, modelID: "fixture-claude",
        baseURL: bedrock
          ? "https://bedrock-runtime.us-east-1.amazonaws.com" : "https://fixture.invalid",
        reasoning: false,
        metadata: [
          "compat": .object([bedrock ? "supportsStrictMode" : "supportsStrictTools": .bool(true)])
        ])
      let request = ProviderRequest(
        id: name, providerID: provider, modelID: "fixture-claude",
        messages: [.user([.text("Hello")])],
        tools: try XCTUnwrap(spec.array("preferences")).enumerated().map { index, value in
          let preference: ProviderStrictPreference?
          if case .string(let text) = value {
            preference = ProviderStrictPreference(rawValue: text)
          } else {
            preference = nil
          }
          return ProviderToolDefinition(
            name: "tool_\(index)", description: "Fixture lookup",
            inputSchema: try XCTUnwrap(fixture["schema"]),
            constrainedSampling: preference.map { .jsonSchema(strict: $0) })
        },
        options: .init(
          maximumOutputTokens: 100, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: [:], cacheRetention: .none))
      let transport = IOSMistralHTTPFixture(
        status: try XCTUnwrap(failure.int("status")), body: body)
      let adapter = try XCTUnwrap(StandardWireProtocols.make().first { $0.protocolID == api })
      var observed: ProviderRuntimeFailure?
      do {
        for try await _ in adapter.stream(request, context: context, transport: transport) {}
      } catch let failure as ProviderRuntimeFailure { observed = failure }
      let expected = oracle.object("cases")?.object(name)?.array("outcomes")?.first?.objectValue
      XCTAssertEqual(try XCTUnwrap(observed, name).message, expected?.string("errorMessage"), name)
    }
  }

  func testCompletionsReasoningDetailSignaturesMatchPinnedSource() async throws {
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    let cases = try XCTUnwrap(
      oracle.object("cases")?.object("completions.reasoning-detail-signatures"))
    XCTAssertEqual(cases.count, 6)
    for (name, value) in cases {
      let spec = try XCTUnwrap(value.objectValue)
      let (request, context) = inputs(api: "openai-completions")
      let result = try await replay(
        OpenAICompletionsAdapter(), request: request, context: context,
        chunks: [Data(try XCTUnwrap(spec.string("sse")).utf8)])
      XCTAssertNil(result.failure, name)
      let reasoning = try XCTUnwrap(result.snapshot, name).content.compactMap {
        item -> ProviderReasoningContent? in
        guard case .reasoning(let value) = item else { return nil }
        return value
      }.first
      let expected = spec.array("content")?.compactMap(\.objectValue).first {
        $0.string("type") == "thinking"
      }
      XCTAssertEqual(reasoning?.signature, expected?.string("thinkingSignature"), name)
      XCTAssertEqual(reasoning?.text, expected?.string("thinking"), name)
    }
  }

  func testCompletionsStructuredReasoningReplayMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("completions-structured-replay.") == true }
    XCTAssertEqual(cases.count, 8)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let model = try XCTUnwrap(spec.object("model"))
      let modelID = try XCTUnwrap(model.string("id"))
      let provider = try XCTUnwrap(model.string("provider"))
      let (_, context) = inputs(
        api: "openai-completions", providerID: provider, modelID: modelID,
        reasoning: true, metadata: model)
      let assistant: [ProviderAssistantContent] = try XCTUnwrap(spec.array("assistantContent")).map
      { value in
        let block = try XCTUnwrap(value.objectValue)
        switch block.string("type") {
        case "thinking":
          return .reasoning(
            .init(
              text: block.string("thinking") ?? "", signature: block.string("thinkingSignature"),
              providerMetadata: [:]))
        case "toolCall":
          return .toolCall(
            .init(
              id: try XCTUnwrap(block.string("id")), name: try XCTUnwrap(block.string("name")),
              arguments: try XCTUnwrap(block["arguments"]),
              thoughtSignature: block.string("thoughtSignature")))
        default: return .text(block.string("text") ?? "")
        }
      }
      let request = ProviderRequest(
        id: name, providerID: provider, modelID: modelID,
        messages: [
          .user([.text("hello")]),
          .assistantMessage(
            .init(
              content: assistant,
              source: .init(api: "openai-completions", providerID: provider, modelID: modelID),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: nil, cachedInputTokens: 0,
                providerMetadata: [:]),
              stopReason: .stop, timestampMilliseconds: 1)),
        ], tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil, responseSchema: nil,
          providerOptions: [:], cacheRetention: .none))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in OpenAICompletionsAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: provider,
        operation: "ios.completions.structured.body")
      XCTAssertEqual(
        body["messages"], oracle.object("cases")?.object(name)?.object("requestBody")?["messages"],
        name)
    }
  }

  func testBedrockBlankContentMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("bedrock-blank-content.") == true }
    XCTAssertEqual(cases.count, 14)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let model = try XCTUnwrap(spec.object("model"))
      let modelID = try XCTUnwrap(model.string("id"))
      let (_, context) = inputs(
        api: "bedrock-converse-stream", providerID: "amazon-bedrock", modelID: modelID,
        baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com", reasoning: false,
        metadata: model)
      let userContent = (spec.array("userContent") ?? [.object(["text": .string("hello")])]).map {
        ProviderUserContent.text($0.objectValue?.string("text") ?? "")
      }
      var messages: [ProviderMessage] = [
        .userMessage(.init(content: userContent, timestampMilliseconds: 0))
      ]
      if spec.bool("history") == true {
        let assistantContent: [ProviderAssistantContent] = try XCTUnwrap(
          spec.array("assistantContent")
        ).map {
          let block = try XCTUnwrap($0.objectValue)
          if block.string("type") == "text" { return .text(block.string("text") ?? "") }
          return .toolCall(
            .init(
              id: try XCTUnwrap(block.string("id")), name: try XCTUnwrap(block.string("name")),
              arguments: try XCTUnwrap(block["arguments"])))
        }
        messages.append(
          .assistantMessage(
            .init(
              content: assistantContent,
              source: .init(
                api: "bedrock-converse-stream", providerID: "amazon-bedrock", modelID: modelID),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: nil, cachedInputTokens: 0,
                providerMetadata: [:]),
              stopReason: .stop, timestampMilliseconds: 1)))
        if let blocks = spec.array("toolResultContent") {
          messages.append(
            .toolResult(
              .init(
                toolCallID: "call_1", toolName: "read",
                content: blocks.map {
                  .text($0.objectValue?.string("text") ?? "")
                }, isError: false, timestampMilliseconds: 2)))
        }
      }
      let request = ProviderRequest(
        id: name, providerID: "amazon-bedrock", modelID: modelID, messages: messages, tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil, responseSchema: nil,
          providerOptions: [:], cacheRetention: .none))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in BedrockConverseStreamAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: "amazon-bedrock",
        operation: "ios.bedrock.blank.body")
      XCTAssertEqual(
        body["messages"], oracle.object("cases")?.object(name)?.object("requestBody")?["messages"],
        name)
    }
  }

  func testAzureProxyQueriesMatchPinnedSource() async throws {
    let fixture = try load("AzureOpenAIConfiguration/Cases/configuration.json")
    let oracle = try load("AzureOpenAIConfiguration/Oracle/configuration.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("azure-config-proxy-query-") == true }
    XCTAssertEqual(cases.count, 4)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let modelID = try XCTUnwrap(spec.string("modelID"))
      let (_, context) = inputs(
        api: "azure-openai-responses", providerID: "azure-openai-responses", modelID: modelID,
        baseURL: try XCTUnwrap(spec.string("modelBaseURL")), reasoning: false)
      let request = ProviderRequest(
        id: name, providerID: "azure-openai-responses", modelID: modelID,
        messages: [.system("Azure source fixture"), .user([.text("hello")])], tools: [],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: [:]),
        connectionOptions: .init(
          azureOpenAIResponses: .init(
            azureAPIVersion: spec.object("options")?.string("azureApiVersion"))))
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in OpenAIResponsesAdapter(
          protocolID: "azure-openai-responses", flavor: .azure
        )
        .stream(request, context: context, transport: transport) {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      XCTAssertEqual(
        try XCTUnwrap(sent, name).url?.absoluteString,
        oracle.object("cases")?.object(name)?.string("url"), name)
    }
  }

  private func load(_ path: String) throws -> [String: JSONValue] {
    let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
    return try decodeJSONObject(
      Data(contentsOf: root.appending(path: path)), providerID: "fixture", operation: "ios.fixture")
  }

  private func content(_ snapshot: ProviderResponseSnapshot) -> [JSONValue] {
    snapshot.content.map {
      switch $0 {
      case .text(let value):
        return .object(["type": .string("text"), "text": .string(value.text)])
      case .toolCall(let value):
        var object: [String: JSONValue] = [
          "type": .string("toolCall"), "id": .string(value.id), "name": .string(value.name),
          "arguments": value.arguments,
        ]
        if let namespace = value.namespace { object["namespace"] = .string(namespace) }
        return .object(object)
      default:
        XCTFail("unexpected content in the selected source fixtures")
        return .null
      }
    }
  }

  private func inputs(
    api: String, providerID: String? = nil, modelID: String? = nil,
    baseURL: String = "https://fixture.invalid",
    reasoning: Bool? = nil,
    metadata: [String: JSONValue] = [:], headers: [String: String] = [:],
    options: ProviderGenerationOptions? = nil
  ) -> (
    ProviderRequest, WireProtocolContext
  ) {
    let isCodex = api == "openai-codex-responses"
    let isAzure = api == "azure-openai-responses"
    let providerID =
      providerID
      ?? (isCodex
        ? "openai-codex"
        : isAzure
          ? "azure-openai-responses"
          : api == "anthropic-messages"
            ? "anthropic"
            : (api == "mistral-conversations" ? "mistral" : "openai"))
    let modelID = modelID ?? (api == "openai-completions" ? "requested-model" : "fixture-model")
    let model = ProviderModel(
      id: modelID, providerID: providerID, name: modelID, protocolID: api,
      capabilities: .init(
        textInput: true, imageInput: false, toolCalling: true,
        reasoning: reasoning ?? (api != "mistral-conversations"),
        structuredOutput: true, imageGeneration: false),
      contextWindow: 32_768, maximumOutputTokens: 4_096)
    var metadata = metadata
    metadata["cost"] = .object([
      "input": .integer(0), "output": .integer(0), "cacheRead": .integer(0),
      "cacheWrite": .integer(0),
    ])
    return (
      ProviderRequest(
        id: "ios-conformance", providerID: providerID, modelID: modelID,
        messages: [.user([.text("hello")])], tools: [],
        options: options
          ?? .init(
            maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
            responseSchema: nil, providerOptions: [:])),
      WireProtocolContext(
        provider: .init(
          id: providerID, name: providerID, authorizationMethods: [], models: [model]),
        model: model, baseURL: URL(string: baseURL)!, headers: headers,
        credential: isCodex
          ? .oauth(
            .init(
              accessToken: "synthetic-fixture-token", refreshToken: "synthetic-fixture-refresh",
              expiresAt: .distantFuture, metadata: ["accountID": "fixture-account"]))
          : .apiKey(
            .init(
              key: "synthetic-fixture-key", metadata: isAzure ? ["deploymentName": modelID] : [:])),
        modelConfiguration: .init(protocolID: api, baseURL: nil, headers: [:], metadata: metadata))
    )
  }

  private func replay(
    _ adapter: any WireProtocolAdapter, request: ProviderRequest, context: WireProtocolContext,
    chunks: [Data]
  ) async throws -> (
    snapshot: ProviderResponseSnapshot?, failure: ProviderRuntimeFailure?, starts: Int
  ) {
    var snapshot: ProviderResponseSnapshot?
    var starts = 0
    do {
      for try await event in adapter.stream(
        request, context: context, transport: IOSFixtureTransport(chunks: chunks))
      {
        if case .responseSnapshot(let value) = event { snapshot = value }
        if case .responseStarted = event { starts += 1 }
      }
      return (snapshot, nil, starts)
    } catch let error as ProviderRuntimeFailure {
      return (snapshot, error, starts)
    }
  }
}

private actor IOSMistralTimeoutFixture: ProviderHTTPStreamingTransport {
  let spec: [String: JSONValue]
  var requested = false
  init(spec: [String: JSONValue]) { self.spec = spec }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    requested = true
    if let delay = spec.int("headerDelayMs"), delay > 0 {
      try await Task.sleep(for: .milliseconds(delay))
    }
    let chunks = try XCTUnwrap(spec.array("chunks"))
    return .init(
      statusCode: 200, headers: ["content-type": "text/event-stream"],
      body: AsyncThrowingStream { continuation in
        let task = Task {
          do {
            for value in chunks {
              let chunk = try XCTUnwrap(value.objectValue)
              if let delay = chunk.int("delayMs"), delay > 0 {
                try await Task.sleep(for: .milliseconds(delay))
              }
              continuation.yield(Data(try XCTUnwrap(chunk.string("data")).utf8))
            }
            continuation.finish()
          } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
      })
  }
}

private actor IOSMistralHTTPFixture: ProviderHTTPStreamingTransport {
  let status: Int
  let body: Data
  var sent: URLRequest?

  init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    sent = request
    return .init(
      statusCode: status, headers: [:],
      body: AsyncThrowingStream { continuation in
        continuation.yield(body)
        continuation.finish()
      })
  }
}

private struct IOSFixtureTransport: ProviderHTTPStreamingTransport {
  let chunks: [Data]

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    .init(
      statusCode: 200, headers: ["content-type": "text/event-stream"],
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      })
  }
}
