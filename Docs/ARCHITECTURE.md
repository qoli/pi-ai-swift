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
