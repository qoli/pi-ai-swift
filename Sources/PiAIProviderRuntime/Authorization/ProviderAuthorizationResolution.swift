import Foundation

struct ProviderResolvedAuthorization<Value: Sendable>: Sendable {
  let authorization: Value
  let source: String
  let environment: [String: String]?
}

struct ProviderAuthorizationBindings<Value: Sendable>: Sendable {
  typealias Primary =
    @Sendable (APIKeyCredential?, ProviderAuthenticationContext) async throws ->
    ProviderResolvedAuthorization<Value>?
  struct OAuth: Sendable {
    let refresh: CredentialRefreshCoordinator.RefreshOperation
    let derive: @Sendable (OAuthCredential) async throws -> Value
    var now: @Sendable () -> Date = { Date() }
  }
  let primary: Primary?
  let oauth: OAuth?
}

typealias ProviderAuthorizationOverrides = ProviderRequestAuthenticationOverrides

struct ProviderAuthorizationResolutionFailure: LocalizedError {
  enum Kind: String, Sendable { case auth, oauth }
  let kind: Kind
  let providerID: String
  let message: String
  let cause: (any Error)?

  init(_ kind: Kind, providerID: String, message: String, cause: (any Error)? = nil) {
    self.kind = kind
    self.providerID = providerID
    self.cause = cause
    let detail = cause?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.message = detail.isEmpty || message.contains(detail) ? message : message + ": " + detail
  }
  var errorDescription: String? { message }
  var runtimeFailure: ProviderRuntimeFailure {
    .init(
      code: .authorizationFailed, message: message, providerID: providerID,
      operation: "authorization.resolve." + kind.rawValue,
      causeDescription: cause?.localizedDescription)
  }
}

enum ProviderAuthorizationResolution {
  static func refreshStored(
    providerID: String, coordinator: CredentialRefreshCoordinator,
    needsRefresh: @escaping @Sendable (OAuthCredential) async throws -> Bool,
    refresh: @escaping CredentialRefreshCoordinator.RefreshOperation
  ) async throws -> OAuthCredential? {
    do {
      return try await coordinator.refreshStored(
        providerID: providerID, needsRefresh: needsRefresh,
        refresh: { current in
          do { return try await refresh(current) } catch {
            throw ProviderAuthorizationResolutionFailure(
              .oauth, providerID: providerID,
              message: "OAuth refresh failed for \(providerID)", cause: error)
          }
        })
    } catch let error as ProviderAuthorizationResolutionFailure { throw error } catch {
      if Task.isCancelled { throw CancellationError() }
      throw ProviderAuthorizationResolutionFailure(
        .auth, providerID: providerID,
        message: "Credential store modify failed for \(providerID)", cause: error)
    }
  }

  static func resolve<Value: Sendable>(
    providerID: String, store: any ProviderCredentialStore,
    context: ProviderAuthenticationContext, bindings: ProviderAuthorizationBindings<Value>,
    coordinator: CredentialRefreshCoordinator,
    overrides: ProviderAuthorizationOverrides = .init()
  ) async throws -> ProviderResolvedAuthorization<Value>? {
    try await ProviderCancellableOperation.run {
      let scoped =
        overrides.environment.map { environment in
          ProviderAuthenticationContext(
            environment: { name in
              if let value = environment[name], !value.isEmpty { return value }
              return try await context.environment(name)
            }, fileExists: context.fileExists)
        } ?? context
      if let key = overrides.apiKey, let primary = bindings.primary {
        return try await resolvePrimary(
          primary, providerID: providerID, context: scoped,
          credential: .init(key: key, metadata: [:], environment: overrides.environment))
      }
      let stored: ProviderCredential?
      do { stored = try await store.read(providerID: providerID) } catch {
        if Task.isCancelled { throw CancellationError() }
        throw ProviderAuthorizationResolutionFailure(
          .auth, providerID: providerID,
          message: "Credential store read failed for \(providerID)", cause: error)
      }
      switch stored {
      case .oauth(let credential):
        guard let oauth = bindings.oauth else { return nil }
        let resolved: OAuthCredential?
        do {
          resolved = try await coordinator.credential(
            providerID: providerID,
            optimisticCredential: credential,
            minimumValidity: overrides.minimumOAuthValidityMilliseconds.map { $0 / 1_000 },
            now: oauth.now,
            refresh: { current in
              do { return try await oauth.refresh(current) } catch {
                throw ProviderAuthorizationResolutionFailure(
                  .oauth, providerID: providerID,
                  message: "OAuth refresh failed for \(providerID)", cause: error)
              }
            })
        } catch let error as ProviderAuthorizationResolutionFailure { throw error } catch {
          if Task.isCancelled { throw CancellationError() }
          if let failure = error as? ProviderRuntimeFailure,
            failure.operation == "credential.refresh.validity"
          {
            throw ProviderAuthorizationResolutionFailure(
              .oauth, providerID: providerID,
              message: failure.message)
          }
          throw ProviderAuthorizationResolutionFailure(
            .auth, providerID: providerID,
            message: "Credential store modify failed for \(providerID)", cause: error)
        }
        guard let resolved else { return nil }
        do {
          return .init(
            authorization: try await oauth.derive(resolved), source: "OAuth", environment: nil)
        } catch {
          if Task.isCancelled { throw CancellationError() }
          throw ProviderAuthorizationResolutionFailure(
            .oauth, providerID: providerID,
            message: "OAuth auth derivation failed for \(providerID)", cause: error)
        }
      case .apiKey(let credential):
        guard let primary = bindings.primary else { return nil }
        let merged: APIKeyCredential
        if let environment = overrides.environment {
          let values = (credential.environment ?? [:]).merging(environment) { _, explicit in
            explicit
          }
          if let key = credential.configuredKey {
            merged = .init(key: key, metadata: credential.metadata, environment: values)
          } else {
            merged = .init(environment: values, metadata: credential.metadata)
          }
        } else {
          merged = credential
        }
        return try await resolvePrimary(
          primary, providerID: providerID, context: scoped, credential: merged)
      case .none:
        guard let primary = bindings.primary else { return nil }
        return try await resolvePrimary(
          primary, providerID: providerID, context: scoped, credential: nil)
      }
    }
  }

  static func check<Value: Sendable>(
    providerID: String, store: any ProviderCredentialStore, context: ProviderAuthenticationContext,
    bindings: ProviderAuthorizationBindings<Value>
  ) async throws -> (source: String, credential: ProviderCredential?)? {
    try await ProviderCancellableOperation.run {
      let stored = try await store.read(providerID: providerID)
      if case .oauth = stored { return bindings.oauth == nil ? nil : ("OAuth", stored) }
      guard let primary = bindings.primary else { return nil }
      let key: APIKeyCredential?
      if case .apiKey(let value) = stored { key = value } else { key = nil }
      guard
        let result = try await resolvePrimary(
          primary, providerID: providerID, context: context, credential: key)
      else { return nil }
      return (result.source, stored)
    }
  }

  private static func resolvePrimary<Value: Sendable>(
    _ primary: ProviderAuthorizationBindings<Value>.Primary, providerID: String,
    context: ProviderAuthenticationContext, credential: APIKeyCredential?
  ) async throws -> ProviderResolvedAuthorization<Value>? {
    do { return try await primary(credential, context) } catch {
      if Task.isCancelled { throw CancellationError() }
      throw ProviderAuthorizationResolutionFailure(
        .auth, providerID: providerID,
        message: "API key auth failed for provider \(providerID)", cause: error)
    }
  }
}
