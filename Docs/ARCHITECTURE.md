# Architecture

## Current status

**Partially landed.** The public seam, normalized DTOs, explicit failure model,
injected HTTP transport, and OpenAI Codex device authorization exist. Live
generation adapters, credential refresh persistence, and full differential
fixtures are not yet landed.

## Purpose

`PiAIProviderRuntime` is a provider compatibility kernel. Its public interface
hides catalog selection, authentication, request transformation, wire protocol,
stream parsing, and usage normalization behind three operations: `catalog`,
`authorize`, and `stream`.

The deletion test for this module is deliberate: without it, every consumer
would need to reimplement provider OAuth, endpoint rules, message conversion,
stream framing, tool-call assembly, and error handling.

## Ownership

The module owns:

- provider and model descriptors;
- API-key and OAuth state machines;
- serialized credential refresh;
- exact request URL, headers, and body encoding;
- SSE/WebSocket response parsing;
- normalized text, reasoning, tool-call, asset, usage, and completion events;
- typed, fail-closed errors.

The module does not own:

- conversation or agent loops;
- tool execution or approval policy;
- browser, document, or shell tools;
- UI and OAuth presentation;
- product persistence outside an injected credential store;
- provider fallback.

## Internal runtime seam

`ProviderRuntimeKernel` is the provider-neutral composition layer behind the
public `ProviderRuntime` interface. It resolves an exact provider and model,
requires the declared credential state, and dispatches exclusively through the
wire adapter named by `ProviderModel.protocolID`. Provider authorization and
wire-protocol adapters are internal seams; consumers do not select or assemble
them.

The kernel is partially landed. Its dispatch and explicit configuration
failures have deterministic coverage, but the public built-in `PiAIRuntime`,
provider definitions, and production wire adapters are not yet landed. An
unimplemented protocol therefore fails explicitly instead of selecting another
protocol or provider.

## OpenAI Codex authorization

The first native authorization slice uses device-code OAuth. This avoids
depending on a loopback callback listener while an iOS app is backgrounded.
The Swift client preserves pi-ai's device-code, polling, token-exchange, and
ChatGPT account-claim invariants. Browser/localhost login is not an automatic
fallback when device authorization is unavailable.

## External dependencies

Provider networks are true external dependencies. Production implementations
use explicit transport and credential adapters; tests use deterministic mock
adapters. Tests assert only through the public provider-runtime seam.

## Upstream relationship

The pinned pi source is a behavior oracle. Swift code is a semantic port, not a
line-by-line translation. Observable equivalence is defined by:

1. canonical structured input;
2. exact outbound URL, headers, and body;
3. raw inbound frames;
4. normalized event sequence;
5. credential state transition;
6. typed final result or error.

Catalog-only changes may be automated after tests pass. Authentication,
endpoint, request, credential-schema, or provider-policy changes require an
explicit review even when an automated port passes.

The classification, synchronization, incompatibility, and reconstruction rules
are defined in [AI_MAINTENANCE.md](AI_MAINTENANCE.md). This document owns the
module seam; the maintenance document must not redefine it.

Every implementation area and its current coverage status is recorded in
`UpstreamMappings/pi-ai.json`. That file is a coverage ledger, not a statement
that every referenced upstream path has already been ported.

The ledger tracks the complete pinned built-in provider registry, independent
of authorization kind. OAuth, subscription, ambient, and API-key providers all
remain in scope. A provider marked `missing` is tracked but not advertised as a
working Swift provider until its authorization, catalog, selected wire
protocols, and deterministic verification are landed.
