import copy
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("conformance", ROOT / "Scripts/Conformance/run.py")
CONFORMANCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFORMANCE)


class ConformanceReportingTests(unittest.TestCase):
    def setUp(self):
        self.upstream = Path("/fixture-upstream")
        self.file = str(self.upstream / "packages/ai/test/schema.test.ts")
        self.case = {"ancestorTitles": ["schema"], "title": "preserves input", "status": "passed"}
        result = {"testResults": [{"name": self.file, "assertionResults": [self.case]}]}
        self.reports = {"upstream": copy.deepcopy(result), "swift": copy.deepcopy(result)}
        self.call = {"file": self.file, "test": "schema > preserves input", "protocol": "anthropic-messages", "operation": "encode"}

    def evaluate(self, calls):
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream"}]
        return CONFORMANCE.evaluate(self.upstream, self.reports, calls, {"upstream": 0, "swift": 0}, original)[0]

    def test_original_test_pass_with_swift_execution_is_accepted(self):
        self.assertTrue(self.evaluate([self.call]))

    def test_typescript_pass_through_is_not_swift_conformance(self):
        self.assertFalse(self.evaluate([]))
        self.assertFalse(self.evaluate([{"file": self.file, "protocol": "anthropic-messages"}]))
        self.assertFalse(self.evaluate([{**self.call, "operation": "catalog"}]))

    def test_duplicate_original_case_cannot_disappear(self):
        self.reports["upstream"]["testResults"][0]["assertionResults"].append(copy.deepcopy(self.case))
        self.assertFalse(self.evaluate([self.call]))

    def test_skipped_failed_or_unrepresentable_cases_are_not_passes(self):
        for implementation, status in [("upstream", "failed"), ("swift", "skipped")]:
            with self.subTest(implementation=implementation, status=status):
                self.reports[implementation]["testResults"][0]["assertionResults"][0]["status"] = status
                self.assertFalse(self.evaluate([self.call]))
                self.reports[implementation]["testResults"][0]["assertionResults"][0]["status"] = "passed"
        call = {**self.call, "unrepresentedCapabilities": ["raw-response-hook"]}
        self.assertFalse(self.evaluate([call]))

    def test_upstream_case_status_is_matched_by_name_when_order_changes(self):
        second = {**self.case, "title": "second", "status": "failed"}
        self.reports["upstream"]["testResults"][0]["assertionResults"].append(second)
        self.reports["swift"]["testResults"][0]["assertionResults"].insert(0, copy.deepcopy(second))
        _, cases = CONFORMANCE.evaluate(self.upstream, self.reports, [], {"upstream": 1, "swift": 1})
        self.assertEqual([case["upstreamStatus"] for case in cases], ["failed", "passed"])

    def test_javascript_heap_success_cannot_count_as_swift_heap_evidence(self):
        call = {**self.call, "unrepresentedCapabilities": ["swift-process-heap-observer"]}
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream"}]
        conformant, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [call], {"upstream": 0, "swift": 0}, original)
        self.assertFalse(conformant)
        self.assertEqual(cases[0]["status"], "passed")
        self.assertEqual(cases[0]["conformanceStatus"], "interface_gap")


if __name__ == "__main__":
    unittest.main()
