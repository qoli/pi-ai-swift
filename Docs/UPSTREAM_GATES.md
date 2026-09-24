# Upstream capability gates

This registry records upstream capabilities that are known but intentionally
not claimed by pi-ai-swift's current provider-runtime seam. A gate is not a
provider fallback and does not make the existing supported surface incomplete.

## Candidate schema 6 classifier operations

**Status:** Missing implementation; separate request/result seam design required.
Source candidate: `d5629e20489ccf770ed90b5a33941cb3b7ef24d0`. This does not
change the accepted revision or imply support for the new providers/protocols.

The candidate introduces classifier `state` and `questions` (choice, score,
bool), returning typed answers with probabilities/confidence. Current
`ProviderRequest` messages/tools and text/image output selection cannot represent
this contract directly; `ProviderEvent` has no classifier result. Do not disguise
the operation as chat, tools or a JSON string. Track TypeSafe, OpenRouter and
Cloudflare classifier models and authentication separately in
`Fixtures/Catalog/Schema6/capabilities.json` until their seam and adapters have
source-derived request/result/error fixtures and acceptance evidence.

The generated catalog keeps these records. The Swift loader selects chat/image
entries for its existing supported runtime surface. Schema 6 catalog generation
and typed identity preservation do not themselves require a public seam change.
See [SCHEMA6_FEASIBILITY.md](SCHEMA6_FEASIBILITY.md) for executed evidence.

## Nullable and ordered header overrides

**Status:** Not representable by the existing string-dictionary declaration.

At candidate `d5629e20489ccf770ed90b5a33941cb3b7ef24d0`,
`utils/headers.ts` deletes a case-insensitive header match when its value is
null, and resolves conflicting case variants within one object by insertion
order. Swift `CustomProvider.headers` and model headers are `[String: String]`:
they cannot encode null deletion or caller insertion order. The source cases in
`Fixtures/Differential/Oracle/candidate-provider-headers.json` demonstrate both
orders and null deletion. Do not invent a sorted winner, add rejection, or
claim those inputs are supported. Exposing them requires an explicit header
representation design, not an implicit maintenance seam expansion.

Cross-scope provider/model replacement is already representable. The kernel
preserves the model scope's case-insensitive precedence for Google and
OpenRouter Images, whose adapters apply that helper to model headers. Bedrock
and Pi Messages use the helper for upstream request-options headers; this does
not authorize changing unrelated Swift adapter header policy.

## Raw provider-event observation

**Status:** Separate public-seam design required; not advertised.

The same candidate adds `onProviderStreamEvent` before normalization. The
current public Swift event enum describes normalized provider results, not raw
events or an executable caller callback. Do not fabricate raw events from a
terminal snapshot or add callback execution implicitly. Existing normalized
event behavior must still be verified at actual emission time, independently
of whether this optional observation capability is exposed.

## Transcript-owned mid-conversation changes

**Status:** Cross-repository design required.

pi-ai 0.86 introduced `TranscriptContext`, mid-conversation system messages,
named prompt sections, and historical tool additions/removals. The Anthropic
adapter can project that history into native `system`, `tool_addition`, and
`tool_removal` wire messages, but the history itself is assembled by the caller.

pi-ai-swift therefore does not mirror `TranscriptContext` or reconstruct tool
availability from a conversation. Its current `ProviderRequest` carries the
caller's fully assembled current system instruction, messages, and tools. A
future coordinated AIReasoningCore/pi-ai-swift design must decide how a caller
supplies historical instruction and tool-lifecycle information before these
capabilities can be advertised.

Provider-owned pieces that already fit the seam remain in scope. In particular,
model capability metadata and Anthropic's `providerThinkingLevel` replay state
are maintained by pi-ai-swift because they directly affect the provider wire
request and can round-trip through existing assistant metadata.

Acceptance for closing this gate requires:

- an explicit caller/runtime ownership design across both repositories;
- a narrow request representation that does not embed an upstream conversation
  engine in pi-ai-swift;
- source-derived fixtures for additions, removals, redefinitions, and
  unsupported-provider behavior; and
- independent verification and release evidence for both repositories.
