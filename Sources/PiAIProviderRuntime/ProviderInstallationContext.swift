import Foundation

public struct ProviderInstallationContext: Sendable {
  let deviceID: String?

  public static func persistent(at directory: URL) throws -> ProviderInstallationContext {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("ProviderInstallationID")
    if FileManager.default.fileExists(atPath: url.path) {
      return ProviderInstallationContext(deviceID: try String(contentsOf: url, encoding: .utf8))
    }
    let id = UUID().uuidString
    try id.write(to: url, atomically: true, encoding: .utf8)
    return ProviderInstallationContext(deviceID: id)
  }
}
