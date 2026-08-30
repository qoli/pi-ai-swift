import Foundation

struct AWSEventStreamMessage: Sendable, Equatable {
  let headers: [String: String]
  let payload: Data
}

struct AWSEventStreamDecoder: Sendable {
  private static let minimumMessageLength = 16
  private static let maximumMessageLength = 32 * 1_024 * 1_024

  private var buffer = Data()

  mutating func append(_ data: Data) throws -> [AWSEventStreamMessage] {
    buffer.append(data)
    var messages: [AWSEventStreamMessage] = []
    while buffer.count >= Self.minimumMessageLength {
      let bytes = [UInt8](buffer)
      let totalLength = Int(Self.uint32(bytes, at: 0))
      guard
        totalLength >= Self.minimumMessageLength,
        totalLength <= Self.maximumMessageLength
      else {
        throw Self.invalid("AWS event-stream message length is invalid")
      }
      guard buffer.count >= totalLength else { break }
      let frame = Data(buffer.prefix(totalLength))
      messages.append(try Self.decode(frame))
      buffer.removeFirst(totalLength)
    }
    return messages
  }

  mutating func finish() throws -> [AWSEventStreamMessage] {
    guard buffer.isEmpty else {
      throw Self.invalid("AWS event-stream ended with a truncated message")
    }
    return []
  }

  static func encode(
    headers: [String: String],
    payload: Data
  ) throws -> Data {
    var encodedHeaders = Data()
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      let nameBytes = Data(name.utf8)
      let valueBytes = Data(value.utf8)
      guard nameBytes.count <= Int(UInt8.max), valueBytes.count <= Int(UInt16.max) else {
        throw invalid("AWS event-stream header is too large")
      }
      encodedHeaders.append(UInt8(nameBytes.count))
      encodedHeaders.append(nameBytes)
      encodedHeaders.append(7)  // AWS event-stream string header.
      appendUInt16(UInt16(valueBytes.count), to: &encodedHeaders)
      encodedHeaders.append(valueBytes)
    }

    let totalLength = 16 + encodedHeaders.count + payload.count
    guard totalLength <= maximumMessageLength else {
      throw invalid("AWS event-stream message is too large")
    }
    var frame = Data()
    appendUInt32(UInt32(totalLength), to: &frame)
    appendUInt32(UInt32(encodedHeaders.count), to: &frame)
    appendUInt32(CRC32.checksum(frame), to: &frame)
    frame.append(encodedHeaders)
    frame.append(payload)
    appendUInt32(CRC32.checksum(frame), to: &frame)
    return frame
  }

  private static func decode(_ frame: Data) throws -> AWSEventStreamMessage {
    let bytes = [UInt8](frame)
    let totalLength = Int(uint32(bytes, at: 0))
    let headersLength = Int(uint32(bytes, at: 4))
    guard totalLength == bytes.count, headersLength <= totalLength - minimumMessageLength else {
      throw invalid("AWS event-stream prelude contains invalid lengths")
    }
    let expectedPreludeCRC = uint32(bytes, at: 8)
    guard CRC32.checksum(Data(bytes[0..<8])) == expectedPreludeCRC else {
      throw invalid("AWS event-stream prelude CRC does not match")
    }
    let expectedMessageCRC = uint32(bytes, at: totalLength - 4)
    guard CRC32.checksum(Data(bytes[0..<(totalLength - 4)])) == expectedMessageCRC else {
      throw invalid("AWS event-stream message CRC does not match")
    }

    let headerEnd = 12 + headersLength
    var index = 12
    var headers: [String: String] = [:]
    while index < headerEnd {
      let nameLength = Int(bytes[index])
      index += 1
      guard index + nameLength + 1 <= headerEnd else {
        throw invalid("AWS event-stream header name is truncated")
      }
      guard let name = String(bytes: bytes[index..<(index + nameLength)], encoding: .utf8) else {
        throw invalid("AWS event-stream header name is not UTF-8")
      }
      index += nameLength
      let type = bytes[index]
      index += 1
      switch type {
      case 0:
        headers[name] = "true"
      case 1:
        headers[name] = "false"
      case 2:
        guard index + 1 <= headerEnd else { throw invalid("AWS byte header is truncated") }
        index += 1
      case 3:
        guard index + 2 <= headerEnd else { throw invalid("AWS short header is truncated") }
        index += 2
      case 4:
        guard index + 4 <= headerEnd else { throw invalid("AWS integer header is truncated") }
        index += 4
      case 5, 8:
        guard index + 8 <= headerEnd else { throw invalid("AWS long header is truncated") }
        index += 8
      case 6, 7:
        guard index + 2 <= headerEnd else { throw invalid("AWS variable header is truncated") }
        let length = Int(uint16(bytes, at: index))
        index += 2
        guard index + length <= headerEnd else {
          throw invalid("AWS variable header value is truncated")
        }
        if type == 7 {
          guard let value = String(bytes: bytes[index..<(index + length)], encoding: .utf8) else {
            throw invalid("AWS string header is not UTF-8")
          }
          headers[name] = value
        }
        index += length
      case 9:
        guard index + 16 <= headerEnd else { throw invalid("AWS UUID header is truncated") }
        index += 16
      default:
        throw invalid("AWS event-stream header has unsupported type: \(type)")
      }
    }

    return AWSEventStreamMessage(
      headers: headers,
      payload: Data(bytes[headerEnd..<(totalLength - 4)])
    )
  }

  private static func uint16(_ bytes: [UInt8], at index: Int) -> UInt16 {
    (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
  }

  private static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
    (UInt32(bytes[index]) << 24) | (UInt32(bytes[index + 1]) << 16)
      | (UInt32(bytes[index + 2]) << 8) | UInt32(bytes[index + 3])
  }

  private static func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
  }

  private static func invalid(_ message: String) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: .invalidResponse,
      message: message,
      providerID: "amazon-bedrock",
      operation: "bedrock.event-stream.decode",
      causeDescription: nil
    )
  }
}

private enum CRC32 {
  static func checksum(_ data: Data) -> UInt32 {
    var value = UInt32.max
    for byte in data {
      value ^= UInt32(byte)
      for _ in 0..<8 {
        value =
          (value & 1) == 1
          ? (value >> 1) ^ 0xedb8_8320
          : value >> 1
      }
    }
    return value ^ UInt32.max
  }
}
