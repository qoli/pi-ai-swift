import Foundation
import Testing

@testable import PiAIProviderRuntime

actor SourceLogicalPayloadCapture {
  private var value: JSONValue?

  nonisolated func observing(_ context: WireProtocolContext) -> WireProtocolContext {
    guard context.model.protocolID == "anthropic-messages" else { return context }
    var result = context
    result.wireObserver = .init(onPayload: { payload, _ in
      await self.capture(.object(payload))
      return nil
    })
    return result
  }

  private func capture(_ value: JSONValue) { self.value = value }

  func body(from wire: JSONValue, protocolID: String) throws -> JSONValue {
    guard protocolID == "anthropic-messages" else { return wire }
    return try #require(
      value, "The source request oracle observes onPayload before SDK HTTP projection")
  }
}
