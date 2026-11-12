import Foundation

extension WireProtocolContext {
  var openAIInstructionRole: String {
    if let supported = modelConfiguration.metadata.object("compat")?.bool("supportsDeveloperRole") {
      return supported ? "developer" : "system"
    }

    // OpenAI documents this role for its native Responses endpoint.
    let documentedEndpoint =
      model.protocolID == "openai-responses"
      && baseURL.appending(path: "responses").absoluteString
        == "https://api.openai.com/v1/responses"
    return documentedEndpoint ? "developer" : "system"
  }
}
