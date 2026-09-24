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

Intentionally agent-owned rather than implemented in the signal script:

- semantic interpretation and Class A/B/C/D classification of upstream drift;
- planning and porting newly added semantics not represented by existing
  protocol fixture suites;
- identification of policy and platform gates, without inventing local policy;
- live generation evidence requiring authorized credentials;
- promotion of provider implementation status.

The executable agent workflow is `prompts/pi-ai-upstream-maintenance.md`.
`Scripts/check-upstream.sh` remains a pure `YES`/`NO` signal.

This document governs both updating an existing checkout and reconstructing the
module from an empty Swift package. It does not authorize live credentials,
billable requests, release publication, or weakening a compatibility gate.

## Objective

`pi-ai-swift` is a native semantic port of pi-ai's provider-facing observable
behavior, not compiled TypeScript, a line-by-line translation, or a port of the
whole TypeScript package. The maintenance objective is:

> Given a pinned pi-ai revision and canonical fixtures, reproduce the same
> supported provider behavior through the small Swift `ProviderRuntime` seam,
> or produce a precise incompatibility result without changing the pin.

"Supported provider behavior" is deliberately narrower than every public type
or utility exported by `packages/ai`. It includes provider/model capabilities,
authentication, final request URL/headers/body, provider stream decoding,
normalized events and usage, replay metadata required by a provider, and typed
provider failures. It excludes caller/session assembly such as transcript
normalization, prompt-section history, tool availability history, conversation
persistence, and agent control flow.

Automation is successful when it reaches a truthful terminal result. A blocked
sync is a successful maintenance outcome when the proposed upstream behavior
cannot be represented equivalently on Apple platforms.

## Mechanical semantic translation only

Intent translation is mechanical preservation of the exact upstream observable
contract within the ownership boundary. It is not permission to reinterpret,
improve, harden, or extend upstream intent. This applies to every change class,
including Class B; "mechanical" does not mean that only Class A data may be ported.
Swift implementation techniques may differ, but supported inputs, defaults,
outputs, failures, and state transitions must preserve upstream behavior.

Do not proactively add capabilities absent from upstream. Do not add validation,
rejection conditions, limits, security policies, normalization, retries, or
fallbacks absent from the exact target source. Neither "safer" nor "more robust"
is evidence of upstream intent. In particular, an explicit upstream HTTP endpoint
must not become HTTPS-only or loopback-only as a side effect of porting.

For every changed observable behavior, identify its exact upstream source and
discriminating evidence before implementation. A local proposal, existing Swift
code, matching local tests, or a green checker cannot authorize an upstream
deviation. Inspect both directions: inputs upstream accepts but Swift rejects,
and inputs or behaviors Swift accepts or adds beyond upstream. Derive expected
results from upstream rather than encoding a locally preferred policy.

If equivalent behavior cannot be represented, record the concrete gate and stop
the affected implementation; do not substitute a supposedly safer behavior.
New local capabilities or intentional deviations require a separate explicit
user request and must be documented as deviations, never as upstream parity.
Class C is a decision boundary for an actual policy change, not a license to
invent one. An agent-added restriction does not become an approved policy merely
because it was committed, documented, or tested. Repairing such a demonstrated
port defect does not require renewed policy approval solely because the faulty
code was described as a security measure. Preserve genuinely user-authorized
deviations unless the user authorizes changing them.

## Sources of truth

Authority is scoped by the question being answered:

- `Docs/ARCHITECTURE.md` and `AGENTS.md` determine module ownership and the
  public seam. Upstream package structure cannot expand that boundary.
- `Upstream.lock.json` identifies the accepted revision and inventory. A sync
  candidate remains unaccepted until its applicable gates close.
- The exact target upstream implementation and its tests determine observable
  provider behavior within that boundary. Defect repair uses the accepted
  source; revision sync uses the exact candidate source.
- `UpstreamMappings/pi-ai.json` records review provenance and coverage claims.
  Canonical fixtures, local code, and tests are fallible evidence of the port,
  not authorities that can override a demonstrated upstream invariant. Correct
  them together when they preserve the same mistaken interpretation.
- Changelogs and provider documentation guide investigation; documentation or
  model names alone never establish wire behavior.

A passing upstream JavaScript/TypeScript test does not establish native Swift
equivalence. A green local fixture does not settle a contradictory source
observation. Explain any intentional divergence as an explicit gate rather
than silently changing the oracle to match Swift.

## Ownership filter

Apply this filter before assigning Class A, B, C, or D. Every changed upstream
hunk belongs to one of three ownership categories:

1. **Provider-owned observable behavior** — provider/model capability metadata,
   authentication, request or wire projection, response normalization, usage,
   provider replay metadata, or provider failure semantics. Continue to A/B/C/D
   classification and deterministic evidence.
2. **Caller/session-owned assembly** — transcript normalization, system-prompt
   composition, named prompt sections, tool availability history, conversation
   persistence, assistant-frame persistence, or agent control flow. Do not port
   it into pi-ai-swift. Record whether it changes the final provider behavior for
   an input already expressible through `ProviderRequest`.
3. **Upstream host implementation** — Node/Bun packaging, process environment,
   proxy integration, filesystem conventions, Workers bindings, or other host
   mechanics not required by the Apple provider runtime. Preserve only an
   observable provider contract that crosses the Swift seam.

An upstream type becoming public, moving into an adapter import closure, or
being consumed by every TypeScript provider does not by itself make it
provider-owned. In particular, `Context`, `TranscriptContext`, generic system
message replay, prompt-section merging, and tool-state reconstruction remain
caller/session concerns.

If a new provider feature needs caller/session information that the current
`ProviderRequest` cannot express, maintenance must record a cross-repository
gate and leave the public seam unchanged. Designing that seam requires a
separate coordinated AIReasoningCore/pi-ai-swift task. It is not Class C merely
because the TypeScript upstream changed a public type.

Out-of-scope additions do not make the whole candidate
`upstream_incompatible`. The pin may move when fixtures prove that the existing
supported provider surface remains equivalent and the omitted capability is
truthfully recorded without being advertised as supported.

## Area coverage ledger

`UpstreamMappings/pi-ai.json` is maintained per implementation area rather than
per repository or broad provider label. Each area records its responsibility,
truthful status, existing Swift paths, planned Swift paths, upstream sources,
and upstream tests. `landed` and `partial` areas must point to real Swift source
files; every production source in `PiAIProviderRuntime` must belong to at least
one area. The upstream check enforces these invariants and requires every
mapped upstream path to remain inside the exact provenance lock.

A mapped path means “this area must review provider-facing consequences from
this source.” It does not assign ownership of every type or helper in that file.
The review may conclude that a hunk is caller/session-owned or host-only, with a
recorded reason and unchanged provider fixtures. Only an area's status plus
executable evidence establishes completion.

Provider inventory is not a hand-maintained subset. The upstream gate parses
the pinned `providers/all.ts` `builtinProviders()` list and requires every
built-in provider to have at least one explicit mapping area and to appear in
the provenance lock. This includes subscription/OAuth providers such as GitHub
Copilot and xAI as well as API-key providers such as DeepSeek, Groq, Moonshot,
OpenRouter, Qwen Token Plan, Together, and Z.AI. The same gate parses
`KnownApi` and rejects an unmapped wire protocol.

## Maintenance trigger and IR lifecycle

Revision synchronization begins when a human names a candidate revision or
when an agent or automation resolves a candidate and the pure signal returns
`NO`. A reported semantic defect also starts maintenance, even when this signal
returns `YES`:

```sh
./Scripts/check-upstream.sh --candidate <full-upstream-commit>
```

The script only detects whether checked-in maintenance evidence covers that
exact hash. It does not interpret the diff or modify files. A `NO` result invokes
`prompts/pi-ai-upstream-maintenance.md`, which applies the bounded workflow in
this document. Normal authorization rules for commits, publishing, credentials,
and billable live tests still apply.

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

Maintenance tasks have three explicit modes:

- **Accepted-pin defect repair:** reproduce a reported mismatch against the
  exact accepted source, correct the owning implementation and evidence, and
  retain the accepted revision. `YES` never closes a known defect by itself.
  Neither resolving latest HEAD nor completing unrelated newer changes is a
  prerequisite. Refresh affected provenance without relabeling newer artifacts
  as accepted-source evidence.
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

Every sync, defect-repair, or reconstruction run must end in exactly one state.
For defect repair, `compatible` means the scoped repair passed its applicable
gates at the unchanged accepted revision. Report any separate newer-candidate
sync result independently; it must not obscure the repair result:

| State | Meaning | Pin may move? |
| --- | --- | --- |
| `compatible` | Required equivalence is proven at every applicable gate | Yes |
| `no_relevant_change` | The mapped semantic surface is unchanged | Yes, after provenance checks |
| `needs_review` | A policy, security, public-seam, or live-account decision is required | No |
| `upstream_incompatible` | Required behavior cannot be represented by the supported Swift/Apple contract | No |
| `verification_failed` | Evidence is missing, malformed, flaky, or contradictory | No |

The pin-movement column applies only to revision sync, never defect repair.

Never partially advance the lock. Never combine implementation files from one
revision with tests, model data, or provenance from another revision.

## Change classification

Only provider-owned observable changes that pass the ownership filter receive
an A/B/C/D class. Classify each such hunk before editing Swift.

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
- a public `ProviderRuntime` interface change required by an already-owned
  provider behavior and not merely by upstream package structure;
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
defaults, or a different provider path. Class D applies only when the behavior
is required by the supported provider surface after the ownership filter; an
unowned upstream subsystem is simply out of scope. End an applicable run as
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

### Upstream conversation and transcript drift

The TypeScript package may change `Context`, `TranscriptContext`, system-message
replay, prompt sections, tool-set history, or assistant-frame persistence. These
are not Swift port targets by structure. Inspect their downstream effect on
provider requests, then:

- port changed capability metadata or final wire behavior for inputs already
  expressible through `ProviderRequest`;
- keep transcript and tool-lifecycle assembly in AIReasoningCore or the host;
- record a cross-repository gate when a new capability needs additional caller
  information; and
- never copy the upstream conversation model into pi-ai-swift merely to make a
  differential fixture easier to express.

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

After a candidate signal returns `NO`, or a semantic defect is reported even
on `YES`, an AI maintainer must execute the
applicable stages in order using `prompts/pi-ai-upstream-maintenance.md`. An
inventory sync normally stops after recording and verifying the decision; an
implementation sync or defect repair continues through fixtures, porting, and
the applicable verification matrix. For repair, references to the proposed
revision below mean the exact accepted revision and the pin must stay fixed.

### 1. Establish a clean baseline

- Read `Docs/README.md`, this document, `Docs/ARCHITECTURE.md`, `AGENTS.md`, the
  lock, and the mappings.
- Confirm the working tree and preserve unrelated user changes.
- Run `swift test`, `swift format lint`, the pinned-upstream check, and the
  generic iOS Simulator build before changing the pin.
- Separate the expected failing defect reproduction from unrelated baseline
  failures. Preserve the failure output and proceed with the scoped repair; a
  known failing regression is evidence, not a reason to abandon the repair.
- An unrelated baseline failure blocks a clean acceptance result and pin
  movement. Diagnose or isolate it without weakening gates; report any remaining
  failure explicitly and do not silently expand the authorized repair scope.

### 2. Fetch without accepting

- Fetch the proposed upstream revision without checking it out into the Swift
  worktree.
- Verify repository identity, commit reachability, package path, package name,
  version, license, and required source paths.
- For revision sync, read the pi-ai changelog between revisions. For defect
  repair, compare the reported behavior with accepted-source semantics.
- Diff all mapped source paths and their relevant upstream tests.
- Expand the mapping before proceeding if behavior moved outside the current
  paths. Missing mapping coverage is `verification_failed`, not “no change.”

### 3. Build an ownership inventory

For every changed upstream hunk, or affected behavior in defect repair, record:

- provider-owned observable behavior, caller/session-owned assembly, or
  upstream host implementation;
- the architecture rule supporting that classification;
- whether an existing `ProviderRequest` can exercise any provider-visible
  consequence; and
- any cross-repository gate needed for a capability outside the current seam.

Do not edit Swift or assign A/B/C/D until this ownership inventory is complete.

### 4. Build a provider semantic change inventory

For every provider-owned relevant hunk or defect, record:

- provider ID and Swift area;
- Class A, B, C, or D;
- request/state/event/error invariant affected;
- exact upstream source for each added or changed observable behavior, including
  acceptance and rejection conditions; identify unsupported local additions;
- upstream test or fixture that demonstrates it;
- Apple platform applicability;
- proposed verification gate;
- whether explicit approval is required.

Do not edit Swift until every provider-owned relevant hunk is classified.

### Semantic evidence contract

For each affected invariant, record a reviewable link between exact upstream
source/test, canonical input, oracle observation, Swift assertion, and the
command that executes that case. A suite name or protocol row alone is not
case-specific evidence. Shared helpers count only when the named case actually
executes their relevant assertions.

- Identify each affected field's source, when it becomes available, permitted
  updates, and relationships across start, incremental, terminal, and replay
  stages. For example, request identity stays stable while reported-model
  metadata follows a distinct provider-defined update rule.
- Capture oracle values at the actual event boundary. Snapshot mutable event
  values immediately; do not synthesize earlier events from terminal messages.
  Review normalization/projection code as part of the evidence because it can
  erase the very difference being tested.
- Choose inputs that distinguish correct and plausible incorrect behavior:
  unequal requested/reported identities, missing versus empty metadata, delayed
  arrival, and later changes where relevant. Equal happy-path values alone do
  not test which source supplies a field.
- Show that the regression fails before the repair and passes afterward, or
  temporarily reintroduce the precise faulty behavior and show the targeted
  test fails. Restore production code afterward. Do not add broad mutation
  machinery when one focused demonstration is sufficient.
- When the defect crosses a consumer seam, exercise the actual provider runtime
  through that consumer with deterministic transport input, proving both valid
  provider behavior and continued rejection of genuinely invalid normalized
  events. Keep provider fixes here and consumer assertions in the owning repo.
  An isolated local dependency override may establish local integration; remove
  it afterward. It does not establish remote-main or shipped-product acceptance.
  Follow the consumer repository's remote-resolution gates after separately
  authorized publication; report that integration as pending in the meantime.

Inventories and digest checks validate the listed evidence, not every possible
semantic branch. `landed` means the declared scope has executable coverage at
that revision. New contradictory evidence reopens the affected claim even if
all existing matrices remain green. Reports must name the checked invariants
and gaps rather than claiming universal provider parity.

### 5. Freeze fixtures before implementation

The response-identity repair is a concrete example of the evidence contract:

| Invariant | Exact accepted source | Source / lifecycle rule | Executable identity cases |
| --- | --- | --- | --- |
| Start identity | `api/openai-completions.ts`, `api/anthropic-messages.ts`, `api/openrouter-images.ts` under `packages/ai/src` | Requested model at start; a server alias cannot replace it | `completions.identity-alias`, `anthropic.identity-alias`, `images.identity-alias` |
| Terminal and replay identity | The same source assistant model and terminal event | Must equal request and start identity | All eight `identityCases`; text cases additionally validate replay source |
| Completion reported model | `api/openai-completions.ts` chunk loop and `test/openai-completions-response-model.test.ts` | First nonempty differing model from any chunk; retain it across later changes | `completions.identity-alias`, `-same`, `-missing`, `-empty`, `-late` |
| Anthropic reported model | `api/anthropic-messages.ts` message-start handler and `test/anthropic-sse-parsing.test.ts` | Report differing message-start model separately | `anthropic.identity-alias`, `anthropic.identity-same` |

Paths above are evaluated at the accepted revision in `Upstream.lock.json`.
Canonical inputs and observations are the `identityCases` collections in
`Fixtures/Differential/{Cases,Oracle}/response-rich.json`; the response inventory
binds each branch to these exact case IDs. `named-scenarios` evidence checks the
input/observation case sets and revisions, so the unrelated rich protocol case
cannot substitute for a deleted alias case. Actual behavior is still established
by running the Swift assertions, not by the static inventory alone.

Reproduce the evidence from the pi-ai-swift checkout:

```sh
swift test --filter responseIdentityMatchesSourceForAliasesAndLateModelMetadata
python3 -B -m unittest discover -s Scripts/tests
python3 Scripts/check-differential-coverage.py .
```

For the consumer boundary, run the consumer-owned
`AIReasoningCore/Scripts/check-provider-identity.py --pi <pi-ai-swift-checkout>`.
It exercises the real provider adapter through Core in an isolated harness with
checked-in frames. It must accept the alias in both response modes and reject a
test-mutated normalized identity. This optional integration probe adds no
AIReasoningCore dependency to the provider package.

- Capture sanitized request bodies, response bodies, SSE frames, and state
  transitions from the proposed exact revision.
- Include positive cases, terminal errors, malformed payloads, cancellation,
  and ordering.
- Remove tokens, authorization headers, account IDs, user content, private
  reasoning, trace IDs, and billable payloads.
- Record fixture provenance: upstream revision, source test/path, provider, and
  transformation used for sanitization.
- Review fixture changes independently from Swift implementation changes.

### 6. Port behind internal seams

- Change the smallest internal adapter that owns the behavior.
- Preserve the three-operation public seam unless a Class C decision approves a
  change.
- Accept dependencies such as transport, credential store, and clock through
  internal seams so deterministic tests can drive them.
- Preserve unknown fields only when the interface explicitly requires opaque
  replay; otherwise reject unknown semantic events.
- Never add a compatibility branch without a fixture proving why both shapes
  are canonical.
- Do not add transcript normalization, prompt-section merging, tool lifecycle,
  or conversation persistence to satisfy an upstream package-structure change.

### 7. Run the verification matrix

All applicable rows must pass:

| Gate | Required evidence |
| --- | --- |
| Provenance | Exact commit, package identity/version, license, source paths |
| Static | `swift format lint`, strict compilation, JSON/schema checks |
| Swift contract | DTO round trips, explicit errors, cancellation, ordering |
| Differential | Case-specific assertions prove equivalent request/events/error and cross-event invariants, with event-time oracle capture and regression sensitivity evidence |
| Consumer boundary | When affected: actual provider runtime through the consumer using deterministic input; local and remote acceptance reported separately |
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

### 8. Decide and record

- Move the lock only for revision sync after all required gates pass; retain
  the accepted revision for defect repair.
- Update mappings, fixtures, docs, and provenance in the same change.
- Emit the terminal state and a concise evidence summary.
- If separately authorized to commit, include only scoped files; never include `.build`, `.swiftpm`, `.xcresult`,
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

### 2026-09-25 source-derived schema 6 acceptance

The accepted revision is now `d5629e20489ccf770ed90b5a33941cb3b7ef24d0`
(package 0.87.1 plus that commit's unreleased changes). See
[UPSTREAM_SYNC_2026-09-25.md](UPSTREAM_SYNC_2026-09-25.md) for ownership,
source-derived regressions and acceptance. Earlier entries below are historical.

Lock schema 4 records exact-source/frozen-input catalog provenance; schema 3
records published npm artifact provenance. These are explicit alternatives,
not failure fallbacks. Source-derived acceptance must rebuild from the exact
commit and preserved public response bodies, compare complete catalog values,
and validate provider/type inventories. Npm publication is not a prerequisite
for that source path; an old npm artifact cannot be relabeled as a new commit.

Run the checker before Swift oracle tests, not concurrently: dependency setup
may reinstall their shared upstream cache. New helper oracles observe mutable
events synchronously at emission, not at later asynchronous consumption.

### 2026-09-22 response identity correction and candidate assessment

The accepted revision remains `19451accdeec671c1f4da9eafac8fc270f510ef4`
(0.86.1). The default-branch candidate resolved for this run was
`1a584a7a56eb5e7b4ff8ccbd46430f1533282eed`. Full candidate synchronization ends
as **verification_failed**; this does not prevent correcting a demonstrated
semantic-port error against the accepted source.

The accepted and candidate sources both preserve the requested `model.id` in
assistant identity. Anthropic records a different server model separately;
Chat Completions records the first nonempty differing model from any chunk.
Swift incorrectly used the server name for response-start identity in Chat
Completions, Anthropic, and OpenRouter Images. A valid server alias therefore
failed a caller's exact request-identity check. Chat Completions also captured
response model metadata only from the first chunk.

The scoped Class B repair changes those three start events to the requested
identity and aligns Chat Completions metadata capture with upstream. It does
not change requests, resolve aliases locally, retry, or select another model.
Existing image-specific terminal metadata remains unchanged; image parity here
is the requested identity, not a claim about an upstream responseModel field.

The previous response-rich fixtures used equal names for these adapters, and
the response oracle projected start identity from the terminal message. The
oracle now snapshots actual start identity. Eight additional source-executed
cases cover completion alias/same/missing/empty/late model metadata, Anthropic
alias/same models, and image aliases. The new test failed with six semantic
assertions before the implementation repair and passed afterward. The upstream
`openai-completions-response-model.test.ts` regression is now explicitly locked
and mapped. Mapping evidence, the response branch inventory, and fixture
digests include this coverage; the signal checker itself is unchanged.

Candidate analysis found these additional changes, not applied by this repair:

| Area | Ownership / classification | Required subsequent work |
| --- | --- | --- |
| Chat Completions strict schemas | Provider wire, B | Default unknown endpoints to non-strict; preserve explicit built-in capabilities |
| Empty user text parts | Provider wire, B | Filter empty array-form parts and omit empty messages, with source fixtures |
| Image input limits and resize metadata | Provider catalog, B; resize application is caller-owned | Preserve catalog data; record caller-facing exposure as a separate seam gate |
| Grok 4.7 and xAI pricing tiers | Catalog data, A | Obtain exact-candidate catalog data and verify tier projection |
| Package version / faux test provider | Provenance / upstream host | Update relevant provenance without importing host behavior |

The published `@earendil/pi-ai@0.87.0` artifact identifies
`16787ad5b2dc748047f314ca1bfe7708f30f54f3` as its gitHead. Its SHA1 is
`e81ec36ab4e9f44bafa2c980c7ec3cf8cda32f8d`, and its model-data structure hash is
`8dd0aefb2a6806069b8eebd57911eb25fe3eca6d216eab0ebd92e9eebc0f2d75`.
It contains image limits and Grok 4.6, but lacks the candidate's unreleased
Grok 4.7 data. Generated provider JSON is not tracked in the source repository.
The current published-artifact catalog pipeline therefore cannot establish
exact-candidate catalog provenance. Relabeling that release with the candidate
hash is not acceptance. Resume full synchronization once exact-candidate model
data can be reproducibly obtained; this is an evidence gap, not a Class C
approval requirement or an intrinsic platform incompatibility.

Verification for the accepted-source repair:

- 161 macOS tests passed; formatting and whitespace checks passed.
- Source-executed oracle and coverage checks passed for all 11 protocols.
- Generic arm64 and explicit x86_64 iOS Simulator builds passed.
- Both response differential tests passed inside an iOS 26.5 Simulator process,
  using a temporary package harness against this checkout. The harness copied
  the same test source and fixtures, changing only fixture lookup to its bundled
  resources; it did not run host Node oracle generation inside iOS.
- The accepted signal and exact accepted-revision signal return `YES`; the
  latest-candidate signal remains `NO`. No accepted pin or provider support
  claim moved. No credentials, billable calls, commits, or publication were used.
- AIReasoningCore and product dependency integration are unchanged. This local
  patch is not evidence that a distributed SwiftChat build has received it.

### 2026-09-22 maintenance-method follow-up

The accepted-pin response-identity repair is **compatible within its tested
scope** at `19451accdeec671c1f4da9eafac8fc270f510ef4`; its pin did not move.
This result is separate from the newer-candidate assessment above.

The repo contract, workflow prompt, architecture claims, and installed skill
now route known defects independently of the revision signal. The eight identity
cases have individual inventory bindings and direct request/start/terminal/replay
assertions. Five checker tests reject missing observations, deleted alias evidence,
duplicate cases, and stale input revisions while accepting the valid inventory.
The signal script itself remains unchanged.

The consumer-owned probe passed two XCTest methods covering both ordinary and
streaming replies with the real provider adapter. Reintroducing the faulty
Chat Completions start-model assignment in an isolated source copy made its
valid-alias test fail; rerunning against the repaired checkout passed. The
consumer probe leaves real dependency manifests and pins untouched.

Final verification: 161 macOS tests, five checker tests, source/coverage gates,
both accepted-revision signals, Swift formatting, and whitespace checks passed.
The updated response suite also passed in iOS 26.5 Simulator; production arm64
and x86_64 Simulator builds passed. The installed skill passed validation and an
independent read-only scenario review of routine YES, defect-with-YES, and a
defect with an unrelated newer-candidate blocker. No live provider calls or
publication were performed. Remote-main and distributed-product integration
remain pending separately authorized publication.

As of 2026-09-20, the accepted pi-ai revision
`19451accdeec671c1f4da9eafac8fc270f510ef4` is upstream `main` and carries
package version `0.86.1`. The 0.86 maintenance run absorbed provider-visible
catalog, request, header, reasoning, usage, and replay changes while recording
transcript-owned mid-conversation system/tool history in
`Docs/UPSTREAM_GATES.md`. This is a point-in-time fact and must be refreshed on
every sync run.

Recent pi-ai changes demonstrate why classification is required: cancellation
became mandatory across auth and model refresh; OAuth refresh gained bounded
validity semantics; raw stop reasons and reasoning replay changed; Codex stream
and cache affinity behavior changed; and Node/Bun loading remains an upstream
implementation concern. Consult the exact changelog and mapped tests rather
than copying this summary forward.
