"""Keep the source-derived request additions bound to their Swift replays."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("coverage", ROOT / "Scripts/check-differential-coverage.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)

class ProviderIntentCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copyfile(ROOT / "Upstream.lock.json", self.root / "Upstream.lock.json")
        for directory in ["Fixtures/Differential", "Fixtures/OpenAIRequestBranches", "Fixtures/AzureOpenAIConfiguration"]:
            shutil.copytree(ROOT / directory, self.root / directory)
        for name in ["ProviderIntentDifferentialTests.swift", "StrictFallbackDifferentialTests.swift"]:
            target = self.root / "Tests/PiAIProviderRuntimeTests" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / "Tests/PiAIProviderRuntimeTests" / name, target)

    def edit(self, relative, change):
        path = self.root / relative
        value = json.loads(path.read_text())
        change(value)
        path.write_text(json.dumps(value))

    def test_checked_in_additions_have_exact_evidence(self):
        self.assertTrue(GATE.executable_request_cases(self.root))

    def test_deleted_observation_is_rejected(self):
        self.edit("Fixtures/Differential/Oracle/provider-intent.json",
                  lambda value: value["cases"].pop("azure.completions-deployment"))
        with self.assertRaisesRegex(SystemExit, "request case drift"):
            GATE.executable_request_cases(self.root)

    def test_duplicate_strict_input_is_rejected(self):
        self.edit("Fixtures/Differential/Cases/strict-fallback.json",
                  lambda value: value["cases"].append(value["cases"][0]))
        with self.assertRaisesRegex(SystemExit, "request case drift"):
            GATE.executable_request_cases(self.root)

    def test_stale_source_revision_is_rejected(self):
        self.edit("Fixtures/Differential/Cases/provider-intent.json",
                  lambda value: value.update(upstreamRevision="stale"))
        with self.assertRaisesRegex(SystemExit, "identity/test drift"):
            GATE.executable_request_cases(self.root)
