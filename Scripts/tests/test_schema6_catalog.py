"""Source-derived catalog regression and frozen-input integrity checks."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / 'Fixtures/Catalog/Schema6'


def replay(manifest, output):
    return subprocess.run(
        ['python3', str(ROOT / 'Scripts/replay-schema6-catalog.py'),
         '--upstream', os.environ.get('SCHEMA6_UPSTREAM', str(ROOT / '.build/upstreams/pi')),
         '--manifest', str(manifest), '--output', str(output)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


@unittest.skipUnless(os.environ.get('SCHEMA6_UPSTREAM'),
                     'Set SCHEMA6_UPSTREAM to a local git repository containing the exact candidate')
class Schema6CatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='schema6-tests-')
        cls.directory = Path(cls.temporary.name)
        cls.evidence = json.loads((FIXTURES / 'manifest.json').read_text())
        cls.output = cls.directory / 'candidate.json'
        cls.result = replay(FIXTURES / 'manifest.json', cls.output)
        if cls.result.returncode:
            raise AssertionError(cls.result.stdout)
        cls.catalog = json.loads(cls.output.read_text())

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_complete_projection_matches_source_values_and_inventory(self):
        providers = self.catalog['providers']
        digest = hashlib.sha256(json.dumps(
            providers, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
        self.assertEqual(digest, self.evidence['projectedProvidersSHA256'])
        self.assertEqual(len(providers), 42)
        counts = {kind: sum(m.get('type', 'chat') == kind for p in providers for m in p['models'])
                  for kind in ['chat', 'image', 'classifier']}
        self.assertEqual(counts, self.evidence['modelCounts'])
        self.assertEqual(self.catalog['classifierProviderIDs'], ['cloudflare-workers-ai', 'openrouter', 'typesafe'])
        self.assertEqual(self.catalog['imageProviderIDs'], ['openrouter'])
        self.assertNotIn('publishedArtifact', self.catalog)
        fixture = json.loads((FIXTURES / 'routing.json').read_text())
        for subset in fixture['providers']:
            provider = next(p for p in providers if p['id'] == subset['id'])
            actual = {(m['type'], m['id']): m for m in provider['models']}
            for model in subset['models']:
                self.assertEqual(actual[(model['type'], model['id'])], model)
        ledger = json.loads((FIXTURES / 'capabilities.json').read_text())
        self.assertEqual(ledger['revision'], self.evidence['candidate'])
        missing = {(area['providerID'], model_id, area['protocolID'])
                   for area in ledger['areas'] for model_id in area['modelIDs']}
        classifiers = {(p['id'], m['id'], m['api']) for p in providers for m in p['models']
                       if m.get('type') == 'classifier'}
        self.assertEqual(missing, classifiers)

    def test_clean_replay_is_byte_identical(self):
        second = self.directory / 'second.json'
        result = replay(FIXTURES / 'manifest.json', second)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.output.read_bytes(), second.read_bytes())

class Schema6InputTests(unittest.TestCase):
    def test_changed_input_cannot_be_relabelled_as_original_evidence(self):
        # Recompute the container digest, but leave the original per-response
        # evidence intact. Integrity must reach the body, not just its archive.
        evidence = json.loads((FIXTURES / 'manifest.json').read_text())
        responses = json.loads(gzip.decompress((FIXTURES / 'responses.json.gz').read_bytes()))
        responses[0]['body'] = 'e30='  # {} in base64
        mutated = gzip.compress(json.dumps(responses).encode(), mtime=0)
        with tempfile.TemporaryDirectory() as temporary:
            location = Path(temporary)
            (location / 'responses.json.gz').write_bytes(mutated)
            evidence['responseArchive']['sha256'] = hashlib.sha256(mutated).hexdigest()
            manifest = location / 'manifest.json'
            manifest.write_text(json.dumps(evidence))
            output = location / 'candidate.json'
            result = replay(manifest, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Captured response mismatch', result.stdout)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
