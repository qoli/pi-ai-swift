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
