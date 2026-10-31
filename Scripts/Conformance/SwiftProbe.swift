import Foundation

@testable import PiAIProviderRuntime

@main
struct SwiftConformanceProbe {
  static func main() async throws {
    if CommandLine.arguments.contains("--server") {
      await WireConformanceServer.run()
      return
    }
    let interactive = CommandLine.arguments.contains("--stream")
    let data =
      interactive
      ? Data((readLine() ?? "").utf8) : FileHandle.standardInput.readDataToEndOfFile()
    do {
      if var output = try await execute(data, interactive: interactive) {
        output.lifetime = await ProbeStreamLifetime.shared.afterScope()
        FileHandle.standardOutput.write(try JSONEncoder().encode(output))
      } else if interactive, let lifetime = await ProbeStreamLifetime.shared.afterScope() {
        try ProbeChannel().write("lifetime", lifetime)
      }
    } catch let error as ProviderRuntimeFailure {
      if interactive {
        try ProbeChannel().write("finished", project(error))
        return
      }
      FileHandle.standardOutput.write(
        try JSONEncoder().encode(
          ProbeOutput(request: nil, pending: false, events: [], failure: project(error))))
    } catch ProbeError.unrepresentable(let capability) {
      let failure: [String: JSONValue] = [
        "code": .string("unsupportedCapability"), "operation": .string("conformance.input"),
        "message": .string(
          "Swift ProviderRequest cannot preserve this upstream fixture: " + capability),
        "unrepresentedCapability": .string(capability),
      ]
      if interactive {
        try ProbeChannel().write("finished", failure)
      } else {
        FileHandle.standardOutput.write(
          try JSONEncoder().encode(
            ProbeOutput(request: nil, pending: false, events: [], failure: failure)))
      }
    }
  }

  static func execute(
    _ data: Data, interactive: Bool, incoming: AsyncStream<[String: JSONValue]>? = nil,
    wireServer: WireConformanceServer? = nil,
    lifetime: ProbeStreamLifetime = .shared
  ) async throws -> ProbeOutput? {
    let envelope = try JSONValue(jsonData: data).objectValue ?? [:]
    if envelope.string("operation") == "classifier", let wireServer {
      try await ClassifierConformanceProbe.run(envelope, server: wireServer, incoming: incoming)
      return nil
    }
    if envelope.string("operation") == "classifier.helper" {
      FileHandle.standardOutput.write(
        try JSONEncoder().encode(ClassifierConformanceProbe.helper(envelope)))
      return nil
    }
    if envelope.string("operation") == "headers.bedrock" {
      let projected = BedrockConverseStreamAdapter.customHeaders(
        (envelope.object("headers") ?? [:]).compactMapValues(\.stringValue))
      FileHandle.standardOutput.write(try JSONEncoder().encode(projected))
      return nil
    }
    if envelope.string("operation") == "headers.open-code" {
      let projection = ProviderSessionHeaders.openCodeHeaders(
        sessionID: envelope.string("sessionID"),
        headers: envelope.object("headers")?.mapValues(\.stringValue))
      var result: [String: JSONValue] = ["changed": .bool(projection.changed)]
      if let headers = projection.headers {
        result["headers"] = .object(headers.mapValues { $0.map(JSONValue.string) ?? .null })
      }
      FileHandle.standardOutput.write(try JSONEncoder().encode(result))
      return nil
    }
    if envelope.string("operation") == "tool-support" {
      let model = envelope.object("model") ?? [:]
      let mode = ProviderToolDeclarationMode.resolve(
        protocolID: model.string("api") ?? "",
        compatibility: model.object("compat") ?? [:])
      FileHandle.standardOutput.write(try JSONEncoder().encode(mode.rawValue))
      return nil
    }
    if ["provider.retry", "oauth.device-poll"].contains(envelope.string("operation") ?? ""),
      let incoming, let wireServer
    {
      await RetryConformanceProbe.run(envelope, incoming: incoming, server: wireServer)
      return nil
    }
    if envelope.string("operation") == "authorization" {
      try await AuthorizationConformanceProbe.run(envelope)
      return nil
    }
    if let operation = envelope.string("operation"), operation.hasPrefix("identity.") {
      let identity = envelope.object("identity")
      let target = envelope.object("target") ?? [:]
      let host = try JSONDecoder().decode(
        ProviderIdentityHost.self,
        from: JSONEncoder().encode(JSONValue.object(envelope.object("host") ?? [:])))
      let result: JSONValue
      switch operation {
      case "identity.version":
        result = .string(identity?.string("version") ?? ProviderClientIdentity.upstreamVersion)
      case "identity.user-agent":
        result = .string(ProviderClientIdentity.userAgent(identity, host: host))
      case "identity.merge":
        result =
          ProviderClientIdentity.merge((envelope.array("sources") ?? []).map(\.objectValue)).map(
            JSONValue.object) ?? .null
      case "identity.attribution":
        result = .object(
          ProviderClientIdentity.attributionHeaders(
            providerID: target.string("provider") ?? "", baseURL: target.string("baseUrl") ?? "",
            identity: identity
          ).mapValues(JSONValue.string))
      case "identity.headers":
        result = .object(
          ProviderClientIdentity.headers(
            providerID: target.string("provider") ?? "", baseURL: target.string("baseUrl") ?? "",
            identity: identity, host: host
          ).mapValues(JSONValue.string))
      case "identity.session-headers":
        result =
          ProviderClientIdentity.openCodeSessionHeaders(
            providerID: target.string("provider") ?? "", baseURL: target.string("baseUrl") ?? "",
            sessionID: envelope.string("sessionID")
          ).map { .object($0.mapValues(JSONValue.string)) } ?? .null
      default: throw ProbeError.unsupported(operation)
      }
      FileHandle.standardOutput.write(try JSONEncoder().encode(result))
      return nil
    }
    if envelope.string("operation") == "tool.arguments.complete" {
      let call = ProviderToolCall.parsing(
        id: "fixture", name: "fixture", input: try envelope.required("text"))
      var result = ["arguments": call.arguments]
      result["argumentsError"] = call.argumentsError.map(JSONValue.string)
      FileHandle.standardOutput.write(try JSONEncoder().encode(result))
      return nil
    }
    if envelope.string("operation") == "usage.openrouter-cost" {
      let raw = envelope.object("usage") ?? [:]
      let cost = try JSONDecoder().decode(
        ProviderUsageCost.self, from: JSONEncoder().encode(raw["cost"]))
      let usage = ProviderUsage(
        inputTokens: raw.int("input") ?? 0, outputTokens: raw.int("output") ?? 0,
        reasoningTokens: nil, cachedInputTokens: raw.int("cacheRead") ?? 0,
        cacheWriteTokens: raw.int("cacheWrite") ?? 0, totalTokens: raw.int("totalTokens") ?? 0,
        providerMetadata: [:], cost: cost)
      FileHandle.standardOutput.write(
        try JSONEncoder().encode(
          usage.applyingOpenRouterCost(envelope.object("reported") ?? [:], enabled: true).cost))
      return nil
    }
    if envelope.string("operation") == "usage.calculate" {
      let raw = envelope.object("usage") ?? [:]
      guard
        let pricing = try ProviderUsagePricing.parse(
          metadata: envelope.object("model") ?? [:], providerID: "fixture",
          operation: "conformance.usage.calculate")
      else {
        throw ProbeError.unsupported("model pricing")
      }
      FileHandle.standardOutput.write(
        try JSONEncoder().encode(
          pricing.cost(
            input: raw.int("input") ?? 0, output: raw.int("output") ?? 0,
            cacheRead: raw.int("cacheRead") ?? 0, cacheWrite: raw.int("cacheWrite") ?? 0,
            cacheWrite1h: raw.int("cacheWrite1h") ?? 0)))
      return nil
    }
    if envelope.string("operation") == "sampling.strict" {
      let projection = try ProviderConstrainedSamplingResolver.jsonSchema(
        for: toolDefinition(envelope["tool"] ?? .null),
        supportsStrictMode: envelope.bool("supportsStrictMode") ?? true,
        providerID: "fixture", operation: "conformance.sampling.strict")
      FileHandle.standardOutput.write(
        try JSONEncoder().encode(projection.strict == true ? projection.schema : .null))
      return nil
    }
    if envelope.string("operation") == "sampling.grammar-buffer" {
      var buffer = try GrammarToolInputJSONBuffer(
        property: try envelope.required("property"), initialInput: "")
      var result: String?
      do {
        for action in envelope.array("actions") ?? [] {
          let raw = action.objectValue ?? [:]
          result =
            try raw.string("kind") == "append"
            ? buffer.append(raw.string("value") ?? "") : buffer.close(raw.string("value"))
        }
      } catch {
        throw ProviderRuntimeFailure(
          code: .invalidResponse, message: String(describing: error), providerID: "fixture",
          operation: "conformance.grammar-buffer", causeDescription: nil)
      }
      FileHandle.standardOutput.write(try JSONEncoder().encode(result))
      return nil
    }
    if envelope.string("operation") == "error.format" {
      let result = ProviderErrorText.format(
        .init(
          status: envelope["status"], body: envelope.string("body"),
          message: envelope.string("message") ?? "",
          messageCarriesBody: envelope.bool("messageCarriesBody") ?? false),
        prefix: envelope.string("prefix"))
      FileHandle.standardOutput.write(try JSONEncoder().encode(result))
      return nil
    }
    if envelope.string("operation") == "error.normalize-sdk-object" {
      func candidate(_ key: String) -> ProviderErrorText.BodyCandidate {
        let value = envelope.object(key) ?? [:]
        if let text = value.string("text") { return .text(text) }
        if value.bool("plain") == true {
          return .plainObject(
            serialized: value.string("serialized") ?? value.string("stringValue") ?? "",
            isEmpty: value.int("ownKeys") == 0, isReadable: value.bool("readable") == true)
        }
        return .other
      }
      let result = ProviderErrorText.normalize(
        isError: envelope.bool("isError") == true, message: envelope.string("message") ?? "",
        serializedValue: envelope.string("serialized"),
        stringValue: envelope.string("stringValue") ?? "",
        statusCandidates: envelope.array("statusCandidates") ?? [], body: candidate("body"),
        error: candidate("error"), responseBody: candidate("responseBody"))
      FileHandle.standardOutput.write(try JSONEncoder().encode(result))
      return nil
    }
    if envelope.string("operation") == "error.truncate" {
      let text = try envelope.required("text")
      let maximum = envelope.int("maximumCharacters")!
      let before = pi_heap_live_bytes()
      let result = autoreleasepool {
        let owned = String(decoding: Array(text.utf8), as: UTF8.self)
        return ProviderErrorText.truncate(owned, maximumCharacters: maximum)
      }
      let retained = Int64(pi_heap_live_bytes()) - Int64(before)
      FileHandle.standardOutput.write(
        try JSONEncoder().encode([
          "value": JSONValue.string(result), "retainedBytes": .integer(retained),
        ]))
      return nil
    }
    if envelope.string("operation") == "google-tools" {
      let projection = try GoogleToolProjection.declarations(
        (envelope.array("tools") ?? []).map(toolDefinition),
        supportsStrictMode: envelope.bool("supportsStrictMode") ?? true, providerID: "google",
        useParameters: envelope.bool("useParameters") ?? false)
      FileHandle.standardOutput.write(
        Data(try ordered(projection.tools ?? .null).encodedString().utf8))
      return nil
    }
    if envelope.string("operation") == "catalog.all-models" {
      let registry = try BuiltinProviderRegistry.load()
      var catalog: [String: [JSONValue]] = [:]
      for provider in registry.providers {
        var models: [JSONValue] = []
        for modality: ProviderOutputModality in [.text, .image, .classification] {
          for model in provider.models {
            if let configuration = provider.modelConfigurations[
              .init(modelID: model.id, outputModality: modality)]
            {
              var raw = configuration.metadata
              if let base = configuration.baseURL ?? provider.baseURL {
                raw["baseUrl"] = .string(base)
              }
              models.append(.object(raw))
            }
          }
        }
        catalog[provider.id] = models
      }
      FileHandle.standardOutput.write(try JSONEncoder().encode(catalog))
      return nil
    }
    if ["catalog", "catalog.images", "catalog.classifiers"].contains(
      envelope.string("operation") ?? "")
    {
      let registry = try BuiltinProviderRegistry.load()
      var catalog: [String: [String: JSONValue]] = [:]
      for provider in registry.providers {
        for model in provider.models {
          let route = ProviderModelRoute(
            modelID: model.id,
            outputModality: envelope.string("operation") == "catalog.images"
              ? .image
              : envelope.string("operation") == "catalog.classifiers" ? .classification : .text)
          guard let config = provider.modelConfigurations[route] else { continue }
          var raw = config.metadata
          raw["id"] = .string(model.id)
          raw["name"] = raw["name"] ?? .string(model.name)
          raw["provider"] = .string(provider.id)
          raw["api"] = .string(config.protocolID)
          if let base = config.baseURL ?? provider.baseURL { raw["baseUrl"] = .string(base) }
          catalog[provider.id + "/" + model.id] = raw
        }
      }
      FileHandle.standardOutput.write(try JSONEncoder().encode(catalog))
      return nil
    }
    let input = try JSONDecoder().decode(ProbeInput.self, from: data)
    let model = input.model
    let api = try model.required("api")
    let provider = try model.required("provider")
    let modelID = try model.required("id")
    let options = input.options
    if envelope.string("operation") == "google-thinking-level" {
      let rawEffort = try options.required("reasoningEffort")
      guard let effort = ProviderReasoningEffort(rawValue: rawEffort) else {
        throw ProbeError.unrepresentable("unknown-reasoning-level")
      }
      let resolved = try GoogleGenerativeAIAdapter.resolveThinkingLevel(
        effort: effort, providerID: provider, modelID: modelID, metadata: model)
      FileHandle.standardOutput.write(try JSONEncoder().encode(resolved))
      return nil
    }
    let providerModel = ProviderModel(
      id: modelID, providerID: provider, name: model.string("name") ?? modelID,
      protocolID: api,
      capabilities: .init(
        textInput: true, imageInput: model.array("input")?.contains(.string("image")) == true,
        toolCalling: true, reasoning: model.bool("reasoning") == true,
        structuredOutput: true, imageGeneration: api == "openrouter-images"),
      contextWindow: model.int("contextWindow"), maximumOutputTokens: model.int("maxTokens"),
      supportedReasoningEfforts: try ProviderReasoning.supportedEfforts(
        reasoning: model.bool("reasoning") == true, metadata: model,
        protocolID: api, providerID: provider, modelID: modelID,
        modelName: model.string("name") ?? modelID))
    if envelope.string("operation") == "reasoning-levels" {
      FileHandle.standardOutput.write(
        try JSONEncoder().encode(providerModel.supportedReasoningEfforts))
      return nil
    }
    var messages: [ProviderMessage] = []
    if let system = input.context.systemPrompt, !system.isEmpty { messages.append(.system(system)) }
    messages += try input.context.messages.map(message)
    let tools = try (envelope.object("context")?.array("tools") ?? []).map(toolDefinition)
    let usesRawMistralOptions = api == "mistral-conversations" && input.generationMode != .simple
    let usesRawAnthropicOptions = api == "anthropic-messages" && input.generationMode != .simple
    let usesRawBedrockOptions = api == "bedrock-converse-stream" && input.generationMode != .simple
    let usesRawCompletionsOptions = api == "openai-completions" && input.generationMode != .simple
    let effort =
      usesRawMistralOptions || usesRawAnthropicOptions || usesRawBedrockOptions
        || usesRawCompletionsOptions
      ? nil
      : (options.string("reasoningEffort") ?? options.string("reasoning")
        ?? (options.bool("thinkingEnabled") == false ? "off" : nil))
    let mappedOptions: Set<String> = [
      "apiKey", "headers", "signal", "fetch", "client", "maxRetries", "maxRetryDelayMs", "timeout",
      "timeoutMs", "websocketConnectTimeoutMs", "identity", "telemetry", "transport", "project",
      "location",
      "maxTokens", "temperature", "reasoningEffort", "reasoning", "thinkingEnabled",
      "thinkingBudgetTokens", "reasoningSummary", "responseSchema", "sessionId", "cacheRetention",
      "serviceTier", "toolChoice", "thinkingBudgets", "textVerbosity", "env",
      "azureBaseUrl", "azureResourceName", "azureApiVersion", "azureDeploymentName", "region",
      "profile", "bearerToken",
    ]
    var providerOptions = options.filter { !mappedOptions.contains($0.key) }
    providerOptions["identity"] = options["identity"]
    if api == "mistral-conversations" {
      for key in ["headers", "timeoutMs"] {
        if let value = options[key] { providerOptions[key] = value }
      }
      if usesRawMistralOptions {
        providerOptions["reasoningEffort"] = options["reasoningEffort"] ?? .null
      }
    }
    if usesRawAnthropicOptions {
      for key in ["thinkingEnabled", "thinkingBudgetTokens", "effort"] {
        providerOptions[key] = options[key] ?? .null
      }
    }
    if usesRawBedrockOptions { providerOptions["reasoning"] = options["reasoning"] ?? .null }
    if usesRawCompletionsOptions {
      providerOptions["reasoningEffort"] = options["reasoningEffort"] ?? .null
    }
    var generationOptions = ProviderGenerationOptions(
      maximumOutputTokens: options.int("maxTokens"),
      temperature: options["temperature"].flatMap(number),
      reasoningEffort: effort.flatMap(ProviderReasoningEffort.init(rawValue:)),
      reasoningSummary: options.string("reasoningSummary"),
      responseSchema: options["responseSchema"], providerOptions: providerOptions,
      outputModality: api == "openrouter-images" ? .image : .text,
      sessionID: options.string("sessionId"),
      cacheRetention: options.string("cacheRetention").flatMap(
        ProviderCacheRetention.init(rawValue:)) ?? .short,
      serviceTier: options.string("serviceTier"), toolChoice: options["toolChoice"],
      thinkingBudgets: options.object("thinkingBudgets").map {
        Dictionary(
          uniqueKeysWithValues: $0.compactMap { key, value -> (ProviderReasoningEffort, Int)? in
            guard let effort = ProviderReasoningEffort(rawValue: key),
              case .integer(let budget) = value
            else { return nil }
            return (effort, Int(budget))
          })
      },
      textVerbosity: options.string("textVerbosity"))
    generationOptions.cacheRetentionIsExplicit = options["cacheRetention"] != nil
    let cloudOptions =
      ["google-vertex", "bedrock-converse-stream", "anthropic-messages"].contains(api)
      ? CloudConformanceProbe.options(options, ambient: envelope.object("cloudEnvironment") ?? [:])
      : nil
    let request = ProviderRequest(
      id: "upstream-conformance", providerID: provider, modelID: modelID,
      messages: messages, tools: tools, options: generationOptions,
      connectionOptions: .init(
        azureOpenAIResponses: api == "azure-openai-responses"
          ? .init(
            azureBaseURL: options.string("azureBaseUrl"),
            azureResourceName: options.string("azureResourceName"),
            azureAPIVersion: options.string("azureApiVersion"),
            azureDeploymentName: options.string("azureDeploymentName"),
            environment: input.environment) : nil,
        headers: options.object("headers")?.mapValues(\.stringValue),
        transport: options.string("transport").flatMap(
          ProviderConnectionOptions.Transport.init(rawValue:)),
        timeoutMilliseconds: options["timeoutMs"].flatMap(number),
        webSocketConnectTimeoutMilliseconds: options["websocketConnectTimeoutMs"].flatMap(number),
        maximumRetries: options.int("maxRetries"),
        maximumRetryDelayMilliseconds: options["maxRetryDelayMs"].flatMap(number),
        cloud: cloudOptions))
    let credential: ProviderCredential?
    if api == "google-vertex", input.credential.key == nil, cloudOptions == nil {
      credential = .oauth(
        .init(
          accessToken: "test", refreshToken: "test", expiresAt: .distantFuture,
          metadata: [
            "projectID": options.string("project") ?? input.environment["GOOGLE_CLOUD_PROJECT"]
              ?? "",
            "location": options.string("location") ?? input.environment["GOOGLE_CLOUD_LOCATION"]
              ?? "",
          ]))
    } else if api == "openai-codex-responses", let key = input.credential.key {
      credential = .oauth(
        .init(
          accessToken: key, refreshToken: "", expiresAt: .distantFuture,
          metadata: ["accountID": try OpenAICodexOAuthClient().extractAccountID(from: key)]))
    } else if api == "anthropic-messages", let key = input.credential.key,
      key.contains("sk-ant-oat")
    {
      credential = .oauth(
        .init(
          accessToken: key, refreshToken: "", expiresAt: .distantFuture,
          metadata: input.credential.metadata))
    } else if let key = input.credential.key {
      credential = .apiKey(.init(key: key, metadata: input.credential.metadata))
    } else {
      credential = nil
    }
    let responses = input.responses ?? []
    let fixtureTransport = ProbeTransport(responses: responses, aborted: input.aborted == true)
    let channel = ProbeChannel()
    let host = try JSONDecoder().decode(
      ProviderIdentityHost.self,
      from: JSONEncoder().encode(JSONValue.object(envelope.object("identityHost") ?? [:])))
    let cloudPlan = try cloudOptions.flatMap { cloud in
      try ProviderCloudPlan.resolve(
        protocolID: api, providerID: provider, modelID: modelID,
        baseURL: model.string("baseUrl") ?? "", credential: credential,
        headers: options.object("headers")?.mapValues(\.stringValue) ?? [:], options: cloud)
    }
    var clientHeaders = ProviderClientIdentity.headers(
      providerID: provider,
      baseURL: model.string("baseUrl") ?? "", identity: options.object("identity"), host: host)
    for source in [(model.object("headers") ?? [:]), (options.object("headers") ?? [:])] {
      for (name, value) in source {
        clientHeaders = clientHeaders.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
        if let value = value.stringValue { clientHeaders[name] = value }
      }
    }
    let cloudConfiguration = cloudPlan.map {
      CloudConformanceProbe.configuration($0, headers: clientHeaders)
    }
    let azureConfiguration =
      api == "azure-openai-responses"
      ? try? ResolvedAzureOpenAIResponsesConfiguration.resolve(
        request: request, modelBaseURL: model.string("baseUrl")) : nil
    let liveTransport = InteractiveProbeTransport(
      channel: channel,
      azureConfiguration: azureConfiguration.map {
        ["baseURL": .string($0.baseURL), "apiVersion": .string($0.apiVersion)]
      }, cloudConfiguration: cloudConfiguration)
    let toolUpdates = ProbeToolUpdates()
    let transport: any ProviderHTTPStreamingTransport =
      interactive ? liveTransport : fixtureTransport
    let authorization: any ProviderAuthorizationAdapter
    if input.requestSource == "provider",
      CloudflareAuthorizationAdapter.providerIDs.contains(provider),
      options.string("apiKey")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
      options.object("headers")?.string("cf-aig-authorization") == nil
    {
      authorization = CloudflareAuthorizationAdapter(providerID: provider, methodID: "api-key")
    } else {
      authorization = FixtureAuthorization()
    }
    let observerFlags = envelope.object("wireObserver") ?? [:]
    var onPayload: ProviderWireObserver.PayloadCallback?
    if interactive && observerFlags.bool("payload") == true {
      onPayload = { payload, context in
        let reply = try await liveTransport.observe("payload", .object(payload), context: context)
        guard let modified = reply.object("payload"), let replaced = reply.bool("replaced") else {
          throw ProbeError.unsupported("observer payload reply")
        }
        payload = modified
        return replaced ? modified : nil
      }
    }
    var onResponse: ProviderWireObserver.ResponseCallback?
    if interactive && observerFlags.bool("response") == true {
      onResponse = { response, context in
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))
        _ = try await liveTransport.observe("response", value, context: context)
      }
    }
    var onEvent: ProviderWireObserver.StreamEventCallback?
    if interactive && observerFlags.bool("event") == true {
      onEvent = { event, context in
        _ = try await liveTransport.observe("event", event, context: context)
      }
    }
    var onToolArguments: ProviderWireObserver.ToolArgumentsCallback?
    if observerFlags.bool("toolArguments") == true {
      let marker = lifetime.marker()
      onToolArguments = { update, context in
        defer { withExtendedLifetime(marker) {} }
        if interactive {
          _ = try await liveTransport.observe("toolArguments", probeJSON(update), context: context)
        } else {
          await toolUpdates.append(update)
        }
      }
    }
    let wireObserver: ProviderWireObserver? =
      observerFlags.isEmpty
      ? nil
      : .init(
        onPayload: onPayload, onResponse: onResponse, onProviderStreamEvent: onEvent,
        onToolArguments: onToolArguments)
    let baseURL: String?
    if input.requestSource == "api", api != "google-vertex", let literal = model.string("baseUrl"),
      let url = URL(string: literal), url.host != nil
    {
      baseURL = url.absoluteString
    } else {
      baseURL = model.string("baseUrl")
    }
    let runtime = try ProviderRuntimeKernel(
      catalogRevision: "upstream-conformance",
      providers: [
        .init(
          descriptor: .init(
            id: provider, name: provider, authorizationMethods: [], models: [providerModel]),
          baseURL: baseURL,
          headers: (model.object("headers") ?? [:]).compactMapValues(\.stringValue),
          modelConfigurations: [
            .init(modelID: modelID, outputModality: api == "openrouter-images" ? .image : .text):
              .init(
                protocolID: api, baseURL: nil, headers: [:], metadata: model)
          ],
          credentialRequirement: credential == nil ? .none : .required,
          endpointPolicy: .httpOrHTTPS,
          authorization: authorization)
      ],
      wireProtocols: StandardWireProtocols.make(),
      credentialStore: InMemoryProviderCredentialStore(
        credentials: credential.map { [provider: $0] } ?? [:]),
      transport: transport, wireObserver: wireObserver,
      identityHost: host,
      webSocketTransport: wireServer.map { ProbeWebSocketTransport(server: $0) },
      codexSessions: wireServer?.sessions ?? CodexWebSocketSessions(),
      clock: wireServer.map { $0.clock as any ProviderOAuthClock } ?? SystemProviderOAuthClock(),
      cloudAuthorizationResolver: { authorizationRequest in
        if !interactive {
          return .init {
            switch authorizationRequest {
            case .awsCredentials(_, let region):
              return .aws(
                .init(
                  accessKeyID: "synthetic-access", secretAccessKey: "synthetic-secret",
                  region: region ?? "us-east-1"))
            default: return .bearerToken("synthetic-cloud-fixture-token")
            }
          }
        }
        let server = wireServer!
        let reply = try await server.cloudExchange(
          "source",
          value: [
            "request": try probeJSON(authorizationRequest),
            "configuration": .object(cloudConfiguration ?? [:]),
          ])
        let source = reply.string("source")!
        return .init { [weak server] in
          guard let server else { throw CancellationError() }
          let result = try await server.cloudExchange(
            "credential", value: ["source": .string(source)])
          return try JSONDecoder().decode(
            ProviderCloudCredential.self,
            from: JSONEncoder().encode(result["credential"] ?? .null))
        }
      }, cloudCredentialSources: wireServer?.cloudCredentialSources ?? .init())
    if input.measureHeap == true, pi_heap_begin() != 0 {
      throw ProbeError.unrepresentable("swift-process-heap-observer")
    }
    let execution = Task {
      var events: [JSONValue] = []
      var failure: [String: JSONValue]?
      do {
        for try await event in runtime.stream(request) {
          if interactive {
            try channel.write("event", event)
          } else {
            if let update = await toolUpdates.next(for: event) {
              events.append(
                .object(["toolArgumentsUpdate": .object(["_0": try probeJSON(update)])]))
            }
            events.append(try probeJSON(event))
          }
        }
        if interactive && Task.isCancelled { failure = ["code": .string("cancelled")] }
      } catch is CancellationError {
        if interactive || input.aborted == true { failure = ["code": .string("cancelled")] }
      } catch let error as ProviderRuntimeFailure {
        failure = project(error)
      } catch {
        failure = [
          "code": .string("transportFailed"), "message": .string(String(describing: error)),
        ]
      }
      return (events, failure)
    }
    var receiver: Task<Void, Never>?
    if interactive {
      receiver = Task.detached {
        let frames: AsyncStream<[String: JSONValue]>
        if let incoming {
          frames = incoming
        } else {
          frames = AsyncStream { continuation in
            Task.detached {
              while let line = readLine() {
                if let frame = try? probeEncoding({
                  try JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8))
                }) {
                  continuation.yield(frame)
                }
              }
              continuation.finish()
            }
          }
        }
        for await frame in frames {
          do {
            if frame.string("kind") == "cancel" { execution.cancel() }
            try await liveTransport.receive(frame)
          } catch {
            await liveTransport.fail(error)
          }
        }
        await liveTransport.fail(ProbeError.unsupported("fixture transport closed"))
      }
    }
    let (events, failure) = await execution.value
    if interactive {
      await liveTransport.finish()
      if let wireServer { try channel.write("codexStats", await wireServer.sessions.debugStats()) }
      if input.measureHeap == true {
        let bytes = pi_heap_allocated_bytes()
        try channel.write("heap", ["allocatedBytes": bytes])
      }
      try channel.write("finished", failure)
      if incoming == nil { await receiver?.value }
      return nil
    }
    let requests = await fixtureTransport.requests
    let captured = requests.last
    var output = ProbeOutput(
      request: try captured.map {
        .init(
          url: $0.url!.absoluteString, headers: $0.allHTTPHeaderFields ?? [:],
          body: $0.value(forHTTPHeaderField: "Content-Encoding") == "zstd"
            ? .null
            : try JSONDecoder().decode(JSONValue.self, from: $0.httpBody ?? Data("null".utf8)),
          rawBody: $0.value(forHTTPHeaderField: "Content-Encoding") == "zstd"
            ? $0.httpBody?.base64EncodedString() : nil)
      }, pending: requests.count > responses.count && input.aborted != true, events: events,
      failure: failure)
    if input.measureHeap == true { output.allocatedBytes = pi_heap_allocated_bytes() }
    return output
  }

  private static func project(_ error: ProviderRuntimeFailure) -> [String: JSONValue] {
    var result: [String: JSONValue] = [
      "code": .string(error.code.rawValue), "message": .string(error.message),
      "operation": error.operation.map(JSONValue.string) ?? .null,
      "cause": error.causeDescription.map(JSONValue.string) ?? .null,
    ]
    if let metadata = error.providerMetadata { result["providerMetadata"] = .object(metadata) }
    return result
  }

  private static func message(_ raw: [String: JSONValue]) throws -> ProviderMessage {
    switch try raw.required("role") {
    case "system":
      return .systemMessage(
        .init(
          content: try raw.required("content"),
          toolsAdded: try (raw.array("toolsAdded") ?? []).map(toolDefinition),
          toolsRemoved: (raw.array("toolsRemoved") ?? []).compactMap {
            $0.objectValue?.string("name")
          }))
    case "user":
      let content = try userContent(raw["content"])
      if let timestamp = raw.int("timestamp") {
        return .userMessage(.init(content: content, timestampMilliseconds: Int64(timestamp)))
      }
      return .user(content)
    case "assistant":
      let content = try (raw.array("content") ?? []).map { value -> ProviderAssistantContent in
        guard let block = value.objectValue else { throw ProbeError.unsupported("assistant block") }
        switch try block.required("type") {
        case "text":
          if let units = try textUTF16(block) { return .textUTF16(units) }
          return .signedText(
            .init(text: block.string("text") ?? "", signature: block.string("textSignature")))
        case "thinking":
          return .reasoning(
            .init(
              text: block.string("thinking") ?? "", signature: block.string("thinkingSignature"),
              isRedacted: block.bool("redacted"), providerMetadata: [:]))
        case "toolCall":
          return .toolCall(
            .init(
              id: try block.required("id"), name: try block.required("name"),
              arguments: block["arguments"] ?? .object([:]),
              thoughtSignature: block.string("thoughtSignature"),
              namespace: block.string("namespace"), argumentsError: block.string("argumentsError")))
        default: return .unrecognized(block)
        }
      }
      let usage = raw.object("usage") ?? [:]
      let cost = try usage["cost"].map {
        try JSONDecoder().decode(ProviderUsageCost.self, from: JSONEncoder().encode($0))
      }
      var metadata: [String: JSONValue] = [:]
      for key in ["providerThinkingLevel", "providerServiceTier", "phase"] {
        metadata[key] = raw[key]
      }
      return .assistantMessage(
        .init(
          content: content,
          source: .init(
            api: try raw.required("api"), providerID: try raw.required("provider"),
            modelID: try raw.required("model")),
          responseID: raw.string("responseId"), responseModelID: raw.string("responseModel"),
          usage: .init(
            inputTokens: usage.int("input"), outputTokens: usage.int("output"),
            reasoningTokens: usage.int("reasoning"),
            cachedInputTokens: usage.int("cacheRead"),
            cacheWriteTokens: usage.int("cacheWrite"), totalTokens: usage.int("totalTokens"),
            providerMetadata: [:], cost: cost),
          stopReason: ProviderAssistantStopReason(rawValue: raw.string("stopReason") ?? "stop")!,
          rawStopReason: raw.string("rawStopReason"),
          timestampMilliseconds: Int64(raw.int("timestamp") ?? 0),
          providerMetadata: metadata))
    case "toolResult":
      return .toolResult(
        .init(
          toolCallID: try raw.required("toolCallId"), toolName: try raw.required("toolName"),
          content: try userContent(raw["content"]).map {
            switch $0 {
            case .text(let text): return .text(text)
            case .image(let image): return .image(image)
            case .textUTF16, .unrecognized:
              throw ProbeError.unrepresentable("tool-result-content")
            }
          }, isError: raw.bool("isError") ?? false,
          timestampMilliseconds: raw.int("timestamp").map(Int64.init)))
    default: throw ProbeError.unsupported("message role")
    }
  }

  private static func userContent(_ raw: JSONValue?) throws -> [ProviderUserContent] {
    if let text = raw?.stringValue { return [.text(text)] }
    guard case .array(let values) = raw else { return [] }
    return try values.map { value in
      guard let block = value.objectValue else { throw ProbeError.unsupported("user block") }
      switch try block.required("type") {
      case "text":
        if let units = try textUTF16(block) { return .textUTF16(units) }
        return .text(block.string("text") ?? "")
      case "image":
        let encoded = try block.required("data")
        let padding = (4 - encoded.utf8.count % 4) % 4
        guard let data = Data(base64Encoded: encoded + String(repeating: "=", count: padding))
        else {
          throw ProbeError.unrepresentable("opaque-base64-image")
        }
        return .image(.data(data, mimeType: try block.required("mimeType")))
      default: return .unrecognized(block)
      }
    }
  }

  private static func textUTF16(_ block: [String: JSONValue]) throws -> [UInt16]? {
    guard let value = block["textUTF16"] else { return nil }
    return try JSONDecoder().decode([UInt16].self, from: JSONEncoder().encode(value))
  }

  private static func toolDefinition(_ value: JSONValue) throws -> ProviderToolDefinition {
    guard let tool = value.objectValue else {
      throw ProbeError.unrepresentable("tool-definition-is-not-an-object")
    }
    return ProviderToolDefinition(
      name: try tool.required("name"), description: tool.string("description") ?? "",
      inputSchema: tool["parameters"] ?? .object([:]),
      constrainedSampling: try sampling(tool.object("constrainedSampling")))
  }

  private static func sampling(_ raw: [String: JSONValue]?) throws -> ProviderConstrainedSampling? {
    guard let raw else { return nil }
    switch try raw.required("type") {
    case "json_schema":
      return .jsonSchema(strict: raw.string("strict") == "require" ? .require : .prefer)
    case "grammar":
      return .grammar(variants: (raw.object("variants") ?? [:]).compactMapValues(\.stringValue))
    default: throw ProbeError.unsupported("constrained sampling")
    }
  }

  private static func number(_ value: JSONValue) -> Double? {
    switch value {
    case .integer(let value): return Double(value)
    case .number(let value): return value
    default: return nil
    }
  }

  private static func ordered(_ value: JSONValue) -> ProviderOrderedJSON {
    if let object = value.objectValue {
      return .object((value.objectPropertyNames ?? []).map { ($0, ordered(object[$0]!)) })
    }
    if case .array(let values) = value { return .array(values.map(ordered)) }
    return .scalar(value)
  }
}

private enum ProbeGenerationMode: String, Decodable {
  case raw
  case simple
}

private struct ProbeInput: Decodable {
  let model: [String: JSONValue]
  let requestSource: String?
  let generationMode: ProbeGenerationMode?
  let context: Context
  let options: [String: JSONValue]
  let credential: Credential
  let environment: [String: String]
  let responses: [Response]?
  let aborted: Bool?
  let measureHeap: Bool?
  struct Context: Decodable {
    let systemPrompt: String?
    let messages: [[String: JSONValue]]
    let tools: [[String: JSONValue]]
  }
  struct Credential: Decodable {
    let key: String?
    let metadata: [String: String]
  }
  struct Response: Decodable, Sendable {
    let status: Int
    let headers: [String: String]
    let chunks: [String]
  }
}

struct ProbeOutput: Encodable {
  let request: Request?
  let pending: Bool
  let events: [JSONValue]
  let failure: [String: JSONValue]?
  var allocatedBytes: UInt64? = nil
  var lifetime: ProbeStreamLifetime.Observation? = nil
  struct Request: Encodable {
    let url: String
    let headers: [String: String]
    let body: JSONValue
    var azureConfiguration: [String: JSONValue]? = nil
    var rawBody: String? = nil
    var cloudConfiguration: [String: JSONValue]? = nil
  }
}

private func probeJSON<T: Encodable>(_ value: T) throws -> JSONValue {
  try probeEncoding { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
}

private func probeEncoding<T>(_ operation: () throws -> T) rethrows -> T {
  pi_heap_pause()
  defer { pi_heap_resume() }
  return try operation()
}

private actor ProbeToolUpdates {
  private struct Queue {
    var values: [ProviderToolArgumentsUpdate] = []
    var index = 0
  }
  private var updates: [String: Queue] = [:]

  func append(_ update: ProviderToolArgumentsUpdate) {
    pi_heap_pause()
    defer { pi_heap_resume() }
    updates[update.id, default: .init()].values.append(update)
  }

  func next(for event: ProviderEvent) -> ProviderToolArgumentsUpdate? {
    pi_heap_pause()
    defer { pi_heap_resume() }
    let id: String
    switch event {
    case .toolCallStarted(let value, _), .toolInputDelta(let value, _): id = value
    default: return nil
    }
    guard let queue = updates[id], queue.index < queue.values.count else { return nil }
    let value = queue.values[queue.index]
    if queue.index + 1 == queue.values.count {
      updates.removeValue(forKey: id)
    } else {
      updates[id]!.index += 1
    }
    return value
  }
}

final class ProbeChannel: @unchecked Sendable {
  private static let lock = NSLock()

  private struct Frame<Payload: Encodable>: Encodable {
    let kind: String
    let payload: Payload
    let id: String?
  }

  func write<T: Encodable>(_ kind: String, _ payload: T) throws {
    try probeEncoding {
      var data = try JSONEncoder().encode(
        Frame(kind: kind, payload: payload, id: WireProbeContext.id))
      data.append(10)
      Self.lock.withLock { FileHandle.standardOutput.write(data) }
    }
  }
}

private actor InteractiveProbeTransport: ProviderHTTPStreamingTransport {
  let channel: ProbeChannel
  let azureConfiguration: [String: JSONValue]?
  let cloudConfiguration: [String: JSONValue]?
  private var response: CheckedContinuation<ProviderHTTPStreamingResponse, any Error>?
  private var bodyRead: CheckedContinuation<Data?, any Error>?
  private var bodyOpen = false
  private var observerReply: CheckedContinuation<[String: JSONValue], any Error>?

  private struct Observation: Encodable {
    let stage: String
    let value: JSONValue
    let context: ProviderWireObserver.Context
  }

  func observe(_ stage: String, _ value: JSONValue, context: ProviderWireObserver.Context)
    async throws -> [String: JSONValue]
  {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        observerReply = continuation
        do {
          try channel.write("observer", Observation(stage: stage, value: value, context: context))
        } catch { fail(error) }
      }
    } onCancel: {
      Task { await self.fail(CancellationError()) }
    }
  }

  init(
    channel: ProbeChannel, azureConfiguration: [String: JSONValue]?,
    cloudConfiguration: [String: JSONValue]?
  ) {
    self.channel = channel
    self.azureConfiguration = azureConfiguration
    self.cloudConfiguration = cloudConfiguration
  }

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    let captured = try probeEncoding {
      ProbeOutput.Request(
        url: request.url!.absoluteString, headers: request.allHTTPHeaderFields ?? [:],
        body: request.value(forHTTPHeaderField: "Content-Encoding") == "zstd"
          ? .null
          : try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data("null".utf8)),
        azureConfiguration: azureConfiguration,
        rawBody: request.value(forHTTPHeaderField: "Content-Encoding") == "zstd"
          ? request.httpBody?.base64EncodedString() : nil, cloudConfiguration: cloudConfiguration)
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        response = continuation
        do { try channel.write("request", captured) } catch { fail(error) }
      }
    } onCancel: {
      Task { await self.cancelRequest() }
    }
  }

  private func cancelRequest() {
    guard response != nil || bodyOpen else { return }
    do { try channel.write("cancelRequest", [String: JSONValue]()) } catch {
      fail(error)
      return
    }
    fail(CancellationError())
  }

  func finish() {
    cancelRequest()
  }

  private func nextChunk() async throws -> Data? {
    guard bodyOpen else { return nil }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pi_heap_pause()
        defer { pi_heap_resume() }
        bodyRead = continuation
        do { try channel.write("readBody", [String: JSONValue]()) } catch { fail(error) }
      }
    } onCancel: {
      Task { await self.cancelRequest() }
    }
  }

  func receive(_ frame: [String: JSONValue]) throws {
    pi_heap_pause()
    defer { pi_heap_resume() }
    switch frame.string("kind") {
    case "observerReply":
      if let error = frame.string("error") {
        observerReply?.resume(
          throwing: ProviderRuntimeFailure(
            code: .transportFailed, message: error,
            providerID: nil, operation: "conformance.observer", causeDescription: nil))
      } else {
        observerReply?.resume(returning: frame)
      }
      observerReply = nil
    case "response":
      bodyOpen = true
      let stream = AsyncThrowingStream<Data, any Error>(unfolding: { try await self.nextChunk() })
      response?.resume(
        returning: .init(
          statusCode: frame.int("status")!,
          headers: (frame.object("headers") ?? [:]).compactMapValues(\.stringValue),
          body: stream))
      response = nil
    case "chunk":
      guard let value = frame.string("data"), let data = Data(base64Encoded: value) else {
        throw ProbeError.unsupported("fixture chunk")
      }
      bodyRead?.resume(returning: data)
      bodyRead = nil
    case "end":
      bodyOpen = false
      bodyRead?.resume(returning: nil)
      bodyRead = nil
    case "cancel": fail(CancellationError())
    case "failure":
      fail(
        ProviderRuntimeFailure(
          code: .transportFailed, message: frame.string("message") ?? "fixture transport failed",
          providerID: nil, operation: "conformance.transport", causeDescription: nil))
    default: throw ProbeError.unsupported("fixture frame")
    }
  }

  func fail(_ error: any Error) {
    observerReply?.resume(throwing: error)
    observerReply = nil
    response?.resume(throwing: error)
    response = nil
    bodyOpen = false
    bodyRead?.resume(throwing: error)
    bodyRead = nil
  }
}

private actor ProbeTransport: ProviderHTTPStreamingTransport {
  let responses: [ProbeInput.Response]
  let aborted: Bool
  var requests: [URLRequest] = []
  init(responses: [ProbeInput.Response], aborted: Bool) {
    self.responses = responses
    self.aborted = aborted
  }
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    requests.append(request)
    if aborted && requests.count >= responses.count {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    guard requests.count <= responses.count else { throw CancellationError() }
    let response = responses[requests.count - 1]
    return .init(
      statusCode: response.status, headers: response.headers,
      body: AsyncThrowingStream { continuation in
        for chunk in response.chunks {
          guard let data = Data(base64Encoded: chunk) else {
            continuation.finish(throwing: ProbeError.unsupported("response chunk"))
            return
          }
          continuation.yield(data)
        }
        continuation.finish()
      })
  }
}

private enum ProbeError: Error {
  case unsupported(String)
  case unrepresentable(String)
}

private struct FixtureAuthorization: ProviderAuthorizationAdapter {
  func authorize(
    _ operation: AuthorizationOperation, interaction: @escaping AuthorizationInteraction,
    credentialStore: any ProviderCredentialStore
  ) async throws -> AuthorizationState {
    throw ProbeError.unsupported("authorization lifecycle fixture")
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func required(_ key: String) throws -> String {
    guard let value = string(key) else { throw ProbeError.unsupported(key) }
    return value
  }
}
