import copy
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("live", Path(__file__).resolve().parents[1] / "LiveConformance/run.py")
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)


class PairedInventoryTests(unittest.TestCase):
    def setUp(self):
        self.identity = {"baselineSHA256": "baseline", "swiftSourceSHA256": "source"}
        self.source = {"suites": [{"path": "fixture", "sha256": "fixture-hash"}], "reviewedInventoryCounts": {}, "offlineConformant": True, "cases": [
            {"caseID": "native", "conformanceStatus": "passed"},
            {"caseID": "caller", "conformanceStatus": "outside_scope"},
        ]}
        for key, explicit in [("live", []), ("literal", [{"line": 10}])]:
            self.source["cases"].append({"caseID": key, "upstreamTest": "fixture", "conformanceStatus": "not_executed", "skipEvidence": {
                "upstream": {"location": {"line": 10}, "conditionalSkips": [], "explicitSkips": explicit}}})
        self.row = {"caseID": "live", "observedAt": "2026-11-22T10:00:00+00:00", "status": "passed",
                    "upstreamAssertion": "passed", "swiftAssertion": "passed",
                    "exitCodes": {"swift": 0, "upstream": 0}, "attempts": {"swift": 1, "upstream": 1},
                    "httpStatus": {"swift": [200], "upstream": [200]}, "upstreamOperations": ["stream"],
                    "nativeStreamOperations": ["encode", "decode"], "missingSwiftOperations": [],
                    "upstreamProtocols": ["openai-responses"], "swiftDispatchProtocols": ["openai-responses"]}

    def batch(self, row):
        return {"identity": self.identity, "results": [row]}

    def report(self, *batches):
        return live.aggregate(self.source, self.identity, batches)

    def test_literal_skip_keeps_strict_false_and_never_counts_as_a_pass(self):
        report = self.report(self.batch(self.row))
        self.assertTrue(report["upstreamRunnableConformant"])
        self.assertFalse(report["conformant"])
        self.assertEqual(report["caseCount"], 4)
        self.assertEqual(report["statusCounts"]["upstream_explicit_skip"], 1)
        self.assertFalse(self.report()["upstreamRunnableConformant"])

    def test_later_failure_supersedes_older_pass_regardless_of_input_order(self):
        failure = dict(self.row, status="upstream_failure", observedAt="2026-11-22T10:10:00+00:00")
        for rows in [(self.row, failure), (failure, self.row)]:
            report = self.report(*(self.batch(row) for row in rows))
            self.assertFalse(report["upstreamRunnableConformant"])
            self.assertEqual(report["statusCounts"]["upstream_failure"], 1)

    def test_rejects_partial_or_incompatible_evidence(self):
        for change in [{"caseID": "literal"}, {"caseID": "missing"}, {"nativeStreamOperations": ["encode"]},
                       {"httpStatus": {"swift": [], "upstream": [200]}}, {"swiftAssertion": "skipped"},
                       {"attempts": {"swift": 2, "upstream": 1}}, {"swiftDispatchProtocols": ["google"]}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.report(self.batch(dict(self.row, **change)))
        stale = copy.deepcopy(self.batch(self.row))
        stale["identity"]["swiftSourceSHA256"] = "different"
        with self.assertRaises(ValueError):
            self.report(stale)


if __name__ == "__main__":
    unittest.main()
