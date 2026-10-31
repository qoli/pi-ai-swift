import Foundation

func applyGitHubCopilotHeaders(
  providerID: String,
  messages: [ProviderMessage],
  to request: inout URLRequest
) {
  guard providerID == GitHubCopilotOAuthAuthorizationAdapter.providerID else {
    return
  }
  let initiator: String
  switch messages.last {
  case nil, .user?, .userMessage?:
    initiator = "user"
  default:
    initiator = "agent"
  }
  request.setValue(initiator, forHTTPHeaderField: "X-Initiator")
  request.setValue("conversation-edits", forHTTPHeaderField: "Openai-Intent")
  if messages.contains(where: containsImage) {
    request.setValue("true", forHTTPHeaderField: "Copilot-Vision-Request")
  }
}

private func containsImage(_ message: ProviderMessage) -> Bool {
  switch message {
  case .user(let content):
    return content.contains { item in
      if case .image = item { return true }
      return false
    }
  case .userMessage(let user):
    return user.content.contains { item in
      if case .image = item { return true }
      return false
    }
  case .toolResult(let result):
    return result.content.contains { item in
      if case .image = item { return true }
      return false
    }
  case .system, .systemMessage, .assistant, .assistantMessage:
    return false
  }
}
