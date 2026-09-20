# Upstream capability gates

This registry records upstream capabilities that are known but intentionally
not claimed by pi-ai-swift's current provider-runtime seam. A gate is not a
provider fallback and does not make the existing supported surface incomplete.

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
