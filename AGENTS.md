# pi-ai-swift maintenance contract

## Scope

This repository is a native Swift semantic port of the provider runtime in
`earendil-works/pi/packages/ai`. Keep it independent from agent loops, tool
execution, product UI, browser/document tools, AIReasoningCore, AnyLanguageModel,
and shell runtimes.

## Public seam

Preserve the three-operation `ProviderRuntime` interface unless a concrete,
verified upstream capability cannot be represented through it. Internal seams
must not leak merely to make tests easier.

## Upstream work

Read `Docs/AI_MAINTENANCE.md` before changing the upstream pin, a provider
adapter, authentication, normalized events, or reconstruction logic. Its sync
terminal states and change classes are mandatory.

Maintenance is initiated explicitly by a human and may be irregular; do not
create a scheduler or unattended sync mechanism. Treat
`UpstreamMappings/pi-ai.json` as the durable maintenance IR. A newly discovered
built-in provider must first be recorded as `missing` with its provider, model,
wire-protocol, authentication, test, and planned Swift ownership. A later,
separately initiated implementation task promotes that area only with executable
evidence. The IR is not runtime configuration and does not advertise support.

1. Read `Upstream.lock.json` and every affected area in
   `UpstreamMappings/pi-ai.json`.
2. Compare the pinned revision with the proposed upstream revision.
3. Inspect the tracked built-in provider inventory, mapped source paths,
   relevant upstream tests, and the changelog.
4. Classify every relevant hunk before editing Swift.
5. Update sanitized fixtures before changing Swift implementation.
6. Prove TypeScript-to-Swift behavioral equivalence through differential tests.
7. Run macOS tests, iOS compile/runtime gates, and any explicitly authorized
   live test required by the affected behavior.
8. Update each affected area's Swift paths, planned paths, upstream paths,
   tests, and truthful status in the same change.
9. Update provenance and the exact upstream revision in the same change.

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
