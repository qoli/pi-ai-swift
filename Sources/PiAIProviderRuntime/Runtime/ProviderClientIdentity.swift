import Foundation

struct ProviderIdentityHost: Sendable, Equatable, Codable {
  var platform: String? = nil
  var arch: String? = nil
  var node: String? = nil
  var bun: String? = nil
  var version: String? = nil
}

enum ProviderClientIdentity {
  static let upstreamVersion = "1.4.0"

  static func userAgent(_ identity: [String: JSONValue]?, host: ProviderIdentityHost) -> String {
    if let custom = identity?.object("userAgent")?.string("custom") { return custom }
    if identity?.string("userAgent") == "short" { return "pi" }
    let product = "pi/\(identity?.string("version") ?? upstreamVersion)"
    let runtime: String?
    if let bun = host.bun, !bun.isEmpty {
      runtime = "bun/\(bun)"
    } else if let node = host.node, !node.isEmpty {
      runtime = "node/\(host.version ?? "undefined")"
    } else {
      runtime = nil
    }
    guard let runtime else { return "\(product) (browser)" }
    return "\(product) (\(host.platform ?? "undefined"); \(runtime); \(host.arch ?? "undefined"))"
  }

  static func attributionHeaders(
    providerID: String, baseURL: String, identity: [String: JSONValue]?
  ) -> [String: String] {
    guard let attribution = identity?.object("attribution"), let name = attribution.string("name"),
      let url = attribution.string("url")
    else { return [:] }
    if providerID == "openrouter" || baseURL.contains("openrouter.ai") {
      var headers = ["HTTP-Referer": url, "X-OpenRouter-Title": name]
      if let categories = attribution.array("categories"), !categories.isEmpty {
        headers["X-OpenRouter-Categories"] = categories.compactMap(\.stringValue).joined(
          separator: ",")
      }
      return headers
    }
    let host = URL(string: baseURL)?.host?.lowercased()
    if providerID == "nvidia" || host == "integrate.api.nvidia.com" {
      return ["X-BILLING-INVOKE-ORIGIN": String(name.prefix(1)).uppercased() + name.dropFirst()]
    }
    if ["opencode", "opencode-go"].contains(providerID) || host == "opencode.ai" {
      return ["x-opencode-client": name]
    }
    return [:]
  }

  static func headers(
    providerID: String, baseURL: String, identity: [String: JSONValue]?,
    host: ProviderIdentityHost = .init()
  ) -> [String: String] {
    var headers = attributionHeaders(providerID: providerID, baseURL: baseURL, identity: identity)
    headers["User-Agent"] = userAgent(identity, host: host)
    return headers
  }
}
