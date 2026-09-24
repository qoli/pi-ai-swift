#!/usr/bin/env python3
"""Verify source-derived catalog provenance and reproduce the complete artifact."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def verify(repo, upstream, lock, catalog):
    artifact = lock['sourceArtifact']
    manifest_path = repo / lock['sourceArtifactManifest']
    manifest_bytes = manifest_path.read_bytes()
    evidence = json.loads(manifest_bytes)
    if evidence['candidate'] != lock['revision'] or evidence['repository'] != lock['repository'] or evidence['package'] != lock['package']:
        raise ValueError('Source catalog evidence identity differs from upstream lock')
    expected = {
        'kind': 'frozen-public-catalog-inputs',
        'evidenceSHA256': hashlib.sha256(manifest_bytes).hexdigest(),
        'responseArchiveSHA256': evidence['responseArchive']['sha256'],
    }
    if artifact != expected or catalog.get('sourceArtifact') != expected:
        raise ValueError('Source catalog provenance differs from frozen evidence')
    if 'publishedArtifact' in lock or 'publishedArtifact' in catalog:
        raise ValueError('Source-derived catalog must not claim npm provenance')
    with tempfile.TemporaryDirectory(prefix='verify-source-catalog-') as temporary:
        output = Path(temporary) / 'catalog.json'
        subprocess.run(['python3', str(repo / 'Scripts/replay-schema6-catalog.py'),
                        '--upstream', str(upstream), '--manifest', str(manifest_path),
                        '--output', str(output)], check=True)
        if json.loads(output.read_bytes()) != catalog:
            raise ValueError('Bundled catalog differs from source replay')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--upstream', type=Path, required=True)
    args = parser.parse_args()
    verify(args.repo, args.upstream,
           json.loads((args.repo / 'Upstream.lock.json').read_bytes()),
           json.loads((args.repo / 'Sources/PiAIProviderRuntime/Resources/BuiltinCatalog.json').read_bytes()))
