import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct SourceDerivedFailureDifferentialTests {
  @Test
  func everySupportedWireProtocolMatchesPinnedSourceTypedFailures() async throws {
    let repository = failureRepositoryRoot()
    let requestCase = try failureDecode(
      FailureRequestCase.self,
      at: repository.appending(path: "Fixtures/Differential/Cases/request-rich.json")
    )
    let expectedRevision = try failurePinnedRevision(repository: repository)
    let expectedProtocols = StandardWireProtocols.supportedProtocolIDs
    #expect(Set(requestCase.protocols.map(\.protocolID)) == expectedProtocols)

    for fixtureName in [
      "failure-http",
      "failure-malformed-wire",
      "failure-missing-terminal",
      "failure-provider-declared",
      "failure-cancellation",
    ] {
      let failureCase = try failureDecode(
        FailureCase.self,
        at: repository.appending(path: "Fixtures/Differential/Cases/\(fixtureName).json")
      )
      let oracle = try failureDecode(
        FailureOracle.self,
        at: repository.appending(path: "Fixtures/Differential/Oracle/\(fixtureName).json")
      )
      #expect(failureCase.caseID == oracle.caseID)
      #expect(failureCase.expectedCategory == oracle.category)
      #expect(oracle.upstreamRevision == expectedRevision)
      #expect(Set(oracle.protocols.keys) == expectedProtocols)

      for protocolCase in requestCase.protocols {
        let source = try #require(oracle.protocols[protocolCase.protocolID])
        if source.outcome == "notApplicable" {
          #expect(
            failureCase.expectedCategory == "missingTerminal"
              && protocolCase.protocolID == "openrouter-images"
          )
          continue
        }
        #expect(source.outcome == "failure")
        let expectedReason = failureCase.expectedCategory == "cancellation" ? "aborted" : "error"
        #expect(
          source.sourceTerminal == FailureSourceTerminal(type: "error", reason: expectedReason))
        let adapter = try #require(
          StandardWireProtocols.make().first { $0.protocolID == protocolCase.protocolID }
        )
        let input = failureInput(protocolCase)
        var emitted: [ProviderEvent] = []
        if failureCase.expectedCategory == "cancellation" {
          do {
            for try await event in adapter.stream(
              input.request,
              context: input.context,
              transport: CancellationReplayTransport()
            ) {
              emitted.append(event)
            }
            Issue.record("\(protocolCase.protocolID) swallowed cancellation")
          } catch is CancellationError {
            // Exact Swift boundary: cancellation propagates, never becomes provider output.
          } catch {
            Issue.record("\(protocolCase.protocolID) changed cancellation into \(error)")
          }
          #expect(emitted.isEmpty)
          continue
        }
        let decoderInput = try #require(source.decoderInput)
        do {
          for try await event in adapter.stream(
            input.request,
            context: input.context,
            transport: FailureReplayTransport(input: decoderInput)
          ) {
            emitted.append(event)
          }
          Issue.record(
            "\(protocolCase.protocolID) accepted source-derived \(failureCase.expectedCategory)"
          )
        } catch let failure as ProviderRuntimeFailure {
          let expectedCode: ProviderRuntimeFailure.Code =
            failureCase.expectedCategory == "httpProviderError"
              || failureCase.expectedCategory == "providerDeclaredError"
            ? .transportFailed : .invalidResponse
          #expect(
            failure.code == expectedCode,
            "typed \(failureCase.expectedCategory) drift for \(protocolCase.protocolID): \(failure.code), \(failure.message)"
          )
          let operation = failure.operation ?? ""
          switch failureCase.expectedCategory {
          case "httpProviderError":
            #expect(operation.contains("response"))
          case "malformedWireSyntax":
            #expect(operation.contains("decode"))
          case "missingTerminal":
            #expect(operation.contains("event"))
            #expect(
              failure.message.localizedCaseInsensitiveContains("without")
                || failure.message.localizedCaseInsensitiveContains("ended")
            )
          case "providerDeclaredError":
            #expect(operation.contains("error") || operation.contains("finish"))
          default:
            Issue.record("unknown failure category: \(failureCase.expectedCategory)")
          }
        }
        #expect(
          emitted.compactMap(failureEventType) == source.partialEventTypes,
          "partial failure trace drift for \(protocolCase.protocolID)"
        )
      }
    }
  }
}

private struct CancellationReplayTransport: ProviderHTTPStreamingTransport {
  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    throw CancellationError()
  }
}

private struct FailureReplayTransport: ProviderHTTPStreamingTransport {
  let input: FailureDecoderInput

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    let chunks: [Data]
    if let encoded = input.chunksBase64 {
      chunks = try encoded.map { try #require(Data(base64Encoded: $0)) }
    } else if let raw = input.rawBodyBase64 {
      chunks = [try #require(Data(base64Encoded: raw))]
    } else {
      chunks = [try JSONEncoder().encode(input.body ?? .null)]
    }
    return ProviderHTTPStreamingResponse(
      statusCode: input.status,
      headers: input.headers,
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      }
    )
  }
}

private func failureInput(
  _ protocolCase: FailureProtocolCase
) -> (request: ProviderRequest, context: WireProtocolContext) {
  let isImage = protocolCase.protocolID == "openrouter-images"
  let model = ProviderModel(
    id: protocolCase.modelID,
    providerID: protocolCase.providerID,
    name: protocolCase.modelID,
    protocolID: protocolCase.protocolID,
    capabilities: ProviderCapabilities(
      textInput: true,
      imageInput: true,
      toolCalling: !isImage,
      reasoning: protocolCase.reasoning,
      structuredOutput: !isImage,
      imageGeneration: isImage
    ),
    contextWindow: 262_144,
    maximumOutputTokens: protocolCase.maximumOutputTokens
  )
  var metadata: [String: JSONValue] = [:]
  if let compat = protocolCase.compat { metadata["compat"] = .object(compat) }
  if protocolCase.protocolID == "google-vertex" {
    metadata["project"] = .string("fixture-project")
    metadata["location"] = .string("us-central1")
  }
  if let output = protocolCase.output {
    metadata["output"] = .array(output.map(JSONValue.string))
  }
  let credential =
    protocolCase.protocolID == "openai-codex-responses"
    ? "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiZml4dHVyZS1hY2NvdW50In19.fixture"
    : "fixture-key"
  let context = WireProtocolContext(
    provider: ProviderDescriptor(
      id: protocolCase.providerID,
      name: protocolCase.providerID,
      authorizationMethods: [],
      models: [model]
    ),
    model: model,
    baseURL: URL(string: protocolCase.baseURL)!,
    headers: [:],
    credential: .apiKey(APIKeyCredential(key: credential, metadata: [:])),
    modelConfiguration: ProviderModelConfiguration(
      protocolID: protocolCase.protocolID,
      baseURL: nil,
      headers: [:],
      metadata: metadata
    )
  )
  let request = ProviderRequest(
    id: "failure-http-provider-v1",
    providerID: protocolCase.providerID,
    modelID: protocolCase.modelID,
    messages: [.user([.text("fixture")])],
    tools: [],
    options: ProviderGenerationOptions(
      maximumOutputTokens: isImage ? nil : 64,
      temperature: nil,
      reasoningEffort: nil,
      responseSchema: nil,
      providerOptions: protocolCase.protocolID == "google-vertex"
        ? [
          "project": .string("fixture-project"),
          "location": .string("us-central1"),
        ] : [:],
      outputModality: isImage ? .image : .text
    )
  )
  return (request, context)
}

private struct FailureRequestCase: Decodable {
  let protocols: [FailureProtocolCase]
}

private struct FailureProtocolCase: Decodable {
  let protocolID: String
  let providerID: String
  let modelID: String
  let baseURL: String
  let reasoning: Bool
  let maximumOutputTokens: Int
  let compat: [String: JSONValue]?
  let output: [String]?
}

private struct FailureCase: Decodable {
  let caseID: String
  let expectedCategory: String
}

private struct FailureDecoderInput: Decodable, Sendable {
  let kind: String
  let status: Int
  let headers: [String: String]
  let body: JSONValue?
  let rawBodyBase64: String?
  let chunksBase64: [String]?
}

private struct FailureOracle: Decodable {
  let caseID: String
  let category: String
  let upstreamRevision: String
  let protocols: [String: FailureOracleProtocol]
}

private struct FailureOracleProtocol: Decodable {
  let outcome: String
  let decoderInput: FailureDecoderInput?
  let sourceTerminal: FailureSourceTerminal?
  let partialEventTypes: [String]?
}

private struct FailureSourceTerminal: Decodable, Equatable {
  let type: String
  let reason: String
}

private func failureEventType(_ event: ProviderEvent) -> String? {
  switch event {
  case .responseStarted: nil
  case .textDelta: "textDelta"
  case .reasoningDelta: "reasoningDelta"
  case .reasoningSignatureDelta: "reasoningSignatureDelta"
  case .toolCallStarted: "toolCallStarted"
  case .toolInputDelta: "toolInputDelta"
  case .toolCallCompleted: "toolCallCompleted"
  case .asset: "asset"
  case .usage: "usage"
  case .responseSnapshot: "responseSnapshot"
  case .completed: "completed"
  }
}

private func failureRepositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

private func failureDecode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
  try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

private func failurePinnedRevision(repository: URL) throws -> String {
  struct Lock: Decodable { let revision: String }
  return try failureDecode(
    Lock.self,
    at: repository.appending(path: "Upstream.lock.json")
  ).revision
}
