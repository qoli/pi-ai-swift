import Foundation
internal import libzstd

enum CodexRequestCompression {
  static func compress(_ data: Data) throws -> Data {
    var output = Data(count: ZSTD_compressBound(data.count))
    let size = output.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        ZSTD_compress(
          destination.baseAddress, destination.count, source.baseAddress, source.count, 3)
      }
    }
    guard ZSTD_isError(size) == 0 else {
      throw ProviderRuntimeFailure(
        code: .transportFailed,
        message: "Codex request compression failed: " + String(cString: ZSTD_getErrorName(size)),
        providerID: "openai-codex", operation: "codex.request.compress", causeDescription: nil)
    }
    output.removeSubrange(size..<output.count)
    return output
  }
}
