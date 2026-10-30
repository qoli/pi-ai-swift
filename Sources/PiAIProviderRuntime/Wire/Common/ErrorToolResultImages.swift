import Foundation

struct ErrorToolResultImages {
  let content: [ProviderToolResultContent]
  let caption: String
  let images: [ProviderImage]

  init?(_ result: ProviderToolResult) {
    guard result.isError else { return nil }
    let images = result.content.compactMap { block -> ProviderImage? in
      guard case .image(let image) = block else { return nil }
      return image
    }
    guard !images.isEmpty else { return nil }
    let placeholder = "(image attached after the tool results)"
    var content: [ProviderToolResultContent] = []
    var previousWasPlaceholder = false
    for block in result.content {
      switch block {
      case .image:
        if !previousWasPlaceholder { content.append(.text(placeholder)) }
        previousWasPlaceholder = true
      case .text(let text):
        content.append(block)
        previousWasPlaceholder = text == placeholder
      }
    }
    self.content = content
    self.caption =
      "Images from the error result of tool call \(result.toolCallID) (\(result.toolName)):"
    self.images = images
  }
}
