"""Offline tests only: never invoke the proposed root transaction or provider."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "scripts/darwin-protected-native"
SCRIPT = ASSETS / "install-protection.py"
spec = importlib.util.spec_from_file_location("proposal", SCRIPT)
proposal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proposal)


class ProtectedNativeProposal(unittest.TestCase):
    def test_cli_apply_refuses_before_mutation_even_with_root_claim(self):
        with mock.patch.object(sys, "argv", [str(SCRIPT), "--apply", "/missing"]), \
                mock.patch.object(os, "geteuid", return_value=0), \
                mock.patch.object(proposal, "proposed_install") as install:
            with self.assertRaises(SystemExit) as error:
                proposal.main()
            self.assertEqual(error.exception.code, 78)
            install.assert_not_called()
        completed = subprocess.run([sys.executable, str(SCRIPT), "--apply", "/missing"],
                                   capture_output=True, text=True)
        self.assertEqual(completed.returncode, 78)
        self.assertIn("REFUSED", completed.stderr)

    def test_pin_and_proposal_agree_and_no_manifest_enables_admission(self):
        pin = json.loads((ROOT / "tools/pty_host/fixtures/codex-darwin-x64-0.162.0.json").read_text())
        data = json.loads((ASSETS / "proposal.json").read_text())
        self.assertEqual(data["native_sha256"], pin["native_sha256"])
        self.assertEqual(proposal.SHA, pin["native_sha256"])
        self.assertEqual(data["archive_url"], pin["url"])
        self.assertEqual(data["archive_integrity"], pin["integrity"])
        self.assertEqual(data["archive_member"], pin["member"])
        self.assertFalse(data["production_admissible"])
        self.assertFalse(data["closure_proven"])
        self.assertFalse(data["enabled"])
        result = subprocess.run([sys.executable, str(SCRIPT), "--plan"],
                                capture_output=True, text=True, check=True)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["version"], data["version"])
        self.assertFalse(plan["apply_available"])

    def test_copy_creates_independent_inode_and_preheld_source_writer_cannot_mutate_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, target = root / "input", root / "output"
            original = b"\xcf\xfa\xed\xfeoriginal"
            source.write_bytes(original)
            with source.open("r+b") as preheld:
                proposal.copy_verified(source, target, hashlib.sha256(original).hexdigest())
                preheld.write(b"changed!")
                preheld.flush()
            self.assertEqual(target.read_bytes(), original)
            self.assertNotEqual(source.stat().st_ino, target.stat().st_ino)
            self.assertEqual(target.stat().st_nlink, 1)

    def test_symlink_fifo_existing_target_tamper_and_oversize_refuse(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, target = root / "input", root / "output"
            source.write_bytes(b"\xcf\xfa\xed\xfeimage")
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            link = root / "link"
            link.symlink_to(source)
            with self.assertRaises(OSError):
                proposal.copy_verified(link, target, digest)
            fifo = root / "fifo"
            os.mkfifo(fifo)
            with self.assertRaisesRegex(ValueError, "regular"):
                proposal.copy_verified(fifo, target, digest)
            with self.assertRaisesRegex(ValueError, "digest"):
                proposal.copy_verified(source, target, "0" * 64)
            # A failed copy remains unpublished, and never gets overwritten.
            with self.assertRaises(FileExistsError):
                proposal.copy_verified(source, target, digest)
            with mock.patch.object(proposal, "MAX_IMAGE", 4):
                with self.assertRaisesRegex(ValueError, "bounded"):
                    proposal.copy_verified(source, root / "large", digest)

    def test_lifecycle_has_no_deletion_or_implicit_enablement(self):
        data = json.loads((ASSETS / "lifecycle.json").read_text())
        self.assertFalse(data["update"]["delete_previous"])
        self.assertFalse(data["update"]["auto_select"])
        self.assertFalse(data["drain"]["permits_image_deletion"])
        self.assertEqual(data["uninstall"]["filesystem_commands"], [])
        self.assertEqual(data["rollback"]["filesystem_commands"], [])


if __name__ == "__main__":
    unittest.main()
