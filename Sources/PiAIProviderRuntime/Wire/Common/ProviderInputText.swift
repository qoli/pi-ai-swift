import Foundation

enum ProviderInputText {
  static func unsupportedContent(_ protocolID: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .unsupportedCapability,
      message: "\(protocolID) does not support unrecognized user content",
      providerID: nil,
      operation: "\(protocolID).request.content",
      causeDescription: nil)
  }

  static func sanitizeUTF16(_ units: [UInt16]) -> String {
    var result: [UInt16] = []
    var index = 0
    while index < units.count {
      let unit = units[index]
      if (0xD800...0xDBFF).contains(unit) {
        if index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) {
          result.append(unit)
          result.append(units[index + 1])
          index += 2
          continue
        }
      } else if !(0xDC00...0xDFFF).contains(unit) {
        result.append(unit)
      }
      index += 1
    }
    return String(decoding: result, as: UTF16.self)
  }
}
