import Foundation

func codexTimeout<T: Sendable>(
  milliseconds: Double?, clock: any ProviderOAuthClock, message: String,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  guard let milliseconds, milliseconds > 0 else { return try await operation() }
  return try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await clock.sleep(for: .milliseconds(milliseconds), purpose: .timeout)
      throw ProviderRuntimeFailure(
        code: .transportFailed, message: message, providerID: "openai-codex",
        operation: "codex.timeout", causeDescription: nil)
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}

actor CodexWebSocketSessions {
  struct Lease: Sendable {
    let id: UUID
    let socket: any ProviderWebSocketConnection
    let key: Key?
    let reused: Bool
  }

  struct Key: Hashable, Sendable {
    let session: String
    let account: String
  }

  private struct Continuation {
    let body: [String: JSONValue]
    let responseID: String
    let responseItems: [JSONValue]
  }

  private struct Entry {
    let lease: Lease
    let created: Date
    var busy = true
    var continuation: Continuation?
    var expiry: Task<Void, Never>?
  }

  private var entries: [Key: Entry] = [:]
  private var fallbackSessions: Set<String> = []
  private var statistics: [String: [String: JSONValue]] = [:]

  deinit {
    for entry in entries.values {
      entry.expiry?.cancel()
      let socket = entry.lease.socket
      Task { await socket.close(code: 1000, reason: "done") }
    }
  }

  func acquire(
    request: URLRequest, session: String?, account: String,
    transport: (any ProviderWebSocketTransport)?, clock: any ProviderOAuthClock,
    connectTimeout: Double?
  ) async throws -> Lease {
    let key = session.map { Key(session: $0, account: account) }
    var cacheNew = key != nil
    if let key, var entry = entries[key] {
      entry.expiry?.cancel()
      entry.expiry = nil
      if entry.busy {
        cacheNew = false
      } else if clock.now().timeIntervalSince(entry.created) >= 55 * 60 {
        entries.removeValue(forKey: key)
        await entry.lease.socket.close(code: 1000, reason: "connection_age_limit")
      } else {
        entry.busy = true
        entries[key] = entry
        if await entry.lease.socket.isOpen() {
          return Lease(id: entry.lease.id, socket: entry.lease.socket, key: key, reused: true)
        }
        entries.removeValue(forKey: key)
        await entry.lease.socket.close(code: 1000, reason: "done")
      }
    }
    guard let transport else {
      throw ProviderRuntimeFailure(
        code: .transportFailed, message: "WebSocket transport is not available in this runtime",
        providerID: "openai-codex", operation: "codex.websocket.connect", causeDescription: nil)
    }
    let timeout = connectTimeout ?? 15_000
    let socket = try await codexTimeout(
      milliseconds: timeout, clock: clock,
      message: "WebSocket connect timeout after \(Int(timeout))ms"
    ) { try await transport.connect(request) }
    let lease = Lease(id: UUID(), socket: socket, key: cacheNew ? key : nil, reused: false)
    if let key = lease.key { entries[key] = Entry(lease: lease, created: clock.now()) }
    return lease
  }

  func requestBody(
    _ body: [String: JSONValue], lease: Lease, session: String?, cachedContext: Bool
  ) -> [String: JSONValue] {
    var next = body
    if cachedContext, let key = lease.key, let continuation = entries[key]?.continuation {
      let rest = body.filter { !["input", "previous_response_id"].contains($0.key) }
      let previous = continuation.body.filter {
        !["input", "previous_response_id"].contains($0.key)
      }
      let input = body.array("input") ?? []
      let baseline = (continuation.body.array("input") ?? []) + continuation.responseItems
      if rest == previous, input.count >= baseline.count,
        Array(input.prefix(baseline.count)) == baseline
      {
        next["previous_response_id"] = .string(continuation.responseID)
        next["input"] = .array(Array(input.dropFirst(baseline.count)))
      } else {
        entries[key]?.continuation = nil
      }
    }
    if let session {
      var stats = statsFor(session)
      increment(&stats, "requests")
      increment(&stats, lease.reused ? "connectionsReused" : "connectionsCreated")
      if cachedContext { increment(&stats, "cachedContextRequests") }
      if next.bool("store") == true { increment(&stats, "storeTrueRequests") }
      stats["lastInputItems"] = .integer(Int64(next.array("input")?.count ?? 0))
      if let id = next.string("previous_response_id"), !id.isEmpty {
        increment(&stats, "deltaRequests")
        stats["lastDeltaInputItems"] = stats["lastInputItems"]
        stats["lastPreviousResponseId"] = .string(id)
      } else {
        increment(&stats, "fullContextRequests")
        stats["lastDeltaInputItems"] = nil
        stats["lastPreviousResponseId"] = nil
      }
      statistics[session] = stats
    }
    return next
  }

  func release(
    _ lease: Lease, keep: Bool, body: [String: JSONValue], responseID: String? = nil,
    responseItems: [JSONValue] = [], cachedContext: Bool, clock: any ProviderOAuthClock
  ) async {
    guard let key = lease.key, var entry = entries[key], entry.lease.id == lease.id else {
      await lease.socket.close(code: 1000, reason: "done")
      return
    }
    guard keep else {
      entries.removeValue(forKey: key)
      entry.expiry?.cancel()
      await lease.socket.close(code: 1000, reason: "done")
      return
    }
    if cachedContext, let responseID, !responseID.isEmpty {
      entry.continuation = Continuation(
        body: body, responseID: responseID, responseItems: responseItems)
    }
    entry.busy = false
    entry.expiry = Task { [weak self] in
      do {
        try await clock.sleep(for: .seconds(5 * 60), purpose: .background)
        await self?.expire(key, id: lease.id)
      } catch {}
    }
    entries[key] = entry
  }

  private func expire(_ key: Key, id: UUID) async {
    guard let entry = entries[key], entry.lease.id == id, !entry.busy else { return }
    entries.removeValue(forKey: key)
    await entry.lease.socket.close(code: 1000, reason: "idle_timeout")
  }

  func isFallbackActive(_ session: String?) -> Bool {
    session.map { fallbackSessions.contains($0) } ?? false
  }

  func recordFailure(session: String?, message: String) {
    guard let session else { return }
    fallbackSessions.insert(session)
    var stats = statsFor(session)
    increment(&stats, "websocketFailures")
    stats["lastWebSocketError"] = .string(message)
    stats["websocketFallbackActive"] = .bool(true)
    statistics[session] = stats
  }

  func recordFallback(session: String?) {
    guard let session else { return }
    var stats = statsFor(session)
    increment(&stats, "sseFallbacks")
    stats["websocketFallbackActive"] = .bool(fallbackSessions.contains(session))
    statistics[session] = stats
  }

  func debugStats() -> [String: [String: JSONValue]] { statistics }

  func close(session: String? = nil) async {
    let removed = entries.filter { session == nil || $0.key.session == session }
    for (key, entry) in removed {
      entries.removeValue(forKey: key)
      entry.expiry?.cancel()
      await entry.lease.socket.close(code: 1000, reason: "debug_close")
    }
  }

  func resetStats(session: String? = nil) {
    if let session {
      statistics.removeValue(forKey: session)
      fallbackSessions.remove(session)
    } else {
      statistics.removeAll()
      fallbackSessions.removeAll()
    }
  }

  private func statsFor(_ session: String) -> [String: JSONValue] {
    statistics[session]
      ?? Dictionary(
        uniqueKeysWithValues: [
          "requests", "connectionsCreated", "connectionsReused", "cachedContextRequests",
          "storeTrueRequests", "fullContextRequests", "deltaRequests", "lastInputItems",
          "websocketFailures", "sseFallbacks",
        ].map { ($0, .integer(0)) })
  }

  private func increment(_ stats: inout [String: JSONValue], _ key: String) {
    stats[key] = .integer(Int64((stats.int(key) ?? 0) + 1))
  }
}
