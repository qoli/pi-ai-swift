# Custom provider HTTP endpoint repair

Accepted-pin defect repair at `19451accdeec671c1f4da9eafac8fc270f510ef4` (0.86.1).
The upstream revision and catalog provenance are unchanged.

The endpoint is provider-owned request routing, already expressible through the
custom provider/model `baseURL`; it does not require caller assembly or a public
seam change. The source behavior is Class B. Removing the Swift-only HTTPS policy
is an explicit user-authorized Class C policy decision (2026-09-24: remove the
HTTPS requirement rather than classify localhost, LAN, or public hosts).

The exact accepted `models.ts` createProvider retains the declared baseUrl, and
`api/openai-completions.ts` supplies it to the OpenAI SDK unchanged. Neither
performs the Swift-only loopback restriction. No upstream sync is attempted.

## Source-derived evidence

`Fixtures/Differential/Cases/custom-provider-endpoints.json` supplies .local,
private IP, public host, IPv4/IPv6 loopback, HTTPS, ports, and nested base paths.
The oracle executes the exact accepted source with a synthetic fetch response,
records the actual outbound URL at fetch time, and performs no network calls.
The frozen output is `Fixtures/Differential/Oracle/custom-provider-endpoints.json`.

```sh
node --experimental-strip-types Scripts/pi-ai-custom-endpoint-oracle.mjs \
  "$PWD/.build/upstreams/pi" Fixtures/Differential/Cases/custom-provider-endpoints.json
swift test --filter 'CustomProviderRuntimeTests|ProviderRuntimeKernelTests'
```

`preservesExplicitHTTPAndHTTPSEndpointsThroughProductionAdapter` replays each
URL at both provider and model override levels through the production adapter,
asserting exact scheme/host/port/path and successful stream completion (12 cases).
The pre-repair test failed at .local construction with the loopback restriction;
after removing both constructor and kernel restrictions it passes.
`defaultBuiltinEndpointPolicyStillRejectsHTTP` proves the default built-in policy
still rejects HTTP before wire dispatch. Unsupported schemes and missing base
URLs still fail explicitly. No fallback, retry, DNS rewrite, or credentials were
added. Fixture keys are synthetic.

Source SHA-256 at the unchanged accepted revision:

- `packages/ai/src/models.ts`: `84f2799b0bf45fb01237c5c2c19641b0da5d1245670b208c05bacb5cff36b96f`
- `packages/ai/src/api/openai-completions.ts`: `b06508ab22b6595d85d636db0737ac7c48adbf9d8d5ff61ba2bac94c9599ac51`

## Verification on 2026-09-24

- Baseline: 161 macOS tests, formatting, exact accepted signal, and iOS build passed.
- Repaired: 163 macOS tests passed; the targeted two suites passed all 10 tests.
- Both accepted and exact accepted-revision signals returned `YES`.
- Source oracle rerun exactly matched the frozen output; fixture-manifest sources
  and existing wire fixtures did not change, so their recorded hashes remain valid.
- Generic arm64 and explicit x86_64 iOS Simulator production builds passed.
- The same two test source files passed all 10 tests in an iPad Simulator process
  through a temporary package harness. The only test adaptation was locating the
  bundled fixture via `Bundle.module` instead of the repository path. Xcode's
  package library scheme has no test action, so the harness supplied one; no
  production code or product dependency pin was overridden.
- `swift format lint` and `git diff --check` passed. Only synthetic fixture input
  and credentials were used; no provider network or live authorization calls ran.

Package repair is compatible within these endpoint cases. Consumer/remote-product
integration remains pending separately authorized dependency publication and
SwiftChat acceptance. This is not evidence that a released app contains the fix.
