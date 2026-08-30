#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="$repo_root/Upstream.lock.json"
mapping_file="$repo_root/UpstreamMappings/pi-ai.json"
cache_root="${PI_AI_SWIFT_UPSTREAM_CACHE:-$repo_root/.build/upstreams/pi}"

if [[ ! -f "$lock_file" ]]; then
  echo "missing upstream lock: $lock_file" >&2
  exit 2
fi

if [[ ! -f "$mapping_file" ]]; then
  echo "missing upstream mapping: $mapping_file" >&2
  exit 2
fi

python3 - "$repo_root" "$lock_file" "$mapping_file" <<'PY'
import json
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    lock = json.load(handle)
with open(sys.argv[3], "r", encoding="utf-8") as handle:
    mapping = json.load(handle)

if mapping.get("schemaVersion") != 2:
    raise SystemExit("malformed upstream mapping: schemaVersion must be 2")

areas = mapping.get("areas")
if not isinstance(areas, list) or not areas:
    raise SystemExit("malformed upstream mapping: areas must be a non-empty array")

required_upstream = set(lock.get("requiredSourcePaths", []))
allowed_statuses = {"landed", "partial", "missing", "blocked"}
area_ids = set()
covered_swift_paths = set()

for area in areas:
    if not isinstance(area, dict):
        raise SystemExit("malformed upstream mapping: every area must be an object")
    area_id = area.get("id")
    if not isinstance(area_id, str) or not area_id:
        raise SystemExit("malformed upstream mapping: every area requires a non-empty id")
    if area_id in area_ids:
        raise SystemExit(f"malformed upstream mapping: duplicate area id {area_id}")
    area_ids.add(area_id)

    status = area.get("status")
    if status not in allowed_statuses:
        raise SystemExit(f"malformed upstream mapping: {area_id} has invalid status {status}")
    responsibility = area.get("responsibility")
    if not isinstance(responsibility, str) or not responsibility:
        raise SystemExit(f"malformed upstream mapping: {area_id} requires responsibility")

    for key in ["swiftPaths", "plannedSwiftPaths", "upstreamPaths", "upstreamTestPaths"]:
        values = area.get(key)
        if not isinstance(values, list) or any(not isinstance(value, str) or not value for value in values):
            raise SystemExit(f"malformed upstream mapping: {area_id}.{key} must be a string array")

    swift_paths = area["swiftPaths"]
    if status in {"landed", "partial"} and not swift_paths:
        raise SystemExit(f"malformed upstream mapping: {area_id} is {status} but has no swiftPaths")
    for relative in swift_paths:
        path = repo_root / relative
        if not path.is_file():
            raise SystemExit(f"mapped Swift source does not exist: {area_id}: {relative}")
        covered_swift_paths.add(relative)

    for relative in area["upstreamPaths"] + area["upstreamTestPaths"]:
        if relative not in required_upstream:
            raise SystemExit(
                f"mapped upstream path is absent from Upstream.lock.json: {area_id}: {relative}"
            )

source_root = repo_root / "Sources" / "PiAIProviderRuntime"
actual_swift_paths = {
    str(path.relative_to(repo_root))
    for path in source_root.rglob("*.swift")
}
unmapped = sorted(actual_swift_paths - covered_swift_paths)
if unmapped:
    raise SystemExit("unmapped Swift provider-runtime sources: " + ", ".join(unmapped))
PY

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

if lock.get("schemaVersion") != 2:
    raise SystemExit("malformed upstream lock: schemaVersion must be 2")
if not isinstance(lock.get("trackedBuiltinProviders"), list):
    raise SystemExit("malformed upstream lock: trackedBuiltinProviders must be an array")

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

python3 - "$cache_root" "$mapping_file" "$lock_file" <<'PY'
import json
import pathlib
import re
import sys

cache_root = pathlib.Path(sys.argv[1])
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    mapping = json.load(handle)
with open(sys.argv[3], "r", encoding="utf-8") as handle:
    lock = json.load(handle)

all_source = (cache_root / "packages/ai/src/providers/all.ts").read_text(encoding="utf-8")
imports = dict(
    re.findall(r'import \{ (\w+) \} from "\./([^"/]+)\.ts";', all_source)
)
try:
    builtin_body = all_source.split("export function builtinProviders()", 1)[1].split("];", 1)[0]
except IndexError as error:
    raise SystemExit("could not parse upstream builtinProviders()") from error

provider_factories = re.findall(r"\b(\w+Provider)\(\)", builtin_body)
upstream_providers = {imports[factory] for factory in provider_factories if factory in imports}
mapped_providers = {
    area["providerID"]
    for area in mapping["areas"]
    if isinstance(area.get("providerID"), str)
}
if upstream_providers != mapped_providers:
    missing = sorted(upstream_providers - mapped_providers)
    extra = sorted(mapped_providers - upstream_providers)
    raise SystemExit(
        f"builtin provider inventory drift: missing={missing}, extra={extra}"
    )

locked_providers = set(lock.get("trackedBuiltinProviders", []))
if locked_providers != upstream_providers:
    missing = sorted(upstream_providers - locked_providers)
    extra = sorted(locked_providers - upstream_providers)
    raise SystemExit(
        f"locked provider inventory drift: missing={missing}, extra={extra}"
    )

types_source = (cache_root / "packages/ai/src/types.ts").read_text(encoding="utf-8")
known_api_match = re.search(
    r"export type KnownApi =(?P<body>.*?);",
    types_source,
    flags=re.DOTALL,
)
if known_api_match is None:
    raise SystemExit("could not parse upstream KnownApi")
upstream_protocols = set(re.findall(r'"([^"]+)"', known_api_match.group("body")))
mapped_protocols = {
    area["protocolID"]
    for area in mapping["areas"]
    if isinstance(area.get("protocolID"), str)
}
missing_protocols = sorted(upstream_protocols - mapped_protocols)
if missing_protocols:
    raise SystemExit(
        "wire protocol inventory drift: missing=" + repr(missing_protocols)
    )
PY

echo "verified pi-ai upstream $upstream_revision ($upstream_package_version)"
