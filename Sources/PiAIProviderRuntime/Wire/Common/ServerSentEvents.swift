import Foundation

struct ServerSentEvent: Sendable, Equatable {
  let event: String?
  let data: String
  let id: String?
  var raw: [String] = []
}

struct ServerSentEventDecoder: Sendable, Codable {
  private var buffer = Data()
  private var skipLeadingLF = false
  private var eventName: String?
  private var eventID: String?
  private var dataLines: [String] = []
  private var rawLines: [String] = []

  var pendingLineBytes: Int { buffer.count }

  mutating func append(_ chunk: Data) throws -> [ServerSentEvent] {
    var events: [ServerSentEvent] = []
    for byte in chunk {
      if skipLeadingLF {
        skipLeadingLF = false
        if byte == 0x0A { continue }
      }
      if byte == 0x0D || byte == 0x0A {
        guard let line = String(data: buffer, encoding: .utf8) else {
          throw failure("event stream contains invalid UTF-8")
        }
        buffer.removeAll(keepingCapacity: true)
        if let event = processLine(line) { events.append(event) }
        skipLeadingLF = byte == 0x0D
      } else {
        buffer.append(byte)
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
      if let event = processLine(line) { events.append(event) }
    }
    skipLeadingLF = false
    if let event = dispatch() { events.append(event) }
    return events
  }

  private mutating func processLine(_ line: String) -> ServerSentEvent? {
    if line.isEmpty { return dispatch() }
    rawLines.append(line)
    if line.first == ":" { return nil }
    let components = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let field = String(components[0])
    var value = components.count == 2 ? String(components[1]) : ""
    if value.first == " " { value.removeFirst() }
    switch field {
    case "event": eventName = value
    case "data": dataLines.append(value)
    case "id" where !value.contains("\0"): eventID = value
    default: break
    }
    return nil
  }

  private mutating func dispatch() -> ServerSentEvent? {
    defer {
      eventName = nil
      dataLines.removeAll(keepingCapacity: true)
      rawLines.removeAll(keepingCapacity: true)
    }
    guard eventName?.isEmpty == false || !dataLines.isEmpty else { return nil }
    return ServerSentEvent(
      event: eventName, data: dataLines.joined(separator: "\n"),
      id: eventID, raw: rawLines)
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
  from stream: AsyncThrowingStream<Data, any Error>
) async throws -> String? {
  var body = Data()
  for try await chunk in stream {
    body.append(chunk)
  }
  guard !body.isEmpty else { return nil }
  return String(data: body, encoding: .utf8)
}
