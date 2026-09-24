# Frozen schema 6 catalog evidence

Exact source: `earendil-works/pi` at
`d5629e20489ccf770ed90b5a33941cb3b7ef24d0`.
These files preserve the original catalog snapshot. `Upstream.lock.json` owns
acceptance; the manifest's capture-stage status is not a runtime support claim.

- `responses.json.gz`: eight public, unauthenticated catalog response bodies
  captured on 2026-09-24, with their URLs, statuses and content types. Gzip has
  a fixed zero timestamp. No request authorization or response cookies are saved.
- `manifest.json`: exact source and input/output hashes; complete provider-value
  projection hash; source-derived provenance, not a published npm identity.
- `routing.json`: exact upstream provider enumeration subset containing the
  three real chat/image ID collisions and all four classifier entries. Fields
  were not synthesized. Python replay tests compare this subset to regenerated
  provider output; Swift tests assert runtime projection through the real loader.
- `capabilities.json`: missing classifier implementation inventory, kept separate
  from accepted revision support claims.

With the exact commit already available in a local upstream git repository:

```sh
python3 Scripts/replay-schema6-catalog.py --upstream .build/upstreams/pi \
  --output .build/schema6-candidate/BuiltinCatalog.json
SCHEMA6_UPSTREAM="$PWD/.build/upstreams/pi" \
  python3 -B -m unittest discover -s Scripts/tests
swift test --filter BuiltinProviderRegistryTests
```

If the commit is absent, obtain it explicitly with
`git -C .build/upstreams/pi fetch origin d5629e20489ccf770ed90b5a33941cb3b7ef24d0`.
Replay never fetches source or network data automatically. `SCHEMA6_UPSTREAM`
also accepts a different git cache. Without that explicit source configuration,
ordinary Python tests skip the two candidate integration tests; input integrity
tests still run. Skips are not candidate acceptance.

The replay starts with a new source archive and no generated data. It validates
source, captured response, schema, structure and every provider-file hash before
projecting the upstream provider objects. The final catalog retains all model
types and their metadata. Runtime projection exposes only supported chat/image
operations; classifier records are preserved here but not advertised as chat.
Manifest generation time is excluded from the final projection so replay is
byte-identical. Live refresh is not part of this command.

The exact source permits chat-only providers such as Radius to omit
`getAllModels`; its `getModels` selection is preserved as specified by upstream
`models.ts`, not used as an error fallback.
