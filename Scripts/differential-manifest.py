#!/usr/bin/env python3

import argparse
import hashlib
import json
import pathlib
import sys


def digest_files(root: pathlib.Path, paths: list[str]) -> str:
    digest = hashlib.sha256()
    for relative in sorted(paths):
        path = root / relative
        if not path.is_file():
            raise SystemExit(f"differential manifest input is missing: {relative}")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def expected_manifest(repo: pathlib.Path, upstream: pathlib.Path) -> dict:
    lock = json.loads((repo / "Upstream.lock.json").read_text(encoding="utf-8"))
    mapping = json.loads(
        (repo / "UpstreamMappings/pi-ai.json").read_text(encoding="utf-8")
    )
    entries = []
    for area in mapping["areas"]:
        protocol_id = area.get("protocolID")
        if not protocol_id:
            continue
        evidence_files = sorted(
            {evidence.split("#", 1)[0] for evidence in area["evidence"]}
        )
        entries.append(
            {
                "protocolID": protocol_id,
                "areaID": area["id"],
                "upstreamSources": area["upstreamPaths"],
                "upstreamTests": area["upstreamTestPaths"],
                "swiftEvidence": area["evidence"],
                "upstreamSourceSHA256": digest_files(
                    upstream, area["upstreamPaths"]
                ),
                "upstreamTestSHA256": digest_files(
                    upstream, area["upstreamTestPaths"]
                ),
                "swiftEvidenceSHA256": digest_files(repo, evidence_files),
            }
        )
    entries.sort(key=lambda entry: entry["protocolID"])
    return {
        "schemaVersion": 1,
        "repository": lock["repository"],
        "revision": lock["revision"],
        "packageVersion": lock["package"]["version"],
        "entries": entries,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=pathlib.Path, required=True)
    parser.add_argument("--upstream", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path)
    parser.add_argument("--generate", action="store_true")
    arguments = parser.parse_args()
    expected = expected_manifest(arguments.repo, arguments.upstream)
    rendered = json.dumps(expected, indent=2, ensure_ascii=False) + "\n"
    if arguments.generate:
        sys.stdout.write(rendered)
        return 0
    if arguments.manifest is None or not arguments.manifest.is_file():
        raise SystemExit("differential manifest is missing")
    try:
        actual = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SystemExit(f"differential manifest is malformed: {error}") from error
    if actual != expected:
        raise SystemExit(
            "differential manifest drift; run Scripts/differential-manifest.py "
            "with --generate and review the semantic changes"
        )
    print(f"verified differential manifest for {len(expected['entries'])} protocols")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
