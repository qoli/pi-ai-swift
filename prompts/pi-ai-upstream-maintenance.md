# pi-ai-swift upstream maintenance

Maintain `pi-ai-swift` as a native Swift semantic port of the provider runtime
in `earendil-works/pi/packages/ai`.

Intent translation is mechanical work: preserve the exact upstream observable
contract within the ownership boundary. Do not proactively add capabilities,
restrictions, validation, defaults, or safety policies that upstream does not
have. Follow "Mechanical semantic translation only" in `Docs/AI_MAINTENANCE.md`;
Class B permits equivalent native implementation, not behavioral redesign, and
Class C does not authorize inventing local policy.

## Inputs

- Repository: use the current `pi-ai-swift` checkout, normally
  `/Volumes/Data/Github/pi-ai-swift`.
- Accepted revision: read `Upstream.lock.json`.
- Mode: ordinary revision sync, or defect repair for a reported mismatch in an
  already accepted behavior. Do not silently expand a defect repair into sync.
- Target revision: for defect repair, use the accepted revision. For revision
  sync, use the caller's candidate; if none is supplied, resolve the upstream
  repository's current default-branch `HEAD` read-only.
- If both repair and newer sync are requested, track their evidence and terminal
  results separately. A newer-candidate blocker does not block accepted-pin repair.

## Signal contract

Run:

```sh
./Scripts/check-upstream.sh --candidate <target-revision>
```

- `YES` means the checked-in maintenance state already covers that exact
  target. Stop without edits only for ordinary revision checking. For a
  reported defect, continue the repair workflow even on `YES`: the signal does
  not establish semantic correctness.
- `NO` is only a maintenance trigger. It is not a diagnosis and does not
  authorize weakening or editing the checker.

Use `./Scripts/check-upstream.sh --explain` only to diagnose the accepted state.
The signal script must not perform semantic analysis or modify repository state.

## Required workflow after NO or a reported defect

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

   Record any expected failing defect reproduction and continue its scoped
   repair. An unrelated baseline failure blocks acceptance and pin movement;
   isolate it and report it without weakening gates or silently expanding scope.
4. For sync, fetch the exact candidate without treating it as accepted. Compare
   accepted and candidate revisions across mapped source paths, reachable
   imports, upstream tests, provider and protocol inventories, package metadata,
   and changelog. For defect repair, inspect the exact accepted source and its
   tests against the failing Swift behavior; no newer revision is required.
5. Apply the ownership filter before A/B/C/D classification. Separate:
   - provider-owned capability, authentication, wire, event, usage, replay, and
     provider-failure semantics;
   - caller/session-owned transcript, system-prompt, prompt-section, tool-set,
     persistence, and agent behavior; and
   - Node/Bun/Workers or other upstream host implementation.
6. Classify only provider-owned observable changes using the mandatory Class
   A/B/C/D definitions in `Docs/AI_MAINTENANCE.md`. An upstream public type or
   adapter import does not establish Swift ownership.
   Identify exact source evidence for each changed behavior, including accepted
   and rejected inputs. Remove agent-invented additions from the plan; local
   extensions or intentional deviations require a separate explicit user request.
7. Present a concrete modification plan mapping each provider-owned upstream change to its
   owning mapping area, Swift implementation, source-derived fixture, regression
   tests, and acceptance gates. The plan is a working artifact, not an approval
   pause for Class A/B work.
8. Continue automatically for Class A mechanical changes and Class B
   representable semantics. Stop for user direction only when a Class C policy,
   security, public-interface, credential, entitlement, billing, or authorized
   live-test decision is genuinely required. End as `upstream_incompatible` for
   Class D rather than substituting another behavior.
9. Follow the semantic evidence contract in `Docs/AI_MAINTENANCE.md`: record
   field sources, lifecycle, and cross-event invariants; observe oracle events
   at emission time; use discriminating inputs; and demonstrate a failing
   regression or targeted mutation. Freeze fixtures from the exact target
   before implementation changes. Do not hand-write an expected
   success result when the target source can execute as the oracle.
   Check both inputs accepted upstream but rejected by Swift and behavior Swift
   adds beyond upstream. Existing Swift tests and a green signal cannot justify
   either deviation. An unapproved agent-added restriction is a port defect,
   not an established policy requiring renewed approval merely to restore parity.
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
    affected documentation. In defect repair, preserve the accepted revision
    while refreshing affected fixture/source provenance.
12. When a defect crosses the consumer seam, add deterministic actual-runtime
    consumer integration evidence as described in `Docs/AI_MAINTENANCE.md`.
    Keep working until all deterministic evidence is closed. Do not stop at a
    truthful `partial` state when the remaining Class A/B work is implementable.
13. Run final acceptance:
    - `./Scripts/check-upstream.sh`
    - `./Scripts/check-upstream.sh --candidate <target-revision>`
    - `swift format lint --recursive Sources Tests Package.swift`
    - `swift test`
    - `python3 -B -m unittest discover -s Scripts/tests` when maintenance checker code changes
    - `xcodebuild -scheme PiAIProviderRuntime -destination 'generic/platform=iOS Simulator' build`
    - `git diff --check`

Both signal invocations must return `YES` before reporting `compatible`. In
defect repair, the exact target is the accepted pin; a separate latest-candidate
`NO` is not a failure of that repair. Required behavioral gates must still pass.

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

Report the mode, previous and target revisions, upstream intent changes, affected
mapping areas, implementation and fixture changes, final YES/NO signals, test
and build results, whether the accepted pin moved, and any remaining decision or
incompatibility. Bound coverage claims to the named executable cases and
invariants. Distinguish local unpublished consumer checks from remote-main
integration and distributed-product acceptance. Confirm that no fallback was
added. Do not commit, push, tag, release, use credentials, or make paid calls
unless separately authorized.
