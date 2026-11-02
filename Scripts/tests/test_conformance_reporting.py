import copy
import hashlib
import importlib.util
import json
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
            (root / "Package.swift").write_text("// fixture package")
            (root / "Package.resolved").write_text('{"pins": []}')
            (root / "Scripts/Conformance").mkdir(parents=True)
            before = CONFORMANCE.evidence_digests(root)
            source.write_text("let value = 2")
            self.assertNotEqual(before, CONFORMANCE.evidence_digests(root))
            before = CONFORMANCE.evidence_digests(root)
            (root / "Package.resolved").write_text('{"pins": [{"revision": "changed"}]}')
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

    def test_classifier_requires_its_own_native_operation_and_protocol(self):
        original = [{"file": self.file, "test": "schema > preserves input",
                     "operation": "classify", "protocol": "typesafe-system-one"}]
        for entrypoint, protocol, expected in [
            ("classify", "typesafe-system-one", "passed"),
            ("helper", "typesafe-system-one", "dispatch_mismatch"),
            ("classify", "openai-decisions", "dispatch_mismatch"),
        ]:
            call = {**self.call, "operation": "classify", "entrypoint": entrypoint, "protocol": protocol}
            conformant, cases = CONFORMANCE.evaluate(self.upstream, self.reports, [call],
                {"upstream": 0, "swift": 0}, original)
            self.assertEqual(cases[0]["conformanceStatus"], expected)
            self.assertEqual(conformant, expected == "passed")

    def test_caller_identity_assembly_remains_visible_without_requiring_a_duplicate_native_call(self):
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream",
                     "protocol": "anthropic-messages"},
                    {"file": self.file, "test": "schema > preserves input", "operation": "identity.merge",
                     "ownership": "caller"}]
        call = {**self.call, "entrypoint": "stream"}
        conformant, cases = CONFORMANCE.evaluate(self.upstream, self.reports, [call],
            {"upstream": 0, "swift": 0}, original)
        self.assertTrue(conformant)
        self.assertEqual(cases[0]["upstreamCallerOperations"], ["identity.merge"])
        for operation in ["identity.merge", "stream"]:
            required = {**original[1], "operation": operation,
                        "ownership": "provider" if operation == "identity.merge" else "caller"}
            self.assertFalse(CONFORMANCE.evaluate(self.upstream, self.reports, [],
                {"upstream": 0, "swift": 0}, [required])[0])

    def test_transport_assertion_caught_by_provider_cannot_count_as_conformance(self):
        assertion = {**self.call, "operation": "assertion", "failure": {
            "code": "bridgeAssertion", "operation": "conformance.fixture.assertion",
            "message": "expected request header was missing",
        }}
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream"}]
        conformant, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [self.call, assertion],
            {"upstream": 0, "swift": 0}, original)
        self.assertFalse(conformant)
        self.assertEqual(cases[0]["conformanceStatus"], "mismatch")
        self.assertEqual(cases[0]["nativeFailures"], [])
        self.assertEqual(cases[0]["bridgeFailures"], [assertion["failure"]])

    def test_typescript_pass_through_is_not_swift_conformance(self):
        self.assertFalse(self.evaluate([]))
        self.assertFalse(self.evaluate([{"file": self.file, "protocol": "anthropic-messages"}]))
        self.assertFalse(self.evaluate([{**self.call, "operation": "catalog"}]))

    def test_skip_audit_preserves_unexecuted_status_and_observes_the_actual_condition(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "case.test.ts"
            source.write_text('describe.skipIf(!configured)("group", () => {\n'
                              '  it("conditional", () => {});\n'
                              '  it.skip("conditional", () => {});\n});\n')
            conditional = {"ancestorTitles": ["group"], "title": "conditional", "status": "skipped",
                           "location": {"line": 2, "column": 3}}
            explicit = {**conditional, "location": {"line": 3, "column": 3}}
            reports = {key: {"testResults": [{"name": str(source), "assertionResults": [conditional, explicit]}]}
                       for key in ["upstream", "swift"]}
            observation = {"file": str(source), "line": 1, "declaration": "describe", "title": "group"}
            observed = {key: [{**observation, "skipped": value}] for key, value in [("upstream", True), ("swift", False)]}
            evidence = CONFORMANCE.skip_evidence(root, reports, observed)
            self.assertTrue(evidence[(source.name, "group > conditional", 0)]["upstream"]["explained"])
            self.assertEqual(evidence[(source.name, "group > conditional", 0)]["upstream"]["conditionalSkips"][0]["expression"], "!configured")
            self.assertFalse(evidence[(source.name, "group > conditional", 0)]["swift"]["explained"])
            self.assertEqual(evidence[(source.name, "group > conditional", 0)]["upstream"]["location"]["line"], 2)
            self.assertEqual(evidence[(source.name, "group > conditional", 1)]["upstream"]["location"]["line"], 3)
            self.assertTrue(evidence[(source.name, "group > conditional", 1)]["swift"]["explicitSkips"])
            conformant, cases = CONFORMANCE.evaluate(root, reports, [], {"upstream": 0, "swift": 0})
            self.assertFalse(conformant)
            self.assertEqual([case["conformanceStatus"] for case in cases], ["not_executed", "not_executed"])

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

    def test_duplicate_case_cannot_reuse_another_instances_native_evidence(self):
        for implementation in ["upstream", "swift"]:
            self.reports[implementation]["testResults"][0]["assertionResults"] = [
                {**self.case, "meta": {"piConformanceInstanceID": identity}}
                for identity in ["first", "second"]
            ]
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream",
                     "caseInstanceID": identity} for identity in ["first", "second"]]
        conformant, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [{**self.call, "caseInstanceID": "first"}],
            {"upstream": 0, "swift": 0}, original)
        self.assertFalse(conformant)
        self.assertEqual([case["conformanceStatus"] for case in cases], ["passed", "bridge_gap"])

    def test_duplicate_case_without_instance_identity_cannot_share_name_only_evidence(self):
        for implementation in ["upstream", "swift"]:
            self.reports[implementation]["testResults"][0]["assertionResults"] *= 2
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream"}]
        conformant, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [self.call], {"upstream": 0, "swift": 0}, original)
        self.assertFalse(conformant)
        self.assertEqual([case["conformanceStatus"] for case in cases], ["bridge_gap", "bridge_gap"])

    def test_formal_run_requires_instance_identity_even_for_unique_names(self):
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream"}]
        conformant, _ = CONFORMANCE.evaluate(
            self.upstream, self.reports, [self.call], {"upstream": 0, "swift": 0}, original,
            require_case_instances=True)
        self.assertFalse(conformant)

    def test_instance_identity_is_local_to_each_implementation(self):
        self.reports["upstream"]["testResults"][0]["assertionResults"][0]["meta"] = {
            "piConformanceInstanceID": "source-instance"}
        self.reports["swift"]["testResults"][0]["assertionResults"][0]["meta"] = {
            "piConformanceInstanceID": "native-instance"}
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream",
                     "caseInstanceID": "source-instance"}]
        conformant, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [{**self.call, "caseInstanceID": "native-instance"}],
            {"upstream": 0, "swift": 0}, original, require_case_instances=True)
        self.assertTrue(conformant)
        self.assertEqual(cases[0]["upstreamCaseInstanceID"], "source-instance")
        self.assertEqual(cases[0]["swiftCaseInstanceID"], "native-instance")

    def test_catalog_lookup_cannot_substitute_for_reasoning_metadata_computation(self):
        original = [{"file": self.file, "test": "schema > preserves input", "operation": operation}
                    for operation in ["catalog", "catalog.reasoning"]]
        call = {**self.call, "operation": "catalog"}
        conformant, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [call], {"upstream": 0, "swift": 0}, original)
        self.assertFalse(conformant)
        self.assertEqual(cases[0]["missingSwiftOperations"], ["catalog.reasoning"])

    def test_cached_value_requires_its_actual_native_origin(self):
        origin = {"id": "catalog-result", "sha256": "a" * 64}
        access = {**self.call, "operation": "catalog", "entrypoint": "value-access", "valueOrigin": origin}
        producer = {**self.call, "test": None, "operation": "catalog", "entrypoint": "value-produced",
                    "valueOrigin": origin}
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "catalog"}]
        for production, expected in [
            ([], False), ([producer], True),
            ([{**producer, "file": self.file + ".other"}], False),
            ([{**producer, "valueOrigin": {**origin, "sha256": "b" * 64}}], False),
        ]:
            conformant, cases = CONFORMANCE.evaluate(
                self.upstream, self.reports, [*production, access],
                {"upstream": 0, "swift": 0}, original)
            self.assertEqual(conformant, expected)
            if expected:
                self.assertEqual(cases[0]["swiftValueAccesses"], 1)
                self.assertEqual(cases[0]["swiftOperationInvocations"], 0)

    def test_audited_caller_case_is_visible_and_is_not_a_native_pass(self):
        audit = {("packages/ai/test/schema.test.ts", "schema > preserves input", 0): {"rule": "caller"}}
        conformant, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [], {"upstream": 0, "swift": 0}, scope_audit=audit)
        self.assertFalse(conformant)
        self.assertEqual(cases[0]["conformanceStatus"], "outside_scope")
        self.assertEqual(cases[0]["swiftInvocations"], 0)
        self.assertEqual(cases[0]["scopeAudit"], {"rule": "caller"})

    def test_scope_audit_cannot_hide_provider_behavior_or_assertion_failures(self):
        audit = {("packages/ai/test/schema.test.ts", "schema > preserves input", 0): {"rule": "caller"}}
        original = [{"file": self.file, "test": "schema > preserves input", "operation": "stream"}]
        conformant, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [self.call], {"upstream": 0, "swift": 0}, original, scope_audit=audit)
        self.assertFalse(conformant)
        self.assertEqual(cases[0]["conformanceStatus"], "scope_audit_conflict")
        self.reports["swift"]["testResults"][0]["assertionResults"][0]["status"] = "failed"
        conformant, cases = CONFORMANCE.evaluate(
            self.upstream, self.reports, [], {"upstream": 0, "swift": 1}, scope_audit=audit)
        self.assertFalse(conformant)
        self.assertEqual(cases[0]["conformanceStatus"], "mismatch")

    def test_scope_audit_is_bound_to_original_tests_source_and_prior_ownership_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "repo"
            upstream = Path(directory) / "upstream"
            contract = repo / "AGENTS.md"
            contract.parent.mkdir(parents=True)
            contract.write_text("Provider runtime ownership contract")
            test = upstream / "packages/ai/test/schema.test.ts"
            test.parent.mkdir(parents=True)
            test.write_text("unchanged upstream test")
            source = upstream / "packages/ai/src/caller.ts"
            source.parent.mkdir(parents=True)
            source.write_text("export function recover() {}")
            sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            reason = "Outside provider scope: caller recovery"
            manifest = {"suites": ["schema.test.ts"], "excludedSuites": {"retry.test.ts": reason}}
            audit = {"schemaVersion": 1, "upstreamRevision": "0" * 40,
                     "contract": {"path": "AGENTS.md", "sha256": sha(contract)},
                     "rules": {"caller": {"existingSuiteRules": [{"suite": "retry.test.ts",
                         "sha256": hashlib.sha256(reason.encode()).hexdigest()}]}},
                     "cases": [{"upstreamTest": "packages/ai/test/schema.test.ts", "name": "case", "occurrence": 0,
                         "testSHA256": sha(test), "rule": "caller", "references": [{"path": "packages/ai/src/caller.ts",
                             "symbol": "recover", "sha256": sha(source)}]}]}
            path = repo / "Scripts/Conformance/scope-audit.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(audit))
            self.assertEqual(len(CONFORMANCE.load_scope_audit(repo, upstream, manifest, "0" * 40)), 1)
            for changed in [contract, test, source]:
                original = changed.read_bytes()
                changed.write_text("changed")
                with self.assertRaises(ValueError):
                    CONFORMANCE.load_scope_audit(repo, upstream, manifest, "0" * 40)
                changed.write_bytes(original)
            manifest["excludedSuites"]["retry.test.ts"] = "Outside scope changed"
            with self.assertRaises(ValueError):
                CONFORMANCE.load_scope_audit(repo, upstream, manifest, "0" * 40)

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
