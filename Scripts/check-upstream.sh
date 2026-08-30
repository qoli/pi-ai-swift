#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="$repo_root/Upstream.lock.json"
cache_root="${PI_AI_SWIFT_UPSTREAM_CACHE:-$repo_root/.build/upstreams/pi}"

if [[ ! -f "$lock_file" ]]; then
  echo "missing upstream lock: $lock_file" >&2
  exit 2
fi

readarray_output="$({
  python3 - "$lock_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    lock = json.load(handle)

required = ["repository", "revision", "package", "requiredSourcePaths"]
for key in required:
    if key not in lock:
        raise SystemExit(f"malformed upstream lock: missing {key}")

revision = lock["revision"]
if not isinstance(revision, str) or len(revision) != 40:
    raise SystemExit("malformed upstream lock: revision must be a full 40-character commit")

package = lock["package"]
for key in ["path", "name", "version"]:
    if key not in package or not isinstance(package[key], str) or not package[key]:
        raise SystemExit(f"malformed upstream lock: package.{key} is required")

print(lock["repository"])
print(revision)
print(package["path"])
print(package["name"])
print(package["version"])
for path in lock["requiredSourcePaths"]:
    if not isinstance(path, str) or not path:
        raise SystemExit("malformed upstream lock: requiredSourcePaths entries must be non-empty strings")
    print(path)
PY
} 2>&1)" || {
  echo "$readarray_output" >&2
  exit 2
}

upstream_repository="$(sed -n '1p' <<<"$readarray_output")"
upstream_revision="$(sed -n '2p' <<<"$readarray_output")"
upstream_package_path="$(sed -n '3p' <<<"$readarray_output")"
upstream_package_name="$(sed -n '4p' <<<"$readarray_output")"
upstream_package_version="$(sed -n '5p' <<<"$readarray_output")"
required_paths=()
while IFS= read -r required_path; do
  required_paths+=("$required_path")
done < <(printf '%s\n' "$readarray_output" | tail -n +6)

if [[ -e "$cache_root" && ! -d "$cache_root/.git" ]]; then
  echo "invalid upstream cache: $cache_root exists but is not a Git checkout" >&2
  exit 3
fi

created_cache=0
if [[ ! -d "$cache_root/.git" ]]; then
  mkdir -p "$(dirname "$cache_root")"
  git clone --filter=blob:none --no-checkout "$upstream_repository" "$cache_root"
  created_cache=1
fi

configured_remote="$(git -C "$cache_root" remote get-url origin)"
if [[ "$configured_remote" != "$upstream_repository" ]]; then
  echo "invalid upstream cache remote: expected $upstream_repository, found $configured_remote" >&2
  exit 3
fi

if [[ "$created_cache" -eq 0 ]]; then
  dirty_state="$(git -C "$cache_root" status --porcelain)"
  if [[ -n "$dirty_state" ]]; then
    echo "upstream cache has local changes: $cache_root" >&2
    exit 3
  fi
fi

git -C "$cache_root" fetch --depth 1 origin "$upstream_revision"
git -C "$cache_root" checkout --detach "$upstream_revision"

resolved_revision="$(git -C "$cache_root" rev-parse HEAD)"
if [[ "$resolved_revision" != "$upstream_revision" ]]; then
  echo "upstream revision mismatch: expected $upstream_revision, found $resolved_revision" >&2
  exit 4
fi

package_file="$cache_root/$upstream_package_path/package.json"
if [[ ! -f "$package_file" ]]; then
  echo "missing upstream package manifest: $package_file" >&2
  exit 4
fi

python3 - "$package_file" "$upstream_package_name" "$upstream_package_version" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    package = json.load(handle)

expected_name = sys.argv[2]
expected_version = sys.argv[3]
if package.get("name") != expected_name:
    raise SystemExit(
        f"upstream package name mismatch: expected {expected_name}, found {package.get('name')}"
    )
if package.get("version") != expected_version:
    raise SystemExit(
        f"upstream package version mismatch: expected {expected_version}, found {package.get('version')}"
    )
PY

for required_path in "${required_paths[@]}"; do
  if [[ ! -f "$cache_root/$required_path" ]]; then
    echo "missing required upstream source: $required_path" >&2
    exit 4
  fi
done

echo "verified pi-ai upstream $upstream_revision ($upstream_package_version)"
