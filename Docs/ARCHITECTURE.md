# Architecture

## Current status

**Landed for the pinned provider scope.** The public seam, normalized DTOs, explicit failure model,
complete pinned catalog, static custom-provider construction, native wire adapters, raw streaming transport,
Keychain storage, serialized credential refresh, and Kimi Coding/OpenAI Codex
device authorization exist. Provider reasoning signatures remain opaque but
round-trip through normalized events. Bedrock supports bearer credentials and
native SigV4 credentials supplied by the host. Provider-by-provider
equivalence is pinned by the differential manifest. Anthropic and OpenRouter
use native host-returned PKCE callbacks; GitHub Copilot, Kimi Coding, OpenAI
Codex, and xAI use native device or callback flows. Radius supports browser or
device OAuth, authenticated dynamic catalog refresh, persisted offline catalog
restoration, and `pi-messages` streaming. All areas in the maintenance IR have
deterministic Swift evidence; live credentials remain a separate acceptance
layer rather than a substitute for compatibility fixtures.

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

The kernel dispatches both `BuiltinProviderRuntime` and `CustomProviderRuntime`
through exact catalog routes and the same production wire adapters. The custom
runtime semantically ports upstream's static `createProvider` declaration:
provider API-root URL, headers, default API, models, and model-level API/URL/header
overrides. Explicit configuration failures have
deterministic coverage. A missing protocol, credential, endpoint, output
modality, or authorization method fails explicitly instead of selecting another
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

## Reasoning effort selections

`ProviderGenerationOptions.reasoningEffort` uses `ProviderReasoningEffort`, not
an arbitrary string. A nil selection leaves provider defaults unchanged; `.off`
requests disabled reasoning. `ProviderModel.supportedReasoningEfforts` supplies
ordered, model-specific choices for host pickers. The runtime rejects unsupported
selections before resolving credentials or starting transport.

Catalog choices follow the pinned upstream `getSupportedThinkingLevels`: null
mappings remove a level, omitted basic levels use the protocol's defined mapping,
and xhigh/max require explicit mappings. Swift additionally excludes settings
that its adapter cannot represent, including Google minimum-thinking modes that
cannot actually disable reasoning and Bedrock reasoning on non-Claude models.
It never clamps an unsupported caller selection to another level.

The model-store persistence schema is now 2 because catalog descriptors include
reasoning choices. Older snapshots fail explicitly; no inferred migration or
silent catalog replacement is performed. Model metadata and persisted choices
must agree. The upstream pin remains unchanged.

Google 2.5 Pro is also excluded from `.off`: its documented minimum thinking
budget is 128. This deliberately rejects the pinned upstream's generic 2.x
zero-budget behavior for that model. Source:
https://ai.google.dev/gemini-api/docs/generate-content/thinking?hl=en .
