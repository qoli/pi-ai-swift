#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="$repo_root/Upstream.lock.json"
output_file="$repo_root/Sources/PiAIProviderRuntime/Resources/BuiltinCatalog.json"
lock_schema="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schemaVersion"])' "$lock_file")"
if [[ "$lock_schema" == 4 ]]; then
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/pi-ai-source-catalog.XXXXXX")"
  trap 'rm -rf "$temporary_root"' EXIT
  evidence_path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceArtifactManifest"])' "$lock_file")"
  python3 "$repo_root/Scripts/replay-schema6-catalog.py" \
    --upstream "${PI_AI_SWIFT_UPSTREAM_CACHE:-$repo_root/.build/upstreams/pi}" \
    --manifest "$repo_root/$evidence_path" --output "$temporary_root/catalog.json"
  python3 - "$lock_file" "$temporary_root/catalog.json" "$output_file" <<'PY'
import hashlib, json, pathlib, sys
lock = json.loads(pathlib.Path(sys.argv[1]).read_bytes())
data = pathlib.Path(sys.argv[2]).read_bytes()
catalog = json.loads(data)
if ('publishedArtifact' in lock or 'publishedArtifact' in catalog
        or catalog['upstreamRevision'] != lock['revision']
        or catalog['upstreamRepository'] != lock['repository']
        or catalog['upstreamPackage'] != lock['package']
        or catalog['sourceArtifact'] != lock['sourceArtifact']
        or hashlib.sha256(data).hexdigest() != lock['generatedCatalogSHA256']):
    raise SystemExit('source-derived catalog differs from accepted lock')
pathlib.Path(sys.argv[3]).write_bytes(data)
PY
  echo "regenerated accepted source-derived catalog"
  exit 0
elif [[ "$lock_schema" != 3 ]]; then
  echo "unsupported upstream lock schema: $lock_schema" >&2
  exit 4
fi
package_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["package"]["name"])' "$lock_file")"
package_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["package"]["version"])' "$lock_file")"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/pi-ai-swift-catalog.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

package_archive="$(cd "$temporary_root" && npm pack "$package_name@$package_version" --silent)"
expected_shasum="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["publishedArtifact"]["shasum"])' "$lock_file")"
actual_shasum="$(shasum "$temporary_root/$package_archive" | awk '{print $1}')"
if [[ "$actual_shasum" != "$expected_shasum" ]]; then
  echo "published artifact shasum mismatch: expected $expected_shasum, found $actual_shasum" >&2
  exit 4
fi
tar -xzf "$temporary_root/$package_archive" -C "$temporary_root"
mkdir -p "$(dirname "$output_file")"
node "$repo_root/Scripts/generate-builtin-catalog.mjs" \
  "$temporary_root/package" \
  "$lock_file" \
  "$output_file"

echo "generated $output_file from $package_name@$package_version"
