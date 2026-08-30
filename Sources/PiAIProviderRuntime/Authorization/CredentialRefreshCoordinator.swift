import Foundation

actor CredentialRefreshCoordinator {
  typealias RefreshOperation =
    @Sendable (OAuthCredential) async throws -> OAuthCredential

  private struct Flight: Sendable {
    let id: UUID
    let task: Task<OAuthCredential, any Error>
  }

  private let credentialStore: any ProviderCredentialStore
  private var generations: [String: UInt64] = [:]
  private var flights: [String: Flight] = [:]

  init(credentialStore: any ProviderCredentialStore) {
    self.credentialStore = credentialStore
  }

  func credential(
    providerID: String,
    minimumValidity: TimeInterval = 60,
    now: Date = Date(),
    refresh: @escaping RefreshOperation
  ) async throws -> OAuthCredential {
    guard !providerID.isEmpty, minimumValidity >= 0 else {
      throw failure(
        .invalidRequest,
        providerID: providerID,
        operation: "credential.refresh.configure",
        message: "Credential refresh parameters are invalid"
      )
    }
    if let flight = flights[providerID] {
      let result = try await flight.task.value
      try Task.checkCancellation()
      return result
    }

    let generation = generations[providerID, default: 0]
    let flightID = UUID()
    let task = Task<OAuthCredential, any Error> { [weak self] in
      do {
        guard let self else { throw CancellationError() }
        guard
          let stored = try await self.credentialStore.read(
            providerID: providerID
          )
        else {
          throw Self.failure(
            .missingCredential,
            providerID: providerID,
            operation: "credential.refresh.read",
            message: "OAuth credential is missing"
          )
        }
        guard case .oauth(let credential) = stored else {
          throw Self.failure(
            .invalidCredential,
            providerID: providerID,
            operation: "credential.refresh.read",
            message: "Credential is not OAuth"
          )
        }
        guard credential.expiresAt.timeIntervalSince(now) <= minimumValidity
        else {
          await self.clearFlight(providerID: providerID, flightID: flightID)
          return credential
        }

        let refreshed: OAuthCredential
        do {
          refreshed = try await refresh(credential)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw Self.failure(
            .authorizationFailed,
            providerID: providerID,
            operation: "credential.refresh",
            message: "OAuth credential refresh failed"
          )
        }
        guard !refreshed.accessToken.isEmpty, !refreshed.refreshToken.isEmpty,
          refreshed.expiresAt > now
        else {
          throw Self.failure(
            .invalidCredential,
            providerID: providerID,
            operation: "credential.refresh.validate",
            message: "OAuth refresh returned an invalid credential"
          )
        }
        return try await self.commit(
          refreshed,
          replacing: credential,
          providerID: providerID,
          generation: generation,
          flightID: flightID
        )
      } catch is CancellationError {
        await self?.clearFlight(providerID: providerID, flightID: flightID)
        throw CancellationError()
      } catch {
        await self?.clearFlight(providerID: providerID, flightID: flightID)
        throw Self.failure(
          .authorizationFailed,
          providerID: providerID,
          operation: "credential.refresh",
          message: "OAuth credential refresh failed"
        )
      }
    }
    flights[providerID] = Flight(id: flightID, task: task)
    let result = try await task.value
    try Task.checkCancellation()
    return result
  }

  func logout(providerID: String) async throws {
    guard !providerID.isEmpty else {
      throw failure(
        .invalidRequest,
        providerID: providerID,
        operation: "credential.logout",
        message: "Credential provider identifier is empty"
      )
    }
    generations[providerID, default: 0] &+= 1
    if let flight = flights.removeValue(forKey: providerID) {
      flight.task.cancel()
    }
    try await credentialStore.delete(providerID: providerID)
  }

  private func commit(
    _ refreshed: OAuthCredential,
    replacing source: OAuthCredential,
    providerID: String,
    generation: UInt64,
    flightID: UUID
  ) async throws -> OAuthCredential {
    try Task.checkCancellation()
    guard generations[providerID, default: 0] == generation,
      flights[providerID]?.id == flightID
    else {
      throw raceFailure(providerID: providerID)
    }

    let updated = try await credentialStore.modify(providerID: providerID) {
      current in
      guard current == .oauth(source) else {
        throw Self.failure(
          .authorizationFailed,
          providerID: providerID,
          operation: "credential.refresh.commit",
          message: "OAuth credential changed while refresh was running"
        )
      }
      return .oauth(refreshed)
    }

    guard generations[providerID, default: 0] == generation,
      flights[providerID]?.id == flightID
    else {
      try await credentialStore.delete(providerID: providerID)
      throw raceFailure(providerID: providerID)
    }
    flights[providerID] = nil
    guard updated == .oauth(refreshed) else {
      throw raceFailure(providerID: providerID)
    }
    return refreshed
  }

  private func clearFlight(providerID: String, flightID: UUID) {
    if flights[providerID]?.id == flightID {
      flights[providerID] = nil
    }
  }

  private func raceFailure(providerID: String) -> ProviderRuntimeFailure {
    Self.failure(
      .authorizationFailed,
      providerID: providerID,
      operation: "credential.refresh.commit",
      message: "OAuth credential changed while refresh was running"
    )
  }

  private func failure(
    _ code: ProviderRuntimeFailure.Code,
    providerID: String?,
    operation: String,
    message: String
  ) -> ProviderRuntimeFailure {
    Self.failure(
      code,
      providerID: providerID,
      operation: operation,
      message: message
    )
  }

  private static func failure(
    _ code: ProviderRuntimeFailure.Code,
    providerID: String?,
    operation: String,
    message: String
  ) -> ProviderRuntimeFailure {
    ProviderRuntimeFailure(
      code: code,
      message: message,
      providerID: providerID,
      operation: operation,
      causeDescription: nil
    )
  }
}
