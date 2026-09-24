# Schema 6 catalog feasibility

## Current status

**Landed for catalog generation and supported chat/image projection.** Owner:
provider catalog and maintenance tooling. The subsequent full revision sync is
recorded in [UPSTREAM_SYNC_2026-09-25.md](UPSTREAM_SYNC_2026-09-25.md); the probe
and tooling-stage results below preserve their original acceptance boundaries.

Target is `d5629e20489ccf770ed90b5a33941cb3b7ef24d0`, not a moving branch.
The initial probe retained `19451accdeec671c1f4da9eafac8fc270f510ef4`;
the later sync accepted the target after completing the remaining gates.
This investigation supersedes the acquisition blocker in
[the initial check](UPSTREAM_CHECK_2026-09-24.md). Npm artifact mismatch is real,
but does not prevent running the exact upstream generator. The available result
is an exact source revision plus frozen public inputs captured on 2026-09-24;
it is not a recovered snapshot of upstream's historical release inputs.

## Source and artifact trace

All source references below are at the target commit in `earendil-works/pi`.

| Source | Contract and consequence |
| --- | --- |
| `packages/ai/package.json` | `hydrate-model-data` runs the generator with `--strict --data-only`; no package publication is required |
| `packages/ai/scripts/generate-models.ts` | Fetches public catalogs, applies upstream transformations, stages and validates data before replacing it; data-only mode preserves tracked source modules |
| `packages/ai/scripts/model-data.ts` | Schema 6, typed identity keys, provider inventory, structure hash, and per-file hashes |
| `packages/ai/scripts/check-model-data.ts` | Executes the upstream generated-data validator |
| `.github/workflows/publish-model-catalog.yml` | Independently generates catalog JSON from a source ref, validates it, and uploads an artifact; npm is not the only upstream catalog path |
| `scripts/publish-model-catalog.mjs` | Dry-run validates the JSON bundle without uploading |
| `packages/ai/src/models.ts` | `getModels()` remains chat-only; `getAllModels()` includes all operation types |
| `packages/ai/src/utils/model-operations.ts` | Legacy model declarations without type remain chat; generated schema requirements must not become new custom-provider rejection rules |

## Executed probe

An isolated source archive was extracted to `.build/schema6-probe/source`.
The accepted upstream checkout and production catalog were not changed. Node
v26.0.0 executed the original generator without installing dependencies.
The process used an empty environment except PATH and probe configuration,
and no credentials. All eight public catalog responses returned HTTP 200:
models.dev main and decision catalogs, NVIDIA, OpenRouter chat/image/decision
catalogs, Vercel AI Gateway, and Radius public configuration.

The probe captured response bytes, URL, status, content type and SHA-256.
Replay replaces fetch completely and fails if a response is missing or its
digest differs; it has no network fallback. The original generator's strict
mode stayed enabled. No upstream source was patched.

Verified results:

- Schema 6; 42 provider files; 1,518 chat, 57 image and 4 classifier models.
- Structure hash: `53e161de9d88baaa7e561f3594051ed714c8e7a8f52c27c320462da24289f147`.
- Two generations from the same captured inputs have identical structure hash
  and all 42 provider-file hashes. Manifest `generatedAt` is intentionally
  time-dependent and is not claimed byte-identical.
- Upstream `check-model-data.ts` passed.
- Offline `--strict --json-only` export and publisher `--dry-run` passed for
  1,579 models; no objects were uploaded.
- Three OpenRouter IDs occur in both chat and image types:
  `google/gemini-3-pro-image`, `openrouter/auto`, `openrouter/auto-beta`.

[SCHEMA6_PROBE_EVIDENCE.json](SCHEMA6_PROBE_EVIDENCE.json) records source and
input hashes, counts and output hashes from the initial probe. The subsequent
tooling stage preserves all eight bodies in
`Fixtures/Catalog/Schema6/responses.json.gz` (1,115,803 bytes), with their archive
digest, source hashes and complete provider-value projection hash in
`Fixtures/Catalog/Schema6/manifest.json`. Logs remain local. The frozen inputs
now support clean reconstruction without relying on the original probe cache.

Reproduce from frozen fixtures and the exact commit in a local git repository:

```sh
python3 Scripts/replay-schema6-catalog.py --upstream .build/upstreams/pi \
  --output .build/schema6-candidate/BuiltinCatalog.json
SCHEMA6_UPSTREAM="$PWD/.build/upstreams/pi" \
  python3 -B -m unittest discover -s Scripts/tests
```

The replay command creates a fresh temporary source archive and validates all
inputs/outputs without network requests. `SCHEMA6_UPSTREAM` makes the candidate
integration test prerequisite explicit; ordinary Python tests skip those two
integration cases when it is absent. See the fixture README for exact-source
bootstrap. Skipping candidate tests is not acceptance. The capture hook remains
available only for an explicit new snapshot; replay never switches to capture.

## Tooling-stage work inventory (subsequently completed by the sync)

| Workstream | Current state | Evidence required before promotion |
| --- | --- | --- |
| Catalog provenance | Implemented for candidate tooling | Frozen archive plus exact git source rebuild from empty generated-data state; no invented npm identity |
| Generator | Implemented as explicit source path | `generate-source-catalog.mjs` enumerates all types with exact upstream optional-method semantics; full provider-value hash and subset comparison pass |
| Chat/image routing | Implemented and regression-tested | Three actual collisions retain distinct routes; classifier entries never become chat; accepted no-type catalog still passes |
| Metadata | Verified for all candidate supported routes | 1,575 chat/image route objects retain exact metadata; no new limits or preprocessing introduced |
| Classifier inventory | Recorded as missing | Candidate ledger includes all four records, both protocols and authentication ownership; separate seam design remains pending |
| Acceptance tooling | Candidate gate implemented; pin-promotion work pending | Reproducible catalog has explicit `sourceArtifact`; accepted lock/checker still use their npm provenance. Full promotion must migrate source paths, lock provenance and differential oracles together, not weaken the current gate |
| Full candidate semantics | Not verified | Complete hunk classification and source-derived regressions for wire/header/usage changes from the initial check, then the repository acceptance matrix |

Schema 6 storage/projection is representable mechanical work, not inherently a
public-interface or security decision. Swift's existing chat/image routing can
already distinguish output modalities. Classifier `state/questions` and typed
`answers` cannot be silently substituted with chat prompts or JSON strings;
implementing that operation requires a separate seam design. Exposing input
limits to callers is also distinct from retaining them in internal metadata.
Raw provider-event observation is a separate capability, not a prerequisite for
schema 6 generation. None of these additions authorizes copying upstream's
collection API wholesale.

## Tooling-stage acceptance

The new source-derived routing regression failed with 14 assertions against the
old loader because it advertised classifiers as chat. The typed projection
passes that regression and preserves the accepted bundled inventory. Python
tests rebuild twice from clean source archives and compare final catalog bytes,
verify the complete provider-value digest and classifier inventory, and reject
a mutated response body even when the compressed archive digest is recomputed.

A separate local package harness loads the complete candidate catalog through
the actual Swift loader and compares every supported route's metadata; it also
runs the registry tests with fixture lookup adapted to bundled resources.
This validates catalog projection, not candidate provider wire behavior.

Verification on 2026-09-24:

- All 164 macOS package tests passed; the accepted bundled inventory is unchanged.
- All 8 Python tests passed with `SCHEMA6_UPSTREAM` explicitly configured,
  including two candidate integration tests and response mutation rejection.
- A targeted generator mutation using chat-only `getModels()` loses 57 image
  and 4 classifier entries and fails the complete provider-value digest check.
- A temporary harness passed all 4 catalog tests on macOS and in an iPad Pro
  13-inch (M5), iOS 26.5 Simulator process. It used unchanged production sources
  and bundled fixture paths; the full-catalog case checked all 1,575 routes.
- Generic arm64 and explicit x86_64 Simulator production builds passed.
- Swift format lint and `git diff --check` passed.
- Accepted-revision signal remains `YES`; the exact candidate signal remains
  `NO` because full revision acceptance and pin promotion are not part of this
  completed catalog-tooling stage.

Run the accepted checker before Swift tests, not concurrently: it can reinstall
the shared upstream `node_modules` cache. A concurrent run caused three Node
oracle import failures; rerunning the unchanged suite after the checker finished
passed. This was verification orchestration, not a provider behavior repair.

At the end of the tooling stage the bundled catalog and pin remained unchanged. The original npm
generator continues to own accepted regeneration; the new source generator is
an explicit candidate path, not a fallback. Remaining full-revision work is the
wire/header/usage regressions and coordinated lock, provenance and differential
oracle migration. No npm publication is required to make that work possible.
