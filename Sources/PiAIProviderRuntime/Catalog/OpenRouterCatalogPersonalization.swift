import Foundation

extension CustomProvider {
  public func personalizingOpenRouterCatalog(
    credential: ProviderCredential?,
    transport: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
  ) async throws -> CustomProvider {
    let catalog = models.map { model in
      var raw = model.metadata
      raw["id"] = .string(model.id)
      if let value = model.contextWindow { raw["contextWindow"] = .integer(Int64(value)) }
      if let value = model.maximumOutputTokens { raw["maxTokens"] = .integer(Int64(value)) }
      if model.capabilities.classification {
        raw["type"] = .string("classifier")
      } else if model.capabilities.imageGeneration {
        raw["type"] = .string("image")
      }
      return JSONValue.object(raw)
    }
    let result = try await OpenRouterCatalogPersonalization.apply(
      catalog, baseURL: baseURL?.absoluteString, credential: credential, transport: transport)
    guard result.personalized else { return self }
    let models = zip(result.sourceIndices, result.catalog).map { index, value in
      let original = self.models[index]
      guard result.updatedIndices.contains(index), let raw = value.objectValue else {
        return original
      }
      return CustomProviderModel(
        id: original.id, name: original.name, api: original.api, baseURL: original.baseURL,
        headers: original.headers, capabilities: original.capabilities,
        contextWindow: raw.int("contextWindow"), maximumOutputTokens: raw.int("maxTokens"),
        metadata: raw)
    }
    return CustomProvider(
      id: id, name: name, baseURL: baseURL, api: api, headers: headers, models: models)
  }
}

enum OpenRouterCatalogPersonalization {
  struct Result: Sendable {
    let catalog: [JSONValue]
    let sourceIndices: [Int]
    let updatedIndices: Set<Int>
    let personalized: Bool
  }

  static func apply(
    _ catalog: [JSONValue], baseURL: String?, credential: ProviderCredential?,
    transport: any ProviderHTTPTransport
  ) async throws -> Result {
    func unchanged() -> Result {
      .init(
        catalog: catalog, sourceIndices: Array(catalog.indices), updatedIndices: [],
        personalized: false)
    }
    let key: String?
    switch credential {
    case .apiKey(let value): key = value.configuredKey
    case .oauth(let value): key = value.accessToken
    case nil: key = nil
    }
    guard let key, !key.isEmpty else { return unchanged() }
    let base = (baseURL ?? "https://openrouter.ai/api/v1").replacingOccurrences(
      of: #"/+$"#, with: "", options: .regularExpression)
    guard let url = URL(string: base + "/models/user") else {
      throw failure(.invalidRequest, "Invalid OpenRouter model list URL")
    }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue("Bearer " + key, forHTTPHeaderField: "authorization")
    let response = try await transport.send(request)
    if [401, 403, 404].contains(response.statusCode) { return unchanged() }
    guard (200..<300).contains(response.statusCode) else {
      throw failure(
        .invalidResponse, "OpenRouter model list request failed: \(response.statusCode)")
    }
    let body = try JSONValue(jsonData: response.body)
    guard let entries = body.objectValue?.array("data") else {
      throw failure(.invalidResponse, "Invalid OpenRouter model list response")
    }
    var allowed: [String: [String: JSONValue]] = [:]
    for entry in entries {
      if let raw = entry.objectValue, let id = raw.string("id") { allowed[id] = raw }
    }
    var values: [JSONValue] = []
    var indices: [Int] = []
    var updated: Set<Int> = []
    for (index, model) in catalog.enumerated() {
      let type = model.objectValue?["type"]
      if type != nil && type != .null && type != .string("chat") {
        values.append(model)
        indices.append(index)
        continue
      }
      guard var raw = model.objectValue, let id = raw.string("id"), let entry = allowed[id] else {
        continue
      }
      func nonzero(_ value: JSONValue?) -> JSONValue? {
        guard let value, ProviderOrderedJSON(value).isTruthy else { return nil }
        return value
      }
      raw["contextWindow"] =
        nonzero(entry.object("top_provider")?["context_length"])
        ?? nonzero(entry["context_length"]) ?? raw["contextWindow"]
      raw["maxTokens"] =
        nonzero(entry.object("top_provider")?["max_completion_tokens"]) ?? raw["maxTokens"]
      if let pricing = entry["pricing"], ProviderOrderedJSON(pricing).isTruthy {
        raw["cost"] = cost(pricing.objectValue ?? [:])
      }
      values.append(.object(raw))
      indices.append(index)
      updated.insert(index)
    }
    return .init(
      catalog: values, sourceIndices: indices, updatedIndices: updated, personalized: true)
  }

  static func cost(_ pricing: [String: JSONValue]) -> JSONValue {
    func perMillion(_ value: JSONValue?, fallback: JSONValue) -> JSONValue {
      guard let parsed = ProviderRequestRetry.parseFloat(value?.stringValue ?? ""), parsed >= 0
      else { return fallback }
      let scaled = parsed * 1_000_000
      // toFixed chooses the larger integer at an exact halfway point; printf uses ties-to-even.
      let significand = scaled.significandBitPattern | (UInt64(1) << 52)
      let halfway = scaled > 0 && significand.trailingZeroBitCount + 6 == 51 - scaled.exponent
      let value = Double(String(format: "%.6f", halfway ? scaled.nextUp : scaled))!
      return Int64(exactly: value).map(JSONValue.integer) ?? .number(value)
    }
    let names = [
      ("input", "prompt"), ("output", "completion"),
      ("cacheRead", "input_cache_read"), ("cacheWrite", "input_cache_write"),
    ]
    var base = Dictionary(
      uniqueKeysWithValues: names.map { ($0.0, perMillion(pricing[$0.1], fallback: .integer(0))) })
    let tiers = (pricing.array("overrides") ?? []).compactMap { item -> JSONValue? in
      guard let raw = item.objectValue, raw["min_prompt_tokens"] != nil,
        raw["utc_start"] == nil, raw["utc_end"] == nil, raw["utc_days"] == nil
      else { return nil }
      var tier = Dictionary(
        uniqueKeysWithValues: names.map { ($0.0, perMillion(raw[$0.1], fallback: base[$0.0]!)) })
      tier["inputTokensAbove"] = raw["min_prompt_tokens"]
      return .object(tier)
    }
    if !tiers.isEmpty { base["tiers"] = .array(tiers) }
    return .object(base)
  }

  private static func failure(_ code: ProviderRuntimeFailure.Code, _ message: String)
    -> ProviderRuntimeFailure
  {
    .init(
      code: code, message: message, providerID: "openrouter",
      operation: "catalog.openrouter.personalize", causeDescription: nil)
  }
}
