import Foundation

enum ProviderEndpointTemplate {
  static func cloudflare(_ template: String, environment: [String: String]?) -> String {
    guard let environment else { return template }
    var result = template
    for key in ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_GATEWAY_ID"] {
      if let value = environment[key] {
        result = result.replacingOccurrences(of: "{\(key)}", with: value)
      }
    }
    return result
  }

  static func materialize(_ template: String, metadata: [String: String]) -> String {
    var value = template
    for (key, replacement) in metadata {
      for name in [key, key.uppercased(), key.lowercased()] {
        value = value.replacingOccurrences(of: "{\(name)}", with: replacement)
      }
    }
    return value
  }
}
