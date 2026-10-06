# OpenAI Completions content order repair

## Accepted-pin repair

This is a Class B semantic-port repair against accepted upstream
`d5629e20489ccf770ed90b5a33941cb3b7ef24d0` (2026-10-07). The upstream pin,
catalog, public ProviderRuntime seam, credentials and endpoints are unchanged.

The accepted `packages/ai/src/api/openai-completions.ts` appends text,
thinking and tool blocks when they first appear and retains those blocks for
delta, end and terminal events. Wire tool indices identify blocks; they do not
sort the output. Swift previously reconstructed terminal content as text,
reasoning, then tools, and sorted tool completions by wire index.

The private reducer now records first-seen blocks and uses that order for
terminal content and tool completions. Valid metadata-only reasoning establishes
a thinking block immediately. Per-chunk processing follows the accepted source:
text, visible reasoning, tools, then reasoning_details. Existing text aggregation,
signatures, arguments, usage and error handling retain their owners.

## Discriminating evidence

Five synthetic `completions.order-*` cases in
`Fixtures/Differential/Cases/response-rich.json` were frozen before implementation
changes. The existing `Scripts/pi-ai-response-oracle.mjs` executed the accepted
source to generate their complete normalized events and terminal replay in
`Fixtures/Differential/Oracle/response-rich.json`. Existing oracle observations
were checked to be unchanged. Synchronous emission snapshots confirmed stable
source contentIndex values at start, delta and end.

The cases distinguish reasoning-before-text, tool-before-text, metadata-only
thinking-before-text, tools arriving at wire index 5 then 1, and interleaved
reasoning/text deltas. Assertions compare full terminal content order, opaque
reasoning signatures, tool arguments, completion order and usage with the
source oracle. The existing differential test failed with six issues before
the repair and both response differential tests passed afterward.

Actual consumer evidence uses Core's
`testRealCompletionsRuntimeContinuesNativeTextToolsAndRestoredTranscript`:
CustomProviderRuntime and the real OpenAI Completions wire adapter, a deterministic
HTTP streaming transport, and Foundation Models LanguageModelSession. It covers
reasoning-first text, second-turn replay, Tool execution and continuation, unique
canonical entry IDs, Codable restoration and another provider request. The test
reproduced duplicate IDs and invalidTranscript on Pi `44c079d`; it passed against
the repaired local source. This source result is separate from remote integration
and live oMLX acceptance.

## Verification

- Accepted baseline and repaired exact-candidate signal: YES. Final accepted
  signal: YES. No checker or source lock was weakened.
- 169 macOS CLI tests passed. The other two Keychain tests encountered -25308
  in the CLI execution context and both passed under Xcode MCP with My Mac.
  Initial oracle tests ran before cache dependency preparation had completed;
  the dependency-ready run passed. No Keychain settings or access controls changed.
- Recursive Swift format lint and diff check passed.
- Generic iOS Simulator build passed for arm64 and x86_64.
- Core local-source suite: 53 tests passed, including the actual-runtime consumer
  regression. Simulator consumer and remote/live receipts belong to Core and
  SwiftChat's coordinated acceptance, rather than this source-only receipt.
- `Fixtures/Manifest.json` was regenerated from the exact accepted source and
  affected evidence; `wire-openai-completions` maintenance notes were updated.

Coverage is bounded to the frozen cases. ProviderEvent text/reasoning deltas do
not expose upstream logical block indices. Core's generic native live mapping
therefore has separate metadata-only and interleaved-block identity limitations;
this provider repair does not claim to resolve that consumer seam for every
protocol. The demonstrated oMLX reasoning-then-text and Tool round are verified
through the actual consumer test. No fallback or automatic resend was added.
