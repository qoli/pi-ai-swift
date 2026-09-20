# pi-ai-swift upstream maintenance

Maintain `pi-ai-swift` as a native Swift semantic port of the provider runtime
in `earendil-works/pi/packages/ai`.

## Inputs

- Repository: use the current `pi-ai-swift` checkout, normally
  `/Volumes/Data/Github/pi-ai-swift`.
- Accepted revision: read `Upstream.lock.json`.
- Candidate revision: use the revision supplied by the caller. If none is
  supplied, resolve the upstream repository's current default-branch `HEAD`
  without modifying the checkout.

## Signal contract

Run:

```sh
./Scripts/check-upstream.sh --candidate <candidate-revision>
```

- `YES` means the checked-in maintenance state already covers that exact
  candidate. Report the accepted and candidate revisions, make no changes, and
  stop.
- `NO` is only a maintenance trigger. It is not a diagnosis and does not
  authorize weakening or editing the checker.

Use `./Scripts/check-upstream.sh --explain` only to diagnose the accepted state.
The signal script must not perform semantic analysis or modify repository state.

## Required workflow after NO

1. Read `AGENTS.md`, `Docs/AI_MAINTENANCE.md`, `Docs/ARCHITECTURE.md`,
   `Upstream.lock.json`, `UpstreamMappings/pi-ai.json`, and the differential
   coverage inventories.
2. Inspect the worktree and preserve unrelated user changes.
3. Verify the accepted baseline before changing the pin:
   - `./Scripts/check-upstream.sh`
   - `swift test`
   - `swift format lint --recursive Sources Tests Package.swift`
   - `xcodebuild -scheme PiAIProviderRuntime -destination 'generic/platform=iOS Simulator' build`
   - `git diff --check`
4. Fetch the exact candidate without treating it as accepted. Compare the
   accepted and candidate revisions across mapped source paths, reachable
   imports, upstream tests, provider and protocol inventories, package metadata,
   and changelog.
5. Apply the ownership filter before A/B/C/D classification. Separate:
   - provider-owned capability, authentication, wire, event, usage, replay, and
     provider-failure semantics;
   - caller/session-owned transcript, system-prompt, prompt-section, tool-set,
     persistence, and agent behavior; and
   - Node/Bun/Workers or other upstream host implementation.
6. Classify only provider-owned observable changes using the mandatory Class
   A/B/C/D definitions in `Docs/AI_MAINTENANCE.md`. An upstream public type or
   adapter import does not establish Swift ownership.
7. Present a concrete modification plan mapping each provider-owned upstream change to its
   owning mapping area, Swift implementation, source-derived fixture, regression
   tests, and acceptance gates. The plan is a working artifact, not an approval
   pause for Class A/B work.
8. Continue automatically for Class A mechanical changes and Class B
   representable semantics. Stop for user direction only when a Class C policy,
   security, public-interface, credential, entitlement, billing, or authorized
   live-test decision is genuinely required. End as `upstream_incompatible` for
   Class D rather than substituting another behavior.
9. Freeze sanitized source-derived fixtures from the exact candidate before or
   together with implementation changes. Do not hand-write an expected success
   result when the candidate source can execute as the oracle.
10. Modify the smallest owning Swift adapter. Never introduce a provider, model,
   protocol, endpoint, authentication, retry, execution-mode, or data fallback.
    Do not copy upstream `Context`, `TranscriptContext`, prompt-section merging,
    tool-lifecycle reconstruction, assistant-frame persistence, or other
    caller/session assembly into pi-ai-swift. If a new provider capability needs
    information absent from `ProviderRequest`, record a cross-repository gate
    and keep the seam unchanged during this maintenance run.
11. Update every affected maintenance artifact in the same scoped change:
    `Upstream.lock.json`, `UpstreamMappings/pi-ai.json`, `Fixtures/Manifest.json`,
    branch inventories, generated catalog/provenance, tests, fixtures, and
    affected documentation.
12. Keep working until all deterministic evidence is closed. Do not stop at a
    truthful `partial` state when the remaining Class A/B work is implementable.
13. Run final acceptance:
    - `./Scripts/check-upstream.sh`
    - `./Scripts/check-upstream.sh --candidate <candidate-revision>`
    - `swift format lint --recursive Sources Tests Package.swift`
    - `swift test`
    - `xcodebuild -scheme PiAIProviderRuntime -destination 'generic/platform=iOS Simulator' build`
    - `git diff --check`

Both signal invocations must return `YES` before reporting `compatible`.

## Terminal states

Finish in exactly one state defined by `Docs/AI_MAINTENANCE.md`:

- `compatible`
- `no_relevant_change`
- `needs_review`
- `upstream_incompatible`
- `verification_failed`

For any state other than `compatible` or `no_relevant_change`, keep the accepted
pin and supported-provider claims unchanged.

## Completion report

Report the previous and candidate revisions, upstream intent changes, affected
mapping areas, implementation and fixture changes, final YES/NO signals, test
and build results, whether the accepted pin moved, and any remaining decision or
incompatibility. Confirm that no fallback was added. Do not commit, push, tag,
release, use credentials, or make paid calls unless separately authorized.
