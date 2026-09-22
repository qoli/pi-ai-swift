"""Ensure identity coverage cannot be supplied by an unrelated rich fixture."""

import importlib.util
import json
import pathlib
import shutil
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "coverage_gate", ROOT / "Scripts/check-differential-coverage.py"
)
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
INVENTORY = "Fixtures/Differential/ResponseBranchInventory.json"
CASES = "Fixtures/Differential/Cases/response-rich.json"
ORACLE = "Fixtures/Differential/Oracle/response-rich.json"


class IdentityCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        inventory = json.loads((ROOT / INVENTORY).read_text())
        paths = {INVENTORY, "Upstream.lock.json"}
        for source in inventory["evidenceSources"]:
            paths.update(source[key] for key in ("oracle", "cases", "test") if key in source)
        for relative in paths:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        self.protocols = {
            protocol for branch in inventory["branches"] for protocol in branch["protocols"]
        }

    def edit(self, relative, change):
        path = self.root / relative
        value = json.loads(path.read_text())
        change(value)
        path.write_text(json.dumps(value))

    def validate(self):
        return GATE.validate_branch_inventory(self.root, self.protocols, "responseEvents")

    def test_checked_in_identity_cases_close_coverage(self):
        closed, gaps = self.validate()
        self.assertEqual(set(closed), self.protocols)
        self.assertFalse(any(gaps.values()))

    def test_missing_alias_observation_fails(self):
        self.edit(ORACLE, lambda value: value["identityCases"].pop("completions.identity-alias"))
        with self.assertRaisesRegex(SystemExit, "invalid.*named scenario"):
            self.validate()

    def test_removing_input_and_observation_cannot_reuse_rich_case(self):
        self.edit(CASES, lambda value: value.__setitem__(
            "identityCases", [case for case in value["identityCases"]
                              if case["caseID"] != "completions.identity-alias"]))
        self.edit(ORACLE, lambda value: value["identityCases"].pop("completions.identity-alias"))
        with self.assertRaisesRegex(SystemExit, "lacks executable oracle/test.*completions.identity-alias"):
            self.validate()

    def test_duplicate_identity_case_fails(self):
        self.edit(CASES, lambda value: value["identityCases"].append(value["identityCases"][0]))
        with self.assertRaisesRegex(SystemExit, "invalid.*named scenario"):
            self.validate()

    def test_stale_input_revision_fails(self):
        self.edit(CASES, lambda value: value.__setitem__("upstreamRevision", "stale"))
        with self.assertRaisesRegex(SystemExit, "malformed.*named scenarios"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
