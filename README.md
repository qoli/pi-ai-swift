# pi-ai-swift

`pi-ai-swift` is a native Swift semantic port of the provider runtime in
[`earendil-works/pi`](https://github.com/earendil-works/pi), scoped for Apple
platform applications.

The package owns provider catalogs, authentication state machines, credential
refresh, provider wire formats, and normalized generation events. It does not
own an agent loop, tool execution, UI, browser automation, document operations,
or a shell runtime.

## Status

The repository contains the public provider-runtime contract, the complete
pinned built-in catalog, native wire adapters, URLSession raw streaming,
API-key and device-code OAuth slices, serialized token refresh, and an optional
Apple Keychain credential store. The `pi-ai-auth-probe` executable verifies
login without printing access or refresh tokens. Live provider evidence is
tracked separately from deterministic compatibility evidence; unsupported
providers and unavailable capabilities fail explicitly, and the runtime never
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

`Upstream.lock.json` pins the exact pi revision and complete built-in provider
inventory. `UpstreamMappings/pi-ai.json` records every foundation,
authorization, wire-protocol, and provider area with a truthful implementation
status. It is the durable maintenance IR between discovery and implementation;
tracking a provider does not claim it is already supported. Maintenance is
human-initiated and may be irregular: an inventory task records a new provider
as `missing`, while a later implementation task supplies the Swift vertical
slice and executable evidence. No scheduler or unattended watcher is required.
Run:

```bash
./Scripts/check-upstream.sh
swift test
```

The upstream TypeScript implementation is an oracle, not a shipping runtime.
Synchronization must compare structured requests, raw stream fixtures,
normalized events, authentication transitions, and explicit errors. See
the [design registry](Docs/README.md),
[`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md), and
[`Docs/AI_MAINTENANCE.md`](Docs/AI_MAINTENANCE.md).
