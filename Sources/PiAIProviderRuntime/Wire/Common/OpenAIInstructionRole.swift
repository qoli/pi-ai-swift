extension WireProtocolContext {
  var openAIInstructionRole: String {
    guard model.capabilities.reasoning else { return "system" }
    let declared = modelConfiguration.metadata.object("compat")?.bool("supportsDeveloperRole")
    let supportedByDefault =
      model.protocolID != "openai-completions" || model.providerID == "openai"
      || baseURL.absoluteString.contains("api.openai.com")
    return (declared ?? supportedByDefault) ? "developer" : "system"
  }
}
