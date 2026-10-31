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

  func testBedrockFailureDiagnosticsMatchPinnedHTTPAndStreamErrors() async throws {
    let oracle = try load("Differential/Oracle/response-anthropic-bedrock-pi.json")
    for (name, value) in try XCTUnwrap(oracle.object("scenarios")) where name.hasPrefix("bedrock") {
      let scenario = try XCTUnwrap(value.objectValue)
      guard scenario.string("outcome") == "failure" else { continue }
      let source = try XCTUnwrap(scenario.object("terminal"))
      let decoder = try XCTUnwrap(scenario.object("decoderInput"))
      let chunks = try XCTUnwrap(decoder.array("chunksBase64")).map {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap($0.stringValue)))
      }
      let headers = (decoder.object("headers") ?? [:]).compactMapValues(\.stringValue)
      let (request, context) = inputs(
        api: "bedrock-converse-stream", providerID: "amazon-bedrock", modelID: "fixture-model",
        baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com", reasoning: true)
      let before = Int64(Date().timeIntervalSince1970 * 1_000)
      let result = try await replay(
        BedrockConverseStreamAdapter(), request: request, context: context, chunks: chunks,
        status: try XCTUnwrap(decoder.int("status")), headers: headers)
      let after = Int64(Date().timeIntervalSince1970 * 1_000)
      let failure = try XCTUnwrap(result.failure, name)
      let diagnostics = try (failure.providerMetadata?.array("diagnostics") ?? []).map {
        value -> JSONValue in
        var object = try XCTUnwrap(value.objectValue)
        let timestamp = try XCTUnwrap(object.int("timestamp"))
        XCTAssertTrue(Int64(timestamp) >= before && Int64(timestamp) <= after, name)
        object.removeValue(forKey: "timestamp")
        return .object(object)
      }
      XCTAssertEqual(diagnostics, source.array("diagnostics") ?? [], name)
      XCTAssertEqual(failure.message, source.string("errorMessage"), name)
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
      let (_, baseContext) = inputs(
        api: "anthropic-messages", providerID: "anthropic", modelID: modelID,
        reasoning: true, metadata: model)
      var context = baseContext
      let payloads = IOSWireObserverCapture()
      context.wireObserver = .init(onPayload: { payload, _ in
        await payloads.payload(.object(payload))
        return nil
      })
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
      let observed = await payloads.payloads
      let body = try XCTUnwrap(observed.last?.objectValue, name)
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

  func testAnthropicInlineToolValuesMatchPinnedSource() async throws {
    let fixture = try load("Differential/Cases/strict-fallback-inline.json")
    let oracle = try load("Differential/Oracle/strict-fallback-inline.json")
    for value in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(value.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      func tools(_ values: [JSONValue]) throws -> [ProviderToolDefinition] {
        try values.map { value in
          let tool = try XCTUnwrap(value.objectValue)
          return .init(
            name: try XCTUnwrap(tool.string("name")), description: tool.string("description") ?? "",
            inputSchema: try XCTUnwrap(tool["parameters"]),
            constrainedSampling: tool.object("constrainedSampling")?.string("strict")
              .flatMap(ProviderStrictPreference.init(rawValue:)).map { .jsonSchema(strict: $0) })
        }
      }
      let messages = try XCTUnwrap(spec.array("messages")).map { value -> ProviderMessage in
        let message = try XCTUnwrap(value.objectValue)
        switch message.string("role") {
        case "system":
          return .systemMessage(
            .init(
              content: message.string("content") ?? "",
              toolsAdded: try tools(message.array("toolsAdded") ?? []),
              toolsRemoved: (message.array("toolsRemoved") ?? []).compactMap {
                $0.objectValue?.string("name")
              }))
        case "assistant": return .assistant([])
        default: return .user([.text(message.string("content") ?? "")])
        }
      }
      var compat = spec.object("compat") ?? [:]
      compat["supportsStrictTools"] = .bool(true)
      let (_, base) = inputs(
        api: "anthropic-messages", modelID: "fixture-claude", reasoning: false,
        metadata: ["compat": .object(compat)])
      let key = try XCTUnwrap(spec.string("apiKey"))
      let credential: ProviderCredential =
        key.contains("sk-ant-oat")
        ? .oauth(
          .init(accessToken: key, refreshToken: "", expiresAt: .distantFuture, metadata: [:]))
        : .apiKey(.init(key: key, metadata: [:]))
      var context = WireProtocolContext(
        provider: base.provider, model: base.model, baseURL: base.baseURL,
        headers: base.headers, credential: credential, modelConfiguration: base.modelConfiguration)
      let capture = IOSWireObserverCapture()
      context.wireObserver = .init(onPayload: { payload, _ in
        for (key, value) in spec.object("payloadChanges") ?? [:] { payload[key] = value }
        await capture.payload(.object(payload))
        return nil
      })
      let request = ProviderRequest(
        id: name, providerID: "anthropic", modelID: "fixture-claude", messages: messages,
        tools: try tools(spec.array("currentTools") ?? []),
        options: .init(
          maximumOutputTokens: 100, temperature: nil,
          reasoningEffort: nil, responseSchema: nil, providerOptions: [:],
          cacheRetention: spec.string("cacheRetention") == "none" ? .none : .short))
      let transport = IOSStrictFallbackFixture(spec: spec)
      for try await _ in AnthropicMessagesAdapter().stream(
        request, context: context, transport: transport)
      {}
      let actual = await capture.payloads
      XCTAssertEqual(actual, oracle.object("cases")?.object(name)?.array("logicalPayloads"), name)
      let http = await transport.httpRequests
      XCTAssertEqual(http, oracle.object("cases")?.object(name)?.array("httpRequests"), name)
    }
  }

  func testBedrockImportedContentMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/bedrock-input-interop.json")
    let oracle = try load("Differential/Oracle/bedrock-input-interop.json")
    for value in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(value.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      let blocks = try XCTUnwrap(spec.array("content")).map { try XCTUnwrap($0.objectValue) }
      let message: ProviderMessage
      if spec.string("role") == "user" {
        message = .user(
          try blocks.map { block in
            if let units = block["utf16"] {
              return .textUTF16(
                try JSONDecoder().decode([UInt16].self, from: JSONEncoder().encode(units)))
            }
            if block.string("type") == "text" { return .text(block.string("text") ?? "") }
            return .unrecognized(block)
          })
      } else {
        message = .assistant(
          try blocks.map { block in
            if let units = block["utf16"] {
              return .textUTF16(
                try JSONDecoder().decode([UInt16].self, from: JSONEncoder().encode(units)))
            }
            if block.string("type") == "text" { return .text(block.string("text") ?? "") }
            return .unrecognized(block)
          })
      }
      let (_, context) = inputs(
        api: "bedrock-converse-stream", providerID: "amazon-bedrock", modelID: "fixture-model",
        baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com", reasoning: false)
      let request = ProviderRequest(
        id: name, providerID: "amazon-bedrock", modelID: "fixture-model", messages: [message],
        tools: [],
        options: .init(
          maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil, responseSchema: nil,
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
        operation: "ios.bedrock.input-interop")
      XCTAssertEqual(body["messages"], oracle.object("cases")?[name], name)
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

  func testResponsesProviderErrorsMatchPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    var cases = try XCTUnwrap(fixture.array("responsesProviderErrorCases"))
    XCTAssertEqual(cases.count, 23)
    var observations = try XCTUnwrap(oracle.object("cases")?.object("responses.provider-errors"))
    let codexBranches = try XCTUnwrap(
      oracle.object("cases")?.object("responses.codex-failure-branches"))
    XCTAssertEqual(codexBranches.count, 3)
    for (name, value) in codexBranches {
      let id = "codex-branch." + name
      observations[id] = value
      cases.append(
        .object([
          "id": .string(id), "api": .string("openai-codex-responses"),
          "provider": .string("openai-codex"), "status": .integer(200),
          "body": .string(try XCTUnwrap(value.objectValue?.string("body"))),
        ]))
    }
    for value in cases {
      let spec = try XCTUnwrap(value.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      let api = try XCTUnwrap(spec.string("api"))
      let provider = try XCTUnwrap(spec.string("provider"))
      let expected = try XCTUnwrap(observations[name]?.objectValue)
      let (request, context) = inputs(api: api, providerID: provider, modelID: "gpt-model")
      let adapter = try XCTUnwrap(StandardWireProtocols.make().first { $0.protocolID == api })
      let transport = IOSMistralHTTPFixture(
        status: try XCTUnwrap(spec.int("status")),
        body: Data(try XCTUnwrap(spec.string("body")).utf8))
      var observed: ProviderRuntimeFailure?
      do {
        for try await _ in adapter.stream(request, context: context, transport: transport) {}
      } catch let failure as ProviderRuntimeFailure { observed = failure }
      let failure = try XCTUnwrap(observed, name)
      XCTAssertEqual(failure.code, .transportFailed, name)
      XCTAssertEqual(failure.message, expected.string("errorMessage"), name)
      XCTAssertEqual(
        failure.providerMetadata?.string("rawStopReason"), expected.string("rawStopReason"), name)
    }
  }

  func testPiTerminalEventsWithoutStartMatchPinnedSource() async throws {
    let oracle = try load("Differential/Oracle/response-anthropic-bedrock-pi.json")
    let cases = try XCTUnwrap(oracle.object("scenarios")).filter {
      $0.key.hasPrefix("pi-terminal-no-start-")
    }
    XCTAssertEqual(cases.count, 4)
    for (name, value) in cases {
      let spec = try XCTUnwrap(value.objectValue)
      let expected = try XCTUnwrap(spec.object("terminal"))
      let chunks = try XCTUnwrap(spec.object("decoderInput")?.array("chunksBase64")).map {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap($0.stringValue)))
      }
      let (request, context) = inputs(
        api: "pi-messages", providerID: "fixture-pi", modelID: "fixture-model")
      let result = try await replay(
        PiMessagesAdapter(), request: request, context: context, chunks: chunks)
      XCTAssertEqual(result.starts, 0, name)
      if spec.string("outcome") == "failure" {
        XCTAssertEqual(result.failure?.code, .transportFailed, name)
        XCTAssertEqual(result.failure?.message, expected.string("errorMessage"), name)
        XCTAssertNil(result.snapshot, name)
      } else {
        XCTAssertNil(result.failure, name)
        let snapshot = try XCTUnwrap(result.snapshot, name)
        XCTAssertEqual(snapshot.responseID, expected.string("responseID"), name)
        XCTAssertEqual(snapshot.responseModelID, expected.string("responseModel"), name)
        XCTAssertEqual(
          snapshot.providerMetadata["providerThinkingLevel"], expected["providerThinkingLevel"],
          name)
        XCTAssertTrue(snapshot.content.isEmpty, name)
        let reason =
          snapshot.finishReason == .toolCalls ? "toolUse" : snapshot.finishReason.rawValue
        XCTAssertEqual(reason, expected.string("stopReason"), name)
        XCTAssertEqual(
          snapshot.usage?.totalTokens, expected.object("usage")?.int("totalTokens"), name)
      }
    }
  }

  func testOrderedStrictSchemasMatchPinnedSource() async throws {
    let fixture = try load("Differential/Cases/provider-intent.json")
    let oracle = try load("Differential/Oracle/provider-intent.json")
    let cases = try XCTUnwrap(fixture.array("cases")).compactMap(\.objectValue)
      .filter { $0.string("id")?.hasPrefix("ordered-schema.") == true }
    XCTAssertEqual(cases.count, 20)
    for spec in cases {
      let name = try XCTUnwrap(spec.string("id"))
      let model = try XCTUnwrap(spec.object("model"))
      let api = try XCTUnwrap(model.string("api"))
      let provider = try XCTUnwrap(model.string("provider"))
      let modelID = try XCTUnwrap(model.string("id"))
      let (_, context) = inputs(api: api, providerID: provider, modelID: modelID, metadata: model)
      let schema = try JSONValue(
        jsonData: Data(try XCTUnwrap(spec.string("toolParametersJSON")).utf8))
      let options = spec.object("options") ?? [:]
      let request = ProviderRequest(
        id: name, providerID: provider, modelID: modelID, messages: [.user([.text("hello")])],
        tools: [
          .init(
            name: "lookup", description: "Fixture lookup", inputSchema: schema,
            constrainedSampling: name.hasSuffix(".legacy") ? nil : .jsonSchema(strict: .require))
        ],
        options: .init(
          maximumOutputTokens: 4096, temperature: nil, reasoningEffort: nil,
          responseSchema: nil, providerOptions: [:], cacheRetention: .none),
        connectionOptions: .init(
          azureOpenAIResponses: options.string("azureDeploymentName").map {
            .init(azureDeploymentName: $0)
          }))
      let adapter = try XCTUnwrap(StandardWireProtocols.make().first { $0.protocolID == api })
      let transport = IOSMistralHTTPFixture(status: 400, body: Data())
      do {
        for try await _ in adapter.stream(request, context: context, transport: transport) {}
      } catch is ProviderRuntimeFailure {}
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody, name), providerID: provider,
        operation: "ios.ordered.schema")
      let actual = Dictionary(
        uniqueKeysWithValues: try XCTUnwrap(spec.array("projectFields")).compactMap {
          value -> (String, JSONValue)? in
          guard let key = value.stringValue, let value = body[key] else { return nil }
          return (key, value)
        })
      XCTAssertEqual(actual, oracle.object("cases")?.object(name)?.object("requestBody"), name)
    }
  }

  func testResponsesBlockLifecycleAndPhasesMatchPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    let cases = try XCTUnwrap(fixture.object("responsesBlockLifecycleEvents"))
    XCTAssertEqual(cases.count, 5)
    for api in ["openai-responses", "azure-openai-responses", "openai-codex-responses"] {
      for (name, value) in cases {
        let expected = try XCTUnwrap(
          oracle.object("cases")?.object("responses.block-lifecycle")?.object(name))
        let chunks = try XCTUnwrap(value.arrayValue).map {
          Data(
            ("data: " + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n\n").utf8
          )
        }
        let (request, context) = inputs(api: api)
        let adapter = try XCTUnwrap(StandardWireProtocols.make().first { $0.protocolID == api })
        let transport = IOSFixtureTransport(chunks: chunks)
        var observed: [JSONValue] = []
        var blockText: [Int: String] = [:]
        var snapshot: ProviderResponseSnapshot?
        for try await event in adapter.stream(request, context: context, transport: transport) {
          if case .contentBlock(let block) = event {
            observed.append(try blockObservation(block, textByIndex: &blockText))
          }
          if case .responseSnapshot(let value) = event { snapshot = value }
        }
        XCTAssertEqual(observed, expected.array("events"), "\(api):\(name)")
        let final = try XCTUnwrap(snapshot)
        XCTAssertEqual(final.finishReason.rawValue, expected.string("stopReason"), name)
        XCTAssertEqual(
          try final.content.map { .object(try blockFields($0)) }, expected.array("content"), name)
      }
    }
  }

  func testCompletionsBlockLifecycleMatchesPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    let cases = try XCTUnwrap(fixture.object("completionBlockLifecycleCases"))
    XCTAssertEqual(cases.count, 5)
    for (name, value) in cases {
      let spec = try XCTUnwrap(value.objectValue)
      let expected = try XCTUnwrap(
        oracle.object("cases")?.object("completions.block-lifecycle")?.object(name))
      let chunks =
        try XCTUnwrap(spec.array("chunks")).map {
          Data(
            ("data: " + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n\n").utf8
          )
        } + [Data("data: [DONE]\n\n".utf8)]
      let (request, context) = inputs(
        api: "openai-completions",
        metadata: [
          "compat": .object([
            "supportsFinishReason": .bool(spec.bool("supportsFinishReason") ?? true)
          ])
        ])
      var observed: [JSONValue] = []
      var blockText: [Int: String] = [:]
      var snapshot: ProviderResponseSnapshot?
      for try await event in OpenAICompletionsAdapter().stream(
        request, context: context,
        transport: IOSFixtureTransport(chunks: chunks))
      {
        if case .contentBlock(let block) = event {
          observed.append(try blockObservation(block, textByIndex: &blockText))
        }
        if case .responseSnapshot(let value) = event { snapshot = value }
      }
      XCTAssertEqual(observed, expected.array("events"), name)
      let final = try XCTUnwrap(snapshot)
      XCTAssertEqual(
        final.finishReason == .toolCalls ? "toolUse" : final.finishReason.rawValue,
        expected.string("stopReason"), name)
      let projected = try final.content.compactMap { content -> JSONValue? in
        switch content {
        case .text, .reasoning: .object(try blockFields(content))
        default: nil
        }
      }
      XCTAssertEqual(projected, expected.array("content"), name)
    }
  }

  private func blockObservation(_ block: ProviderContentBlock, textByIndex: inout [Int: String])
    throws -> JSONValue
  {
    var fields = try blockFields(block.content)
    let kind = fields.string("type") == "text" ? "text" : "thinking"
    let stage: String
    switch block.update {
    case .started: stage = "start"
    case .delta(let delta):
      stage = "delta"
      fields["delta"] = .string(delta)
    case .completed: stage = "end"
    }
    fields["type"] = .string(kind + "_" + stage)
    fields["contentIndex"] = .integer(Int64(block.index))
    if case .delta(let delta) = block.update {
      textByIndex[block.index, default: ""] += delta
    } else {
      textByIndex[block.index] = fields.string("text") ?? ""
    }
    fields["text"] = .string(textByIndex[block.index] ?? "")
    fields["stopReason"] = .string(
      block.provisionalFinishReason == .toolCalls
        ? "toolUse" : block.provisionalFinishReason?.rawValue ?? "pending")
    return .object(fields)
  }

  private func blockFields(_ content: ProviderResponseContent) throws -> [String: JSONValue] {
    let kind: String
    let text: String
    let signature: String?
    switch content {
    case .text(let value):
      kind = "text"
      text = value.text
      signature = value.signature
    case .reasoning(let value):
      kind = "thinking"
      text = value.text
      signature = value.signature
    default: throw NSError(domain: "ios.conformance.unexpectedBlock", code: 1)
    }
    var fields: [String: JSONValue] = ["type": .string(kind), "text": .string(text)]
    if let signature {
      fields["signature"] =
        (try? JSONDecoder().decode(JSONValue.self, from: Data(signature.utf8)))
        ?? .string(signature)
    }
    return fields
  }

  func testCompletionsSDKErrorsStayOutsideRawObserver() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    for (name, value) in try XCTUnwrap(fixture.object("completionSDKErrorEvents")) {
      let sse = try XCTUnwrap(value.stringValue)
      let expected = try XCTUnwrap(
        oracle.object("cases")?.object("completions.sdk-error-events")?.object(name))
      let (request, base) = inputs(
        api: "openai-completions", providerID: "fixture", modelID: "requested-model",
        reasoning: false)
      var context = base
      let capture = IOSWireObserverCapture()
      context.wireObserver = .init(onProviderStreamEvent: { event, model in
        await capture.event(event, model)
      })
      let result = try await replay(
        OpenAICompletionsAdapter(), request: request, context: context, chunks: [Data(sse.utf8)])
      let actual = await capture.events
      XCTAssertEqual(actual, expected.array("events"), name)
      if let message = expected.object("output")?.string("errorMessage") {
        XCTAssertEqual(result.failure?.message, message, name)
      } else {
        XCTAssertNil(result.failure, name)
        XCTAssertEqual(
          result.snapshot?.content, [.text(.init(text: "hello", signature: nil))], name)
      }
    }
  }

  func testCompletionsNativeWireObserverMatchesPinnedSource() async throws {
    let fixture = try load("OpenAIRequestBranches/Cases/response-event-branches.json")
    let oracle = try load("OpenAIRequestBranches/Oracle/response-event-branches.json")
    for (inputKey, oracleKey) in [
      ("completionObserverChunks", "completions.provider-stream-observer"),
      ("completionObserverNonObjectChunks", "completions.non-object-provider-events"),
    ] {
      let chunks = try XCTUnwrap(fixture.array(inputKey))
      let expected = try XCTUnwrap(
        oracle.object("cases")?.object(oracleKey))
      let capture = IOSWireObserverCapture()
      let observer = ProviderWireObserver(
        onPayload: { payload, context in
          await capture.stage("payload", context)
          payload["temperature"] = .number(0.75)
          return nil
        },
        onResponse: { response, context in
          await capture.stage("response", context)
          XCTAssertEqual(response.status, 200)
        },
        onProviderStreamEvent: { event, context in
          await Task.yield()
          await capture.event(event, context)
        })
      let (request, context) = inputs(
        api: "openai-completions", providerID: "fixture", modelID: "requested-model")
      let body =
        try chunks.map {
          "data: " + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n\n"
        }.joined() + "data: [DONE]\n\n"
      let transport = IOSMistralHTTPFixture(status: 200, body: Data(body.utf8))
      let runtime = try CustomProviderRuntime(
        providers: [
          .init(
            id: "fixture", baseURL: context.baseURL,
            api: "openai-completions",
            models: [
              .init(
                id: context.model.id, capabilities: context.model.capabilities,
                metadata: context.modelConfiguration.metadata)
            ])
        ],
        credentialStore: InMemoryProviderCredentialStore(credentials: [
          "fixture": .apiKey(.init(key: "fixture", metadata: [:]))
        ]),
        streamingTransport: transport, wireObserver: observer)
      var snapshot: ProviderResponseSnapshot?
      for try await event in runtime.stream(request) {
        if case .responseSnapshot(let value) = event { snapshot = value }
      }
      let observed = await capture.events
      let models = await capture.models
      let stages = await capture.stages
      let ids = await capture.requestIDs
      XCTAssertEqual(observed, expected.array("events"))
      XCTAssertEqual(models, expected.array("models"))
      XCTAssertEqual(
        stages, ["payload", "response"] + Array(repeating: "event", count: chunks.count))
      XCTAssertEqual(ids, Array(repeating: request.id, count: chunks.count + 2))
      let sent = await transport.sent
      let encoded = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody), providerID: "fixture", operation: "ios.wire-observer")
      XCTAssertEqual(encoded["temperature"], .number(0.75))
      XCTAssertEqual(snapshot?.content, [.text(.init(text: "hello", signature: nil))])
    }
  }

  func testAnthropicNativeWireObserverMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/response-anthropic-bedrock-pi.json")
    let cases = try XCTUnwrap(
      load("Differential/Oracle/response-anthropic-bedrock-pi.json").object("scenarios"))
    for value in try XCTUnwrap(fixture.array("scenarios")) {
      let scenario = try XCTUnwrap(value.objectValue)
      guard scenario.string("protocolID") == "anthropic-messages",
        scenario.bool("observeWire") == true
      else { continue }
      let name = try XCTUnwrap(scenario.string("caseID"))
      let spec = try XCTUnwrap(cases.object(name))
      let expected = try XCTUnwrap(spec.object("wire"))
      let decoder = try XCTUnwrap(spec.object("decoderInput"))
      let chunks = try XCTUnwrap(decoder.array("chunksBase64")).map {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap($0.stringValue)))
      }
      let capture = IOSWireObserverCapture()
      let mode = scenario.string("payloadMode")
      let (request, initialContext) = inputs(
        api: "anthropic-messages", providerID: "anthropic", modelID: "fixture-model")
      var context = initialContext
      context.wireObserver = .init(
        onPayload: { payload, context in
          await Task.yield()
          await capture.stage("payload", context)
          if mode == "replacement" {
            return payload.merging(["stream": .bool(false)]) { _, new in new }
          }
          if mode == "mutation" { payload["stream"] = .bool(false) }
          return nil
        },
        onResponse: { response, context in
          await Task.yield()
          await capture.response(response, context)
        },
        onProviderStreamEvent: { event, context in
          await Task.yield()
          await capture.event(event, context)
        })
      let transport = IOSMistralHTTPFixture(
        status: try XCTUnwrap(decoder.int("status")),
        body: chunks.reduce(into: Data()) { $0.append($1) },
        headers: (decoder.object("headers") ?? [:]).compactMapValues(\.stringValue))
      do {
        for try await _ in AnthropicMessagesAdapter().stream(
          request, context: context, transport: transport)
        {}
        XCTAssertEqual(spec.string("outcome"), "success", name)
      } catch { XCTAssertEqual(spec.string("outcome"), "failure", name) }
      let events = await capture.events
      let models = await capture.models
      let stages = await capture.stages
      let responses = await capture.responses
      let ids = await capture.requestIDs
      XCTAssertEqual(events, expected.array("events"), name)
      XCTAssertEqual(models, expected.array("models"), name)
      XCTAssertEqual(stages.map(JSONValue.string), expected.array("stages"), name)
      XCTAssertEqual(responses, expected.array("responses"), name)
      XCTAssertEqual(ids, Array(repeating: request.id, count: stages.count), name)
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody), providerID: "anthropic", operation: "ios.observer")
      XCTAssertEqual(body["stream"], expected["stream"], name)
    }
  }

  func testResponsesNativeWireObserverMatchesPinnedSourceAcrossFlavors() async throws {
    let specs = try XCTUnwrap(
      load("OpenAIRequestBranches/Cases/response-event-branches.json").object(
        "responsesWireObserverCases"))
    let cases = try XCTUnwrap(
      load("OpenAIRequestBranches/Oracle/response-event-branches.json").object("cases")?.object(
        "responses.wire-observers"))
    for (name, value) in specs {
      let spec = try XCTUnwrap(value.objectValue)
      let api = try XCTUnwrap(spec.string("api"))
      let expected = try XCTUnwrap(cases.object(name))
      let capture = IOSWireObserverCapture()
      let (request, base) = inputs(
        api: api, providerID: try XCTUnwrap(spec.string("provider")),
        modelID: try XCTUnwrap(spec.string("model")))
      var context = base
      context.wireObserver = .init(
        onPayload: { payload, context in
          await Task.yield()
          await capture.stage("payload", context)
          payload["temperature"] = .number(0.75)
          return nil
        },
        onResponse: { response, context in
          await Task.yield()
          await capture.response(response, context)
        },
        onProviderStreamEvent: { event, context in
          await Task.yield()
          await capture.event(event, context)
        })
      let sse =
        try spec.string("body")
        ?? XCTUnwrap(spec.array("events")).map {
          "data: " + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n\n"
        }.joined()
      let transport = IOSMistralHTTPFixture(
        status: spec.int("status") ?? 200, body: Data(sse.utf8),
        headers: [
          "content-type": (spec.int("status") ?? 200) >= 400
            ? "application/json" : "text/event-stream"
        ])
      let adapter = try XCTUnwrap(StandardWireProtocols.make().first { $0.protocolID == api })
      var outcome = "stop"
      do {
        for try await _ in adapter.stream(request, context: context, transport: transport) {}
      } catch { outcome = "error" }
      XCTAssertEqual(outcome, expected.string("outcome"), name)
      let events = await capture.events
      let models = await capture.models
      let stages = await capture.stages
      let responses = await capture.responses
      let ids = await capture.requestIDs
      XCTAssertEqual(events, expected.array("events"), name)
      XCTAssertEqual(models, expected.array("models"), name)
      XCTAssertEqual(stages.map(JSONValue.string), expected.array("stages"), name)
      XCTAssertEqual(responses, expected.array("responses"), name)
      XCTAssertEqual(ids, Array(repeating: request.id, count: stages.count), name)
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody), providerID: request.providerID,
        operation: "ios.responses.observer")
      XCTAssertEqual(body["temperature"], .number(0.75), name)
    }
  }

  func testMistralNativeWireObserverMatchesPinnedSource() async throws {
    let cases = try XCTUnwrap(load("Differential/Oracle/mistral-http.json").object("observers"))
    for (name, value) in cases {
      let expected = try XCTUnwrap(value.objectValue)
      let decoder = try XCTUnwrap(expected.object("decoderInput"))
      let chunks = try XCTUnwrap(decoder.array("chunksBase64")).map {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap($0.stringValue)))
      }
      let capture = IOSWireObserverCapture()
      let (request, base) = inputs(
        api: "mistral-conversations", providerID: "mistral", modelID: "fixture-model")
      var context = base
      context.wireObserver = .init(
        onPayload: { payload, context in
          await Task.yield()
          await capture.stage("payload", context)
          payload["temperature"] = .number(0.25)
          return nil
        },
        onResponse: { response, context in
          await Task.yield()
          await capture.response(response, context)
        },
        onProviderStreamEvent: { event, context in
          await Task.yield()
          await capture.event(event, context)
        })
      let transport = IOSMistralHTTPFixture(
        status: try XCTUnwrap(decoder.int("status")),
        body: chunks.reduce(into: Data()) { $0.append($1) },
        headers: (decoder.object("headers") ?? [:]).compactMapValues(\.stringValue))
      var outcome = "stop"
      var message: String?
      do {
        for try await _ in MistralConversationsAdapter().stream(
          request, context: context, transport: transport)
        {}
      } catch let failure as ProviderRuntimeFailure {
        outcome = "error"
        message = failure.message
      }
      XCTAssertEqual(outcome, expected.string("outcome"), name)
      XCTAssertEqual(message, expected.string("errorMessage"), name)
      let events = await capture.events
      let models = await capture.models
      let stages = await capture.stages
      let responses = await capture.responses
      let ids = await capture.requestIDs
      XCTAssertEqual(events, expected.array("events"), name)
      XCTAssertEqual(models, expected.array("models"), name)
      XCTAssertEqual(stages.map(JSONValue.string), expected.array("stages"), name)
      XCTAssertEqual(responses, expected.array("responses"), name)
      XCTAssertEqual(ids, Array(repeating: request.id, count: stages.count), name)
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody), providerID: "mistral", operation: "ios.mistral.observer")
      XCTAssertEqual(body["temperature"], expected["wireTemperature"], name)
      XCTAssertEqual(body["max_tokens"], expected["wireMaxTokens"], name)
    }
  }

  func testGoogleNativeWireObserverMatchesPinnedSourceAcrossFlavors() async throws {
    let cases = try XCTUnwrap(
      load("Differential/Oracle/response-provider-branches.json").object("cases")?.object(
        "google-native-wire-observer"))
    for (api, value) in cases {
      let spec = try XCTUnwrap(value.objectValue)
      let wire = try XCTUnwrap(spec.object("wire"))
      let events = try XCTUnwrap(spec.object("decoderInput")?.array("events"))
      let capture = IOSWireObserverCapture()
      let provider = api == "google-vertex" ? "fixture-vertex" : "fixture-google"
      let (request, base) = inputs(
        api: api, providerID: provider, modelID: "gemini-3-flash-preview", reasoning: true)
      var context = base
      context.wireObserver = .init(
        onPayload: { payload, context in
          await Task.yield()
          await capture.stage("payload", context)
          var config = payload["generationConfig"]?.objectValue ?? [:]
          config["temperature"] = .number(0.5)
          payload["generationConfig"] = .object(config)
          return nil
        },
        onResponse: { response, context in await capture.response(response, context) },
        onProviderStreamEvent: { event, context in
          await Task.yield()
          await capture.event(event, context)
        })
      let sse = try events.map {
        "data: " + String(decoding: try JSONEncoder().encode($0), as: UTF8.self) + "\n\n"
      }.joined()
      let transport = IOSMistralHTTPFixture(status: 200, body: Data(sse.utf8))
      let adapter = try XCTUnwrap(StandardWireProtocols.make().first { $0.protocolID == api })
      var snapshot: ProviderResponseSnapshot?
      for try await event in adapter.stream(request, context: context, transport: transport) {
        if case .responseSnapshot(let value) = event { snapshot = value }
      }
      let observed = await capture.events
      let models = await capture.models
      let stages = await capture.stages
      let responses = await capture.responses
      let ids = await capture.requestIDs
      XCTAssertEqual(observed, wire.array("events"), api)
      XCTAssertEqual(models, wire.array("models"), api)
      XCTAssertEqual(stages.map(JSONValue.string), wire.array("stages"), api)
      XCTAssertEqual(responses, wire.array("responses"), api)
      XCTAssertEqual(ids, Array(repeating: request.id, count: stages.count), api)
      XCTAssertEqual(
        content(try XCTUnwrap(snapshot)),
        spec.object("sourceOutcome")?.object("terminalReplay")?.array("content"), api)
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody), providerID: provider, operation: "ios.google.observer")
      XCTAssertEqual(body.object("generationConfig")?["temperature"], wire["temperature"], api)
    }
  }

  func testBedrockNativeWireObserverMatchesPinnedSource() async throws {
    let fixture = try load("Differential/Cases/response-anthropic-bedrock-pi.json")
    let cases = try XCTUnwrap(
      load("Differential/Oracle/response-anthropic-bedrock-pi.json").object("scenarios"))
    for value in try XCTUnwrap(fixture.array("scenarios")) {
      let scenario = try XCTUnwrap(value.objectValue)
      guard scenario.string("protocolID") == "bedrock-converse-stream",
        scenario.bool("observeWire") == true
      else { continue }
      let name = try XCTUnwrap(scenario.string("caseID"))
      let spec = try XCTUnwrap(cases.object(name))
      let wire = try XCTUnwrap(spec.object("wire"))
      let decoder = try XCTUnwrap(spec.object("decoderInput"))
      let chunks = try XCTUnwrap(decoder.array("chunksBase64")).map {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap($0.stringValue)))
      }
      let capture = IOSWireObserverCapture()
      let (request, base) = inputs(
        api: "bedrock-converse-stream", providerID: "amazon-bedrock", modelID: "fixture-model")
      var context = base
      context.wireObserver = .init(
        onPayload: { payload, context in
          await Task.yield()
          await capture.stage("payload", context)
          var config = payload["inferenceConfig"]?.objectValue ?? [:]
          config["temperature"] = .number(0.25)
          payload["inferenceConfig"] = .object(config)
          return nil
        },
        onResponse: { response, context in
          await Task.yield()
          await capture.response(response, context)
        },
        onProviderStreamEvent: { event, context in
          await Task.yield()
          await capture.event(event, context)
        })
      let transport = IOSMistralHTTPFixture(
        status: try XCTUnwrap(decoder.int("status")),
        body: chunks.reduce(into: Data()) { $0.append($1) },
        headers: (decoder.object("headers") ?? [:]).compactMapValues(\.stringValue))
      do {
        for try await _ in BedrockConverseStreamAdapter().stream(
          request, context: context, transport: transport)
        {}
        XCTAssertEqual(spec.string("outcome"), "success", name)
      } catch let failure as ProviderRuntimeFailure {
        XCTAssertEqual(spec.string("outcome"), "failure", name)
        XCTAssertEqual(failure.message, spec.object("terminal")?.string("errorMessage"), name)
      }
      let observed = await capture.events
      let models = await capture.models
      let stages = await capture.stages
      let responses = await capture.responses
      let ids = await capture.requestIDs
      XCTAssertEqual(observed, wire.array("events"), name)
      XCTAssertEqual(models, wire.array("models"), name)
      XCTAssertEqual(stages.map(JSONValue.string), wire.array("stages"), name)
      XCTAssertEqual(responses, wire.array("responses"), name)
      XCTAssertEqual(ids, Array(repeating: request.id, count: stages.count), name)
      let sent = await transport.sent
      let body = try decodeJSONObject(
        try XCTUnwrap(sent?.httpBody), providerID: "amazon-bedrock",
        operation: "ios.bedrock.observer")
      XCTAssertEqual(body.object("inferenceConfig")?["temperature"], wire["temperature"], name)
      XCTAssertNil(body["modelId"], name)
    }
  }

  func testAzureCompletionsKeepsMidConversationSystemMessages() async throws {
    let expected = try XCTUnwrap(
      load("OpenAIRequestBranches/Oracle/request-branches.json").object("cases")?.object(
        "azure-completions.mid-system")?.object("requestBody"))
    let (base, context) = inputs(
      api: "openai-completions", providerID: "azure", modelID: "deepseek-v4-pro",
      baseURL: "https://fixture.openai.azure.com/openai/v1", reasoning: true,
      metadata: [
        "compat": .object([
          "supportsMidConvoSystemMessages": .bool(true), "supportsDeveloperRole": .bool(false),
        ])
      ])
    let request = ProviderRequest(
      id: base.id, providerID: base.providerID, modelID: base.modelID,
      messages: [
        .system("first"), .user([.text("hi")]), .system("second"), .user([.text("again")]),
      ], tools: [], options: base.options)
    let transport = IOSMistralHTTPFixture(status: 418, body: Data("fixture".utf8))
    do {
      for try await _ in OpenAICompletionsAdapter().stream(
        request, context: context, transport: transport)
      {}
      XCTFail("expected fixture HTTP failure")
    } catch let failure as ProviderRuntimeFailure { XCTAssertEqual(failure.code, .transportFailed) }
    let sent = await transport.sent
    let body = try decodeJSONObject(
      try XCTUnwrap(sent?.httpBody), providerID: "azure", operation: "ios.mid-system")
    XCTAssertEqual(body["messages"], expected["messages"])
  }

  func testClientIdentityHeadersMatchPinnedSource() throws {
    let fixture = try load("Differential/Cases/client-identity.json")
    let oracle = try load("Differential/Oracle/client-identity.json")
    for value in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(value.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      let target = try XCTUnwrap(spec.object("target"))
      let host = try JSONDecoder().decode(
        ProviderIdentityHost.self, from: JSONEncoder().encode(try XCTUnwrap(spec["host"])))
      let headers = ProviderClientIdentity.headers(
        providerID: try XCTUnwrap(target.string("provider")),
        baseURL: try XCTUnwrap(target.string("baseUrl")), identity: spec.object("identity"),
        host: host)
      XCTAssertEqual(
        JSONValue.object(headers.mapValues(JSONValue.string)), oracle.object("cases")?[name], name)
    }
  }

  func testPreferredStrictFallbackDiagnosticsMatchPinnedSource() async throws {
    let fixture = try load("Differential/Cases/strict-fallback.json")
    let expectedCases = try XCTUnwrap(
      load("Differential/Oracle/strict-fallback.json").object("cases"))
    let schema = try XCTUnwrap(fixture["schema"])
    for value in try XCTUnwrap(fixture.array("cases")) {
      let spec = try XCTUnwrap(value.objectValue)
      let name = try XCTUnwrap(spec.string("id"))
      guard
        [".limit-0", ".second-rejection", ".later-request-restores-strict"].contains(
          where: name.hasSuffix)
      else { continue }
      let api = try XCTUnwrap(spec.string("protocolID"))
      let bedrock = api == "bedrock-converse-stream"
      let providerID = bedrock ? "amazon-bedrock" : "anthropic"
      let expected = try XCTUnwrap(expectedCases.object(name))
      let outcomes = try XCTUnwrap(expected.array("outcomes"))
      let (base, context) = inputs(
        api: api, providerID: providerID, modelID: "fixture-claude", reasoning: false,
        metadata: [
          "compat": .object([bedrock ? "supportsStrictMode" : "supportsStrictTools": .bool(true)])
        ],
        options: .init(
          maximumOutputTokens: 100, temperature: nil, reasoningEffort: nil, responseSchema: nil,
          providerOptions: [:], cacheRetention: .none))
      let tools = try XCTUnwrap(spec.array("preferences")).enumerated().map { index, value in
        ProviderToolDefinition(
          name: "tool_\(index)", description: "Fixture lookup", inputSchema: schema,
          constrainedSampling: value.stringValue.flatMap(ProviderStrictPreference.init(rawValue:))
            .map { .jsonSchema(strict: $0) })
      }
      let request = ProviderRequest(
        id: name, providerID: providerID, modelID: "fixture-claude", messages: base.messages,
        tools: tools, options: base.options)
      let transport = IOSStrictFallbackFixture(spec: spec)
      let adapter = try XCTUnwrap(StandardWireProtocols.make().first { $0.protocolID == api })
      for outcomeValue in outcomes {
        let outcome = try XCTUnwrap(outcomeValue.objectValue)
        var diagnostics: [JSONValue] = []
        do {
          for try await event in adapter.stream(request, context: context, transport: transport) {
            if case .responseSnapshot(let snapshot) = event {
              diagnostics = snapshot.providerMetadata.array("diagnostics") ?? []
            }
          }
          XCTAssertEqual(outcome.string("stopReason"), "stop", name)
        } catch let failure as ProviderRuntimeFailure {
          XCTAssertEqual(outcome.string("stopReason"), "error", name)
          XCTAssertEqual(failure.message, outcome.string("errorMessage"), name)
          diagnostics = failure.providerMetadata?.array("diagnostics") ?? []
        }
        let observed = diagnostics.filter {
          $0.objectValue?.string("type")?.hasSuffix("_strict_tools_fallback") == true
        }
        .map { JSONValue.object(($0.objectValue ?? [:]).filter { $0.key != "timestamp" }) }
        XCTAssertEqual(observed, outcome.array("strictFallbackDiagnostics"), name)
      }
      let attempts = await transport.attempts
      XCTAssertEqual(attempts, expected.array("requests")?.count, name)
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
    chunks: [Data], status: Int = 200,
    headers: [String: String] = ["content-type": "text/event-stream"]
  ) async throws -> (
    snapshot: ProviderResponseSnapshot?, failure: ProviderRuntimeFailure?, starts: Int
  ) {
    var snapshot: ProviderResponseSnapshot?
    var starts = 0
    do {
      for try await event in adapter.stream(
        request, context: context,
        transport: IOSFixtureTransport(chunks: chunks, status: status, headers: headers))
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

private actor IOSStrictFallbackFixture: ProviderHTTPStreamingTransport {
  let spec: [String: JSONValue]
  var attempts = 0
  var httpRequests: [JSONValue] = []
  init(spec: [String: JSONValue]) { self.spec = spec }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    httpRequests.append(
      .object([
        "url": .string(try XCTUnwrap(request.url?.absoluteString)),
        "body": try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody)),
        "headers": .object(
          Dictionary(
            uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).compactMap { key, value in
              let name = key.lowercased()
              return ["anthropic-beta", "anthropic-user-profile-id", "anthropic-workspace-id"]
                .contains(name) ? (name, .string(value)) : nil
            })),
      ]))
    let index = attempts
    attempts += 1
    let bedrock = spec.string("protocolID") == "bedrock-converse-stream"
    let data: Data
    let status: Int
    if let failures = spec.array("failures"), index < failures.count,
      let failure = failures[index].objectValue
    {
      status = try XCTUnwrap(failure.int("status"))
      if let body = failure.string("body") {
        data = Data(body.utf8)
      } else {
        let fields: [String: JSONValue] = [
          "message": try XCTUnwrap(failure["message"]), "__type": try XCTUnwrap(failure["type"]),
        ]
        data = try JSONEncoder().encode(JSONValue.object(fields))
      }
    } else if bedrock {
      status = 200
      var bytes = Data()
      for (type, payload) in [
        ("messageStart", #"{"role":"assistant"}"#), ("messageStop", #"{"stopReason":"end_turn"}"#),
      ] {
        bytes.append(
          try AWSEventStreamDecoder.encode(
            headers: [
              ":message-type": "event", ":event-type": type, ":content-type": "application/json",
            ], payload: Data(payload.utf8)))
      }
      data = bytes
    } else {
      status = 200
      data = Data(
        ("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_fixture\",\"model\":\"fixture-claude\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}\n\n"
          + "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":0}}\n\n"
          + "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n").utf8)
    }
    return .init(
      statusCode: status, headers: ["x-amzn-requestid": "fixture-request"],
      body: AsyncThrowingStream {
        $0.yield(data)
        $0.finish()
      })
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
  let headers: [String: String]
  var sent: URLRequest?

  init(status: Int, body: Data, headers: [String: String] = [:]) {
    self.status = status
    self.body = body
    self.headers = headers
  }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    sent = request
    return .init(
      statusCode: status, headers: headers,
      body: AsyncThrowingStream { continuation in
        continuation.yield(body)
        continuation.finish()
      })
  }
}

private struct IOSFixtureTransport: ProviderHTTPStreamingTransport {
  let chunks: [Data]
  var status = 200
  var headers = ["content-type": "text/event-stream"]

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    .init(
      statusCode: status, headers: headers,
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      })
  }
}

private actor IOSWireObserverCapture {
  var payloads: [JSONValue] = []
  func payload(_ value: JSONValue) { payloads.append(value) }
  var stages: [String] = []
  var requestIDs: [String] = []
  var events: [JSONValue] = []
  var models: [JSONValue] = []
  var responses: [JSONValue] = []
  func stage(_ name: String, _ context: ProviderWireObserver.Context) {
    stages.append(name)
    requestIDs.append(context.requestID)
  }
  func event(_ value: JSONValue, _ context: ProviderWireObserver.Context) {
    stage("event", context)
    events.append(value)
    models.append(
      .object([
        "id": .string(context.model.id), "provider": .string(context.model.providerID),
        "api": .string(context.model.protocolID),
      ]))
  }
  func response(_ response: ProviderWireObserver.Response, _ context: ProviderWireObserver.Context)
  {
    stage("response", context)
    responses.append(
      .object([
        "status": .integer(Int64(response.status)),
        "headers": .object(response.headers.mapValues(JSONValue.string)),
      ]))
  }
}
