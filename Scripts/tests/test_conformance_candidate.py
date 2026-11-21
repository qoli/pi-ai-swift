import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("candidate", ROOT / "Scripts/Conformance/candidate.py")
CANDIDATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CANDIDATE)


class CandidateConformanceTests(unittest.TestCase):
    def test_review_requires_both_exact_revisions(self):
        data = json.loads((ROOT / "Scripts/Conformance/candidate-v1.6.0.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            manifests = repo / "Scripts/Conformance"
            manifests.mkdir(parents=True)
            for name, key in [("suites.json", "baseManifestSHA256"), ("scope-audit.json", "baseScopeAuditSHA256")]:
                path = manifests / name
                path.write_text("{}")
                data[key] = CANDIDATE.sha256(path)
            (manifests / "candidate-v1.6.0.json").write_text(json.dumps(data))
            self.assertEqual(CANDIDATE.profile(repo, data["revision"], data["baseRevision"]), data)
            for revision, base in [(data["revision"][:8], data["baseRevision"]), (data["revision"], "0" * 40)]:
                with self.assertRaisesRegex(ValueError, "exact candidate"):
                    CANDIDATE.profile(repo, revision, base)
            (manifests / "suites.json").write_text("changed")
            with self.assertRaisesRegex(ValueError, "rebasing"):
                CANDIDATE.profile(repo, data["revision"], data["baseRevision"])

    def test_unverified_tarball_cannot_write_candidate_model_data(self):
        with tempfile.TemporaryDirectory() as directory:
            upstream = Path(directory)
            tarball = upstream / "wrong.tgz"
            tarball.write_bytes(b"different release")
            with self.assertRaisesRegex(ValueError, "integrity mismatch"):
                CANDIDATE.prepare_catalog(upstream, tarball, {"publishedPackage": {"integrity": "sha512-invalid"}})
            self.assertFalse((upstream / "packages").exists())

    def test_inventory_rejects_unreviewed_or_missing_candidate_files(self):
        with tempfile.TemporaryDirectory() as directory:
            upstream = Path(directory)
            tests = upstream / "packages/ai/test"
            tests.mkdir(parents=True)
            manifest = {"suites": ["existing.test.ts"], "excludedSuites": {"retired.test.ts": "Outside scope"}}
            review = {"addSuites": ["new.test.ts"], "excludedSuites": {}, "removeExcludedSuites": ["retired.test.ts"]}
            for name in ["existing.test.ts", "new.test.ts"]:
                (tests / name).touch()
            self.assertEqual(CANDIDATE.inventory(upstream, manifest, review)["suites"],
                             ["existing.test.ts", "new.test.ts"])
            (tests / "other.test.ts").touch()
            with self.assertRaisesRegex(ValueError, "inventory"):
                CANDIDATE.inventory(upstream, manifest, review)
            (tests / "other.test.ts").unlink()
            (tests / "existing.test.ts").unlink()
            with self.assertRaisesRegex(ValueError, "inventory"):
                CANDIDATE.inventory(upstream, manifest, review)
            self.assertIn("retired.test.ts", manifest["excludedSuites"])
