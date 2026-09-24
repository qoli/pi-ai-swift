#!/usr/bin/env python3
"""Rebuild a candidate catalog from exact source and frozen public inputs.

No fetching, credentials, pin changes, or publication. Output is explicitly
written to an explicit staging path; generate-builtin-catalog.sh separately
verifies the accepted lock before replacing the bundled resource.
"""
import argparse
import base64
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def replay(upstream, manifest_path, output):
    repo = Path(__file__).resolve().parent.parent
    evidence_bytes = manifest_path.read_bytes()
    evidence = json.loads(evidence_bytes)
    archive = (manifest_path.parent / evidence['responseArchive']['path']).read_bytes()
    if sha256(archive) != evidence['responseArchive']['sha256']:
        raise ValueError('Frozen response archive digest mismatch')
    responses = json.loads(gzip.decompress(archive))
    expected_inputs = {item['url']: item for item in evidence['sourceInputs']}
    if len(responses) != len(expected_inputs) or {item['url'] for item in responses} != set(expected_inputs):
        raise ValueError('Frozen response inventory mismatch')
    for item in responses:
        expected = expected_inputs[item['url']]
        if (sha256(base64.b64decode(item['body'])) != expected['sha256']
                or item['sha256'] != expected['sha256'] or item['status'] != expected['status']):
            raise ValueError('Captured response mismatch: ' + item['url'])
    resolved = subprocess.check_output(
        ['git', '-C', str(upstream), 'rev-parse', evidence['candidate'] + '^{commit}'], text=True
    ).strip()
    if resolved != evidence['candidate']:
        raise ValueError('Exact upstream commit mismatch')
    # Always start without generated data. Never reuse the accepted source cache
    # as a writable hydration tree.
    with tempfile.TemporaryDirectory(prefix='pi-schema6-') as temporary:
        root = Path(temporary)
        source = root / 'source'
        source.mkdir()
        source_tar = root / 'source.tar'
        with source_tar.open('wb') as handle:
            run('git', '-C', str(upstream), 'archive', evidence['candidate'], stdout=handle)
        with tarfile.open(source_tar) as handle:
            handle.extractall(source, filter='data')
        for relative, digest in evidence['generatorSourceHashes'].items():
            if sha256((source / relative).read_bytes()) != digest:
                raise ValueError('Generator source digest mismatch: ' + relative)
        captures = root / 'responses'
        captures.mkdir()
        for item in responses:
            (captures / (sha256(item['url'].encode()) + '.json')).write_text(json.dumps(item))
        env = {'PATH': os.environ['PATH'], 'SCHEMA6_MODE': 'replay', 'SCHEMA6_RESPONSES': str(captures)}
        package = source / evidence['package']['path']
        run('node', '--import', str(repo / 'Scripts/schema6-probe-fetch.mjs'),
            str(package / 'scripts/generate-models.ts'), '--strict', '--data-only', env=env)
        run('node', str(package / 'scripts/check-model-data.ts'), env=env)
        model_manifest = json.loads((package / 'src/providers/data/.manifest.json').read_text())
        if (model_manifest['schemaVersion'] != evidence['schemaVersion']
                or model_manifest['structureHash'] != evidence['structureHash']
                or model_manifest['files'] != evidence['providerFileHashes']):
            raise ValueError('Replayed model data differs from frozen evidence')
        candidate = root / 'BuiltinCatalog.json'
        run('node', str(repo / 'Scripts/generate-source-catalog.mjs'), str(source),
            str(manifest_path.resolve()), str(candidate), env=env)
        # Write only after all source and replay gates pass.
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(candidate.read_bytes())
        print('Candidate catalog generated:', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, required=True, help='Local git repository containing the exact commit')
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parent.parent / 'Fixtures/Catalog/Schema6/manifest.json')
    parser.add_argument('--output', type=Path, required=True, help='Candidate output; never the accepted bundled catalog')
    options = parser.parse_args()
    accepted = Path(__file__).resolve().parent.parent / 'Sources/PiAIProviderRuntime/Resources/BuiltinCatalog.json'
    if options.output.resolve() == accepted:
        parser.error('Candidate replay cannot overwrite the accepted bundled catalog')
    replay(options.upstream, options.manifest, options.output)
