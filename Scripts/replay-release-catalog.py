#!/usr/bin/env python3
"""Project a release catalog from the pinned Git source and checksum-verified npm archive."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "Scripts/Conformance"))
from candidate import prepare_catalog


def replay(upstream, manifest, output):
    evidence = json.loads(manifest.read_bytes())
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=upstream, text=True).strip()
    if revision != evidence["revision"]:
        raise ValueError("Release catalog checkout revision differs from evidence")
    archive = manifest.parent / evidence["archive"]
    prepare_catalog(upstream, archive, evidence)
    subprocess.run(["node", ROOT / "Scripts/generate-source-catalog.mjs", upstream,
                    manifest, output], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    replay(args.upstream.resolve(), args.manifest.resolve(), args.output.resolve())
