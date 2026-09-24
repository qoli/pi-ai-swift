# pi-ai-swift maintenance contract

## Scope

This repository is a native Swift semantic port of the provider runtime in
`earendil-works/pi/packages/ai`. Keep it independent from agent loops, tool
execution, product UI, browser/document tools, AIReasoningCore, AnyLanguageModel,
and shell runtimes.

The upstream TypeScript package is broader than this repository. Its public
types and utilities also include transcript normalization, system-prompt
composition, tool-set history, assistant-frame persistence, and other caller or
agent concerns. Their location in `packages/ai` and their use by an upstream
adapter do not transfer ownership to pi-ai-swift. Port only provider-facing
observable behavior: capability metadata, authentication, request/wire
projection, response normalization, usage, and provider failure semantics.

## Public seam

Preserve the three-operation `ProviderRuntime` interface unless a concrete,
verified upstream capability cannot be represented through it. Internal seams
must not leak merely to make tests easier.

## Upstream work

Intent translation is mechanical preservation of upstream observable behavior,
not redesign. Do not proactively add capabilities, restrictions, validation,
defaults, or safety policies absent from the exact target upstream source.
Different native implementation techniques must preserve the same semantics.
Follow "Mechanical semantic translation only" in `Docs/AI_MAINTENANCE.md`:
require source-derived evidence for each behavioral change, check both extra
Swift rejections and extra Swift behavior, and record real incompatibilities
instead of substituting behavior. Local extensions or intentional deviations
require a separate explicit user request; Class C does not authorize inventing
policy, and existing code or tests do not establish user authorization.

Read `Docs/AI_MAINTENANCE.md` before changing the upstream pin, a provider
adapter, authentication, normalized events, or reconstruction logic. Its sync
terminal states and change classes are mandatory.

`Scripts/check-upstream.sh` is a pure engineering signal. Its normal output is
exactly `YES` or `NO`; it must not analyze upstream intent, edit files, move the
pin, or perform maintenance. A human or automation may supply a candidate
revision. For an ordinary revision check, `YES` ends the check without changes.
A reported semantic defect instead enters accepted-pin defect repair even when
the signal is `YES`; hash coverage cannot disprove a behavioral defect. `NO`
must trigger the workflow in `prompts/pi-ai-upstream-maintenance.md`; never
modify or weaken the signal to
obtain `YES`.

Maintenance may be initiated directly by a human or proactively by an agent or
automation after a candidate signal returns `NO`. Treat
`UpstreamMappings/pi-ai.json` as the durable maintenance IR. A newly discovered
built-in provider must first be recorded as `missing` with its provider, model,
wire-protocol, authentication, test, and planned Swift ownership. A later,
separately initiated implementation task promotes that area only with executable
evidence. The IR is not runtime configuration and does not advertise support.

1. Select revision sync or accepted-pin defect repair using
   `prompts/pi-ai-upstream-maintenance.md`. Run the exact target signal; stop on
   `YES` only for an ordinary revision check without a reported defect.
2. Read `Upstream.lock.json` and every affected area in
   `UpstreamMappings/pi-ai.json`.
3. For sync, compare the pinned and proposed revisions. For defect repair,
   compare the demonstrated Swift behavior with the exact accepted source;
   keep the accepted revision and do not require unrelated latest-HEAD sync.
4. Inspect the tracked built-in provider inventory, mapped source paths,
   relevant upstream tests, and the changelog.
5. Apply the ownership filter in `Docs/AI_MAINTENANCE.md`. Separate
   provider-owned observable semantics from caller/session assembly and
   upstream host implementation before using the A/B/C/D change classes.
6. Classify every provider-owned relevant hunk before editing Swift.
7. Update sanitized fixtures before changing Swift implementation.
8. Prove the affected invariants through case-specific differential tests,
   event-time oracle observations, and a failing regression or targeted mutation
   before reporting success. Follow the semantic evidence contract in
   `Docs/AI_MAINTENANCE.md`; passing inventories do not prove universal parity.
9. Run macOS tests, iOS compile/runtime gates, and any explicitly authorized
   live test required by the affected behavior.
10. Update each affected area's Swift paths, planned paths, upstream paths,
   tests, and truthful status in the same change.
11. Update affected provenance in the same change. Move the exact revision only
    for an accepted sync; defect repair refreshes evidence at the existing pin.
12. Rerun both accepted and exact-target signals; both must return `YES` before
    a compatible result may be reported. In defect repair the target is the
    accepted revision. Report any separate latest-candidate assessment separately.

Do not mirror an upstream `Context`, `TranscriptContext`, message-history,
prompt-section, or tool-lifecycle type merely because provider implementations
consume it. AIReasoningCore or the host owns assembling current instructions,
messages, schemas, and tools into `ProviderRequest`. A change to that seam is a
separate coordinated design task, not an implicit result of upstream sync.

An automated run may end as `upstream_incompatible` or `verification_failed`.
That is preferable to moving the lock without equivalence. Keep the last
compatible pin and report the exact invariant.

Do not infer provider behavior from model names or documentation alone. Exact
URLs, headers, bodies, refresh transitions, stream framing, and errors are part
of the interface.

## No fallback

Never switch provider, model, protocol, endpoint, authentication source, or
execution mode after a failure. Missing credentials, unsupported capabilities,
unknown stream events, malformed payloads, and upstream drift fail explicitly.

## Credentials

Never commit credentials, raw authorization headers, token-bearing fixtures,
or unsanitized provider responses. Live authenticated tests are opt-in and must
not run in ordinary CI.

## Completion evidence

Run `swift test` and `./Scripts/check-upstream.sh`. A provider is not supported
until its request encoding, stream decoding, authentication lifecycle,
cancellation, and explicit failure behavior all have contract coverage.

A macOS CLI test cannot establish iOS runtime support. Use an actual Simulator
XCTest for Apple-runtime claims. Live tests require explicit opt-in and may emit
only safe metadata; browser completion alone is not authorization success.
