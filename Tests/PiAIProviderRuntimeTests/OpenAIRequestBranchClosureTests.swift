import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct OpenAIRequestBranchClosureTests {
  @Test
  func azureCompletionsRetainsMidConversationSystemMessages() async throws {
    let fixture = makeFixture(
      protocolID: "openai-completions", providerID: "azure", modelID: "deepseek-v4-pro",
      reasoning: true,
      baseURL: "https://fixture.openai.azure.com/openai/v1",
      metadata: [
        "compat": .object([
          "supportsMidConvoSystemMessages": .bool(true), "supportsDeveloperRole": .bool(false),
        ])
      ],
      options: options(), tool: .init(name: "unused", description: "", inputSchema: .object([:])),
      messages: [
        .system("first"), .user([.text("hi")]), .system("second"), .user([.text("again")]),
      ], tools: [])
    let transport = BranchCaptureTransport()
    do {
      for try await _ in fixture.adapter.stream(
        fixture.request, context: fixture.context, transport: transport)
      {}
    } catch is ProviderRuntimeFailure {}
    let sent = try #require(await transport.request())
    let body = try decodeJSONObject(
      try fixtureHTTPBody(sent), providerID: "azure", operation: "test.mid-system")
    #expect(
      body["messages"] == (try expectedRequestBody("azure-completions.mid-system"))["messages"])
  }

  @Test
  func pinnedSourceOracleIsReproducible() throws {
    let root = repositoryRoot()
    for stem in ["request-branches", "completions-compat"] {
      let process = Process()
      process.currentDirectoryURL = root
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [
        "node", "Scripts/openai-request-branch-oracle.mjs", ".build/upstreams/pi",
        "Fixtures/OpenAIRequestBranches/Cases/\(stem).json",
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

      let observed = try decodeJSONObject(
        output.fileHandleForReading.readDataToEndOfFile(),
        providerID: "fixture", operation: "openai-request-branch.oracle")
      let expected = try decodeJSONObject(
        Data(
          contentsOf: root.appending(
            path: "Fixtures/OpenAIRequestBranches/Oracle/\(stem).json")),
        providerID: "fixture", operation: "openai-request-branch.fixture")
      #expect(observed == expected)
    }
  }

  @Test
  func completionsCompatGrammarRoutingAndCacheMatchOracle() async throws {
    let schema = toolSchema()
    let compat = try await capture(
      protocolID: "openai-completions", providerID: "fixture", modelID: "chat-model",
      reasoning: false,
      metadata: [
        "compat": .object([
          "supportsUsageInStreaming": .bool(false), "supportsStore": .bool(false),
          "supportsStrictMode": .bool(false), "maxTokensField": .string("max_tokens"),
        ])
      ],
      options: options(maximum: 12, temperature: 0.25, toolChoice: .string("auto")),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema)
    )
    #expect(compat.int("max_tokens") == 12)
    #expect(compat["stream_options"] == nil)
    #expect(compat["store"] == nil)
    #expect(compat.string("tool_choice") == "auto")
    #expect(compat.array("tools")?.first?.objectValue?.object("function")?["strict"] == nil)

    let grammar = try await capture(
      protocolID: "openai-completions", providerID: "fixture", modelID: "chat-model",
      reasoning: false,
      metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])],
      options: options(),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema,
        constrainedSampling: .grammar(variants: ["openai_lark": "start: /[a-z]+/"]))
    )
    let grammarTool = grammar.array("tools")?.first?.objectValue
    #expect(grammarTool?.string("type") == "custom")
    #expect(
      grammarTool?.object("custom")?.object("format")?.object("grammar")?.string("syntax") == "lark"
    )

    let routing = try await capture(
      protocolID: "openai-completions", providerID: "openrouter", modelID: "anthropic/model",
      reasoning: true, baseURL: "https://openrouter.ai/api/v1",
      metadata: [
        "thinkingLevelMap": .object(["high": .string("xhigh")]),
        "compat": .object([
          "thinkingFormat": .string("openrouter"),
          "openRouterRouting": .object(["only": .array([.string("anthropic")])]),
          "cacheControlFormat": .string("anthropic"),
          "supportsLongCacheRetention": .bool(true),
        ]),
      ],
      options: options(effort: .high, sessionID: "branch-session", cache: .long),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema)
    )
    #expect(routing.string("prompt_cache_key") == "branch-session")
    #expect(routing.string("prompt_cache_retention") == "24h")
    #expect(routing.object("provider")?.array("only") == [.string("anthropic")])
    #expect(routing.object("reasoning")?.string("effort") == "xhigh")
    #expect(
      routing.array("messages")?.first?.objectValue?.array("content")?.first?.objectValue?
        .object("cache_control")?.string("ttl") == "1h")
    #expect(
      routing.array("messages")?.last?.objectValue?.array("content")?.last?.objectValue?
        .object("cache_control")?.string("ttl") == "1h")
    #expect(
      routing.array("tools")?.last?.objectValue?.object("cache_control")?.string("ttl") == "1h")

    let retentionOnly = try await capture(
      protocolID: "openai-completions", providerID: "fixture", modelID: "chat-model",
      reasoning: false,
      metadata: ["compat": .object(["supportsLongCacheRetention": .bool(true)])],
      options: options(cache: .long),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema)
    )
    #expect(retentionOnly["prompt_cache_key"] == nil)
    #expect(retentionOnly.string("prompt_cache_retention") == "24h")

    let xai = try await capture(
      protocolID: "openai-responses", providerID: "xai", modelID: "grok-model",
      reasoning: true,
      metadata: [:], options: options(maximum: 1),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema)
    )
    #expect(xai.int("max_output_tokens") == 16)
    #expect(xai.array("include") == [.string("reasoning.encrypted_content")])

    let copilot = try await capture(
      protocolID: "openai-responses", providerID: "github-copilot",
      modelID: "copilot-model", reasoning: true,
      metadata: [:], options: options(),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema)
    )
    #expect(copilot["reasoning"] == nil)
  }

  @Test
  func currentToolsIgnoreObsoleteToolResultAnnotationsLikePinnedSource() async throws {
    let oracle = try decodeJSONObject(
      Data(
        contentsOf: repositoryRoot().appending(
          path:
            "Fixtures/OpenAIRequestBranches/Oracle/request-branches.json")),
      providerID: "fixture", operation: "tool-placement.fixture")
    let cases = try #require(oracle.object("cases"))
    for (caseID, api, provider, compat) in [
      (
        "responses.deferred-additional-tools", "openai-responses", "openai",
        ["supportsAdditionalTools": JSONValue.bool(true)]
      ),
      (
        "responses.deferred-tool-search", "openai-responses", "openai",
        ["supportsToolSearch": JSONValue.bool(true)]
      ),
      (
        "codex.deferred-additional-tools", "openai-codex-responses", "openai-codex",
        ["supportsAdditionalTools": JSONValue.bool(true)]
      ),
      (
        "completions.deferred-kimi", "openai-completions", "kimi",
        ["deferredToolsMode": JSONValue.string("kimi")]
      ),
    ] {
      let body = try await captureDeferred(
        protocolID: api, providerID: provider,
        metadata: ["compat": .object(compat)])
      var actual: [String: JSONValue] = [
        "topLevelToolNames": .array(
          (body.array("tools") ?? []).compactMap {
            ($0.objectValue?.string("name") ?? $0.objectValue?.object("function")?.string("name"))
              .map(JSONValue.string)
          })
      ]
      let input = body.array("input") ?? []
      if caseID == "responses.deferred-tool-search" {
        actual["calls"] = .array(
          input.filter { $0.objectValue?.string("type") == "tool_search_call" })
        actual["outputs"] = .array(
          input.filter { $0.objectValue?.string("type") == "tool_search_output" })
      } else if api == "openai-completions" {
        actual["systemTools"] = .array(
          (body.array("messages") ?? []).compactMap { $0.objectValue?["tools"] })
      } else {
        actual["added"] = .array(
          input.filter { $0.objectValue?.string("type") == "additional_tools" })
      }
      #expect(.object(actual) == cases.object(caseID)?["requestBody"], Comment(rawValue: caseID))
    }
  }

  @Test
  func responsesCacheReasoningAzureAndCodexMatchOracle() async throws {
    let schema = toolSchema()
    let standard = try await capture(
      protocolID: "openai-responses", providerID: "openai", modelID: "gpt-model",
      reasoning: true, baseURL: "https://api.openai.com/v1",
      metadata: [
        "thinkingLevelMap": .object(["off": .string("none")]),
        "compat": .object(["supportsExplicitPromptCacheMode": .bool(true)]),
      ],
      options: options(cache: .none),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema)
    )
    #expect(standard.object("prompt_cache_options")?.string("mode") == "explicit")
    #expect(standard["prompt_cache_key"] == nil)
    #expect(standard.object("reasoning")?.string("effort") == "none")

    let retentionOnly = try await capture(
      protocolID: "openai-responses", providerID: "openai", modelID: "gpt-model",
      reasoning: false, baseURL: "https://api.openai.com/v1",
      metadata: ["compat": .object(["supportsLongCacheRetention": .bool(true)])],
      options: options(cache: .long),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema)
    )
    #expect(retentionOnly["prompt_cache_key"] == nil)
    #expect(retentionOnly.string("prompt_cache_retention") == "24h")

    let longSession = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-OVERFLOW"
    let azure = try await capture(
      protocolID: "azure-openai-responses", providerID: "azure-openai-responses",
      modelID: "source-model", reasoning: true,
      baseURL: "https://fixture.openai.azure.com/openai/v1",
      metadata: ["thinkingLevelMap": .object(["low": .string("minimal")])],
      connectionOptions: ProviderConnectionOptions(
        azureOpenAIResponses: AzureOpenAIResponsesConnectionOptions(
          azureBaseURL: "https://fixture.openai.azure.com/openai/v1",
          azureAPIVersion: "2025-04-01-preview",
          azureDeploymentName: "deployment-branch")),
      options: options(effort: .low, sessionID: longSession),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema)
    )
    #expect(azure.string("model") == "deployment-branch")
    #expect(azure.string("prompt_cache_key") == String(longSession.prefix(64)))
    #expect(azure.object("reasoning")?.string("effort") == "minimal")
    #expect(azure.object("reasoning")?.string("summary") == "auto")
    #expect(azure.array("include") == [.string("reasoning.encrypted_content")])
    #expect(azure.array("tools")?.first?.objectValue?.bool("strict") == false)

    let codex = try await capture(
      protocolID: "openai-codex-responses", providerID: "openai-codex",
      modelID: "gpt-5.1-codex", reasoning: true,
      baseURL: "https://chatgpt.com/backend-api/codex",
      metadata: [:],
      credentialMetadata: ["accountID": "fixture-account"],
      options: options(
        temperature: 0.4, sessionID: "codex-session", cache: .short,
        serviceTier: "priority"),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema)
    )
    #expect(codex.string("instructions") == "System branch fixture")
    #expect(codex.bool("parallel_tool_calls") == true)
    #expect(codex.string("prompt_cache_key") == "codex-session")
    #expect(codex.string("service_tier") == "priority")
    #expect(codex.object("text")?.string("verbosity") == "low")
    #expect(codex.string("tool_choice") == "auto")
    #expect(codex.array("tools")?.first?.objectValue?["strict"] == JSONValue.null)
  }

  @Test
  func azureStrictCompatibilityMatchesSourceFieldPresenceAndRejection() async throws {
    let fixture = try decodeJSONObject(
      Data(
        contentsOf: repositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Cases/request-branches.json")),
      providerID: "fixture", operation: "azure.strict.cases")
    let oracle = try decodeJSONObject(
      Data(
        contentsOf: repositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Oracle/request-branches.json")),
      providerID: "fixture", operation: "azure.strict.oracle")
    for spec in try #require(fixture.array("cases")).compactMap(\.objectValue)
    where spec.string("id")?.hasPrefix("azure.strict-compat-") == true {
      let id = try #require(spec.string("id"))
      let expected = try #require(oracle.object("cases")?.object(id))
      let preference = spec.object("toolConstraint")?.string("strict").flatMap(
        ProviderStrictPreference.init(rawValue:))
      let fixture = makeFixture(
        protocolID: "azure-openai-responses", providerID: "azure-openai-responses",
        modelID: "source-model", reasoning: false, baseURL: try #require(spec.string("baseURL")),
        metadata: ["compat": .object(spec.object("compat") ?? [:])], options: options(),
        tool: .init(
          name: "sample_tool", description: "Sample tool", inputSchema: toolSchema(),
          constrainedSampling: preference.map { .jsonSchema(strict: $0) }))
      let transport = BranchCaptureTransport()
      var failure: ProviderRuntimeFailure?
      do {
        for try await _ in fixture.adapter.stream(
          fixture.request, context: fixture.context, transport: transport)
        {}
      } catch let value as ProviderRuntimeFailure { failure = value }
      if let error = expected.string("errorMessage") {
        #expect(failure?.message == error, Comment(rawValue: id))
        #expect(await transport.request() == nil, Comment(rawValue: id))
      } else {
        let sent = try #require(await transport.request())
        let actual = try decodeJSONObject(
          try fixtureHTTPBody(sent), providerID: "fixture", operation: "azure.strict.capture")
        #expect(actual["tools"] == expected.object("requestBody")?["tools"], Comment(rawValue: id))
      }
    }
  }

  @Test
  func strictRequiredFailureIsTypedAndDoesNotSend() async {
    let transport = BranchCaptureTransport()
    let fixture = makeFixture(
      protocolID: "openai-responses", providerID: "fixture", modelID: "response-model",
      reasoning: false,
      metadata: ["compat": .object(["supportsStrictMode": .bool(false)])],
      options: options(),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema(),
        constrainedSampling: .jsonSchema(strict: .require))
    )
    await #expect(throws: ProviderRuntimeFailure.self) {
      for try await _ in fixture.adapter.stream(
        fixture.request, context: fixture.context, transport: transport)
      {}
    }
    #expect(await transport.request() == nil)
  }

  @Test
  func grammarFailuresAreTypedAndNeverReachTransport() async {
    let protocols = [
      ("openai-completions", "fixture"),
      ("openai-responses", "fixture"),
      ("openai-codex-responses", "openai-codex"),
    ]
    for (protocolID, providerID) in protocols {
      for tool in [
        ProviderToolDefinition(
          name: "sample_tool", description: "Sample tool", inputSchema: toolSchema(),
          constrainedSampling: .grammar(variants: [:])),
        ProviderToolDefinition(
          name: "sample_tool", description: "Sample tool", inputSchema: toolSchema(),
          constrainedSampling: .grammar(
            variants: ["openai_lark": "  ", "openai_regex": ""])),
        ProviderToolDefinition(
          name: "sample_tool", description: "Sample tool",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["payload": .object(["type": .string("number")])]),
            "required": .array([.string("payload")]),
          ]),
          constrainedSampling: .grammar(variants: ["openai_lark": "start: /[a-z]+/"])),
      ] {
        let transport = BranchCaptureTransport()
        let fixture = makeFixture(
          protocolID: protocolID, providerID: providerID, modelID: "model", reasoning: false,
          metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])],
          credentialMetadata: protocolID == "openai-codex-responses"
            ? ["accountID": "fixture-account"] : [:],
          options: options(), tool: tool)
        await #expect(throws: ProviderRuntimeFailure.self) {
          for try await _ in fixture.adapter.stream(
            fixture.request, context: fixture.context, transport: transport)
          {}
        }
        #expect(await transport.request() == nil)
      }
    }
  }

  @Test
  func samplingParametersOverrideNamedFieldsOnlyForPinnedProtocols() async throws {
    for (protocolID, providerID, field) in [
      ("openai-completions", "fixture", "max_completion_tokens"),
      ("openai-responses", "openai", "max_output_tokens"),
      ("azure-openai-responses", "azure-openai-responses", "max_output_tokens"),
    ] {
      let body = try await capture(
        protocolID: protocolID, providerID: providerID, modelID: "model", reasoning: false,
        metadata: [:],
        options: options(
          maximum: 10, temperature: 0.1,
          providerOptions: [field: .integer(77), "temperature": .number(0.7)]),
        tool: ProviderToolDefinition(
          name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
      #expect(body.int(field) == 77)
      #expect(body["temperature"] == .number(0.7))
    }
  }

  @Test
  func responsesReplayHashDifferentModelAndCustomOutputMatchSource() async throws {
    let hashed = try await captureReplay("text-id-hash")
    let message = hashed.array("input")?.first { $0.objectValue?.string("type") == "message" }?
      .objectValue
    #expect(message?.string("id") == "msg_tmmpzgchk7t0")
    #expect(message?.string("phase") == "final_answer")

    let different = try await captureReplay("different-model")
    let function = different.array("input")?.first {
      $0.objectValue?.string("type") == "function_call"
    }?.objectValue
    let output = different.array("input")?.first {
      $0.objectValue?.string("type") == "function_call_output"
    }?.objectValue
    #expect(function?.string("call_id") == "call_1")
    #expect(function?["id"] == nil)
    #expect(function?["namespace"] == nil)
    #expect(output?.string("call_id") == "call_1")

    let custom = try await captureReplay("custom-output")
    let customCall = custom.array("input")?.first {
      $0.objectValue?.string("type") == "custom_tool_call"
    }?.objectValue
    let customOutput = custom.array("input")?.first {
      $0.objectValue?.string("type") == "custom_tool_call_output"
    }?.objectValue
    #expect(customCall?.string("id") == "ctc_1")
    #expect(customCall?.string("input") == "abc")
    #expect(customCall?.string("namespace") == "dynamic_tools")
    #expect(customOutput?.string("call_id") == "call_1")
    #expect(customOutput?.string("output") == "done")

    for (protocolID, providerID, baseURL) in [
      (
        "azure-openai-responses", "azure-openai-responses",
        "https://fixture.openai.azure.com/openai/v1"
      ),
      (
        "openai-codex-responses", "openai-codex",
        "https://chatgpt.com/backend-api/codex"
      ),
    ] {
      for variant in ["text-id-hash", "different-model", "custom-output"] {
        let body = try await captureReplay(
          variant, protocolID: protocolID, providerID: providerID, baseURL: baseURL,
          modelID: "matrix-model")
        let expected = try expectedRequestBody(protocolID + ".replay-" + variant)
        #expect(["input": body["input"] ?? .null] == expected)
      }
    }
  }

  @Test
  func customReasoningBudgetAndAdvancedToolChoicesMatchSource() async throws {
    let budget = try await capture(
      protocolID: "openai-completions", providerID: "fixture", modelID: "reasoning-model",
      reasoning: true,
      metadata: [
        "compat": .object([
          "supportsReasoningEffort": .bool(true),
          "thinkingTokenBudgetField": .string("thinking_token_budget"),
        ])
      ],
      options: options(
        maximum: 4_096, effort: .high, thinkingBudgets: [.high: 3_072]),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    #expect(budget.int("max_completion_tokens") == 4_096)
    #expect(budget.string("reasoning_effort") == "high")
    #expect(budget.int("thinking_token_budget") == 3_072)

    for (protocolID, providerID, choice) in [
      (
        "openai-completions", "fixture",
        JSONValue.object([
          "type": .string("function"),
          "function": .object(["name": .string("sample_tool")]),
        ])
      ),
      (
        "openai-responses", "openai",
        JSONValue.object(["type": .string("function"), "name": .string("sample_tool")])
      ),
      (
        "azure-openai-responses", "azure-openai-responses",
        JSONValue.object(["type": .string("function"), "name": .string("sample_tool")])
      ),
    ] {
      let body = try await capture(
        protocolID: protocolID, providerID: providerID, modelID: "model", reasoning: false,
        metadata: [:],
        credentialMetadata: protocolID == "openai-codex-responses"
          ? ["accountID": "fixture-account"] : [:],
        options: options(toolChoice: choice),
        tool: ProviderToolDefinition(
          name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
      #expect(body["tool_choice"] == choice)
    }

    let codexNamedTransport = BranchCaptureTransport()
    let codexNamed = makeFixture(
      protocolID: "openai-codex-responses", providerID: "openai-codex",
      modelID: "gpt-5.1-codex", reasoning: true,
      baseURL: "https://chatgpt.com/backend-api/codex", metadata: [:],
      credentialMetadata: ["accountID": "fixture-account"],
      options: options(
        toolChoice: .object([
          "type": .string("function"), "name": .string("sample_tool"),
        ])),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    await #expect(throws: ProviderRuntimeFailure.self) {
      for try await _ in codexNamed.adapter.stream(
        codexNamed.request, context: codexNamed.context,
        transport: codexNamedTransport)
      {}
    }
    #expect(await codexNamedTransport.request() == nil)
  }

  @Test
  func strictInvalidRequiredPropertyFailureIsTypedAndDoesNotSend() async {
    let transport = BranchCaptureTransport()
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "payload": .object(["type": .string("string")])
      ]),
      "required": .array([.string("missing")]),
    ])
    let fixture = makeFixture(
      protocolID: "openai-responses", providerID: "fixture", modelID: "response-model",
      reasoning: false,
      metadata: ["compat": .object(["supportsStrictMode": .bool(true)])],
      options: options(),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: schema,
        constrainedSampling: .jsonSchema(strict: .require))
    )
    do {
      for try await _ in fixture.adapter.stream(
        fixture.request, context: fixture.context, transport: transport)
      {}
      Issue.record("invalid strict required property unexpectedly reached transport")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .invalidRequest)
      #expect(failure.message.contains("required contains an unknown property"))
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(await transport.request() == nil)
  }

  @Test
  func azureEnvironmentResourceAndMissingBaseConfigurationMatchSource() async throws {
    let configurations: [(ProviderConnectionOptions, String, String)] = [
      (
        ProviderConnectionOptions(
          azureOpenAIResponses: AzureOpenAIResponsesConnectionOptions(
            environment: [
              "AZURE_OPENAI_BASE_URL": "https://environment.openai.azure.com/openai/v1",
              "AZURE_OPENAI_API_VERSION": "2025-04-01-preview",
              "AZURE_OPENAI_DEPLOYMENT_NAME_MAP": "source-model=environment-deployment",
            ])),
        "environment.openai.azure.com", "environment-deployment"
      ),
      (
        ProviderConnectionOptions(
          azureOpenAIResponses: AzureOpenAIResponsesConnectionOptions(
            azureResourceName: "fixture-resource")),
        "fixture-resource.openai.azure.com", "source-model"
      ),
    ]
    for (connectionOptions, expectedHost, expectedModel) in configurations {
      let transport = BranchCaptureTransport()
      let fixture = makeFixture(
        protocolID: "azure-openai-responses", providerID: "azure-openai-responses",
        modelID: "source-model", reasoning: false, baseURL: "relative", metadata: [:],
        connectionOptions: connectionOptions, options: options(),
        tool: ProviderToolDefinition(
          name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
      do {
        for try await _ in fixture.adapter.stream(
          fixture.request, context: fixture.context, transport: transport)
        {}
      } catch is ProviderRuntimeFailure {}
      let sent = try #require(await transport.request())
      #expect(sent.url?.host == expectedHost)
      #expect(sent.url?.path == "/openai/v1/responses")
      let body = try decodeJSONObject(
        try fixtureHTTPBody(sent), providerID: "fixture", operation: "azure.config.capture")
      #expect(body.string("model") == expectedModel)
    }

    let missingTransport = BranchCaptureTransport()
    let missing = makeFixture(
      protocolID: "azure-openai-responses", providerID: "azure-openai-responses",
      modelID: "source-model", reasoning: false, baseURL: "relative", metadata: [:],
      options: options(),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    do {
      for try await _ in missing.adapter.stream(
        missing.request, context: missing.context, transport: missingTransport)
      {}
      Issue.record("missing Azure base configuration unexpectedly reached transport")
    } catch let failure as ProviderRuntimeFailure {
      #expect(failure.code == .invalidRequest)
      #expect(failure.message.contains("Invalid Azure OpenAI base URL"))
    }
    #expect(await missingTransport.request() == nil)
  }

  @Test
  func grammarMatrixMatchesSourceAndInvalidInputsFailBeforeTransport() async throws {
    let protocols = [
      ("openai-completions", "fixture", "https://fixture.invalid/v1", false),
      ("openai-responses", "openai", "https://api.openai.com/v1", false),
      (
        "azure-openai-responses", "azure-openai-responses",
        "https://fixture.openai.azure.com/openai/v1", false
      ),
      (
        "openai-codex-responses", "openai-codex",
        "https://chatgpt.com/backend-api/codex", true
      ),
    ]
    let variants = [
      ("lark", ["openai_lark": "start: /[a-z]+/"]),
      ("regex", ["openai_regex": "[a-z]+"]),
      (
        "lark-precedence",
        ["openai_lark": "start: /[a-z]+/", "openai_regex": "[0-9]+"]
      ),
    ]
    for (protocolID, providerID, baseURL, reasoning) in protocols {
      for (variant, definitions) in variants {
        let body = try await capture(
          protocolID: protocolID, providerID: providerID, modelID: "matrix-model",
          reasoning: reasoning, baseURL: baseURL,
          metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])],
          credentialMetadata: protocolID == "openai-codex-responses"
            ? ["accountID": "fixture-account"] : [:],
          options: options(),
          tool: ProviderToolDefinition(
            name: "sample_tool", description: "Sample tool", inputSchema: toolSchema(),
            constrainedSampling: .grammar(variants: definitions)))
        let observed = ["tools": body["tools"] ?? .null]
        let expected = try expectedRequestBody(protocolID + ".grammar-" + variant)
        #expect(
          observed == expected,
          Comment(rawValue: protocolID + " " + variant))
      }
    }

    let invalidSchemas: [(String, JSONValue)] = [
      ("non-object", .object(["type": .string("string")])),
      (
        "required-zero",
        .object([
          "type": .string("object"),
          "properties": .object(["payload": .object(["type": .string("string")])]),
          "required": .array([]),
        ])
      ),
      (
        "required-two",
        .object([
          "type": .string("object"),
          "properties": .object([
            "payload": .object(["type": .string("string")]),
            "extra": .object(["type": .string("string")]),
          ]),
          "required": .array([.string("payload"), .string("extra")]),
        ])
      ),
      (
        "missing-required-property",
        .object([
          "type": .string("object"),
          "properties": .object(["payload": .object(["type": .string("string")])]),
          "required": .array([.string("missing")]),
        ])
      ),
      (
        "non-string",
        .object([
          "type": .string("object"),
          "properties": .object(["payload": .object(["type": .string("number")])]),
          "required": .array([.string("payload")]),
        ])
      ),
    ]
    for (protocolID, providerID, baseURL, reasoning) in protocols {
      for (variant, schema) in invalidSchemas {
        let transport = BranchCaptureTransport()
        let fixture = makeFixture(
          protocolID: protocolID, providerID: providerID, modelID: "matrix-model",
          reasoning: reasoning, baseURL: baseURL,
          metadata: ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])],
          credentialMetadata: protocolID == "openai-codex-responses"
            ? ["accountID": "fixture-account"] : [:],
          options: options(),
          tool: ProviderToolDefinition(
            name: "sample_tool", description: "Sample tool", inputSchema: schema,
            constrainedSampling: .grammar(variants: ["openai_lark": "start: /[a-z]+/"])))
        await #expect(throws: ProviderRuntimeFailure.self) {
          for try await _ in fixture.adapter.stream(
            fixture.request, context: fixture.context, transport: transport)
          {}
        }
        #expect(
          await transport.request() == nil,
          Comment(rawValue: protocolID + " " + variant))
      }
    }
  }

  @Test
  func requiredToolChoiceMatchesAllDirectSourceProtocols() async throws {
    for (protocolID, providerID, baseURL, reasoning) in [
      ("openai-completions", "fixture", "https://fixture.invalid/v1", false),
      ("openai-responses", "openai", "https://api.openai.com/v1", false),
      (
        "azure-openai-responses", "azure-openai-responses",
        "https://fixture.openai.azure.com/openai/v1", false
      ),
      (
        "openai-codex-responses", "openai-codex",
        "https://chatgpt.com/backend-api/codex", true
      ),
    ] {
      let body = try await capture(
        protocolID: protocolID, providerID: providerID, modelID: "matrix-model",
        reasoning: reasoning, baseURL: baseURL, metadata: [:],
        credentialMetadata: protocolID == "openai-codex-responses"
          ? ["accountID": "fixture-account"] : [:],
        options: options(toolChoice: .string("required")),
        tool: ProviderToolDefinition(
          name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
      #expect(body.string("tool_choice") == "required")
    }
  }

  @Test
  func completionsReasoningFormatAndBudgetMatricesMatchSource() async throws {
    let formats: [(String, String, [String: JSONValue])] = [
      ("deepseek", "fixture", [:]), ("together", "fixture", [:]),
      (
        "baseten", "fixture",
        [
          "chatTemplateArgs": .object([
            "enabled": .object(["$var": .string("thinking.enabled")]),
            "level": .object(["$var": .string("thinking.level")]),
            "budget": .object([
              "$var": .string("thinking.budget"), "omitWhenOff": .bool(true),
            ]),
          ])
        ]
      ),
      ("zai", "fixture", [:]), ("qwen", "fixture", [:]),
      ("qwen-chat-template", "fixture", [:]),
      (
        "chat-template", "fixture",
        [
          "chatTemplateKwargs": .object([
            "enabled": .object(["$var": .string("thinking.enabled")]),
            "level": .object(["$var": .string("thinking.level")]),
            "budget": .object([
              "$var": .string("thinking.budget"), "omitWhenOff": .bool(true),
            ]),
          ])
        ]
      ),
      ("string-thinking", "fixture", [:]), ("ant-ling", "fixture", [:]),
      ("openrouter", "openrouter", [:]), ("openai", "fixture", [:]),
    ]
    let projectionKeys = [
      "reasoning", "reasoning_effort", "thinking", "enable_thinking",
      "chat_template_kwargs", "chat_template_args",
    ]
    for (format, providerID, extraCompat) in formats {
      for state in ["enabled", "off", "mapped-null"] {
        var map: [String: JSONValue] = ["low": .string("source-low")]
        if state == "mapped-null" { map["off"] = .null }
        var compat = extraCompat
        compat["thinkingFormat"] = .string(format)
        compat["supportsReasoningEffort"] = .bool(true)
        let body = try await capture(
          protocolID: "openai-completions", providerID: providerID,
          modelID: "reasoning-model", reasoning: true,
          metadata: ["thinkingLevelMap": .object(map), "compat": .object(compat)],
          options: options(
            maximum: state == "enabled" ? 4_096 : nil,
            effort: state == "enabled" ? .low : .off),
          tool: ProviderToolDefinition(
            name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
        let observed = Dictionary(
          uniqueKeysWithValues: projectionKeys.compactMap { key in body[key].map { (key, $0) } })
        let expected = try expectedRequestBody(
          "completions.reasoning-" + format + "-" + state)
        #expect(
          observed == expected,
          Comment(rawValue: format + " " + state))
      }
    }

    for field in ["thinking_token_budget", "thinking_budget", "thinking_budget_tokens"] {
      let body = try await capture(
        protocolID: "openai-completions", providerID: "fixture",
        modelID: "reasoning-model", reasoning: true,
        metadata: [
          "compat": .object([
            "supportsReasoningEffort": .bool(true),
            "thinkingTokenBudgetField": .string(field),
          ])
        ],
        options: options(maximum: 2_048, effort: .high, thinkingBudgets: [.high: 9_999]),
        tool: ProviderToolDefinition(
          name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
      let observed = Dictionary(
        uniqueKeysWithValues: ["max_completion_tokens", "reasoning_effort", field]
          .compactMap { key in body[key].map { (key, $0) } })
      let expected = try expectedRequestBody("completions.budget-" + field)
      #expect(observed == expected)
    }
  }

  @Test
  func templateEffortsAndBudgetsMatchSourceWithoutExtraCapabilityRejections() async throws {
    let fixture = try decodeJSONObject(
      Data(
        contentsOf: repositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Cases/request-branches.json")),
      providerID: "fixture", operation: "template.cases")
    let oracle = try decodeJSONObject(
      Data(
        contentsOf: repositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Oracle/request-branches.json")),
      providerID: "fixture", operation: "template.oracle")
    for value in try #require(fixture.array("cases")) {
      let spec = try #require(value.objectValue)
      guard let id = spec.string("id"), id.hasPrefix("completions.template-") else { continue }
      let metadata: [String: JSONValue] = [
        "compat": try #require(spec["compat"]),
        "thinkingLevelMap": try #require(spec["thinkingLevelMap"]),
      ]
      let expected = try #require(oracle.object("cases")?.object(id))
      let levels = try ProviderReasoning.supportedEfforts(
        reasoning: true, metadata: metadata, protocolID: "openai-completions", providerID: "fixture"
      )
      #expect(
        levels.map { JSONValue.string($0.rawValue) } == expected.array("supportedThinkingLevels"),
        Comment(rawValue: id))
      let rawOptions = try #require(spec.object("options"))
      let budgets = rawOptions.object("thinkingBudgets").map { raw in
        Dictionary(
          uniqueKeysWithValues: raw.compactMap { key, value -> (ProviderReasoningEffort, Int)? in
            guard let effort = ProviderReasoningEffort(rawValue: key),
              case .integer(let count) = value
            else { return nil }
            return (effort, Int(count))
          })
      }
      do {
        let body = try await capture(
          protocolID: "openai-completions", providerID: "fixture", modelID: "template-model",
          reasoning: true, metadata: metadata,
          options: options(
            maximum: rawOptions.int("maxTokens"),
            effort: rawOptions.string("reasoningEffort").flatMap(
              ProviderReasoningEffort.init(rawValue:)),
            thinkingBudgets: budgets),
          tool: ProviderToolDefinition(
            name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
        let projection = Dictionary(
          uniqueKeysWithValues:
            try #require(spec.array("projectFields")).compactMap { value -> (String, JSONValue)? in
              guard let key = value.stringValue, let value = body[key] else { return nil }
              return (key, value)
            })
        #expect(projection == expected.object("requestBody"), Comment(rawValue: id))
      } catch { Issue.record("\(id): \(error)") }
    }
  }

  @Test
  func detectedCompatibilityMatchesSourceRequestsAndWireHeaders() async throws {
    let fixture = try decodeJSONObject(
      Data(
        contentsOf: repositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Cases/completions-compat.json")),
      providerID: "fixture", operation: "completions.compat.cases")
    let oracle = try decodeJSONObject(
      Data(
        contentsOf: repositoryRoot().appending(
          path: "Fixtures/OpenAIRequestBranches/Oracle/completions-compat.json")),
      providerID: "fixture", operation: "completions.compat.oracle")
    for value in try #require(fixture.array("cases")) {
      let spec = try #require(value.objectValue)
      let id = try #require(spec.string("id"))
      let rawOptions = try #require(spec.object("options"))
      let target = makeFixture(
        protocolID: "openai-completions",
        providerID: try #require(spec.string("providerID")),
        modelID: try #require(spec.string("modelID")),
        reasoning: true, baseURL: try #require(spec.string("baseURL")),
        metadata: ["compat": try #require(spec["compat"])],
        options: options(
          maximum: rawOptions.int("maxTokens"), effort: .low,
          sessionID: rawOptions.string("sessionId"), cache: .long),
        tool: ProviderToolDefinition(
          name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
      let transport = BranchCaptureTransport()
      do {
        for try await _ in target.adapter.stream(
          target.request, context: target.context, transport: transport)
        {}
      } catch let failure as ProviderRuntimeFailure {
        #expect(failure.code == .transportFailed, Comment(rawValue: id))
      }
      let request = try #require(await transport.request())
      let body = try decodeJSONObject(
        try #require(request.httpBody),
        providerID: "fixture", operation: "completions.compat.body")
      let projected = Dictionary(
        uniqueKeysWithValues:
          try #require(spec.array("projectFields")).compactMap { value -> (String, JSONValue)? in
            guard let key = value.stringValue, let value = body[key] else { return nil }
            return (key, value)
          })
      let headers = Dictionary(
        uniqueKeysWithValues:
          try #require(spec.array("headerKeys")).map { value -> (String, JSONValue) in
            let key = try #require(value.stringValue)
            return (key, request.value(forHTTPHeaderField: key).map(JSONValue.string) ?? .null)
          })
      let expected = try #require(oracle.object("cases")?.object(id))
      #expect(projected == expected.object("requestBody"), Comment(rawValue: id))
      #expect(headers == expected.object("requestHeaders"), Comment(rawValue: id))
    }
  }

  @Test
  func responsesSummaryAndCodexVerbosityMatchSource() async throws {
    let summary = try await capture(
      protocolID: "openai-responses", providerID: "openai", modelID: "gpt-model",
      reasoning: true, baseURL: "https://api.openai.com/v1", metadata: [:],
      options: options(reasoningSummary: "detailed"),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    #expect(summary.object("reasoning")?.string("effort") == "medium")
    #expect(summary.object("reasoning")?.string("summary") == "detailed")
    #expect(summary.array("include") == [.string("reasoning.encrypted_content")])

    let verbosity = try await capture(
      protocolID: "openai-codex-responses", providerID: "openai-codex",
      modelID: "codex-model", reasoning: true,
      baseURL: "https://chatgpt.com/backend-api/codex", metadata: [:],
      credentialMetadata: ["accountID": "fixture-account"],
      options: options(textVerbosity: "high"),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    #expect(verbosity.object("text")?.string("verbosity") == "high")

    let defaultTransport = BranchCaptureTransport()
    let defaultFixture = makeFixture(
      protocolID: "openai-codex-responses", providerID: "openai-codex",
      modelID: "codex-model", reasoning: true,
      baseURL: "https://chatgpt.com/backend-api/codex", metadata: [:],
      credentialMetadata: ["accountID": "fixture-account"], options: options(),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()),
      messages: [.user([.text("hello")])])
    do {
      for try await _ in defaultFixture.adapter.stream(
        defaultFixture.request, context: defaultFixture.context, transport: defaultTransport)
      {}
    } catch is ProviderRuntimeFailure {}
    let defaultRequest = try #require(await defaultTransport.request())
    let defaultBody = try decodeJSONObject(
      try fixtureHTTPBody(defaultRequest), providerID: "fixture",
      operation: "codex.default-instructions")
    #expect(defaultBody.string("instructions") == "You are a helpful assistant.")
  }

  @Test
  func completionsCompatMessagesRoutingAndCacheMarkersMatchSource() async throws {
    for (caseID, reasoning, compat, signature) in [
      (
        "completions.compat-tool-result-name", false,
        ["requiresToolResultName": JSONValue.bool(true)], "reasoning_content"
      ),
      (
        "completions.compat-assistant-bridge", false,
        ["requiresAssistantAfterToolResult": JSONValue.bool(true)], "reasoning_content"
      ),
      (
        "completions.compat-thinking-as-text", true,
        ["requiresThinkingAsText": JSONValue.bool(true)], "reasoning_content"
      ),
      (
        "completions.compat-reasoning-content", true,
        ["requiresReasoningContentOnAssistantMessages": JSONValue.bool(true)], "reasoning"
      ),
    ] {
      let body = try await captureCompatTranscript(
        reasoning: reasoning, compat: compat, signature: signature)
      let expected = try expectedRequestBody(caseID)
      #expect(
        ["messages": body["messages"] ?? .null] == expected,
        Comment(rawValue: caseID))
    }

    let zai = try await capture(
      protocolID: "openai-completions", providerID: "fixture", modelID: "chat-model",
      reasoning: false,
      metadata: ["compat": .object(["zaiToolStream": .bool(true)])],
      options: options(),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    #expect(zai.bool("tool_stream") == true)

    let vercel = try await capture(
      protocolID: "openai-completions", providerID: "vercel", modelID: "chat-model",
      reasoning: false, baseURL: "https://ai-gateway.vercel.sh/v1",
      metadata: [
        "compat": .object([
          "vercelGatewayRouting": .object([
            "only": .array([.string("anthropic")]),
            "order": .array([.string("anthropic"), .string("openai")]),
          ])
        ])
      ],
      options: options(),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    let expectedVercel = try expectedRequestBody("completions.vercel-routing")
    #expect(["providerOptions": vercel["providerOptions"] ?? .null] == expectedVercel)

    for retention in [ProviderCacheRetention.short, .long] {
      let body = try await capture(
        protocolID: "openai-completions", providerID: "openrouter",
        modelID: "anthropic/model", reasoning: false,
        baseURL: "https://openrouter.ai/api/v1",
        metadata: [
          "compat": .object([
            "cacheControlFormat": .string("anthropic"),
            "supportsLongCacheRetention": .bool(true),
          ])
        ], options: options(cache: retention),
        tool: ProviderToolDefinition(
          name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
      let expected = try expectedRequestBody(
        "completions.anthropic-cache-" + retention.rawValue)
      #expect(
        ["messages": body["messages"] ?? .null, "tools": body["tools"] ?? .null]
          == expected)
    }
  }

  @Test
  func responsesProviderCacheBranchesMatchSource() async throws {
    let github = try await capture(
      protocolID: "openai-responses", providerID: "github-copilot", modelID: "gpt-model",
      reasoning: true, baseURL: "https://api.githubcopilot.com", metadata: [:],
      options: options(),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    #expect(github["reasoning"] == nil)
    #expect(github["include"] == nil)

    let unsupportedLong = try await capture(
      protocolID: "openai-responses", providerID: "fixture", modelID: "gpt-model",
      reasoning: false,
      metadata: ["compat": .object(["supportsLongCacheRetention": .bool(false)])],
      options: options(sessionID: "cache-session", cache: .long),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    #expect(unsupportedLong.string("prompt_cache_key") == "cache-session")
    #expect(unsupportedLong["prompt_cache_retention"] == nil)

    let environmentLong = try await capture(
      protocolID: "openai-responses", providerID: "openai", modelID: "gpt-model",
      reasoning: false, baseURL: "https://api.openai.com/v1", metadata: [:],
      options: options(
        sessionID: "cache-session", environment: ["PI_CACHE_RETENTION": "long"]),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    #expect(environmentLong.string("prompt_cache_key") == "cache-session")
    #expect(environmentLong.string("prompt_cache_retention") == "24h")

    let unsupportedNone = try await capture(
      protocolID: "openai-responses", providerID: "fixture", modelID: "gpt-model",
      reasoning: false,
      metadata: ["compat": .object(["supportsExplicitPromptCacheMode": .bool(false)])],
      options: options(sessionID: "cache-session", cache: .none),
      tool: ProviderToolDefinition(
        name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()))
    #expect(unsupportedNone["prompt_cache_key"] == nil)
    #expect(unsupportedNone["prompt_cache_options"] == nil)
  }
}

private actor BranchCaptureTransport: ProviderHTTPStreamingTransport {
  private var captured: URLRequest?
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    captured = request
    return ProviderHTTPStreamingResponse(
      statusCode: 418, headers: [:],
      body: AsyncThrowingStream { continuation in continuation.finish() })
  }
  func request() -> URLRequest? { captured }
}

private func capture(
  protocolID: String, providerID: String, modelID: String, reasoning: Bool,
  baseURL: String = "https://fixture.invalid/v1",
  metadata: [String: JSONValue], credentialMetadata: [String: String] = [:],
  connectionOptions: ProviderConnectionOptions = .init(),
  options: ProviderGenerationOptions, tool: ProviderToolDefinition
) async throws -> [String: JSONValue] {
  let transport = BranchCaptureTransport()
  let fixture = makeFixture(
    protocolID: protocolID, providerID: providerID, modelID: modelID, reasoning: reasoning,
    baseURL: baseURL, metadata: metadata, credentialMetadata: credentialMetadata,
    connectionOptions: connectionOptions, options: options, tool: tool)
  do {
    for try await _ in fixture.adapter.stream(
      fixture.request, context: fixture.context, transport: transport)
    {}
  } catch is ProviderRuntimeFailure {
    // HTTP 418 is intentional: request capture is the assertion boundary.
  }
  let sent = try #require(await transport.request())
  return try decodeJSONObject(
    try fixtureHTTPBody(sent), providerID: "fixture", operation: "branch.capture")
}

private func captureDeferred(
  protocolID: String,
  providerID: String,
  metadata: [String: JSONValue]
) async throws -> [String: JSONValue] {
  let responses = protocolID.contains("responses")
  let toolID = responses ? "call_loader|fc_loader" : "call-loader"
  let source = ProviderMessageSource(api: protocolID, providerID: providerID, modelID: "model")
  let assistant = ProviderAssistantMessage(
    content: [
      .toolCall(
        ProviderToolCall(
          id: toolID, name: "sample_tool",
          arguments: .object(["payload": .string("lookup")])))
    ],
    source: source,
    usage: ProviderUsage(
      inputTokens: 1, outputTokens: 1, reasoningTokens: 0, cachedInputTokens: 0,
      cacheWriteTokens: 0, totalTokens: 2, providerMetadata: [:]),
    stopReason: .toolUse, timestampMilliseconds: 1)
  let messages: [ProviderMessage] = [
    .system("System branch fixture"),
    .user([.text("load a tool")]),
    .assistantMessage(assistant),
    .toolResult(
      ProviderToolResult(
        toolCallID: toolID, toolName: "sample_tool", content: [.text("loaded")],
        isError: false, addedToolNames: ["lookup"], timestampMilliseconds: 2)),
  ]
  let tools = [
    ProviderToolDefinition(
      name: "sample_tool", description: "Sample tool", inputSchema: toolSchema()),
    ProviderToolDefinition(
      name: "lookup", description: "Deferred lookup",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string")])]),
        "required": .array([.string("query")]),
      ])),
  ]
  let transport = BranchCaptureTransport()
  let fixture = makeFixture(
    protocolID: protocolID, providerID: providerID, modelID: "model", reasoning: false,
    metadata: metadata,
    credentialMetadata: protocolID == "openai-codex-responses"
      ? ["accountID": "fixture-account"] : [:],
    options: options(), tool: tools[0], messages: messages, tools: tools)
  do {
    for try await _ in fixture.adapter.stream(
      fixture.request, context: fixture.context, transport: transport)
    {}
  } catch is ProviderRuntimeFailure {}
  let sent = try #require(await transport.request())
  return try decodeJSONObject(
    try fixtureHTTPBody(sent), providerID: "fixture", operation: "deferred.capture")
}

private func captureCompatTranscript(
  reasoning: Bool, compat: [String: JSONValue], signature: String
) async throws -> [String: JSONValue] {
  let tool = ProviderToolDefinition(
    name: "sample_tool", description: "Sample tool", inputSchema: toolSchema())
  let source = ProviderMessageSource(
    api: "openai-completions", providerID: "fixture", modelID: "chat-model")
  let assistant = ProviderAssistantMessage(
    content: [
      .reasoning(
        ProviderReasoningContent(
          text: "private thought", signature: signature, providerMetadata: [:])),
      .text("answer"),
      .toolCall(
        ProviderToolCall(
          id: "call_compat", name: "sample_tool",
          arguments: .object(["payload": .string("abc")]))),
    ], source: source,
    usage: ProviderUsage(
      inputTokens: 1, outputTokens: 1, reasoningTokens: 0, cachedInputTokens: 0,
      cacheWriteTokens: 0, totalTokens: 2, providerMetadata: [:]),
    stopReason: .toolUse, timestampMilliseconds: 1)
  let messages: [ProviderMessage] = [
    .system("System branch fixture"), .assistantMessage(assistant),
    .toolResult(
      ProviderToolResult(
        toolCallID: "call_compat", toolName: "sample_tool", content: [.text("done")],
        isError: false, timestampMilliseconds: 2)),
    .user([.text("continue")]),
  ]
  let transport = BranchCaptureTransport()
  let fixture = makeFixture(
    protocolID: "openai-completions", providerID: "fixture", modelID: "chat-model",
    reasoning: reasoning, metadata: ["compat": .object(compat)], options: options(), tool: tool,
    messages: messages)
  do {
    for try await _ in fixture.adapter.stream(
      fixture.request, context: fixture.context, transport: transport)
    {}
  } catch is ProviderRuntimeFailure {}
  let sent = try #require(await transport.request())
  return try decodeJSONObject(
    try fixtureHTTPBody(sent), providerID: "fixture", operation: "compat.capture")
}

private func captureReplay(
  _ variant: String,
  protocolID: String = "openai-responses",
  providerID: String = "openai",
  baseURL: String = "https://api.openai.com/v1",
  modelID: String = "gpt-model"
) async throws -> [String: JSONValue] {
  let sourceModelID = variant == "different-model" ? "other-model" : modelID
  let source = ProviderMessageSource(
    api: protocolID, providerID: providerID, modelID: sourceModelID)
  let content: [ProviderAssistantContent]
  let toolResult: ProviderMessage?
  let constrained: ProviderConstrainedSampling?
  if variant == "text-id-hash" {
    let signature = #"{"v":1,"id":"\#(String(repeating: "x", count: 70))","phase":"final_answer"}"#
    content = [.signedText(ProviderTextContent(text: "answer", signature: signature))]
    toolResult = nil
    constrained = nil
  } else {
    let custom = variant == "custom-output"
    let id = custom ? "call_1|ctc_1" : "call_1|fc_item"
    content = [
      .toolCall(
        ProviderToolCall(
          id: id, name: "sample_tool", arguments: .object(["payload": .string("abc")]),
          namespace: "dynamic_tools"))
    ]
    toolResult = .toolResult(
      ProviderToolResult(
        toolCallID: id, toolName: "sample_tool", content: [.text("done")], isError: false))
    constrained =
      custom
      ? .grammar(variants: ["openai_lark": "start: /[a-z]+/"])
      : nil
  }
  let assistant = ProviderAssistantMessage(
    content: content, source: source,
    usage: ProviderUsage(
      inputTokens: 1, outputTokens: 1, reasoningTokens: 0, cachedInputTokens: 0,
      cacheWriteTokens: 0, totalTokens: 2, providerMetadata: [:]),
    stopReason: toolResult == nil ? .stop : .toolUse, timestampMilliseconds: 1)
  var messages: [ProviderMessage] =
    protocolID == "openai-codex-responses"
    ? [.assistantMessage(assistant)]
    : [.system("System branch fixture"), .assistantMessage(assistant)]
  if let toolResult { messages.append(toolResult) }
  let tool = ProviderToolDefinition(
    name: "sample_tool", description: "Sample tool", inputSchema: toolSchema(),
    constrainedSampling: constrained)
  let transport = BranchCaptureTransport()
  let fixture = makeFixture(
    protocolID: protocolID, providerID: providerID, modelID: modelID,
    reasoning: protocolID == "openai-codex-responses", baseURL: baseURL,
    metadata: constrained == nil
      ? [:] : ["compat": .object(["supportsOpenAIGrammarTools": .bool(true)])],
    credentialMetadata: protocolID == "openai-codex-responses"
      ? ["accountID": "fixture-account"] : [:],
    options: options(), tool: tool, messages: messages, tools: [tool])
  do {
    for try await _ in fixture.adapter.stream(
      fixture.request, context: fixture.context, transport: transport)
    {}
  } catch is ProviderRuntimeFailure {}
  let sent = try #require(await transport.request())
  return try decodeJSONObject(
    try fixtureHTTPBody(sent), providerID: "fixture", operation: "replay.capture")
}

private func responseToolNames(_ body: [String: JSONValue]) -> [String] {
  body.array("tools")?.compactMap { $0.objectValue?.string("name") } ?? []
}

private func expectedRequestBody(_ caseID: String) throws -> [String: JSONValue] {
  let root = try decodeJSONObject(
    Data(
      contentsOf: repositoryRoot().appending(
        path: "Fixtures/OpenAIRequestBranches/Oracle/request-branches.json")),
    providerID: "fixture", operation: "openai-request-branch.expected")
  return try #require(root.object("cases")?.object(caseID)?.object("requestBody"))
}

private func makeFixture(
  protocolID: String, providerID: String, modelID: String, reasoning: Bool,
  baseURL: String = "https://fixture.invalid/v1",
  metadata: [String: JSONValue], credentialMetadata: [String: String] = [:],
  connectionOptions: ProviderConnectionOptions = .init(),
  options: ProviderGenerationOptions, tool: ProviderToolDefinition,
  messages: [ProviderMessage]? = nil,
  tools: [ProviderToolDefinition]? = nil
) -> (adapter: any WireProtocolAdapter, request: ProviderRequest, context: WireProtocolContext) {
  let model = ProviderModel(
    id: modelID, providerID: providerID, name: modelID, protocolID: protocolID,
    capabilities: ProviderCapabilities(
      textInput: true, imageInput: false, toolCalling: true, reasoning: reasoning,
      structuredOutput: true, imageGeneration: false),
    contextWindow: 32_768, maximumOutputTokens: 4_096,
    supportedReasoningEfforts: [.off, .minimal, .low, .medium, .high, .xhigh, .max])
  let adapter: any WireProtocolAdapter
  let credential: ProviderCredential
  switch protocolID {
  case "azure-openai-responses":
    adapter = OpenAIResponsesAdapter(protocolID: protocolID, flavor: .azure)
    credential = .apiKey(APIKeyCredential(key: "sk-fixture", metadata: credentialMetadata))
  case "openai-codex-responses":
    adapter = OpenAIResponsesAdapter(protocolID: protocolID, flavor: .codex)
    credential = .oauth(
      OAuthCredential(
        accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture,
        metadata: credentialMetadata))
  case "openai-responses":
    adapter = OpenAIResponsesAdapter()
    credential = .apiKey(APIKeyCredential(key: "sk-fixture", metadata: credentialMetadata))
  default:
    adapter = OpenAICompletionsAdapter()
    credential = .apiKey(APIKeyCredential(key: "sk-fixture", metadata: credentialMetadata))
  }
  let request = ProviderRequest(
    id: "branch", providerID: providerID, modelID: modelID,
    messages: messages ?? [.system("System branch fixture"), .user([.text("hello")])],
    tools: tools ?? [tool], options: options, connectionOptions: connectionOptions)
  let context = WireProtocolContext(
    provider: ProviderDescriptor(
      id: providerID, name: providerID, authorizationMethods: [], models: [model]),
    model: model, baseURL: URL(string: baseURL)!, headers: [:], credential: credential,
    modelConfiguration: ProviderModelConfiguration(
      protocolID: protocolID, baseURL: nil, headers: [:], metadata: metadata))
  return (adapter, request, context)
}

private func options(
  maximum: Int? = nil, temperature: Double? = nil,
  effort: ProviderReasoningEffort? = nil, reasoningSummary: String? = nil,
  sessionID: String? = nil,
  cache: ProviderCacheRetention = .short, serviceTier: String? = nil,
  toolChoice: JSONValue? = nil,
  providerOptions: [String: JSONValue] = [:],
  thinkingBudgets: [ProviderReasoningEffort: Int]? = nil,
  textVerbosity: String? = nil,
  environment: [String: String] = [:]
) -> ProviderGenerationOptions {
  ProviderGenerationOptions(
    maximumOutputTokens: maximum, temperature: temperature, reasoningEffort: effort,
    reasoningSummary: reasoningSummary, responseSchema: nil,
    providerOptions: providerOptions, sessionID: sessionID,
    cacheRetention: cache, serviceTier: serviceTier, toolChoice: toolChoice,
    thinkingBudgets: thinkingBudgets, textVerbosity: textVerbosity, environment: environment)
}

private func toolSchema() -> JSONValue {
  .object([
    "type": .string("object"),
    "properties": .object(["payload": .object(["type": .string("string")])]),
    "required": .array([.string("payload")]),
  ])
}

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
