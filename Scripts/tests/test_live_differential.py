import pathlib
import importlib.util
import os
import subprocess
import unittest


class LiveDifferentialTests(unittest.TestCase):
    def test_shared_live_assertions_offline(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        subprocess.run(
            ["node", "--test", "Scripts/LiveDifferential/assertions.test.mjs"],
            cwd=root, check=True, capture_output=True, text=True,
        )

    def test_upstream_live_harness_adaptations_offline(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        upstream = pathlib.Path(os.environ.get("PI_AI_SWIFT_UPSTREAM_CACHE", root / ".build/upstreams/pi"))
        subprocess.run(["npm", "run", "build", "--workspace", "@earendil-works/pi-telemetry"],
                       cwd=upstream, check=True, capture_output=True, text=True)
        result = subprocess.run(["node", "--test", "Scripts/LiveDifferential/oracle-fixture.test.mjs"],
                                cwd=root, capture_output=True, text=True,
                                env={**os.environ, "PI_AI_SWIFT_UPSTREAM_CACHE": str(upstream.resolve())})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_matrix_keeps_failures_and_does_not_replace_tests_with_unselected_rows(self):
        path = pathlib.Path(__file__).resolve().parents[1] / "LiveDifferential/report.py"
        spec = importlib.util.spec_from_file_location("live_report", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        base = {"providerID": "fixture", "providerName": "Fixture", "modelID": "m", "capability": "tools"}
        first = {"upstreamRevision": "fixture", "rows": [{**base, "status": "swift_failure"}]}
        second = {"upstreamRevision": "fixture", "rows": [{**base, "status": "not_selected"}]}
        combined = module.combine([("first", first), ("second", second)])
        self.assertEqual(combined["rows"][0]["status"], "swift_failure")
        third = {"upstreamRevision": "fixture", "rows": [{**base, "status": "passed"}]}
        combined = module.combine([("first", first), ("second", second), ("third", third)])
        self.assertEqual(combined["rows"][0]["status"], "passed")
        self.assertEqual(combined["history"][0]["status"], "swift_failure")
        self.assertIn("swift_failure", module.render(combined))
