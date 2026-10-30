import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct OpenAIResponseEventBranchTests {
  @Test
  func pinnedResponseEventOracleIsReproducible() throws {
    let root = responseEventRepositoryRoot()
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "node", "Scripts/openai-response-event-oracle.mjs", ".build/upstreams/pi",
      "Fixtures/OpenAIRequestBranches/Cases/response-event-branches.json",
    ]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let errorText =
      String(
        data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, Comment(rawValue: errorText))
    let observed = try JSONDecoder().decode(
      JSONValue.self, from: output.fileHandleForReading.readDataToEndOfFile())
    let expected = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(
        contentsOf: root.appending(
          path: "Fixtures/OpenAIRequestBranches/Oracle/response-event-branches.json")))
    #expect(observed == expected)
  }

  @Test
  func responsesCustomNamespaceUsageAndIncompleteTerminalMatchSource() async throws {
    let fixture = try responseEventFixture()
    let grammarTool = responseGrammarTool()

    let custom = try await responseEvents(
      protocolID: "openai-responses", modelID: "gpt-model",
      events: try #require(fixture.array("responsesCustomEvents")),
      tools: [grammarTool],
      metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])])
    #expect(custom.responseID == "resp-terminal")
    #expect(custom.finishReason == .toolCalls)
    #expect(custom.rawFinishReason == "completed")
    #expect(custom.usage?.inputTokens == 15)
    #expect(custom.usage?.outputTokens == 7)
    #expect(custom.usage?.cachedInputTokens == 2)
    #expect(custom.usage?.cacheWriteTokens == 3)
    #expect(custom.usage?.reasoningTokens == 1)
    #expect(custom.usage?.totalTokens == 27)
    guard case .toolCall(let call) = custom.content.first else {
      Issue.record("expected custom tool call snapshot")
      return
    }
    #expect(call.id == "call_1|ctc_1")
    #expect(call.arguments == .object(["payload": .string("abc")]))
    #expect(call.namespace == "dynamic_tools")

    let codex = try await responseEvents(
      protocolID: "openai-codex-responses", modelID: "gpt-5.1-codex",
      events: try #require(fixture.array("responsesCustomEvents")),
      tools: [grammarTool],
      metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])])
    #expect(codex.finishReason == .toolCalls)
    guard case .toolCall(let codexCall) = codex.content.first else {
      Issue.record("expected Codex custom tool call snapshot")
      return
    }
    #expect(codexCall.arguments == .object(["payload": .string("abc")]))
    #expect(codexCall.namespace == "dynamic_tools")

    let incomplete = try await responseEvents(
      protocolID: "openai-responses", modelID: "gpt-model",
      events: try #require(fixture.array("responsesIncompleteEvents")), tools: [], metadata: [:])
    #expect(incomplete.responseID == "resp-incomplete")
    #expect(incomplete.finishReason == .length)
    #expect(incomplete.rawFinishReason == "incomplete.max_output_tokens")
    #expect(incomplete.usage?.inputTokens == 25)
    #expect(incomplete.usage?.outputTokens == 12)
    #expect(incomplete.usage?.cachedInputTokens == 5)
    #expect(incomplete.usage?.cacheWriteTokens == 0)
    #expect(incomplete.usage?.totalTokens == 42)
  }

  @Test
  func responsesServiceTierMonetaryCostsMatchSourceAcrossFlavors() async throws {
    let fixture = try responseEventFixture()
    let usage = try #require(fixture.object("responsesServiceTierUsage"))
    let modelCost: [String: JSONValue] = [
      "input": .integer(1_000_000),
      "output": .integer(2_000_000),
      "cacheRead": .integer(3_000_000),
      "cacheWrite": .integer(4_000_000),
    ]
    let cases:
      [(
        protocolID: String, modelID: String, requestedTier: String?, responseTier: String?,
        expected: ProviderUsageCost
      )] = [
        (
          "openai-responses", "gpt-model", "flex", nil,
          ProviderUsageCost(
            input: 2.5, output: 4, cacheRead: 3, cacheWrite: 6, total: 15.5,
            totalFromProvider: false)
        ),
        (
          "openai-responses", "gpt-model", "flex", "priority",
          ProviderUsageCost(
            input: 10, output: 16, cacheRead: 12, cacheWrite: 24, total: 62,
            totalFromProvider: false)
        ),
        (
          "openai-responses", "gpt-model", nil, "fast",
          ProviderUsageCost(
            input: 10, output: 16, cacheRead: 12, cacheWrite: 24, total: 62,
            totalFromProvider: false)
        ),
        (
          "openai-responses", "gpt-5.5", nil, "priority",
          ProviderUsageCost(
            input: 12.5, output: 20, cacheRead: 15, cacheWrite: 30, total: 77.5,
            totalFromProvider: false)
        ),
        (
          "azure-openai-responses", "gpt-model", nil, "priority",
          ProviderUsageCost(
            input: 5, output: 8, cacheRead: 6, cacheWrite: 12, total: 31, totalFromProvider: false)
        ),
        (
          "openai-codex-responses", "gpt-model", "flex", "default",
          ProviderUsageCost(
            input: 2.5, output: 4, cacheRead: 3, cacheWrite: 6, total: 15.5,
            totalFromProvider: false)
        ),
        (
          "openai-codex-responses", "gpt-model", "flex", "priority",
          ProviderUsageCost(
            input: 10, output: 16, cacheRead: 12, cacheWrite: 24, total: 62,
            totalFromProvider: false)
        ),
      ]

    for testCase in cases {
      var response: [String: JSONValue] = [
        "id": .string("resp-cost"),
        "status": .string("completed"),
        "usage": .object(usage),
      ]
      if let tier = testCase.responseTier { response["service_tier"] = .string(tier) }
      let snapshot = try await responseEvents(
        protocolID: testCase.protocolID,
        modelID: testCase.modelID,
        events: [
          .object([
            "type": .string("response.created"),
            "response": .object(["id": .string("resp-cost"), "model": .string(testCase.modelID)]),
          ]),
          .object(["type": .string("response.completed"), "response": .object(response)]),
        ],
        tools: [], metadata: ["cost": .object(modelCost)],
        serviceTier: testCase.requestedTier)
      #expect(snapshot.usage?.cost == testCase.expected, Comment(rawValue: testCase.protocolID))
    }
  }

  @Test
  func malformedOpenAIPricingFailsExplicitly() async throws {
    do {
      _ = try await responseEvents(
        protocolID: "openai-responses", modelID: "gpt-model",
        events: [], tools: [],
        metadata: ["cost": .object(["input": .integer(1)])])
      Issue.record("expected malformed pricing failure")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .upstreamDrift)
      #expect(failure.operation == "openai-responses.usage.pricing")
    }

    do {
      _ = try await responseEvents(
        protocolID: "openai-responses", modelID: "gpt-model",
        events: [
          .object([
            "type": .string("response.created"),
            "response": .object(["id": .string("resp-missing-cost")]),
          ]),
          .object([
            "type": .string("response.completed"),
            "response": .object([
              "status": .string("completed"),
              "usage": .object(["input_tokens": .integer(1), "output_tokens": .integer(1)]),
            ]),
          ]),
        ], tools: [], metadata: ["cost": .null])
      Issue.record("expected missing pricing failure")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .upstreamDrift)
      #expect(failure.operation == "openai-responses.usage.pricing")
      #expect(failure.message.contains("missing"))
    }
  }

  @Test
  func responsesReasoningStopReasonsAndCustomCallsMatchAllFlavors() async throws {
    let fixture = try responseEventFixture()
    let flavors = [
      ("openai-responses", "gpt-model"),
      ("azure-openai-responses", "deployment-model"),
      ("openai-codex-responses", "gpt-5.1-codex"),
    ]
    for (protocolID, modelID) in flavors {
      let reasoning = try await responseEvents(
        protocolID: protocolID, modelID: modelID,
        events: try #require(fixture.array("responsesReasoningEvents")), tools: [], metadata: [:])
      #expect(reasoning.finishReason == .stop)
      #expect(reasoning.rawFinishReason == "completed")
      let reasoningContent = reasoning.content.compactMap { item -> ProviderReasoningContent? in
        guard case .reasoning(let value) = item else { return nil }
        return value
      }.first
      #expect(reasoningContent?.text == "summary")
      let signature = try #require(reasoningContent?.signature)
      let signatureJSON = try JSONDecoder().decode(JSONValue.self, from: Data(signature.utf8))
      #expect(signatureJSON.objectValue?.string("encrypted_content") == "encrypted")
      let textContent = reasoning.content.compactMap { item -> ProviderTextContent? in
        guard case .text(let value) = item else { return nil }
        return value
      }.first
      let textSignature = try #require(textContent?.signature)
      let textSignatureJSON = try JSONDecoder().decode(
        JSONValue.self, from: Data(textSignature.utf8))
      #expect(textSignatureJSON.objectValue?.string("phase") == "final_answer")

      let incomplete = try await responseEvents(
        protocolID: protocolID, modelID: modelID,
        events: try #require(fixture.array("responsesIncompleteEvents")), tools: [], metadata: [:])
      #expect(incomplete.finishReason == .length)
      #expect(incomplete.rawFinishReason == "incomplete.max_output_tokens")

      let custom = try await responseEvents(
        protocolID: protocolID, modelID: modelID,
        events: try #require(fixture.array("responsesCustomEvents")),
        tools: [responseGrammarTool()],
        metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])])
      #expect(custom.finishReason == .toolCalls)
      guard case .toolCall(let call) = custom.content.first else {
        Issue.record("expected custom tool call for \(protocolID)")
        continue
      }
      #expect(call.namespace == "dynamic_tools")
      #expect(call.arguments == .object(["payload": .string("abc")]))
    }
  }

  @Test
  func terminalResponseWithoutCreatedMatchesPinnedSource() async throws {
    let fixture = try responseEventFixture()
    let cases = try #require(fixture.object("responsesTerminalWithoutStartEvents"))
    let oracle = try decodeJSONObject(
      Data(
        contentsOf: responseEventRepositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Oracle/response-event-branches.json")),
      providerID: "fixture", operation: "terminal-without-start.oracle")
    let expected = try #require(oracle.object("cases")?.object("responses.terminal-without-start"))
    for api in ["openai-responses", "azure-openai-responses", "openai-codex-responses"] {
      for (name, events) in cases {
        let result = try await responseEvents(
          protocolID: api, modelID: "gpt-model", events: try #require(events.arrayValue),
          tools: [], metadata: [:])
        let source = try #require(expected.object(name))
        #expect(result.responseID == source.string("responseId"))
        #expect(result.rawFinishReason == source.string("rawStopReason"))
        #expect(result.finishReason.rawValue == source.string("stopReason"))
        #expect(result.usage?.inputTokens == source.object("usage")?.int("input"))
        #expect(result.usage?.totalTokens == source.object("usage")?.int("totalTokens"))
      }
    }
  }

  @Test
  func responsesFailureBranchesAreTypedAcrossAllFlavors() async throws {
    let fixture = try responseEventFixture()
    let failures = try #require(fixture.object("responsesFailureEvents"))
    let oracle = try decodeJSONObject(
      Data(
        contentsOf: responseEventRepositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Oracle/response-event-branches.json")),
      providerID: "fixture", operation: "failure-message.oracle")
    let expected = try #require(oracle.object("cases")?.object("responses.failure-branches"))
    let expectedCauses = [
      "failedError": "server_error",
      "failedDetails": "policy",
      "streamError": "bad_event",
      "contentFilter": "content_filter",
      "unknownStatus": "mystery",
    ]
    for (protocolID, modelID) in [
      ("openai-responses", "gpt-model"),
      ("azure-openai-responses", "deployment-model"),
      ("openai-codex-responses", "gpt-5.1-codex"),
    ] {
      for (name, cause) in expectedCauses {
        do {
          _ = try await responseEvents(
            protocolID: protocolID, modelID: modelID,
            events: try #require(failures[name]?.arrayValue), tools: [], metadata: [:])
          Issue.record("expected \(name) failure for \(protocolID)")
        } catch let failure as ProviderRuntimeFailure {
          #expect(failure.code == .transportFailed)
          #expect(failure.causeDescription == cause)
          if ["failedError", "failedDetails", "streamError"].contains(name) {
            #expect(failure.message == expected.object(name)?.string("thrown"))
          }
        }
      }
    }
  }

  @Test
  func earlyResponseEOFPreservesSourceError() async throws {
    let fixture = try responseEventFixture()
    let events = try #require(fixture.object("responsesFailureEvents")?.array("earlyEof"))
    do {
      _ = try await responseEvents(
        protocolID: "openai-responses", modelID: "gpt-model", events: events,
        tools: [], metadata: [:])
      Issue.record("expected early EOF failure")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.message == "OpenAI Responses stream ended before a terminal response event")
    }
  }

  @Test
  func unfinishedResponseToolsFailAtTerminalAcrossAllFlavors() async throws {
    let fixture = try responseEventFixture()
    let oracle = try decodeJSONObject(
      Data(
        contentsOf: responseEventRepositoryRoot().appending(
          path:
            "Fixtures/OpenAIRequestBranches/Oracle/response-event-branches.json")),
      providerID: "fixture", operation: "unfinished-tool.oracle")
    #expect(
      oracle.object("cases")?.object("responses.failure-branches")?.object("unfinishedTool")?
        .string("thrown")?.contains("unfinished tool call") == true)
    let events = try #require(fixture.object("responsesFailureEvents")?.array("unfinishedTool"))
    for api in ["openai-responses", "azure-openai-responses", "openai-codex-responses"] {
      do {
        _ = try await responseEvents(
          protocolID: api, modelID: "gpt-model", events: events, tools: [], metadata: [:])
        Issue.record("unfinished tool call completed for \(api)")
      } catch let failure as ProviderRuntimeFailure {
        #expect(failure.code == .invalidResponse)
        #expect(
          failure.message
            == oracle.object("cases")?.object("responses.failure-branches")?
            .object("unfinishedTool")?.string("thrown"))
      }
    }
  }

  @Test
  func toolSlotsMatchSourceAtEveryEmissionAcrossAllFlavors() async throws {
    let fixture = try responseEventFixture()
    let oracle = try decodeJSONObject(
      Data(
        contentsOf: responseEventRepositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Oracle/response-event-branches.json")),
      providerID: "fixture", operation: "responses.tool-slots.oracle")
    let cases = try #require(fixture.object("responseToolSlotEvents"))
    let expectedCases = try #require(
      oracle.object("cases")?.object("responses.tool-slot-lifecycle"))
    for api in ["openai-responses", "azure-openai-responses", "openai-codex-responses"] {
      for name in cases.keys.sorted() {
        let expected = try #require(expectedCases[name]?.objectValue)
        let transport = EventBranchTransport(
          chunks: responsesSSE(try #require(cases[name]?.arrayValue)))
        let (request, context) = eventRequestContext(
          protocolID: api, modelID: "gpt-model", tools: [], metadata: [:])
        let adapter = OpenAIResponsesAdapter(
          protocolID: api,
          flavor: api == "azure-openai-responses"
            ? .azure
            : (api == "openai-codex-responses" ? .codex : .standard))
        var observed: [JSONValue] = []
        var snapshot: ProviderResponseSnapshot?
        var failure: ProviderRuntimeFailure?
        do {
          for try await event in adapter.stream(request, context: context, transport: transport) {
            switch event {
            case .toolCallStarted(let id, let name):
              observed.append(
                .object([
                  "type": .string("toolCallStarted"), "id": .string(id), "name": .string(name),
                ]))
            case .toolInputDelta(let id, let delta):
              observed.append(
                .object([
                  "type": .string("toolInputDelta"), "id": .string(id), "delta": .string(delta),
                ]))
            case .toolCallCompleted(let call):
              observed.append(
                .object([
                  "type": .string("toolCallCompleted"), "id": .string(call.id),
                  "name": .string(call.name), "arguments": call.arguments,
                ]))
            case .responseSnapshot(let value): snapshot = value
            default: break
            }
          }
        } catch let error as ProviderRuntimeFailure { failure = error }
        #expect(observed == expected.array("events"), Comment(rawValue: "\(api):\(name)"))
        if let thrown = expected.string("thrown") {
          #expect(failure?.message == thrown, Comment(rawValue: "\(api):\(name)"))
          #expect(snapshot == nil)
        } else {
          #expect(failure == nil, Comment(rawValue: "\(api):\(name)"))
          let calls = try #require(snapshot).content.compactMap { content -> JSONValue? in
            guard case .toolCall(let call) = content else { return nil }
            return .object([
              "type": .string("toolCall"), "id": .string(call.id), "name": .string(call.name),
              "arguments": call.arguments,
            ])
          }
          #expect(calls == expected.array("content"), Comment(rawValue: "\(api):\(name)"))
        }
      }
    }
  }

  @Test
  func grammarHistoryMapMatchesSourceWithoutCurrentToolDefinitions() async throws {
    let fixture = try responseEventFixture()
    let replay = try #require(fixture.object("responsesGrammarReplay"))
    let source = try #require(replay.object("source"))
    let call = try #require(replay.object("call"))
    let oracle = try decodeJSONObject(
      Data(
        contentsOf: responseEventRepositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Oracle/response-event-branches.json")),
      providerID: "fixture", operation: "grammar-history.oracle")
    let expectedCases = try #require(
      oracle.object("cases")?.object("responses.grammar-history-replay"))
    for (name, value) in try #require(replay.object("cases")) {
      let spec = try #require(value.objectValue)
      let target = try #require(spec.object("target"))
      let api = try #require(target.string("api"))
      let (baseRequest, context) = eventRequestContext(
        protocolID: api, providerID: target.string("provider"),
        modelID: try #require(target.string("id")), tools: [], metadata: [:])
      let toolCall = ProviderToolCall(
        id: try #require(call.string("id")), name: try #require(call.string("name")),
        arguments: try #require(spec["arguments"]), namespace: call.string("namespace"))
      let request = ProviderRequest(
        id: name, providerID: baseRequest.providerID, modelID: baseRequest.modelID,
        messages: [
          .assistantMessage(
            .init(
              content: [.toolCall(toolCall)],
              source: .init(
                api: try #require(source.string("api")),
                providerID: try #require(source.string("provider")),
                modelID: try #require(source.string("model"))),
              usage: .init(
                inputTokens: 0, outputTokens: 0, reasoningTokens: 0,
                cachedInputTokens: 0, providerMetadata: [:]),
              stopReason: .toolUse, timestampMilliseconds: 0)),
          .toolResult(
            .init(
              toolCallID: toolCall.id, toolName: toolCall.name,
              content: [.text(try #require(replay.string("result")))], isError: false)),
        ], tools: [],
        options: .init(
          maximumOutputTokens: 64, temperature: nil,
          reasoningEffort: nil, responseSchema: nil,
          providerOptions: [
            "grammarToolInputProperties": try #require(spec["grammarToolInputProperties"])
          ]))
      let adapter = OpenAIResponsesAdapter(
        protocolID: api,
        flavor: api == "azure-openai-responses"
          ? .azure : api == "openai-codex-responses" ? .codex : .standard)
      let transport = EventBranchTransport(chunks: [], statusCode: 418)
      var failure: ProviderRuntimeFailure?
      do {
        for try await _ in adapter.stream(request, context: context, transport: transport) {}
      } catch let error as ProviderRuntimeFailure { failure = error }
      let sent = await transport.sent
      let expected = try #require(expectedCases.object(name))
      if let thrown = expected.string("thrown") {
        #expect(sent == nil, Comment(rawValue: name))
        #expect(failure?.message == thrown, Comment(rawValue: name))
      } else {
        let body = try decodeJSONObject(
          try #require(sent?.httpBody),
          providerID: "fixture", operation: "grammar-history.body")
        #expect(body.array("input") == expected.array("input"), Comment(rawValue: name))
        #expect(body["grammarToolInputProperties"] == nil, Comment(rawValue: name))
        #expect(body["tools"] == nil, Comment(rawValue: name))
      }
    }
  }

  @Test
  func completionsStructuredReasoningResponseModelAndUsageMatchSource() async throws {
    let fixture = try responseEventFixture()
    let chunks = try #require(fixture.array("completionChunks"))
    let transport = EventBranchTransport(chunks: completionSSE(chunks))
    let (request, context) = eventRequestContext(
      protocolID: "openai-completions", modelID: "requested-model", tools: [], metadata: [:])
    var snapshot: ProviderResponseSnapshot?
    for try await event in OpenAICompletionsAdapter().stream(
      request, context: context, transport: transport)
    {
      if case .responseSnapshot(let value) = event { snapshot = value }
    }
    let result = try #require(snapshot)
    #expect(result.responseID == "chat-1")
    #expect(result.modelID == "requested-model")
    #expect(result.responseModelID == "routed-model")
    #expect(result.finishReason == .stop)
    #expect(result.rawFinishReason == "stop")
    #expect(result.usage?.inputTokens == 7)
    #expect(result.usage?.outputTokens == 4)
    #expect(result.usage?.cachedInputTokens == 2)
    #expect(result.usage?.cacheWriteTokens == 1)
    #expect(result.usage?.reasoningTokens == 1)
    #expect(result.usage?.totalTokens == 14)
    let reasoning = result.content.compactMap { item -> ProviderReasoningContent? in
      guard case .reasoning(let value) = item else { return nil }
      return value
    }.first
    #expect(reasoning?.text == "think")
    let signatureData = try #require(reasoning?.signature?.data(using: .utf8))
    let details = try JSONDecoder().decode(JSONValue.self, from: signatureData)
    #expect(
      details
        == .array([
          .object([
            "type": .string("reasoning.text"), "text": .string("ab"),
            "id": .string("r1"), "signature": .string("sig"),
          ]),
          .object(["type": .string("reasoning.summary"), "summary": .string("sum")]),
          .object(["type": .string("reasoning.encrypted"), "data": .string("opaque")]),
        ]))
  }

  @Test
  func completionsStopReasonReasoningUsageCustomAndCompatBranchesMatchSource() async throws {
    let fixture = try responseEventFixture()
    let branches = try #require(fixture.object("completionBranchChunks"))

    let stop = try await completionEvents(try #require(branches["stop"]?.arrayValue))
    #expect(stop.finishReason == .stop)
    let length = try await completionEvents(try #require(branches["length"]?.arrayValue))
    #expect(length.finishReason == .length)
    let toolUse = try await completionEvents(try #require(branches["toolUse"]?.arrayValue))
    #expect(toolUse.finishReason == .toolCalls)

    let reasoning = try await completionEvents(
      try #require(branches["reasoningPrecedenceChoiceUsage"]?.arrayValue))
    let reasoningContent = reasoning.content.compactMap { item -> ProviderReasoningContent? in
      guard case .reasoning(let value) = item else { return nil }
      return value
    }.first
    #expect(reasoningContent?.text == "preferred")
    #expect(reasoningContent?.signature == "reasoning_content")
    #expect(reasoning.usage?.inputTokens == 4)
    #expect(reasoning.usage?.outputTokens == 3)
    #expect(reasoning.usage?.cachedInputTokens == 1)
    #expect(reasoning.usage?.reasoningTokens == 2)
    #expect(reasoning.usage?.totalTokens == 8)

    let custom = try await completionEvents(
      try #require(branches["customTool"]?.arrayValue), tools: [responseGrammarTool()],
      metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])])
    guard case .toolCall(let customCall) = custom.content.first else {
      Issue.record("expected custom completion tool call")
      return
    }
    #expect(customCall.arguments == .object(["payload": .string("abc")]))

    let missingFinish = try await completionEvents(
      try #require(branches["missingFinish"]?.arrayValue),
      metadata: ["compat": .object(["supportsFinishReason": .bool(false)])])
    #expect(missingFinish.finishReason == .stop)
    #expect(missingFinish.rawFinishReason == nil)
  }

  @Test
  func completionsTransportTerminationMatchesPinnedSource() async throws {
    let fixture = try responseEventFixture()
    let cases = try #require(fixture.object("completionTransportCases"))
    let oracle = try decodeJSONObject(
      Data(
        contentsOf: responseEventRepositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Oracle/response-event-branches.json")),
      providerID: "fixture", operation: "completions.termination.oracle")
    let expectedCases = try #require(
      oracle.object("cases")?.object("completions.transport-termination"))
    for (name, value) in cases {
      let spec = try #require(value.objectValue)
      let expected = try #require(expectedCases[name]?.objectValue)
      let output = try #require(expected.object("output"))
      let (request, context) = eventRequestContext(
        protocolID: "openai-completions", modelID: "requested-model", tools: [],
        metadata: ["compat": .object(["supportsFinishReason": spec["supportsFinishReason"]!])])
      let transport = EventBranchTransport(chunks: [Data(try #require(spec.string("sse")).utf8)])
      var events: [ProviderEvent] = []
      var failure: ProviderRuntimeFailure?
      do {
        for try await event in OpenAICompletionsAdapter().stream(
          request, context: context, transport: transport)
        {
          events.append(event)
        }
      } catch let error as ProviderRuntimeFailure {
        failure = error
      }
      let expectedStarts = expected.array("eventTypes")?.filter { $0 == .string("start") }.count
      #expect(
        events.filter { if case .responseStarted = $0 { true } else { false } }.count
          == expectedStarts)
      if output.string("stopReason") == "error" {
        #expect(failure?.message == output.string("errorMessage"), Comment(rawValue: name))
        #expect(!events.contains { if case .completed = $0 { true } else { false } })
        continue
      }
      #expect(failure == nil, Comment(rawValue: name))
      let snapshot = try #require(
        events.compactMap { event -> ProviderResponseSnapshot? in
          guard case .responseSnapshot(let value) = event else { return nil }
          return value
        }.last)
      #expect(snapshot.finishReason == .stop)
      #expect(snapshot.rawFinishReason == output.string("rawStopReason"))
      #expect(snapshot.responseID == output.string("responseId"))
      let texts = snapshot.content.compactMap { content -> String? in
        guard case .text(let text) = content else { return nil }
        return text.text
      }
      #expect(texts == output.array("content")?.compactMap { $0.objectValue?.string("text") })
      let usage = try #require(snapshot.usage)
      let expectedUsage = try #require(output.object("usage"))
      #expect(usage.inputTokens == expectedUsage.int("input"))
      #expect(usage.outputTokens == expectedUsage.int("output"))
      #expect(usage.cachedInputTokens == expectedUsage.int("cacheRead"))
      #expect(usage.cacheWriteTokens == expectedUsage.int("cacheWrite"))
      #expect(usage.totalTokens == expectedUsage.int("totalTokens"))
    }
  }

  @Test
  func completionsErrorFinishReasonsAreTypedFailures() async throws {
    let branches = try #require(try responseEventFixture().object("completionBranchChunks"))
    for (name, cause, code) in [
      ("contentFilter", "content_filter", ProviderRuntimeFailure.Code.transportFailed),
      ("networkError", "network_error", ProviderRuntimeFailure.Code.transportFailed),
      ("unknownFinish", nil, ProviderRuntimeFailure.Code.invalidResponse),
    ] {
      do {
        _ = try await completionEvents(try #require(branches[name]?.arrayValue))
        Issue.record("expected \(name) completion failure")
      } catch let failure as ProviderRuntimeFailure {
        #expect(failure.code == code)
        #expect(failure.causeDescription == cause)
      }
    }
  }

  @Test
  func openAIAdaptersPreserveHTTPRawMetadataAndCancellation() async throws {
    let rawBody = Data(
      #"{"error":{"message":"bad request","metadata":{"raw":"provider raw detail"}}}"#.utf8)
    let rawTransport = EventBranchTransport(chunks: [rawBody], statusCode: 400)
    let (completionRequest, completionContext) = eventRequestContext(
      protocolID: "openai-completions", modelID: "requested-model", tools: [], metadata: [:])
    do {
      for try await _ in OpenAICompletionsAdapter().stream(
        completionRequest, context: completionContext, transport: rawTransport)
      {}
      Issue.record("expected HTTP raw metadata failure")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .transportFailed)
      #expect(failure.causeDescription?.contains("provider raw detail") == true)
    }

    for (protocolID, modelID) in [
      ("openai-completions", "requested-model"),
      ("openai-responses", "gpt-model"),
      ("azure-openai-responses", "deployment-model"),
      ("openai-codex-responses", "gpt-5.1-codex"),
    ] {
      let (request, context) = eventRequestContext(
        protocolID: protocolID, modelID: modelID, tools: [], metadata: [:])
      let stream =
        protocolID == "openai-completions"
        ? OpenAICompletionsAdapter().stream(
          request, context: context, transport: CancellationEventBranchTransport())
        : OpenAIResponsesAdapter(
          protocolID: protocolID,
          flavor: protocolID == "azure-openai-responses"
            ? .azure : (protocolID == "openai-codex-responses" ? .codex : .standard)
        ).stream(request, context: context, transport: CancellationEventBranchTransport())
      do {
        for try await _ in stream {}
        Issue.record("expected cancellation for \(protocolID)")
      } catch is CancellationError {
        // The adapters preserve the transport cancellation as the typed Swift cancellation.
      }
    }
  }
}

private actor EventBranchTransport: ProviderHTTPStreamingTransport {
  let chunks: [Data]
  let statusCode: Int
  private(set) var sent: URLRequest?
  init(chunks: [Data], statusCode: Int = 200) {
    self.chunks = chunks
    self.statusCode = statusCode
  }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    sent = request
    return ProviderHTTPStreamingResponse(
      statusCode: statusCode, headers: [:],
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      })
  }
}

private actor CancellationEventBranchTransport: ProviderHTTPStreamingTransport {
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    throw CancellationError()
  }
}

private func completionEvents(
  _ chunks: [JSONValue],
  tools: [ProviderToolDefinition] = [],
  metadata: [String: JSONValue] = [:]
) async throws -> ProviderResponseSnapshot {
  let transport = EventBranchTransport(chunks: completionSSE(chunks))
  let (request, context) = eventRequestContext(
    protocolID: "openai-completions", modelID: "requested-model", tools: tools,
    metadata: metadata)
  var snapshot: ProviderResponseSnapshot?
  for try await event in OpenAICompletionsAdapter().stream(
    request, context: context, transport: transport)
  {
    if case .responseSnapshot(let value) = event { snapshot = value }
  }
  return try #require(snapshot)
}

private func responseGrammarTool() -> ProviderToolDefinition {
  ProviderToolDefinition(
    name: "sample_tool", description: "Sample tool",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object(["payload": .object(["type": .string("string")])]),
      "required": .array([.string("payload")]),
    ]),
    constrainedSampling: .grammar(variants: ["openai_lark": "start: /[a-z]+/"]))
}

private func responseEvents(
  protocolID: String,
  modelID: String,
  events: [JSONValue],
  tools: [ProviderToolDefinition],
  metadata: [String: JSONValue],
  serviceTier: String? = nil
) async throws -> ProviderResponseSnapshot {
  let transport = EventBranchTransport(chunks: responsesSSE(events))
  let (request, context) = eventRequestContext(
    protocolID: protocolID, modelID: modelID, tools: tools, metadata: metadata,
    serviceTier: serviceTier)
  var snapshot: ProviderResponseSnapshot?
  let adapter =
    protocolID == "openai-codex-responses"
    ? OpenAIResponsesAdapter(protocolID: protocolID, flavor: .codex)
    : protocolID == "azure-openai-responses"
      ? OpenAIResponsesAdapter(protocolID: protocolID, flavor: .azure)
      : OpenAIResponsesAdapter()
  for try await event in adapter.stream(
    request, context: context, transport: transport)
  {
    if case .responseSnapshot(let value) = event { snapshot = value }
  }
  return try #require(snapshot)
}

private func eventRequestContext(
  protocolID: String,
  providerID: String? = nil,
  modelID: String,
  tools: [ProviderToolDefinition],
  metadata: [String: JSONValue],
  serviceTier: String? = nil
) -> (ProviderRequest, WireProtocolContext) {
  let isCodex = protocolID == "openai-codex-responses"
  let isAzure = protocolID == "azure-openai-responses"
  let providerID =
    providerID ?? (isCodex ? "openai-codex" : (isAzure ? "azure-openai-responses" : "openai"))
  let model = ProviderModel(
    id: modelID,
    providerID: providerID,
    name: modelID, protocolID: protocolID,
    capabilities: ProviderCapabilities(
      textInput: true, imageInput: false, toolCalling: true, reasoning: true,
      structuredOutput: true, imageGeneration: false),
    contextWindow: 32_768, maximumOutputTokens: 4_096)
  let credential: ProviderCredential =
    isCodex
    ? .oauth(
      OAuthCredential(
        accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture,
        metadata: ["accountID": "fixture-account"]))
    : .apiKey(
      APIKeyCredential(
        key: "fixture", metadata: isAzure ? ["deploymentName": modelID] : [:]))
  var effectiveMetadata = metadata
  if effectiveMetadata["cost"] == nil {
    effectiveMetadata["cost"] = .object([
      "input": .integer(0), "output": .integer(0),
      "cacheRead": .integer(0), "cacheWrite": .integer(0),
    ])
  }
  return (
    ProviderRequest(
      id: "event", providerID: providerID, modelID: modelID,
      messages: [.user([.text("hello")])], tools: tools,
      options: ProviderGenerationOptions(
        maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil,
        responseSchema: nil, providerOptions: [:], serviceTier: serviceTier)),
    WireProtocolContext(
      provider: ProviderDescriptor(
        id: providerID, name: providerID, authorizationMethods: [], models: [model]),
      model: model, baseURL: URL(string: "https://fixture.invalid/v1")!, headers: [:],
      credential: credential,
      modelConfiguration: ProviderModelConfiguration(
        protocolID: protocolID, baseURL: nil, headers: [:], metadata: effectiveMetadata))
  )
}

private func responsesSSE(_ events: [JSONValue]) -> [Data] {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  let string = events.map { value in
    let data = try! encoder.encode(value)
    return "data: \(String(data: data, encoding: .utf8)!)\n\n"
  }.joined()
  return [Data(string.utf8)]
}

private func completionSSE(_ chunks: [JSONValue]) -> [Data] {
  responsesSSE(chunks) + [Data("data: [DONE]\n\n".utf8)]
}

private func responseEventFixture() throws -> [String: JSONValue] {
  try decodeJSONObject(
    Data(
      contentsOf: responseEventRepositoryRoot().appending(
        path: "Fixtures/OpenAIRequestBranches/Cases/response-event-branches.json")),
    providerID: "fixture", operation: "response-event.fixture")
}

private func responseEventRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
