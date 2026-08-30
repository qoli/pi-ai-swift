#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="$repo_root/Upstream.lock.json"
mapping_file="$repo_root/UpstreamMappings/pi-ai.json"
catalog_file="$repo_root/Sources/PiAIProviderRuntime/Resources/BuiltinCatalog.json"
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

if mapping.get("schemaVersion") != 3:
    raise SystemExit("malformed upstream mapping: schemaVersion must be 3")

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

    for key in [
        "swiftPaths", "plannedSwiftPaths", "upstreamPaths", "upstreamTestPaths",
        "dependsOn", "evidence", "requiredGates",
    ]:
        values = area.get(key)
        if not isinstance(values, list) or any(not isinstance(value, str) or not value for value in values):
            raise SystemExit(f"malformed upstream mapping: {area_id}.{key} must be a string array")

    if area.get("supportDisposition") not in {"planned", "supported", "blocked"}:
        raise SystemExit(f"malformed upstream mapping: {area_id} has invalid supportDisposition")
    if area.get("liveVerificationStatus") not in {"notRun", "notRequired", "passed"}:
        raise SystemExit(f"malformed upstream mapping: {area_id} has invalid liveVerificationStatus")

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

    for evidence in area["evidence"]:
        relative = evidence.split("#", 1)[0]
        if not (repo_root / relative).is_file():
            raise SystemExit(f"mapped evidence does not exist: {area_id}: {evidence}")
    if status == "landed" and not area["evidence"]:
        raise SystemExit(f"landed area has no executable evidence: {area_id}")

for area in areas:
    for dependency in area["dependsOn"]:
        if dependency not in area_ids:
            raise SystemExit(f"unknown area dependency: {area['id']}: {dependency}")
        if dependency == area["id"]:
            raise SystemExit(f"self-referential area dependency: {area['id']}")

def visit(area_id, active, completed):
    if area_id in completed:
        return
    if area_id in active:
        raise SystemExit(f"cyclic area dependency: {area_id}")
    active.add(area_id)
    area = next(item for item in areas if item["id"] == area_id)
    for dependency in area["dependsOn"]:
        visit(dependency, active, completed)
    active.remove(area_id)
    completed.add(area_id)

completed = set()
for area_id in area_ids:
    visit(area_id, set(), completed)

statuses = {area["id"]: area["status"] for area in areas}
for area in areas:
    if area["status"] == "landed":
        incomplete = [
            dependency
            for dependency in area["dependsOn"]
            if statuses[dependency] != "landed"
        ]
        if incomplete:
            raise SystemExit(
                f"landed area depends on incomplete areas: {area['id']}: {incomplete}"
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

if lock.get("schemaVersion") != 3:
    raise SystemExit("malformed upstream lock: schemaVersion must be 3")
if not isinstance(lock.get("trackedBuiltinProviders"), list):
    raise SystemExit("malformed upstream lock: trackedBuiltinProviders must be an array")
artifact = lock.get("publishedArtifact")
if not isinstance(artifact, dict):
    raise SystemExit("malformed upstream lock: publishedArtifact must be an object")
for key in ["registry", "shasum", "integrity", "modelDataManifestStructureHash"]:
    if not isinstance(artifact.get(key), str) or not artifact[key]:
        raise SystemExit(f"malformed upstream lock: publishedArtifact.{key} is required")
catalog_hash = lock.get("generatedCatalogSHA256")
if not isinstance(catalog_hash, str) or len(catalog_hash) != 64:
    raise SystemExit("malformed upstream lock: generatedCatalogSHA256 is required")

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

python3 - "$cache_root" "$mapping_file" "$lock_file" "$catalog_file" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

cache_root = pathlib.Path(sys.argv[1])
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    mapping = json.load(handle)
with open(sys.argv[3], "r", encoding="utf-8") as handle:
    lock = json.load(handle)
catalog_path = pathlib.Path(sys.argv[4])
if not catalog_path.is_file():
    raise SystemExit("bundled provider catalog is missing")
catalog_bytes = catalog_path.read_bytes()
catalog_digest = hashlib.sha256(catalog_bytes).hexdigest()
if catalog_digest != lock["generatedCatalogSHA256"]:
    raise SystemExit(
        f"bundled provider catalog digest mismatch: expected={lock['generatedCatalogSHA256']} "
        f"actual={catalog_digest}"
    )
catalog = json.loads(catalog_bytes)
if catalog.get("upstreamRevision") != lock["revision"]:
    raise SystemExit("bundled provider catalog revision does not match upstream lock")
if catalog.get("publishedArtifact") != lock["publishedArtifact"]:
    raise SystemExit("bundled provider catalog artifact provenance does not match upstream lock")

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

catalog_providers = {provider.get("id") for provider in catalog.get("providers", [])}
if catalog_providers != upstream_providers:
    raise SystemExit(
        "bundled provider catalog inventory drift: "
        f"missing={sorted(upstream_providers - catalog_providers)}, "
        f"extra={sorted(catalog_providers - upstream_providers)}"
    )

try:
    images_body = all_source.split("export function builtinImagesProviders()", 1)[1].split("];", 1)[0]
except IndexError as error:
    raise SystemExit("could not parse upstream builtinImagesProviders()") from error
image_factories = re.findall(r"\b(\w+Provider)\(\)", images_body)
upstream_image_providers = {
    imports[factory].removesuffix("-images")
    for factory in image_factories
    if factory in imports
}
mapped_image_providers = {
    area["imageProviderID"]
    for area in mapping["areas"]
    if isinstance(area.get("imageProviderID"), str)
}
if upstream_image_providers != mapped_image_providers:
    raise SystemExit(
        "image provider inventory drift: "
        f"missing={sorted(upstream_image_providers - mapped_image_providers)}, "
        f"extra={sorted(mapped_image_providers - upstream_image_providers)}"
    )
catalog_image_providers = set(catalog.get("imageProviderIDs", []))
if upstream_image_providers != catalog_image_providers:
    raise SystemExit(
        "bundled image provider inventory drift: "
        f"missing={sorted(upstream_image_providers - catalog_image_providers)}, "
        f"extra={sorted(catalog_image_providers - upstream_image_providers)}"
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

# Every relative production import reachable from a mapped pi-ai source must
# remain inside the semantic provenance closure. This intentionally excludes
# external packages and test-only imports.
mapped_sources = {
    path
    for area in mapping["areas"]
    for path in area["upstreamPaths"]
    if path.startswith("packages/ai/src/")
}
import_pattern = re.compile(r'(?:from\s+|import\s*\()["\'](\.[^"\']+)["\']')
reachable = set()
pending = list(mapped_sources)
while pending:
    relative = pending.pop()
    if relative in reachable:
        continue
    reachable.add(relative)
    source_path = cache_root / relative
    if not source_path.is_file():
        continue
    for imported in import_pattern.findall(source_path.read_text(encoding="utf-8")):
        candidate = pathlib.PurePosixPath(relative).parent / imported
        parts = []
        for part in candidate.parts:
            if part == "..":
                if parts:
                    parts.pop()
            elif part != ".":
                parts.append(part)
        normalized = "/".join(parts)
        if not pathlib.PurePosixPath(normalized).suffix:
            normalized += ".ts"
        if (
            normalized.startswith("packages/ai/src/")
            and (cache_root / normalized).is_file()
            and normalized not in reachable
        ):
            pending.append(normalized)
unmapped_dependencies = sorted(reachable - mapped_sources)
if unmapped_dependencies:
    raise SystemExit(
        "upstream semantic import closure drift: " + repr(unmapped_dependencies)
    )
PY

echo "verified pi-ai upstream $upstream_revision ($upstream_package_version)"
