"""Regression checks for missing aggregate values and unapproved dispositions."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class AggregateParityGate(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for directory in ("src/contracts", "src/lib/owner_local", "src/hub/domain", "src/hub/service/taskv2", "src/hub/service/taskchain", "docs"):
            shutil.copytree(ROOT / directory, self.root / directory)
        (self.root / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/check-owner-aggregate-parity.py", self.root / "scripts")

    def gate(self, expected=None):
        result = subprocess.run([sys.executable, "scripts/check-owner-aggregate-parity.py"], cwd=self.root, capture_output=True, text=True)
        if expected is None:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("240 original fields / 23 structs", result.stdout)
            self.assertIn("82 signed methods", result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr + result.stdout)

    def change_json(self, path, edit):
        file = self.root / path
        value = json.loads(file.read_text())
        edit(value)
        file.write_text(json.dumps(value))

    def test_complete_gate(self):
        self.gate()

    def test_original_fixture_value_cannot_disappear(self):
        def remove(value):
            entry = next(row for row in value["metadata"] if row["kind"] == "review")
            body = json.loads(entry["raw"])
            del body["records"][0]["findings_json"]
            entry["raw"] = json.dumps(body)
        self.change_json("src/contracts/fixtures/owner-native-aggregate.json", remove)
        self.gate("Fixture is missing original field values: Task_Review")

    def test_storage_mapping_cannot_be_invented(self):
        self.change_json("docs/owner-local-parity-evidence.json", lambda value: value["structs"]["Task_Lease"]["storage"].update({"lease_id": "invented_table.lease_id"}))
        self.gate("Missing storage mapping: Task_Lease.lease_id")

    def test_required_rows_cannot_remain_partial(self):
        path = self.root / "docs/owner-local-aggregate-parity.md"
        path.write_text(path.read_text().replace("**CANONICAL**", "**PARTIAL**", 1))
        self.gate("Unresolved required ledger row")

    def test_signed_method_cannot_lose_family(self):
        def remove(value):
            for family in value["command_families"]:
                if "workflow.read" in family["methods"]:
                    family["methods"].remove("workflow.read")
        self.change_json("docs/owner-local-parity-evidence.json", remove)
        self.gate("Signed methods without a canonical family")

    def test_unapproved_milestone_cannot_hide_gap(self):
        self.change_json("docs/owner-local-parity-evidence.json", lambda value: value["external_milestones"].append({"id": "C5", "scope": "gap", "approved_by": value["scope_decision"]}))
        self.gate("Unapproved external disposition")

    def test_full_brief_vocabulary_is_required(self):
        def remove(value):
            body = json.loads(value["operational_brief"])
            del body["requires_user_approval"]
            value["operational_brief"] = json.dumps(body)
        self.change_json("src/contracts/fixtures/owner-native-aggregate.json", remove)
        self.gate("Rich fixture does not cover the full original brief vocabulary")

if __name__ == "__main__":
    unittest.main()
