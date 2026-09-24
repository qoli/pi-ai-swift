# Architecture

## Current status

**The declared wire fixture scope is landed at the accepted revision.**
Source-executed oracles and Swift replay tests cover the listed request,
response-event, and typed-failure cases across all eleven wire protocols. This
is bounded evidence, not proof of every possible provider behavior; a newly
discovered invariant reopens the affected claim even when existing tests pass. The coverage gate requires
the protocol-by-variant matrices, checked-in source oracle, and Swift replay to
agree before a wire area can remain `landed`; coverage status refers to the
declared cases and their asserted invariants. Monetary usage, including pricing tiers, cache read/write,
Anthropic one-hour cache writes, OpenAI service-tier multipliers, Pi direct
cost, and OpenRouter image cost, is part of that deterministic response gate.

The public seam, normalized DTOs, explicit failure model, complete pinned
catalog, static custom-provider construction, native wire adapters, raw
streaming transport, Keychain storage, serialized credential refresh, and Kimi
Coding/OpenAI Codex device authorization exist. Provider reasoning signatures
remain opaque but round-trip through normalized events. Bedrock supports bearer
credentials and native SigV4 credentials supplied by the host. Anthropic and
OpenRouter use native host-returned PKCE callbacks; GitHub Copilot, Kimi Coding,
OpenAI Codex, and xAI use native device or callback flows. Radius supports
browser or device OAuth, authenticated dynamic catalog refresh, persisted
offline catalog restoration, and `pi-messages` streaming. Provider catalog and
authorization areas retain their own ledger statuses; wire closure does not
promote them. Live credentials remain a separate acceptance layer rather than
a substitute for compatibility fixtures.

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
- transcript normalization, system-prompt sections, or instruction history;
- deciding when tools become available or unavailable in a conversation;
- replaying conversation state to compute the caller's current instructions and
  tool set;
- tool execution or approval policy;
- browser, document, or shell tools;
- UI and OAuth presentation;
- product persistence outside an injected credential store;
- provider fallback.

## Input assembly seam

The caller supplies a fully assembled, provider-neutral `ProviderRequest`.
AIReasoningCore or another host owns translating its transcript, instructions,
schemas, tool lifecycle, and generation choices into that request. pi-ai-swift
owns validating the request against the selected model and projecting it into
the exact provider wire format.

This distinction remains true when the TypeScript upstream puts both concerns
in one package. Upstream `Context`, `TranscriptContext`, system-message replay,
prompt-section merging, tool-set history, and assistant-frame persistence are
not automatically Swift port targets. They are inspected only to determine
whether they change provider capability metadata or the observable wire result
for inputs already expressible through `ProviderRequest`.

If a new provider capability genuinely requires information the current request
cannot carry, record that as a cross-repository seam decision. Do not enlarge
`ProviderRuntime` during routine upstream maintenance and do not reproduce the
upstream conversation engine inside this module.

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

The pinned pi source is a behavior oracle for the provider-owned surface. Swift
code is a semantic port, not a line-by-line or public-type translation.
Observable equivalence is defined by:

1. canonical structured input;
2. exact outbound URL, headers, and body;
3. raw inbound frames;
4. normalized event sequence;
5. credential state transition;
6. typed final result or error.

Response identity is the requested catalog identity throughout the stream:
`responseStarted.modelID`, `responseSnapshot.modelID`, and the replay message's
source model must agree with `ProviderRequest.modelID`. A server-reported alias
or resolved model name does not replace that identity. Adapters retain reported
names separately in terminal `responseModelID` metadata. Chat Completions uses
the first nonempty differing model from any chunk, matching upstream; absent,
empty, or echoed names do not establish a different response model.

Catalog-only changes may be automated after tests pass. Authentication,
endpoint, request, credential-schema, or provider-policy changes require an
explicit review even when an automated port passes.

An upstream source path can contain both provider-owned behavior and
caller/session implementation. Mapping that path establishes review provenance,
not ownership of every exported type or helper in the file. The ownership list
above is authoritative when the maintenance document or upstream package layout
would otherwise imply a broader port.

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

## Source-derived catalog provenance

The accepted schema 6 catalog is generated from an exact upstream commit and
frozen public catalog responses, recorded by lock schema 4. It is not labeled
as an npm release artifact. Rebuilding must reproduce the complete values and
typed provider inventory. Published-artifact lock schema 3 remains a separate
explicit provenance form in the maintenance tooling.

Chat/image records with equal IDs keep separate output-modality routes and
their complete metadata. Classifier entries remain in source evidence but are
not advertised through the current runtime; TypeSafe is inventoried as missing.
The store and registry both select the supported operation types. Input-limit
metadata does not authorize new rejection rules or caller-side preprocessing.

Google response-start events carry no response ID, matching the source emission
boundary. The first nonempty ID from later chunks is retained in terminal
metadata. Requested model identity remains stable throughout.

## Reasoning effort selections

`ProviderGenerationOptions.reasoningEffort` uses `ProviderReasoningEffort`, not
an arbitrary string. A nil selection leaves provider defaults unchanged; `.off`
requests disabled reasoning. `ProviderModel.supportedReasoningEfforts` supplies
ordered, model-specific choices for host pickers. The runtime rejects unsupported
selections before resolving credentials or starting transport.

Catalog choices follow the pinned upstream `getSupportedThinkingLevels`: null
mappings remove a level, omitted basic levels use the protocol's defined mapping,
and xhigh/max require explicit mappings. Protocol adapters preserve the pinned
provider-specific disabled representation: Google families use their exact
minimum-thinking encoding, while non-Claude Bedrock models omit Claude-only
reasoning fields. The runtime never clamps an unsupported caller selection to
another level.

The model-store persistence schema is now 3 because catalog descriptors include
reasoning choices and prompt-cache lifetime metadata. Older snapshots fail
explicitly; no inferred migration or silent catalog replacement is performed.
Model metadata and persisted choices must agree.

For Google models, `.off` is the canonical caller request for the pinned
source's model-family-specific hidden/minimum-thinking form; it does not claim
that every Google backend can encode a literal zero-token budget.
