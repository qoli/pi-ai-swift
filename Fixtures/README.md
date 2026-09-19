# Differential fixtures

A provider is not implemented until this directory contains sanitized fixtures
covering its observable contract. Each provider fixture set must include:

- canonical structured `ProviderRequest` input;
- exact outbound URL, headers with secrets redacted, and JSON body;
- raw response or stream frames with credentials and account identifiers removed;
- expected ordered `ProviderEvent` output;
- authentication transitions for login, refresh, and logout;
- explicit failures for missing credentials, unsupported capabilities, malformed
  frames, and upstream drift.

Fixtures are generated or confirmed against the exact revision in
`Upstream.lock.json`. Do not create provider success fixtures by hand when the
upstream oracle can produce them, and never record live credentials.

Each fixture set must also record:

- upstream repository and full revision;
- upstream source path and test path that establish the behavior;
- provider ID and protocol dialect;
- sanitization transformation and fields removed;
- whether the fixture is deterministic, Simulator-only, or live opt-in;
- the expected Swift terminal result or typed error.

Do not copy JavaScript objects directly and call them fixtures. Serialize the
observable wire request, wire response/frame, state transition, or normalized
event. If an upstream test relies on Node/Bun process state, timers, dynamic
modules, prototypes, or callbacks, first derive a platform-neutral observable
contract or classify it as incompatible under
`Docs/AI_MAINTENANCE.md`.

`Manifest.json` records aggregate provenance for the current executable
protocol fixtures. `Scripts/source-differential.py` executes the pinned source
oracles and rejects request, ordered response-event, or typed-failure drift.
`Scripts/check-differential-coverage.py` prevents a wire area from being marked
landed unless every required case class has executable oracle evidence.
`Differential/RequestBranchInventory.json`,
`Differential/ResponseBranchInventory.json`, and
`Differential/FailureBranchInventory.json` are the branch-semantic coverage
ledgers. Each required source branch records its protocols, variants, source
symbols, expected behavior, and executable case IDs. A protocol may list a case
class in `Differential/Coverage.json` only after every applicable protocol ×
variant cell is covered by a checked-in source input, pinned-source oracle, and
Swift replay test. Runtime-invalid `streamSimple` inputs never count as evidence
for protocol-specific branches; deliberate Swift domain restrictions require a
source-contract oracle plus an explicit typed-failure regression.
`Scripts/differential-manifest.py` separately recomputes aggregate SHA-256
values from the exact pinned upstream source/tests and mapped Swift evidence.
`Scripts/check-upstream.sh` runs all three gates and rejects any missing
protocol, stale pin, or unreviewed fixture change. The fixtures contain no
credentials or raw live responses.
