# Upstream review: 2026-10-30

## Result

**`needs_review` — candidate inspected, implementation sync not accepted.**

This is an ordinary revision-sync assessment, not an accepted-pin defect
repair. The candidate adds a provider retry/fallback policy for an input the
Swift runtime already represents. The maintenance contract classifies that
policy as Class C and requires an explicit decision before adoption. The
candidate also adds tool-argument error semantics that need a coordinated
consumer-contract decision. No production Swift, accepted fixtures, catalog,
mapping claims, package resolutions, or upstream pin changed in this review.

| Item | Revision |
| --- | --- |
| Accepted pi-ai | `d5629e20489ccf770ed90b5a33941cb3b7ef24d0` |
| Proposed pi-ai | `86dc686cf2fd795b2b24af3d614bb0e1307bcd76` |
| Accepted package | `@earendil-works/pi-ai` 0.87.1 plus its pinned unreleased changes |
| Proposed package | `@earendil-works/pi-ai` 1.4.0 plus its candidate unreleased changes |
| pi-ai-swift checkout | `52b206b` on `main` |
| AIReasoningCore checkout | `0f9affac489bf3b23e307bb226eeb457bec3b04d` on `main` |

The proposed revision was resolved with
`git ls-remote --symref https://github.com/earendil-works/pi.git HEAD`;
`HEAD` named `refs/heads/main`. The exact commit was fetched into the existing
ignored source cache, then inspected from an archive under
`/tmp/pi-ai-candidate-86dc686c`. No branch or Git worktree was created or
switched. The candidate's HEAD commit itself concerns the TUI; relevant AI
changes are established by the package diff, not that commit's title.

## Decision 1: preferred strict-tool rejection

Affected mapping areas: `wire-anthropic-messages`,
`wire-bedrock-converse-stream`, and `wire-common`.

Exact candidate sources:

- [Anthropic request loop](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/api/anthropic-messages.ts#L649).
- [Bedrock request loop](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/api/bedrock-converse-stream.ts#L278).
- [Shared strict-tool predicates](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/api/constrained-sampling.ts).
- [Anthropic regression tests](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/test/anthropic-strict-tool-fallback.test.ts).
- [Bedrock regression tests](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/test/bedrock-strict-tool-fallback.test.ts).

The proposed behavior is narrowly defined:

1. Build the normal request, including strict schemas for eligible `prefer`
   and `require` tools.
2. On an initial provider rejection, retry only if a preferred strict tool was
   actually sent and the provider error is the source-defined strict grammar,
   tool-count, or union-parameter limit error.
3. Anthropic requires its API error with status 400 and
   `invalid_request_error`. Bedrock requires its service
   `ValidationException`. Matching error text alone is insufficient.
4. On the second attempt, restore the original non-strict schemas for `prefer`
   tools, preserving strict schemas for `require` tools. Keep provider, model,
   endpoint, protocol, and authentication unchanged.
5. Do not retry a second rejection, unrelated validation errors, cancellation,
   or an error after streaming has started. The change applies to one request;
   it does not disable strict tools on later requests.

`ProviderStrictPreference.prefer` and `.require` already exist. Thus this is
provider-owned observable behavior for an expressible input, not an optional
new host subsystem. Class B would be inappropriate: a second network attempt
and changed constraints are precisely the retry/fallback policy named under
Class C in `AI_MAINTENANCE.md`. The repository also explicitly forbids adding
fallback without a current-task request for that behavior.

The concrete decision is whether this maintenance run may adopt exactly that
bounded upstream policy. It would not authorize general HTTP retries or any
provider/model/protocol/authentication fallback. Preserving the old failure
while claiming candidate parity would also be incorrect.

After approval, the owning patch belongs in the two wire adapters and the
shared constrained-sampling resolver. Its source-executed differential cases
must capture both request bodies and the attempt count, preserving the negative
cases listed above. Show a failing Swift regression before the patch or a
targeted mutation afterward. Any live verification remains separately opt-in.

## Decision 2: malformed terminal tool arguments

Affected mapping areas: `canonical-request-event-dtos`, all affected tool-stream
adapters, and the consumer's tool-call mapping.

The candidate's
[ToolCall contract](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/types.ts#L445),
[final argument parser](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/utils/json-parse.ts#L98),
and [stream state](https://github.com/earendil-works/pi/blob/86dc686cf2fd795b2b24af3d614bb0e1307bcd76/packages/ai/src/utils/streaming-json.ts#L447)
distinguish partial previews from final arguments. Invalid completed arguments
produce `arguments: {}` together with `argumentsError`; the error includes the
received argument text. Blank input still produces `{}` without an error.
Incremental parser state stays outside normalized content blocks.

`ProviderToolCall` currently has no declared argument-error field.
AIReasoningCore's `PiAIProviderMapper.transcriptToolCall` converts its arguments
directly to a canonical Tool call. Its arbitrary provider metadata dictionary
is not an existing agreement for preventing execution or returning a validation
error to the model. Merely hiding this error in metadata, executing `{}`, or
turning the complete request into a different failure would not reproduce the
upstream lifecycle.

Record this as a public-contract/consumer design gate. A coordinated task must
decide how a failed argument parse reaches native and compatibility Session
validation, preserving provider/session ownership. It must use the actual
provider runtime through Core and prove that malformed arguments cannot execute
a Host tool. Do not add tool execution to pi-ai-swift. The three runtime
operations need not change; the DTO and consumer error contract still require
an explicit design decision.

### Executed candidate-source observations

The exact candidate's exported `parseToolCallArguments` and
`isStrictToolLimitErrorMessage` functions were executed directly with synthetic
inputs on Node 26.0.0. `partial-json` 0.1.7 matched the candidate lockfile. No
provider transport, credential, or account was used.

| Input | Actual source result |
| --- | --- |
| `{"path":"fixture","content":"ok"}` | Complete object, no `argumentsError` |
| `{"path":"fixture","content": invalid}` | `{}` and an error retaining the synthetic received text |
| `[1,2]` | `{}` and `Tool arguments must be a JSON object` |
| `null` | `{}` and `Tool arguments must be a JSON object` |
| Whitespace only | `{}`, no error |
| Each of the three source strict-limit message prefixes | Strict-limit predicate returns `true` |
| Unrelated validation error | Strict-limit predicate returns `false` |

The observation file is `/tmp/pi-sync-candidate-observations.json`. Its exact
source digests are:

- `api/constrained-sampling.ts`:
  `0b161cd538e95907e78e7223aba629f7741e6e0c4ebf3c19bbe36854dffa5e65`.
- `utils/json-parse.ts`:
  `b101d288394a45498a50e06966c753ffb55a2b4900bec24ecbecafb7c17591bd`.

These observations demonstrate the decision inputs. They do not establish
Swift parity, execute the complete upstream adapter retry loops, or constitute
accepted fixture evidence. Engine-specific parser error wording is not a
portable contract.

## Remaining sync inventory and modification plan

This is a resume plan. Complete the hunk-by-hunk ownership/classification and
freeze exact-source fixtures before editing Swift; this review does not claim
that the full candidate audit or its acceptance matrix is complete.

| Upstream intent | Ownership / classification | Owning Swift work and evidence |
| --- | --- | --- |
| Catalog generator moves to `catalog/`, models.dev v2, new models/prices/tiers and model filtering | Provider data A; compat rules affecting wire behavior B | Replace moved source provenance, rebuild schema 6 from frozen public responses using the exact generator, compare complete catalog values and typed inventory; do not relabel old model data |
| Azure provider changes from `azure-openai-responses` to `azure`, gains Chat Completions | Provider registration/wire B; examine credential-key consequences before migration | Registry, model store, Azure configuration and completion routing; deployment name affects wire model while normalized identity remains the catalog model; no silent alias/migration |
| Kimi Coding changes to Chat Completions at `/coding/v1`; K3.1 request/replay and effort rules change | Provider wire B | Registry/catalog routing plus completion request, reasoning/replay, auth/header fixtures; retain exact OAuth ownership |
| Gemini 4 thinking levels; Gemini schemas convert `const` to `enum` while preserving literal values | Provider wire B | Google/Vertex request fixtures for family-specific disabled/enabled reasoning and nested schemas containing literal objects |
| Bedrock GPT reasoning, Anthropic effort, Mistral reasoning and empty chunk behavior; Xiaomi thinking toggle | Provider wire/event B | Owning adapters, model-specific reasoning fixtures, emission-time event order, replay and stop/failure cases |
| Anthropic/Bedrock error tool images move after the turn's tool results; whitespace-only tool results use protocol placeholders | Provider projection B for existing request inputs | Mixed consecutive tool-result fixtures preserving IDs, ordering, images, error flags, and non-error cases |
| Cross-model thinking is dropped rather than rendered as answer text | Provider replay projection B for existing source-tagged assistant messages | All affected replay adapters; same-model signed/redacted cases and cross-model removal cases |
| OpenCode protocol endpoints; OpenRouter latest Claude aliases; GPT-5.4/5.5 tool placement | Provider routing/wire B | Catalog and request fixtures proving exact protocol/URL and top-level tool declarations; no protocol inference from model names |
| Incremental tool arguments, malformed final arguments, Responses unfinished tool rejection, Pi content-index checks and terminal reported model | Provider event B where representable; argument-error contract gate above | Per-protocol event-time fixtures, immutable previews, final validation, stable requested identity, malformed/error/cancellation cases |
| OpenRouter reported cost and `totalFromProvider`; service-tier `fast`; prompt-length cost tiers | Provider usage B; explicit provenance flag exposure needs DTO review | Usage reducer and monetary differential cases with reported and calculated values deliberately unequal |
| Per-thinking-level sampling overrides; new reasoning capability metadata | Provider B | Model-store persistence and merged request options, including caller precedence and disabled effort |
| OAuth refresh survives caller cancellation after rotation | Provider auth; C for any changed refresh ownership/persistence policy | Existing Swift coordinator already uses an independent flight and persists before reporting caller cancellation; source-derived timing tests must establish remaining differences rather than assume a wholesale rewrite |
| Anthropic copy-code login/federation, Sign in with ChatGPT, device identity/login options | Auth/security C if adopted; optional capabilities need truthful inventory | Separate auth/credential and live-account decisions; no automatic credential-source or browser-flow fallback |
| Retry classifications, strict downgrade retries, callback server fallback and URL trust changes | Inspect provider consequences; retry/security decisions C | Preserve current no-fallback policy until an exact scoped decision; shared-helper extraction alone is not automatically a new Swift security policy |
| Classifier additions (`llama-cpp-classify`, `openai-decisions`) and image inputs | Separate classifier request/result gate, currently unsupported | Extend candidate inventory before a future accepted sync, retain missing support claims; do not encode classification as chat or tools |
| Transcript/tool history, mid-conversation system/effort/tool assembly, assistant-frame removal | Caller/session-owned | Keep assembly in Core/Host; inspect only final wire effects for currently representable requests |
| Node/Bun callback servers, CLI auth-file permissions, packaging and telemetry infrastructure | Upstream host implementation unless a provider-visible contract crosses the existing seam | Do not import the host runtime; separately assess provider identity/attribution headers rather than dismiss all header changes as host-only |

Candidate provenance needs to cover the new `catalog/` source closure,
`providers/compat-schema.ts`, `providers/model-schema.ts`,
`api/azure-openai-config.ts`, `utils/streaming-json.ts`, `utils/identity.ts`,
`utils/openrouter-cost.ts`, moved OAuth-page code, and relevant new tests.
Existing mappings reference removed generator and Azure provider paths. Updating
the accepted lock alone cannot establish compatibility, and the checker must
not be changed to bypass missing source or evidence.

## Verification and unchanged acceptance boundary

The verification-before-completion skill was applied: only the commands below
establish the status claims here.

| Gate | Result |
| --- | --- |
| Accepted `./Scripts/check-upstream.sh` | `YES` |
| Exact candidate signal | `NO`, expected because the accepted pin is unchanged |
| `swift test` | 171 tests in 43 suites passed |
| `swift format lint --recursive Sources Tests Package.swift` | Passed |
| Xcode MCP `BuildProject` with `PiAIProviderRuntime`, generic iOS Simulator | Passed |
| `xcodebuild -scheme PiAIProviderRuntime -destination 'generic/platform=iOS Simulator' build` | Passed |
| `git diff --check` | Passed |

Logs: `/tmp/pi-sync-baseline-check.log`,
`/tmp/pi-sync-baseline-tests.log`, `/tmp/pi-sync-baseline-ios.log`.
The Xcode workspace identifier was obtained by listing/opening the package,
then used for scheme, destination and build calls. No physical device was run.

These are checks of the accepted Swift implementation, not candidate acceptance.
Candidate Swift regressions, red/green evidence, reconstructed catalog,
arm64/x86_64 final compile gates, actual Simulator XCTest, consumer integration,
and any separately approved live auth/generation evidence remain unclosed.
No local consumer override was installed. AIReasoningCore's remote-main
resolution and distributed-product integration remain unchanged.

The accepted upstream pin remains `d5629e20489ccf770ed90b5a33941cb3b7ef24d0`.
No fallback, credential use, paid API call, commit, push, tag, or release was
performed. Resume from the two concrete decisions above, then complete the
authorized implementation and all required evidence before accepting the exact
candidate.
