"""Signed release manifest: generate, sign with an ephemeral key, verify, reject tampering.

Run with: python3 -I scripts/release/test_release_manifest.py
Needs `minisign` on PATH (or MINISIGN=<path>); skipped otherwise.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_manifest", ROOT / "scripts/release/release-manifest.py")
RM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RM)
MINISIGN = os.environ.get("MINISIGN") or shutil.which("minisign")
COMMIT = "0123456789abcdef0123456789abcdef01234567"
TAG = "v9.8.7-rc.1"
NOW = 1_800_000_000


def keygen(directory, name):
    pub, sec = directory / f"{name}.pub", directory / f"{name}.key"
    subprocess.run([MINISIGN, "-G", "-W", "-p", str(pub), "-s", str(sec)],
                   check=True, capture_output=True, stdin=subprocess.DEVNULL)
    return pub, sec


def sign(sec, message, comment, password=None):
    cmd = [MINISIGN, "-S", "-s", str(sec), "-m", str(message), "-t", comment]
    subprocess.run(cmd, check=True, capture_output=True,
                   input=(password + "\n").encode() if password else b"")
    return Path(str(message) + ".minisig")


@unittest.skipUnless(MINISIGN, "minisign is not installed")
class ReleaseManifestTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.keys = self.tmp / "pinned"
        self.keys.mkdir()
        self.secrets = self.tmp / "secrets"
        self.secrets.mkdir()
        self.pub1, self.sec1 = keygen(self.secrets, "release-1")
        self.pub2, self.sec2 = keygen(self.secrets, "release-2")
        shutil.copy(self.pub1, self.keys)
        shutil.copy(self.pub2, self.keys)
        self.dist = self.tmp / "dist"
        self.dist.mkdir()
        self.assets = []
        for target, ext in (("linux-amd64", "tar.gz"), ("windows-amd64", "zip")):
            path = self.dist / f"heimdall-local-{target}-{TAG}.{ext}"
            path.write_bytes(os.urandom(4096) + target.encode())
            self.assets.append((target, str(path)))
        self.policy = RM.load_policy(RM.DEFAULT_POLICY)

    def release(self, sec=None, key_id=None, comment=None):
        sec = sec or self.sec1
        key_id = key_id or RM.public_key_id(self.pub1)
        manifest = RM.build_manifest(TAG, COMMIT, key_id, self.assets, self.policy)
        path = self.tmp / "heimdall-release-manifest.json"
        path.write_bytes(RM.canonical_json(manifest))
        sig = sign(sec, path, comment or RM.trusted_comment(manifest, self.policy, NOW))
        return path, sig

    def verify(self, manifest, sig, **kw):
        kw.setdefault("now", NOW + 60)
        return RM.verify(manifest, sig, self.keys, self.dist, minisign=MINISIGN, **kw)

    def test_pinned_key_verifies_manifest_and_assets(self):
        manifest, sig = self.release()
        verified = self.verify(manifest, sig)
        self.assertEqual(verified["tag"], TAG)
        self.assertEqual(verified["version"], TAG[1:])
        self.assertEqual(verified["commit"], COMMIT)
        self.assertEqual(verified["min_engine"], self.policy["min_engine"])
        self.assertEqual(verified["journal_schema"], self.policy["journal_schema"])
        entry = verified["targets"]["windows-amd64"]
        self.assertEqual(entry["asset"], f"heimdall-local-windows-amd64-{TAG}.zip")
        self.assertEqual(entry["size"], (self.dist / entry["asset"]).stat().st_size)
        trusted = json.loads(RM.parse_signature(sig)[1])
        self.assertEqual(trusted, {"version": TAG, "seq": NOW, "expires": NOW + 365 * 86400})

    def test_second_pinned_key_verifies_after_rotation(self):
        manifest, sig = self.release(self.sec2, RM.public_key_id(self.pub2))
        self.assertEqual(self.verify(manifest, sig)["key_id"], RM.public_key_id(self.pub2))

    def test_single_target_check_ignores_other_assets(self):
        manifest, sig = self.release()
        (self.dist / f"heimdall-local-windows-amd64-{TAG}.zip").unlink()
        self.verify(manifest, sig, targets=["linux-amd64"])
        with self.assertRaisesRegex(RM.Rejected, "missing asset"):
            self.verify(manifest, sig)

    def test_tampered_asset_is_rejected(self):
        manifest, sig = self.release()
        asset = self.dist / f"heimdall-local-linux-amd64-{TAG}.tar.gz"
        data = bytearray(asset.read_bytes())
        data[100] ^= 0x01
        asset.write_bytes(bytes(data))
        with self.assertRaisesRegex(RM.Rejected, "sha256 mismatch"):
            self.verify(manifest, sig)

    def test_truncated_asset_is_rejected(self):
        manifest, sig = self.release()
        asset = self.dist / f"heimdall-local-linux-amd64-{TAG}.tar.gz"
        asset.write_bytes(asset.read_bytes()[:-1])
        with self.assertRaisesRegex(RM.Rejected, "size"):
            self.verify(manifest, sig)

    def test_tampered_manifest_is_rejected(self):
        manifest, sig = self.release()
        doc = json.loads(manifest.read_text())
        doc["targets"]["linux-amd64"]["sha256"] = "0" * 64
        manifest.write_bytes(RM.canonical_json(doc))
        with self.assertRaisesRegex(RM.Rejected, "minisign rejected"):
            self.verify(manifest, sig)

    def test_tampered_trusted_comment_is_rejected(self):
        manifest, sig = self.release()
        lines = sig.read_text().splitlines()
        lines[2] = lines[2].replace(str(NOW + 365 * 86400), str(NOW + 3650 * 86400))
        sig.write_text("\n".join(lines) + "\n")
        with self.assertRaisesRegex(RM.Rejected, "minisign rejected"):
            self.verify(manifest, sig)

    def test_unpinned_key_is_rejected(self):
        rogue_pub, rogue_sec = keygen(self.secrets, "rogue")
        manifest, sig = self.release(rogue_sec, RM.public_key_id(rogue_pub))
        with self.assertRaisesRegex(RM.Rejected, "not pinned"):
            self.verify(manifest, sig)

    def test_manifest_key_id_must_match_signing_key(self):
        manifest, sig = self.release(self.sec1, RM.public_key_id(self.pub2))
        with self.assertRaisesRegex(RM.Rejected, "differs from signing key"):
            self.verify(manifest, sig)

    def test_trusted_comment_must_name_the_release(self):
        manifest, sig = self.release(comment=json.dumps({"version": "v0.0.1", "seq": NOW, "expires": NOW + 99}))
        with self.assertRaisesRegex(RM.Rejected, "version does not match"):
            self.verify(manifest, sig)

    def test_expired_manifest_is_rejected(self):
        manifest, sig = self.release()
        with self.assertRaisesRegex(RM.Rejected, "expired"):
            self.verify(manifest, sig, now=NOW + 365 * 86400)

    def test_no_pinned_keys_fails_closed(self):
        manifest, sig = self.release()
        empty = self.tmp / "empty"
        empty.mkdir()
        with self.assertRaisesRegex(RM.Rejected, "no pinned public keys"):
            RM.verify(manifest, sig, empty, self.dist, now=NOW, minisign=MINISIGN)

    def test_password_protected_key_signs_from_stdin(self):
        # CI feeds RELEASE_MINISIGN_PASSWORD on stdin; keep that path working.
        pub, sec = self.secrets / "pw.pub", self.secrets / "pw.key"
        subprocess.run([MINISIGN, "-G", "-p", str(pub), "-s", str(sec)], check=True,
                       capture_output=True, input=b"hunter2\nhunter2\n")
        shutil.copy(pub, self.keys)
        manifest_doc = RM.build_manifest(TAG, COMMIT, RM.public_key_id(pub), self.assets, self.policy)
        manifest = self.tmp / "pw-manifest.json"
        manifest.write_bytes(RM.canonical_json(manifest_doc))
        sig = sign(sec, manifest, RM.trusted_comment(manifest_doc, self.policy, NOW), password="hunter2")
        self.verify(manifest, sig)

    def test_cli_exit_codes(self):
        manifest, sig = self.release()
        script = str(ROOT / "scripts/release/release-manifest.py")
        base = ["python3", "-I", script, "verify", "--manifest", str(manifest), "--signature", str(sig),
                "--keys-dir", str(self.keys), "--dist", str(self.dist), "--minisign", MINISIGN,
                "--now", str(NOW + 1)]
        self.assertEqual(subprocess.run(base, capture_output=True).returncode, 0)
        (self.dist / f"heimdall-local-linux-amd64-{TAG}.tar.gz").write_bytes(b"evil")
        failed = subprocess.run(base, capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1)
        self.assertIn("REJECTED", failed.stderr)
        key_id = subprocess.run(["python3", "-I", script, "key-id", str(sig)], capture_output=True, text=True)
        self.assertEqual(key_id.stdout.strip(), RM.public_key_id(self.pub1))
        # An internal failure (here: no minisign binary) is exit 3, never the
        # "rejected" verdict a tamper test could mistake for success.
        broken = base[:base.index("--minisign") + 1] + [str(self.tmp / "no-such-minisign")] + base[base.index("--minisign") + 2:]
        crashed = subprocess.run(broken, capture_output=True, text=True)
        self.assertEqual(crashed.returncode, 3, crashed.stderr)
        self.assertIn("not a verdict", crashed.stderr)

    def test_shipped_policy_and_pinned_keys_are_well_formed(self):
        self.assertGreaterEqual(self.policy["expires_after_days"], 1)
        pinned = sorted(RM.DEFAULT_KEYS_DIR.glob("*.pub"))
        if pinned:
            # Rotation needs the current key and the next one pinned together.
            self.assertEqual(len(RM.pinned_keys(RM.DEFAULT_KEYS_DIR)), 2, pinned)


if __name__ == "__main__":
    unittest.main()
