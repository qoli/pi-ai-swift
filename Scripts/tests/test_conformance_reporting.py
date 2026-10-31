import copy
import importlib.util
from pathlib import Path
import unittest
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("conformance", ROOT / "Scripts/Conformance/run.py")
CONFORMANCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFORMANCE)


class ConformanceReportingTests(unittest.TestCase):
    def test_evidence_identity_detects_source_changes_between_build_and_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/PiAIProviderRuntime/Test.swift"
            source.parent.mkdir(parents=True)
            source.write_text("let value = 1")
            (root / "Scripts/Conformance").mkdir(parents=True)
            before = CONFORMANCE.evidence_digests(root)
            source.write_text("let value = 2")
            self.assertNotEqual(before, CONFORMANCE.evidence_digests(root))

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

    def evaluate_dispatch(self, calls):
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream",
                     "protocol": "anthropic-messages"}]
        return CONFORMANCE.evaluate(
            self.upstream, self.reports, calls, {"upstream": 0, "swift": 0}, original)

    def test_matching_wire_dispatch_can_pass(self):
        conformant, _ = self.evaluate_dispatch([{**self.call, "entrypoint": "stream"}])
        self.assertTrue(conformant)

    def test_passing_assertions_cannot_hide_wrong_wire_dispatch(self):
        call = {**self.call, "entrypoint": "stream", "protocol": "openai-responses"}
        conformant, cases = self.evaluate_dispatch([call])
        self.assertFalse(conformant)
        self.assertEqual(cases[0]["conformanceStatus"], "dispatch_mismatch")
        self.assertEqual(cases[0]["missingSwiftProtocols"], ["anthropic-messages"])

    def test_helper_probe_cannot_stand_in_for_the_selected_wire_dispatch(self):
        calls = [
            {**self.call, "entrypoint": "helper"},
            {**self.call, "entrypoint": "stream", "protocol": "openai-responses"},
        ]
        conformant, cases = self.evaluate_dispatch(calls)
        self.assertFalse(conformant)
        self.assertEqual(cases[0]["missingSwiftProtocols"], ["anthropic-messages"])

    def test_unrequested_wire_dispatch_is_not_conformance(self):
        calls = [
            {**self.call, "entrypoint": "stream"},
            {**self.call, "entrypoint": "stream", "protocol": "openai-responses"},
        ]
        conformant, cases = self.evaluate_dispatch(calls)
        self.assertFalse(conformant)
        self.assertEqual(cases[0]["unexpectedSwiftProtocols"], ["openai-responses"])

    def test_duplicate_original_case_cannot_disappear(self):
        self.reports["upstream"]["testResults"][0]["assertionResults"].append(copy.deepcopy(self.case))
        self.assertFalse(self.evaluate([self.call]))
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream"}]
        _, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [self.call], {"upstream": 0, "swift": 0}, original)
        self.assertEqual(len(cases), 2)
        self.assertEqual(cases[-1]["status"], "missing")
        self.assertEqual(cases[-1]["conformanceStatus"], "bridge_gap")

    def test_catalog_lookup_cannot_substitute_for_reasoning_metadata_computation(self):
        original = [{"file": self.file, "test": "schema > preserves input", "operation": operation}
                    for operation in ["catalog", "catalog.reasoning"]]
        call = {**self.call, "operation": "catalog"}
        conformant, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [call], {"upstream": 0, "swift": 0}, original)
        self.assertFalse(conformant)
        self.assertEqual(cases[0]["missingSwiftOperations"], ["catalog.reasoning"])

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
