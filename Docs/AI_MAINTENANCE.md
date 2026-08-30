# AI maintenance and reconstruction contract

## Current status

**Partially landed.**

Implemented today:

- exact upstream repository, revision, package version, and source-path lock;
- the complete tracked built-in provider inventory and per-area mappings;
- clean-cache and source-presence verification;
- a narrow Swift provider-runtime seam;
- a complete pinned catalog with persisted snapshot and dynamic Radius model
  validation, publication, and offline restoration;
- buffered and raw incremental URLSession transports with cancellation tests;
- API-key storage, Apple Keychain persistence, serialized refresh ownership,
  Anthropic/OpenRouter PKCE, and GitHub Copilot/Kimi Coding/OpenAI Codex/xAI
  subscription OAuth, plus Radius browser/device OAuth;
- Bedrock bearer and deterministic SigV4 signing, AWS event-stream CRC
  validation, and opaque reasoning-signature round trips;
- deterministic contract, wire-protocol, catalog, transport, and OAuth fixtures;
- a generated differential manifest that binds every known wire protocol to
  exact upstream source/test digests and executable Swift fixture digests;
- macOS tests, iOS builds, and an opt-in iOS Simulator OAuth test;
- explicit errors instead of provider, protocol, or authentication fallback.

Not implemented yet:

- an automated semantic diff classifier;
- a shared cross-language request/event runner for newly added semantics that
  are not yet represented by the protocol fixture suites;
- a machine-readable sync decision report;
- live generation evidence for providers without authorized credentials;
- unattended promotion of any provider implementation.

This document governs both updating an existing checkout and reconstructing the
module from an empty Swift package. It does not authorize live credentials,
billable requests, release publication, or weakening a compatibility gate.

## Objective

`pi-ai-swift` is a native semantic port, not compiled TypeScript and not a
line-by-line translation. The maintenance objective is:

> Given a pinned pi-ai revision and canonical fixtures, reproduce the same
> supported provider behavior through the small Swift `ProviderRuntime` seam,
> or produce a precise incompatibility result without changing the pin.

Automation is successful when it reaches a truthful terminal result. A blocked
sync is a successful maintenance outcome when the proposed upstream behavior
cannot be represented safely on Apple platforms.

## Sources of truth

Use these sources in this order:

1. `Upstream.lock.json` for the accepted revision and tracked built-in provider
   inventory.
2. `UpstreamMappings/pi-ai.json` for ownership between Swift areas and upstream
   source paths.
3. Canonical sanitized fixtures and differential test results.
4. Current Swift code and tests.
5. The pinned upstream implementation and its tests.
6. Upstream changelog, release notes, and current provider documentation.

Documentation or model names alone never establish wire behavior. A passing
upstream JavaScript/TypeScript test never establishes native Swift equivalence.

## Area coverage ledger

`UpstreamMappings/pi-ai.json` is maintained per implementation area rather than
per repository or broad provider label. Each area records its responsibility,
truthful status, existing Swift paths, planned Swift paths, upstream sources,
and upstream tests. `landed` and `partial` areas must point to real Swift source
files; every production source in `PiAIProviderRuntime` must belong to at least
one area. The upstream check enforces these invariants and requires every
mapped upstream path to remain inside the exact provenance lock.

A mapped path means “this area must absorb or explicitly reject changes from
this source.” It does not mean the behavior is implemented. Only an area's
status plus executable evidence establishes completion.

Provider inventory is not a hand-maintained subset. The upstream gate parses
the pinned `providers/all.ts` `builtinProviders()` list and requires every
built-in provider to have at least one explicit mapping area and to appear in
the provenance lock. This includes subscription/OAuth providers such as GitHub
Copilot and xAI as well as API-key providers such as DeepSeek, Groq, Moonshot,
OpenRouter, Qwen Token Plan, Together, and Z.AI. The same gate parses
`KnownApi` and rejects an unmapped wire protocol.

## Maintenance trigger and IR lifecycle

Maintenance is human-initiated and may occur at irregular intervals. This
repository does not require a scheduler, periodic bot, automatic pull request,
or unattended upstream watcher. Once a maintainer names a candidate upstream
revision or asks for a provider implementation, an agent may execute the
bounded workflow in this document. Normal authorization rules for commits,
publishing, credentials, and billable live tests still apply.

`UpstreamMappings/pi-ai.json` is the durable intermediate representation
between upstream discovery and Swift implementation. It is both a coverage
ledger and a maintenance queue, but it is not runtime configuration and must
not generate supported-provider claims by itself.

Every newly discovered built-in provider must enter this IR before provider
implementation begins. The inventory update must:

1. create a provider area with status `missing`;
2. record its responsibility, upstream provider and model sources, relevant
   upstream tests, and planned Swift paths;
3. map every new wire protocol, authentication mechanism, or shared foundation
   area introduced by that provider;
4. update the complete tracked built-in provider inventory and provenance for
   the exact candidate revision; and
5. prove that no existing supported area regressed before accepting a new pin.

A provider may remain `missing` across releases and maintenance intervals. That
is a truthful result: the provider is known and assigned, but is not registered
as a working Swift provider. The accepted pin may move after the complete
provenance and all applicable existing-support gates pass; moving the pin does
not promote a newly recorded provider.

Maintenance tasks have two explicit modes:

- **Inventory sync:** compare a proposed upstream revision, update the IR and
  provenance, register new areas as `missing`, and verify the already supported
  surface. It does not implement or advertise the new provider.
- **Implementation sync:** select one or more related IR areas, port the
  provider vertical slice, add deterministic evidence, and promote status only
  as far as that evidence proves.

An implementation task may be started immediately after inventory sync or much
later by a separate human request. Agents must resume from the IR rather than
rediscovering scope from provider names or current documentation.

The normal evidence-based promotion path is:

```text
missing -> partial -> landed
```

Use `blocked` when an area is known but cannot currently satisfy a required
policy, platform, or upstream-contract gate. Never promote an area merely
because files, placeholders, mocks, or a provider name exist. If later upstream
drift invalidates earlier evidence, regress the status truthfully rather than
preserving a stale `landed` claim.

## Module seam and deletion test

The public seam remains the three operations `catalog`, `authorize`, and
`stream`. Authentication state machines, request construction, stream parsing,
credential refresh, provider dialects, and error normalization stay behind
that seam.

Do not expose Node, SDK, OAuth, SSE, or provider-specific implementation types
to make a port easier. If deleting this module would force every caller to
reimplement those rules, the module is earning its depth and locality.

## Sync terminal states

Every sync or reconstruction run must end in exactly one state:

| State | Meaning | Pin may move? |
| --- | --- | --- |
| `compatible` | Required equivalence is proven at every applicable gate | Yes |
| `no_relevant_change` | The mapped semantic surface is unchanged | Yes, after provenance checks |
| `needs_review` | A policy, security, public-seam, or live-account decision is required | No |
| `upstream_incompatible` | Required behavior cannot be represented by the supported Swift/Apple contract | No |
| `verification_failed` | Evidence is missing, malformed, flaky, or contradictory | No |

Never partially advance the lock. Never combine implementation files from one
revision with tests, model data, or provenance from another revision.

## Change classification

Classify each relevant upstream hunk before editing Swift.

### Class A — mechanical data

Examples:

- model IDs, display names, pricing, context sizes, and capability flags;
- source-path moves with identical behavior;
- comments, documentation, and TypeScript-only type spelling;
- generated catalogs whose schema and validation rules are unchanged.

AI may update these automatically only when schema validation, catalog tests,
and the full verification matrix pass. A model capability change is not Class
A when it affects request fields, stream events, authentication, or replay.

### Class B — representable semantics

Examples:

- accepted JSON field variants;
- request header/body changes;
- new SSE event shapes;
- reasoning, tool-call, usage, or stop-reason normalization;
- cancellation and refresh timing that Swift concurrency can model directly.

AI may port these without changing the public seam when canonical fixtures
prove both accepted and rejected cases. The port must preserve observable
behavior, not the upstream implementation technique.

The OpenAI Codex device response is the reference example: upstream accepts the
polling interval as either a JSON number or numeric string. Swift therefore
models those two documented wire representations explicitly; it does not turn
on general lossy decoding.

### Class C — policy or security change

Examples:

- OAuth client IDs, scopes, redirect URIs, endpoints, or token claims;
- credential schema, storage, export, refresh ownership, or minimum validity;
- retry, fallback, proxy, telemetry, or data-retention policy;
- a public `ProviderRuntime` interface change;
- new live-account, billing, or entitlement behavior.

AI may investigate, write fixtures, and prepare a candidate patch, but the pin
must not move until the policy decision is explicitly approved and live tests
at the affected layer pass.

### Class D — platform-incompatible semantics

Examples:

- a required Node/Bun built-in with no native Apple equivalent in scope;
- a required localhost callback server that cannot survive the iOS lifecycle;
- reliance on mutable process environment, filesystem layout, or dynamic module
  loading as part of provider semantics;
- JavaScript object identity, prototype, or executable callback behavior that
  crosses the public seam;
- a required hidden fallback forbidden by this repository;
- an upstream behavior that cannot be observed or tested without retaining
  secrets or private reasoning.

Do not emulate these with placeholders, WebViews, embedded Node, guessed
defaults, or a different provider path. End the run as
`upstream_incompatible`, name the exact invariant, and keep the last compatible
pin.

## JavaScript/TypeScript absorption limits

JavaScript/TypeScript instability has several distinct forms. Treating all of
them as source syntax drift is unsafe.

### Syntax and packaging drift

Type-only imports, strip-only TypeScript rules, lazy dynamic imports, package
exports, and Node/Bun bundling changes may have no Swift semantic equivalent.
Record them as ignored implementation details only after confirming that the
wire and state-machine fixtures are unchanged.

### Runtime and scheduling drift

`AbortSignal`, timers, promise races, event-loop ordering, shared in-flight
requests, and Node stream backpressure map to Swift tasks, clocks, actors, and
`AsyncSequence` behavior—not to direct syntax. Require cancellation, ordering,
and concurrency fixtures. A compile-successful translation is insufficient.

### Dynamic-shape drift

Upstream code may accept strings or numbers, missing members, class instances,
arrays, or nested error shapes through runtime checks. Swift must enumerate
every accepted representation and reject everything else. Do not use global
lossy decoding, `Any`, or silent defaults to mimic JavaScript permissiveness.

### SDK and environment drift

Generated JavaScript SDK types are hints, not the contract. Canonicalize the
actual HTTP request, response, SSE frame, and error body. Node proxy variables,
filesystem auth files, browser callbacks, and module loading are host behavior;
they are not automatically requirements for the iOS implementation.

### Upstream fallback and retry drift

Separate protocol-required state transitions from product recovery policy.
Device-code `authorization_pending` polling and RFC-style `slow_down` handling
are part of the primary authorization contract. Switching provider, model,
protocol, endpoint, auth source, or execution mode after failure is forbidden.
Agent-loop retry policies are outside this module unless explicitly adopted as
provider transport semantics.

## Existing-checkout synchronization workflow

After a human initiates an inventory or implementation sync, an AI maintainer
must execute the applicable stages in order. An inventory sync normally stops
after recording and verifying the decision; an implementation sync continues
through fixtures, porting, and the full verification matrix.

### 1. Establish a clean baseline

- Read `Docs/README.md`, this document, `Docs/ARCHITECTURE.md`, `AGENTS.md`, the
  lock, and the mappings.
- Confirm the working tree and preserve unrelated user changes.
- Run `swift test`, `swift format lint`, the pinned-upstream check, and the
  generic iOS Simulator build before changing the pin.
- Stop if baseline verification fails.

### 2. Fetch without accepting

- Fetch the proposed upstream revision without checking it out into the Swift
  worktree.
- Verify repository identity, commit reachability, package path, package name,
  version, license, and required source paths.
- Read the pi-ai changelog between revisions.
- Diff all mapped source paths and their relevant upstream tests.
- Expand the mapping before proceeding if behavior moved outside the current
  paths. Missing mapping coverage is `verification_failed`, not “no change.”

### 3. Build a semantic change inventory

For every relevant hunk, record:

- provider ID and Swift area;
- Class A, B, C, or D;
- request/state/event/error invariant affected;
- upstream test or fixture that demonstrates it;
- Apple platform applicability;
- proposed verification gate;
- whether explicit approval is required.

Do not edit Swift until every relevant hunk is classified.

### 4. Freeze fixtures before implementation

- Capture sanitized request bodies, response bodies, SSE frames, and state
  transitions from the proposed exact revision.
- Include positive cases, terminal errors, malformed payloads, cancellation,
  and ordering.
- Remove tokens, authorization headers, account IDs, user content, private
  reasoning, trace IDs, and billable payloads.
- Record fixture provenance: upstream revision, source test/path, provider, and
  transformation used for sanitization.
- Review fixture changes independently from Swift implementation changes.

### 5. Port behind internal seams

- Change the smallest internal adapter that owns the behavior.
- Preserve the three-operation public seam unless a Class C decision approves a
  change.
- Accept dependencies such as transport, credential store, and clock through
  internal seams so deterministic tests can drive them.
- Preserve unknown fields only when the interface explicitly requires opaque
  replay; otherwise reject unknown semantic events.
- Never add a compatibility branch without a fixture proving why both shapes
  are canonical.

### 6. Run the verification matrix

All applicable rows must pass:

| Gate | Required evidence |
| --- | --- |
| Provenance | Exact commit, package identity/version, license, source paths |
| Static | `swift format lint`, strict compilation, JSON/schema checks |
| Swift contract | DTO round trips, explicit errors, cancellation, ordering |
| Differential | Same canonical input produces equivalent request/events/error |
| macOS | `swift test` |
| iOS compile | arm64 and x86_64 Simulator build |
| iOS runtime | Deterministic XCTest in an actual Simulator process |
| Live auth | Explicit opt-in, user-present, safe metadata only |
| Live generation | Explicit opt-in and billing authority; normalized events checked |
| Security | Secret scan; no token-bearing fixtures, logs, or artifacts |

A generic iOS build does not prove iOS runtime behavior. A macOS CLI OAuth
success does not prove Simulator OAuth. The 2026-08-30 Codex validation required
an iOS 26.5 XCTest to prove device polling, token exchange, and account-claim
decoding in the Simulator process.

### 7. Decide and record

- Move the lock only after all required gates pass.
- Update mappings, fixtures, docs, and provenance in the same change.
- Emit the terminal state and a concise evidence summary.
- Commit only the scoped files; never include `.build`, `.swiftpm`, `.xcresult`,
  simulator containers, safe live-result files, or credentials.

## Reconstruction from an empty Swift package

Reconstruction is not “translate every `.ts` file.” Use this order:

1. Restore the package manifest, platform floors, license, notice, lock, and
   mapping.
2. Recreate only the public `ProviderRuntime` seam and canonical DTOs.
3. Recreate strict errors and injected transport/credential-store seams.
4. Import sanitized fixtures and make the contract tests compile before adding
   live implementations.
5. Implement one provider vertical slice at a time:
   authorization, request encoding, streaming, normalized events, refresh, and
   explicit errors.
6. Start with OpenAI Codex device authorization because it has deterministic
   fixtures plus macOS and iOS live evidence. Do not infer that generation is
   supported from authorization success.
7. Add OpenAI API-key and Kimi Coding only after their provider-specific
   dialect fixtures exist.
8. Run the complete verification matrix for every claimed provider.
9. Mark unsupported paths explicitly; do not create empty adapters or mocks in
   production sources.

The reconstructed module is equivalent only when callers can exercise the same
supported behavior through the small seam. Similar source layout or matching
line counts are irrelevant.

## Live-test lifecycle and observability

Live tests are user-present diagnostics, not ordinary CI.

- Never print or persist access tokens, refresh tokens, account IDs, auth
  headers, raw callbacks, or private reasoning.
- Emit only safe booleans, expiry, platform/runtime identity, terminal state,
  and an ephemeral result path under an ignored build or Simulator directory.
- A task-scoped process may be terminated when Codex Desktop updates or
  restarts. Persist the safe terminal result outside that process before
  reporting success.
- Browser completion alone is not token-exchange evidence.
- A live result belongs only to the exact runtime that produced it. Do not use a
  macOS result to claim iOS support.
- Ordinary CI must skip live tests unless an explicit simulator environment
  gate is enabled.

## Required incompatibility report

For `needs_review`, `upstream_incompatible`, or `verification_failed`, report:

1. proposed and current upstream revisions;
2. affected provider and mapped paths;
3. exact unsupported or unverified invariant;
4. classification and why a lower class is invalid;
5. fixtures/tests that demonstrate the gap;
6. last compatible revision;
7. what authority or platform capability would unblock the run;
8. confirmation that the lock and supported-provider claims did not move.

Do not generate a degraded artifact and call it compatible.

## Promotion policy

AI may automatically commit a sync only when all changes are Class A or B, no
public interface or policy decision changed, all required gates pass, the
secret scan is clear, and repository instructions explicitly authorize the
commit. Pushing, releasing, publishing, billable live calls, or credential use
still require separate authority.

Any Class C or D change blocks automatic promotion. Human approval can decide a
Class C policy; it cannot turn an unrepresentable Class D behavior into proven
compatibility.

## Research baseline

As of 2026-08-30, the accepted pi-ai revision
`853a80d26c90a14c1886f0ebb8ffaae133ca2185` is also upstream `main` and carries
package version `0.84.4`. This is a point-in-time fact and must be refreshed on
every sync run.

Recent pi-ai changes demonstrate why classification is required: cancellation
became mandatory across auth and model refresh; OAuth refresh gained bounded
validity semantics; raw stop reasons and reasoning replay changed; Codex stream
and cache affinity behavior changed; and Node/Bun loading remains an upstream
implementation concern. Consult the exact changelog and mapped tests rather
than copying this summary forward.
