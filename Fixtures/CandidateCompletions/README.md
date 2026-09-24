# Candidate OpenAI Completions request evidence

Target: `d5629e20489ccf770ed90b5a33941cb3b7ef24d0`.

`request.json` is emitted by `Scripts/candidate-completions-oracle.mjs`, running
that revision's real `stream` implementation with `onPayload` capture before
network I/O. The script checks the completion source SHA-256; full source-tree
provenance belongs to the candidate acceptance artifacts. Run it with the
repository's upstream TypeScript loader and the candidate source tree:

```sh
node --import ./.build/upstreams/pi/node_modules/tsx/dist/loader.mjs \
  Scripts/candidate-completions-oracle.mjs .build/schema6-upstream \
  > Fixtures/CandidateCompletions/request.json
```

Provider-owned Class B changes and invariant sources:

- `openai-completions.ts` `detectCompat`: unspecified strict-tool support is
  false. Explicit true still emits `function.strict: false` for unconstrained
  tools; explicit false and absent metadata omit that field.
- `convertMessages`: array text blocks with exactly zero length are filtered.
  Empty resulting arrays omit the user message. Whitespace text and images are
  retained. The Swift seam represents user content as arrays; singleton empty
  text therefore follows upstream array semantics.

The 15 cases cross absent/false/true strict metadata with empty arrays,
singleton empty text, multiple empty texts, empty plus whitespace, and empty
plus image. `CandidateCompletionsTests` compares the exact messages and tools
fields. Before adapter changes this test failed with 20 assertion issues
(`.build/schema6-probe/candidate-completions-red.log`). After the scoped adapter
change, the same 15 cases passed (`candidate-completions-green.log`). Re-running
the oracle against the exact Git checkout `.build/schema6-upstream` produced
byte-identical output.

The candidate's added `onProviderStreamEvent` executable callback is an
upstream host observation hook. It is not a new provider wire/event invariant
and does not justify adding a callback to the Swift public seam.
