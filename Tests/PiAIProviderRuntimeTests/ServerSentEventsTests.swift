import Foundation
import Testing

@testable import PiAIProviderRuntime

@Suite
struct ServerSentEventsTests {
  @Test
  func decodesArbitraryChunksCommentsMultilineDataAndEOF() throws {
    var decoder = ServerSentEventDecoder()
    var events: [ServerSentEvent] = []
    for chunk in [
      "event: mes", "sage\r\ndata: {\"a\":", "1}\r\ndata: two\r\n\r\n: ping\n",
      "id: final\ndata: tail",
    ] {
      events += try decoder.append(Data(chunk.utf8))
    }
    events += try decoder.finish()
    #expect(
      events == [
        ServerSentEvent(event: "message", data: "{\"a\":1}\ntwo", id: nil),
        ServerSentEvent(event: nil, data: "tail", id: "final"),
      ]
    )
  }

  @Test
  func rejectsInvalidUTF8() {
    var decoder = ServerSentEventDecoder()
    #expect(throws: ProviderRuntimeFailure.self) {
      _ = try decoder.append(Data([0xFF, 0x0A]))
    }
  }
}
