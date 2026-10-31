import Foundation
import libzstd

@testable import PiAIProviderRuntime

func fixtureHTTPBody(_ request: URLRequest?) throws -> Data {
  guard let request, let body = request.httpBody else {
    throw ProviderRuntimeFailure(
      code: .invalidResponse, message: "No captured fixture request body",
      providerID: "fixture", operation: "fixture.request-body", causeDescription: nil)
  }
  guard request.value(forHTTPHeaderField: "Content-Encoding") == "zstd" else { return body }
  let size = body.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, $0.count) }
  guard size != ZSTD_CONTENTSIZE_ERROR, size != ZSTD_CONTENTSIZE_UNKNOWN,
    let count = Int(exactly: size)
  else {
    throw ProviderRuntimeFailure(
      code: .invalidResponse, message: "Invalid fixture zstd frame size",
      providerID: "fixture", operation: "fixture.request-body", causeDescription: nil)
  }
  var result = Data(count: count)
  let decoded = result.withUnsafeMutableBytes { output in
    body.withUnsafeBytes { input in
      ZSTD_decompress(output.baseAddress, output.count, input.baseAddress, input.count)
    }
  }
  guard ZSTD_isError(decoded) == 0 else {
    throw ProviderRuntimeFailure(
      code: .invalidResponse, message: String(cString: ZSTD_getErrorName(decoded)),
      providerID: "fixture", operation: "fixture.request-body", causeDescription: nil)
  }
  result.removeSubrange(decoded..<result.count)
  return result
}
