# Upstream check on 2026-09-24

Mode: routine revision sync assessment. Terminal state: `verification_failed`.

**Follow-up:** The later [schema 6 feasibility probe](SCHEMA6_FEASIBILITY.md)
successfully generated and replayed exact-source data with frozen public inputs.
The subsequent tooling stage preserved those inputs, implemented typed catalog
projection and passed macOS/Simulator checks without changing the accepted pin.
The acquisition gap below describes the initial check, not a current claim that
schema 6 cannot be obtained. The [subsequent sync](UPSTREAM_SYNC_2026-09-25.md)
completed the remaining acceptance and moved the pin; this initial failed
assessment is retained as history.

- Accepted: `19451accdeec671c1f4da9eafac8fc270f510ef4` (0.86.1).
- Exact remote default-branch HEAD, resolved with `git ls-remote --symref`:
  `d5629e20489ccf770ed90b5a33941cb3b7ef24d0` (package version 0.87.1,
  with additional unreleased changes).
- Accepted signal: `YES`; exact-candidate signal: `NO`.
- Accepted baseline: 163 macOS tests passed, Swift format lint passed, generic
  iOS Simulator production build passed, and `git diff --check` passed.
  No new Simulator runtime or live-provider acceptance is claimed.

## Candidate evidence gap

The exact candidate's `packages/ai/scripts/model-data.ts` requires generated
model-data schema 6. Its generated provider modules import untracked JSON data,
including `providers/data/typesafe.json`; the source commit does not contain
that generated catalog. Existing `Scripts/generate-builtin-catalog.sh` consumes
a published npm artifact, and its generator still uses the separate
`builtinImagesProviders` surface removed by the candidate.

The registry's `@earendil-works/pi-ai@0.87.1` identifies gitHead
`f07218c4d4bbc12bef056a7058c3dd49dfe41abe`, not the candidate. Its archive has
SHA1 `7d1f174120d5e6d33f301503677ec3281f217e2a`. Direct inspection of
`dist/providers/data/.manifest.json` found schema 3 and structure hash
`c6acf0a192036dd24f23414d3064d4ebbec194485398fee5b9def0b4d86a0095`;
the archive contains no TypeSafe model-data JSON.

Therefore this published artifact cannot establish exact-candidate catalog
provenance. The candidate's hydration script obtains external model catalogs;
executing it is not proof of the original candidate's generated data without
recording and validating those inputs. This run did not establish an alternative
reproducible catalog source. This is a verification gap, not evidence that Swift
cannot implement the behavior, and not a request for security-policy approval.

## Source-reviewed differences and subsequent work

| Area / exact candidate paths under `packages/ai` | Ownership and disposition | Required evidence or decision |
| --- | --- | --- |
| `src/api/openai-completions.ts` | Provider wire, Class B: strict mode defaults to false; empty array-form user text parts are removed | Source oracle for unknown versus explicitly capable endpoints, and image-only/empty messages |
| `src/api/anthropic-messages.ts` | Provider wire/usage, Class B: updated Claude Code version and delta-time one-hour cache-write accounting | Exact headers and `test/anthropic-cache-write-1h-cost.test.ts` usage/pricing cases |
| `src/utils/headers.ts` | Provider wire, Class B: case-insensitive merge and null deletion across header sources | Case-colliding names and deletion fixtures at outbound dispatch |
| `src/models.generated.ts`, `src/model-catalog.ts`, `src/providers/*.models.ts`, `scripts/model-data.ts` | Provider catalog, Class A data plus Class B schema/projection | Exact-candidate catalog provenance and operation-specific identity; migrate generator without relabeling the old artifact |
| `src/types.ts`, `src/models.ts`, `src/image-models.ts`, `src/providers/all.ts` | Provider model/image operation semantics; upstream collection organization is not automatically a Swift public API target | Verify existing chat/image wire invariants against unified model types; do not copy collection APIs merely to mirror TypeScript |
| `src/types.ts` and adapter `onProviderStreamEvent` calls | Provider raw-event observation absent from the current normalized Swift event seam | Separate public-seam design gate; do not synthesize raw events from terminal snapshots or claim this capability |
| `src/providers/typesafe.ts`, `src/api/typesafe-system-one.ts`, `src/api/cloudflare-workers-ai-system-one.ts`, `src/api/system-one-shared.ts` | Newly discovered TypeSafe provider and classifier protocols; not implemented or advertised | Missing candidate capability: model/auth/wire fixtures plus separate classifier request/result seam design; do not encode classifiers as chat |
| `src/types.ts` input limits | Provider-owned metadata; image preprocessing remains caller-owned | Preserve source metadata when catalog provenance closes; expose missing caller information only through separately designed seams |
| `src/auth/resolve.ts` error-class relocation | Internal source organization | Verify error equivalence; no new local authentication policy |

These are candidate findings, not promoted accepted mapping entries. The accepted
ledger and source lock remain tied to 0.86.1. Full hunk classification, candidate
fixture freezing, implementation, and differential acceptance remain unfinished;
this assessment does not claim candidate compatibility. New classifier and raw
event capabilities cannot silently expand the public seam during this run.

Resume by establishing reproducible schema-6 candidate catalog evidence, then
complete the per-hunk inventory, source oracles and Swift regressions before
moving the pin. No Swift implementation, accepted pin, supported-provider claim,
fallback, credentials, billable calls, commit, push, or release changed in this
check. This report is not consumer or distributed-product integration evidence.
