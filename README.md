# pi-ai-swift

`pi-ai-swift` is a native Swift semantic port of the provider runtime in
[`earendil-works/pi`](https://github.com/earendil-works/pi), scoped for Apple
platform applications.

The package owns provider catalogs, authentication state machines, credential
refresh, provider wire formats, and normalized generation events. It does not
own an agent loop, tool execution, UI, browser automation, document operations,
or a shell runtime.

## Status

The repository currently contains the public provider-runtime contract,
upstream provenance lock, synchronization checks, contract tests, and the first
live authorization slice: OpenAI Codex device-code OAuth. The
`pi-ai-auth-probe` executable verifies login without persisting or printing
access and refresh tokens. Production persistence remains a host-app Keychain
responsibility. No live generation provider is claimed yet. Unsupported
providers and unavailable capabilities must fail explicitly; the runtime never
switches providers or protocols automatically.

## Interface

The public seam intentionally has three operations:

```swift
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
```

Consumers adapt this interface to their conversation framework. The package
does not depend on `AnyLanguageModel` or `AIReasoningCore`.

## Upstream synchronization

`Upstream.lock.json` pins the exact pi revision and allowlisted provider paths.
Run:

```bash
./Scripts/check-upstream.sh
swift test
```

The upstream TypeScript implementation is an oracle, not a shipping runtime.
Synchronization must compare structured requests, raw stream fixtures,
normalized events, authentication transitions, and explicit errors. See
[`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md).
