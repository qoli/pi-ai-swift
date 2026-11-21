import CryptoKit
import Foundation

/// Session state shared by the Anthropic and Bedrock adapters.
public enum ProviderSessionResources {
  private static let lock = NSLock()
  private static let storage = Storage()
  private final class Storage: @unchecked Sendable {
    // Every access is protected by lock. Only identifiers and fingerprints are retained.
    var strict: [String: UInt64] = [:]
    var threads: [String: (ThreadState, UInt64)] = [:]
    var sequence: UInt64 = 0
  }
  enum ThreadState {
    case off
    case reply(id: String, count: Int, digest: SHA256.Digest)
  }

  public static func cleanup(_ sessionID: String? = nil) {
    lock.withLock {
      if let sessionID, !sessionID.isEmpty {
        storage.strict.removeValue(forKey: sessionID)
        storage.threads.removeValue(forKey: sessionID)
      } else {
        storage.strict.removeAll()
        storage.threads.removeAll()
      }
    }
  }

  static func hasExceededStrictToolLimits(_ id: String?) -> Bool {
    guard let id else { return false }
    return lock.withLock { storage.strict[id] != nil }
  }

  static func markStrictToolLimitsExceeded(_ id: String?) {
    guard let id else { return }
    lock.withLock {
      guard storage.strict[id] == nil else { return }
      storage.sequence += 1
      storage.strict[id] = storage.sequence
      if storage.strict.count > 10_000, let oldest = storage.strict.min(by: { $0.value < $1.value })
      {
        storage.strict.removeValue(forKey: oldest.key)
      }
    }
  }

  static func setThread(_ state: ThreadState, for id: String) {
    lock.withLock {
      storage.sequence += 1
      storage.threads[id] = (state, storage.sequence)
      if storage.threads.count > 10_000,
        let oldest = storage.threads.min(by: { $0.value.1 < $1.value.1 })
      {
        storage.threads.removeValue(forKey: oldest.key)
      }
    }
  }

  static func prepare(_ thread: AnthropicMessageThread) throws -> URLRequest? {
    let entry = lock.withLock { storage.threads[thread.session] }
    if case .off = entry?.0 { return nil }
    if case .reply(let id, let count, let digest) = entry?.0,
      thread.messages.count > count, try thread.hash(Array(thread.messages.prefix(count))) == digest
    {
      let consumed = lock.withLock {
        guard storage.threads[thread.session]?.1 == entry?.1 else { return false }
        storage.threads.removeValue(forKey: thread.session)
        return true
      }
      if consumed { return try thread.request(continuing: id, after: count) }
    }
    return try thread.request()
  }
}

struct AnthropicMessageThread {
  let session: String
  let full: URLRequest
  let body: [String: JSONValue]
  let provider: String
  var messages: [JSONValue] { body.array("messages") ?? [] }

  func request(continuing id: String? = nil, after count: Int = 0) throws -> URLRequest {
    var params = body
    if let id {
      params["system"] = nil
      params["tools"] = nil
      params["messages"] = .array(Array(messages.dropFirst(count)))
      params["thread"] = .object(["type": .string("continue"), "previous_message_id": .string(id)])
    } else {
      params["thread"] = .object(["type": .string("create")])
    }
    var wire = full
    wire.httpBody = try JSONEncoder().encode(params)
    return wire
  }

  private func normalize(_ value: JSONValue) -> JSONValue {
    if let object = value.objectValue {
      var result = object.filter { $0.key != "cache_control" }.mapValues(normalize)
      if let content = object.string("content") {
        result["content"] = .array([.object(["type": .string("text"), "text": .string(content)])])
      }
      return .object(result)
    }
    if let items = value.arrayValue { return .array(items.map(normalize)) }
    return value
  }

  func hash(_ prefix: [JSONValue]) throws -> SHA256.Digest {
    let settings = [
      "model", "system", "tools", "thinking", "output_config", "tool_choice", "fallbacks",
    ].map { body[$0] ?? .null }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let identity: [JSONValue] = [
      .string(provider), .string(full.url?.absoluteString ?? ""),
      full.value(forHTTPHeaderField: "anthropic-beta").map(JSONValue.string) ?? .null,
    ]
    return try SHA256.hash(
      data: encoder.encode(identity + settings + [.array(prefix.map(normalize))]))
  }

  func record(id: String, reply: JSONValue?) throws {
    let prefix = messages + (reply.map { [$0] } ?? [])
    try ProviderSessionResources.setThread(
      .reply(id: id, count: prefix.count, digest: hash(prefix)), for: session)
  }

  func send(using transport: any ProviderHTTPStreamingTransport, diagnostic: (JSONValue) -> Void)
    async throws -> (ProviderHTTPStreamingResponse, Bool)
  {
    guard let prepared = try ProviderSessionResources.prepare(self) else {
      return (try await transport.stream(full), false)
    }
    let response = try await transport.stream(prepared)
    if (200..<300).contains(response.statusCode) { return (response, true) }
    let text = try await collectErrorBody(from: response.body)
    try Task.checkCancellation()
    let code = text.flatMap {
      try? JSONValue(jsonData: Data($0.utf8)).objectValue?
        .object("error")?.object("details")?.string("error_code")
    }
    let reason = PreferredStrictToolFallback.errorMessage(
      api: .anthropic, response: response, body: text)
    let recreate = [
      "thread_not_found", "thread_already_continued", "thread_continue_in_flight",
      "thread_fingerprint_mismatch",
    ].contains(code)
    guard
      recreate || code == "thread_unsupported_request"
        || (code == nil && response.statusCode == 400 && reason.contains("thread"))
    else {
      return (
        .init(
          statusCode: response.statusCode, headers: response.headers,
          body: AsyncThrowingStream {
            if let text { $0.yield(Data(text.utf8)) }
            $0.finish()
          }), false
      )
    }
    diagnostic(
      .object([
        "type": .string("anthropic_thread_fallback"),
        "timestamp": .integer(Int64(Date().timeIntervalSince1970 * 1000)),
        "error": .object(["message": .string(reason)]),
        "details": .object(["reason": .string(code ?? String(response.statusCode))]),
      ]))
    let retried = try await transport.stream(recreate ? request() : full)
    if !recreate, (200..<300).contains(retried.statusCode) {
      ProviderSessionResources.setThread(.off, for: session)
    }
    return (retried, recreate)
  }
}
