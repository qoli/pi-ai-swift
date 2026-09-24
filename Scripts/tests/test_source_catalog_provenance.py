"""Unit tests for frozen-source identity and replay equality acceptance.

Subprocess is mocked only at the replay comparison boundary. Real offline replay
and complete provider projection are exercised in test_schema6_catalog.py.
"""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    'source_catalog_check', ROOT / 'Scripts/check-source-catalog.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class SourceCatalogProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='source-provenance-unit-')
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.manifest_relative = 'Fixtures/Catalog/Schema6/manifest.json'
        manifest_path = self.repo / self.manifest_relative
        manifest_path.parent.mkdir(parents=True)
        manifest_bytes = (ROOT / self.manifest_relative).read_bytes()
        manifest_path.write_bytes(manifest_bytes)
        evidence = json.loads(manifest_bytes)
        artifact = {
            'kind': 'frozen-public-catalog-inputs',
            'evidenceSHA256': hashlib.sha256(manifest_bytes).hexdigest(),
            'responseArchiveSHA256': evidence['responseArchive']['sha256'],
        }
        self.lock = {
            'schemaVersion': 4,
            'revision': evidence['candidate'],
            'repository': evidence['repository'],
            'package': evidence['package'],
            'sourceArtifactManifest': self.manifest_relative,
            'sourceArtifact': artifact,
        }
        # A real frozen subset makes a discriminating replay-comparison payload;
        # this unit test does not claim it is the complete replay output.
        self.catalog = json.loads((ROOT / 'Fixtures/Catalog/Schema6/routing.json').read_bytes())
        self.catalog['sourceArtifact'] = copy.deepcopy(artifact)
        self.replayed = copy.deepcopy(self.catalog)

    def mock_replay(self, command, check):
        self.assertTrue(check)
        self.assertEqual(command[0:2], ['python3', str(self.repo / 'Scripts/replay-schema6-catalog.py')])
        self.assertEqual(command[command.index('--manifest') + 1],
                         str(self.repo / self.manifest_relative))
        output = Path(command[command.index('--output') + 1])
        output.write_text(json.dumps(self.replayed))
        return subprocess.CompletedProcess(command, 0)

    def verify(self):
        CHECK.verify(self.repo, self.repo / 'unused-upstream', self.lock, self.catalog)

    def test_exact_frozen_identity_and_equal_replay_pass(self):
        with patch.object(CHECK.subprocess, 'run', side_effect=self.mock_replay) as run:
            self.verify()
        run.assert_called_once()

    def test_revision_repository_and_package_mismatches_fail_before_replay(self):
        for field in ['revision', 'repository', 'package']:
            with self.subTest(field=field):
                original = copy.deepcopy(self.lock)
                self.lock[field] = {'name': 'unrelated'} if field == 'package' else 'unrelated'
                with patch.object(CHECK.subprocess, 'run') as run:
                    with self.assertRaisesRegex(ValueError, 'identity differs'):
                        self.verify()
                    run.assert_not_called()
                self.lock = original

    def test_mixed_npm_and_source_provenance_is_rejected(self):
        for location in ['lock', 'catalog']:
            with self.subTest(location=location):
                target = self.lock if location == 'lock' else self.catalog
                target['publishedArtifact'] = {'registry': 'https://registry.npmjs.org'}
                with patch.object(CHECK.subprocess, 'run') as run:
                    with self.assertRaisesRegex(ValueError, 'must not claim npm provenance'):
                        self.verify()
                    run.assert_not_called()
                del target['publishedArtifact']

    def test_relabelled_manifest_or_archive_digest_is_rejected(self):
        for location in ['lock', 'catalog']:
            for field in ['evidenceSHA256', 'responseArchiveSHA256']:
                with self.subTest(location=location, field=field):
                    target = self.lock if location == 'lock' else self.catalog
                    original = target['sourceArtifact'][field]
                    target['sourceArtifact'][field] = '0' * 64
                    with patch.object(CHECK.subprocess, 'run') as run:
                        with self.assertRaisesRegex(ValueError, 'differs from frozen evidence'):
                            self.verify()
                        run.assert_not_called()
                    target['sourceArtifact'][field] = original

    def test_changed_model_metadata_fails_replay_comparison(self):
        self.catalog['providers'][0]['models'][0]['name'] = 'changed-after-replay'
        with patch.object(CHECK.subprocess, 'run', side_effect=self.mock_replay) as run:
            with self.assertRaisesRegex(ValueError, 'differs from source replay'):
                self.verify()
        run.assert_called_once()

    def test_missing_provider_fails_replay_comparison(self):
        self.catalog['providers'].pop()
        with patch.object(CHECK.subprocess, 'run', side_effect=self.mock_replay):
            with self.assertRaisesRegex(ValueError, 'differs from source replay'):
                self.verify()

    def test_failed_replay_propagates_without_accepting_catalog(self):
        with patch.object(CHECK.subprocess, 'run',
                          side_effect=subprocess.CalledProcessError(1, ['unit-replay'])):
            with self.assertRaises(subprocess.CalledProcessError):
                self.verify()


if __name__ == '__main__':
    unittest.main()
