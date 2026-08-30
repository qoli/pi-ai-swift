public protocol ProviderRuntime: Sendable {
  func catalog() async throws -> ProviderCatalog

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction
  ) async throws -> AuthorizationState

  func stream(
    _ request: ProviderRequest
  ) -> AsyncThrowingStream<ProviderEvent, any Error>
}
