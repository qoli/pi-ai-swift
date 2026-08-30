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
