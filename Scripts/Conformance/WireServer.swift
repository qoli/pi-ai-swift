import Foundation

@testable import PiAIProviderRuntime

enum WireProbeContext {
  @TaskLocal static var id: String?
}

actor WireConformanceServer {
  nonisolated let sessions = CodexWebSocketSessions()
  nonisolated let cloudCredentialSources = ProviderCloudCredentialSources()
  nonisolated let clock: ProbeWireClock
  private let channel = ProbeChannel()
  private var inputs: [String: AsyncStream<[String: JSONValue]>.Continuation] = [:]
  private var sockets: [String: ProbeWebSocket] = [:]
  private var timers: [String: CheckedContinuation<Void, any Error>] = [:]
  private var cloudReplies: [String: CheckedContinuation<[String: JSONValue], any Error>] = [:]

  init() { clock = ProbeWireClock() }

  static func run() async {
    let server = WireConformanceServer()
    server.clock.server = server
    try? ProbeChannel().write("serverReady", [String: Bool]())
    await Task.detached {
      while let line = readLine() {
        if let value = try? JSONValue(jsonData: Data(line.utf8)).objectValue {
          await server.receive(value, line: line)
        }
      }
      await server.sessions.close()
    }.value
  }

  private func receive(_ frame: [String: JSONValue], line: String) async {
    clock.update(frame)
    let id = frame.string("id") ?? ""
    switch frame.string("kind") {
    case "start":
      let pair = AsyncStream<[String: JSONValue]>.makeStream()
      inputs[id] = pair.continuation
      Task {
        await WireProbeContext.$id.withValue(id) {
          let lifetime = ProbeStreamLifetime()
          do {
            let input = try ProviderOrderedJSON(data: Data(line.utf8))["input"] ?? .scalar(.null)
            let data = Data(try input.encodedString().utf8)
            _ = try await SwiftConformanceProbe.execute(
              data, interactive: true, incoming: pair.stream, wireServer: self, lifetime: lifetime)
          } catch {
            let failure = error as? ProviderRuntimeFailure
            try? channel.write(
              "finished",
              [
                "code": failure?.code.rawValue ?? "transportFailed",
                "message": failure?.message ?? String(describing: error),
              ])
          }
          complete(id)
          if let observation = await lifetime.afterScope() {
            try? channel.write("lifetime", observation)
          }
          try? channel.write("callComplete", [String: Bool]())
        }
      }
    case "socketEvent":
      if let socket = sockets[frame.string("socket") ?? ""] { await socket.accept(frame) }
    case "clockReply":
      timers.removeValue(forKey: frame.string("timer") ?? "")?.resume()
    case "cloudReply":
      if let error = frame.string("error") {
        cloudReplies.removeValue(forKey: id)?.resume(
          throwing: ProviderRuntimeFailure(
            code: .authorizationFailed, message: error, providerID: nil,
            operation: "conformance.cloud", causeDescription: nil))
      } else {
        cloudReplies.removeValue(forKey: id)?.resume(returning: frame.object("value") ?? [:])
      }
    case "closeSessions": await sessions.close(session: frame.string("session"))
    case "resetStats": await sessions.resetStats(session: frame.string("session"))
    default: inputs[id]?.yield(frame)
    }
  }

  private func complete(_ id: String) {
    inputs.removeValue(forKey: id)?.finish()
  }

  func cloudExchange(_ stage: String, value: [String: JSONValue]) async throws -> [String:
    JSONValue]
  {
    let id = WireProbeContext.id!
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        cloudReplies[id] = continuation
        do {
          try channel.write(
            "cloud", ["stage": JSONValue.string(stage), "value": JSONValue.object(value)])
        } catch { cloudReplies.removeValue(forKey: id)?.resume(throwing: error) }
      }
    } onCancel: {
      Task { await self.cancelCloudExchange(id) }
    }
  }

  private func cancelCloudExchange(_ id: String) {
    cloudReplies.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  func connect(_ request: URLRequest) async throws -> any ProviderWebSocketConnection {
    let id = UUID().uuidString
    let socket = ProbeWebSocket(id: id)
    sockets[id] = socket
    do {
      try await socket.open(request)
      return socket
    } catch {
      sockets.removeValue(forKey: id)
      throw error
    }
  }

  func sleep(_ duration: Duration, purpose: String) async throws {
    let id = UUID().uuidString
    let parts = duration.components
    let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        timers[id] = continuation
        do {
          try channel.write(
            "clockSleep",
            [
              "timer": JSONValue.string(id), "milliseconds": .number(milliseconds),
              "deadline": .number(clock.now().timeIntervalSince1970 * 1_000 + milliseconds),
              "purpose": .string(purpose),
            ])
        } catch { timers.removeValue(forKey: id)?.resume(throwing: error) }
      }
    } onCancel: {
      Task { await self.cancelTimer(id) }
    }
  }

  private func cancelTimer(_ id: String) {
    guard let continuation = timers.removeValue(forKey: id) else { return }
    try? channel.write("clockCancel", ["timer": id])
    continuation.resume(throwing: CancellationError())
  }
}

final class ProbeWireClock: ProviderOAuthClock, @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date()
  weak var server: WireConformanceServer?
  func now() -> Date { lock.withLock { date } }
  func update(_ frame: [String: JSONValue]) {
    if let milliseconds = frame.int("now") {
      lock.withLock { date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
    }
  }
  func sleep(for duration: Duration) async throws {
    guard let server else { throw CancellationError() }
    try await server.sleep(duration, purpose: "sleep")
  }
  func sleep(for duration: Duration, purpose: ProviderClockSleepPurpose) async throws {
    guard let server else { throw CancellationError() }
    try await server.sleep(duration, purpose: purpose.rawValue)
  }
}

struct ProbeWebSocketTransport: ProviderWebSocketTransport {
  let server: WireConformanceServer
  func connect(_ request: URLRequest) async throws -> any ProviderWebSocketConnection {
    try await server.connect(request)
  }
}

private actor ProbeWebSocket: ProviderWebSocketConnection {
  private var sequence = 0
  let id: String
  let channel = ProbeChannel()
  private var opening: CheckedContinuation<Void, any Error>?
  private var receiving: CheckedContinuation<String, any Error>?
  private var messages: [String] = []
  private var index = 0
  private var failure: (any Error)?

  init(id: String) { self.id = id }

  func isOpen() async -> Bool { failure == nil }

  func open(_ request: URLRequest) async throws {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        opening = continuation
        do {
          try channel.write(
            "socketOpen",
            [
              "socket": JSONValue.string(id), "url": .string(request.url!.absoluteString),
              "headers": .object((request.allHTTPHeaderFields ?? [:]).mapValues(JSONValue.string)),
            ])
        } catch { fail(error) }
      }
    } onCancel: {
      Task { await self.close(code: 1000, reason: "connect_timeout") }
    }
  }

  func send(_ text: String) async throws {
    if let failure { throw failure }
    try channel.write("socketSend", ["socket": id, "text": text])
  }

  func receive() async throws -> String {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      if index < messages.count {
        let value = messages[index]
        index += 1
        if index == messages.count {
          messages.removeAll(keepingCapacity: true)
          index = 0
        }
        return value
      }
      if let failure { throw failure }
      return try await withCheckedThrowingContinuation { continuation in
        receiving = continuation
        try? channel.write(
          "socketReceive", ["socket": JSONValue.string(id), "sequence": .integer(Int64(sequence))])
      }
    } onCancel: {
      Task { await self.cancelReceive() }
    }
  }

  private func cancelReceive() {
    receiving?.resume(throwing: CancellationError())
    receiving = nil
  }

  func close(code: Int, reason: String) async {
    try? channel.write(
      "socketClose",
      [
        "socket": JSONValue.string(id), "code": .integer(Int64(code)), "reason": .string(reason),
      ])
    fail(CancellationError())
  }

  func accept(_ frame: [String: JSONValue]) {
    sequence = frame.int("sequence") ?? sequence
    switch frame.string("event") {
    case "open":
      opening?.resume()
      opening = nil
    case "message":
      guard let text = frame.string("text") else { return }
      if let receiving {
        self.receiving = nil
        receiving.resume(returning: text)
      } else {
        messages.append(text)
      }
    default:
      fail(
        ProviderRuntimeFailure(
          code: .transportFailed, message: frame.string("message") ?? "WebSocket error",
          providerID: nil, operation: "websocket.transport", causeDescription: nil))
    }
  }

  private func fail(_ error: any Error) {
    failure = error
    opening?.resume(throwing: error)
    receiving?.resume(throwing: error)
    opening = nil
    receiving = nil
  }
}
