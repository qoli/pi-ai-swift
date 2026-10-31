enum ProviderToolDeclarationMode: String {
  case none, additions, changes

  static func resolve(protocolID: String, compatibility: [String: JSONValue]) -> Self {
    if protocolID == "openai-completions" {
      return compatibility.bool("supportsMidConvoSystemMessages") == true
        && compatibility.bool("supportsMidConvoToolAdditions") == true ? .additions : .none
    }
    if compatibility.bool("supportsMidConvoSystemMessages") == true
      && compatibility.bool("supportsAdditionalTools") == true
    {
      return .changes
    }
    return compatibility.bool("supportsToolSearch") == true ? .additions : .none
  }
}
