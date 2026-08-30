#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="$repo_root/Upstream.lock.json"
output_file="$repo_root/Sources/PiAIProviderRuntime/Resources/BuiltinCatalog.json"
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
