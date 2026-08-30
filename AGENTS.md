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

1. Read `Upstream.lock.json` and the provider's entry in
   `UpstreamMappings/pi-ai.json`.
2. Compare the pinned revision with the proposed upstream revision.
3. Inspect only the allowlisted provider, auth, protocol, and event paths first.
4. Update sanitized fixtures before changing Swift implementation.
5. Prove TypeScript-to-Swift behavioral equivalence through differential tests.
6. Update provenance and the exact upstream revision in the same change.

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
