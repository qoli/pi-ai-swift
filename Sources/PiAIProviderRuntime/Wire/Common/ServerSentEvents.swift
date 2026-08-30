import Foundation

struct ServerSentEvent: Sendable, Equatable {
  let event: String?
  let data: String
  let id: String?
}

struct ServerSentEventDecoder: Sendable {
  private var buffer = Data()
  private var eventName: String?
  private var eventID: String?
  private var dataLines: [String] = []

  mutating func append(_ chunk: Data) throws -> [ServerSentEvent] {
    buffer.append(chunk)
    var events: [ServerSentEvent] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      var line = buffer[..<newline]
      buffer.removeSubrange(...newline)
      if line.last == 0x0D {
        line = line.dropLast()
      }
      guard let string = String(data: line, encoding: .utf8) else {
        throw failure("event stream contains invalid UTF-8")
      }
      if let event = processLine(string) {
        events.append(event)
      }
    }
    return events
  }

  mutating func finish() throws -> [ServerSentEvent] {
    var events: [ServerSentEvent] = []
    if !buffer.isEmpty {
      guard let line = String(data: buffer, encoding: .utf8) else {
        throw failure("event stream contains invalid trailing UTF-8")
      }
      buffer.removeAll()
      if let event = processLine(line) {
        events.append(event)
      }
    }
    if let event = dispatch() {
      events.append(event)
    }
    return events
  }

  private mutating func processLine(_ line: String) -> ServerSentEvent? {
    if line.isEmpty {
      return dispatch()
    }
    if line.first == ":" {
      return nil
    }
    let components = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let field = String(components[0])
    var value = components.count == 2 ? String(components[1]) : ""
    if value.first == " " {
      value.removeFirst()
    }
    switch field {
    case "event": eventName = value
    case "data": dataLines.append(value)
    case "id" where !value.contains("\0"): eventID = value
    default: break
    }
    return nil
  }

  private mutating func dispatch() -> ServerSentEvent? {
    guard !dataLines.isEmpty else {
      eventName = nil
      return nil
    }
    let event = ServerSentEvent(
      event: eventName,
      data: dataLines.joined(separator: "\n"),
      id: eventID
    )
    eventName = nil
    dataLines.removeAll(keepingCapacity: true)
    return event
  }

  private func failure(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: nil,
      operation: "sse.decode",
      causeDescription: nil
    )
  }
}

func collectErrorBody(
  from stream: AsyncThrowingStream<Data, any Error>,
  limit: Int = 16_384
) async throws -> String? {
  var body = Data()
  for try await chunk in stream {
    guard body.count < limit else { break }
    body.append(chunk.prefix(limit - body.count))
  }
  guard !body.isEmpty else { return nil }
  return String(data: body, encoding: .utf8)
}
