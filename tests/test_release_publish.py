"""Immutable releases (chain task T6): publish-release.sh and check-promotion.sh
against a stateful fake `gh`.

Run with: python3 -I tests/test_release_publish.py
The promotion tests need `minisign` on PATH (or MINISIGN=<path>); they are
skipped otherwise (e.g. `nix shell nixpkgs#minisign -c python3 -I ...`).
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
PUBLISH = ROOT / "scripts/release/publish-release.sh"
MINISIGN = os.environ.get("MINISIGN") or shutil.which("minisign")
TAG = "v1.2.3"
WRITE_VERBS = {"create", "delete", "edit", "upload", "delete-asset"}

# Stateful fake of the `gh` subcommands the scripts use. State lives in
# $FAKE_GH_STATE (JSON): {"release": null | {"draft": bool, "prerelease": bool,
# "immutable": bool, "assets": {name: content-file}}}. Faults via env:
#   FAKE_GH_CREATE_FAIL=1   first create uploads only the first asset, then 502
#   FAKE_GH_EDIT_FAIL=1     first edit is applied server-side, then 502
#   FAKE_GH_TAMPER=<name>   create stores different bytes for that asset
#   FAKE_GH_NO_DIGEST=1     asset listing has no digests
#   FAKE_GH_VIEW_ERROR=1    every view fails with a non-transient error
#   FAKE_GH_NO_ATTEST=<name> attestation verify fails for that file
FAKE_GH = r'''#!/usr/bin/env python3
import hashlib, json, os, shutil, sys
from pathlib import Path

args = sys.argv[1:]
state_path = Path(os.environ["FAKE_GH_STATE"])
blobs = state_path.parent / "blobs"
blobs.mkdir(exist_ok=True)
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
state = json.loads(state_path.read_text()) if state_path.exists() else {"release": None}
counters = state.setdefault("counters", {})

def save():
    state_path.write_text(json.dumps(state))

def fail(msg, code=1):
    save()
    sys.stderr.write(msg + "\n")
    sys.exit(code)

def opt(name):
    return args[args.index(name) + 1] if name in args else None

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def store(name, src, tamper=False):
    data = Path(src).read_bytes()
    if tamper:
        data += b"tampered"
    dst = blobs / f"{len(list(blobs.iterdir()))}-{name}"
    dst.write_bytes(data)
    return str(dst)

rel = state["release"]
group, verb = args[0], args[1]
counters[verb] = counters.get(verb, 0) + 1
if group == "attestation" and verb == "verify":
    if Path(args[2]).name == os.environ.get("FAKE_GH_NO_ATTEST"):
        fail("no attestations found")
    save(); sys.exit(0)
if group != "release":
    fail(f"unexpected gh {args}", 9)
if verb == "view":
    if os.environ.get("FAKE_GH_VIEW_ERROR"):
        fail("HTTP 401: Bad credentials")
    if rel is None:
        fail("release not found")
    field = opt("--json")
    if field == "isDraft":
        print("true" if rel["draft"] else "false")
    elif field == "isImmutable":
        print("true" if rel["immutable"] else "false")
    elif field == "assets":
        for name, blob in rel["assets"].items():
            d = "" if os.environ.get("FAKE_GH_NO_DIGEST") else "sha256:" + digest(blob)
            print(f"{name} {d}")
    else:
        fail(f"unexpected view {args}", 9)
elif verb == "delete":
    if rel is None:
        fail("release not found")
    state["release"] = None
elif verb == "create":
    if rel is not None:
        fail("HTTP 422: Validation Failed (already_exists)")
    files = []
    i = 3
    while i < len(args):
        if args[i].startswith("--"):
            i += 1 if args[i] in ("--draft", "--prerelease") else 2
            continue
        files.append(args[i]); i += 1
    rel = state["release"] = {"draft": True, "prerelease": "--prerelease" in args,
                              "immutable": False, "assets": {}, "target": opt("--target")}
    if os.environ.get("FAKE_GH_CREATE_FAIL") and counters["create"] == 1:
        rel["assets"][Path(files[0]).name] = store(Path(files[0]).name, files[0])
        fail("HTTP 502: Bad Gateway")
    for f in files:
        name = Path(f).name
        rel["assets"][name] = store(name, f, name == os.environ.get("FAKE_GH_TAMPER"))
    if "--draft" not in args:
        rel["draft"] = False
elif verb == "edit":
    if rel is None:
        fail("release not found")
    if "--draft=false" in args:
        rel["draft"] = False
        rel["immutable"] = bool(os.environ.get("FAKE_GH_IMMUTABLE_ON_PUBLISH"))
    if os.environ.get("FAKE_GH_EDIT_FAIL") and counters["edit"] == 1:
        fail("HTTP 502: Bad Gateway")
elif verb == "download":
    if rel is None:
        fail("release not found")
    out = Path(opt("--dir"))
    out.mkdir(parents=True, exist_ok=True)
    patterns = [args[i + 1] for i, a in enumerate(args) if a == "--pattern"]
    for p in patterns:
        if p not in rel["assets"]:
            fail(f"no assets match {p}")
        shutil.copyfile(rel["assets"][p], out / p)
elif verb in ("verify", "verify-asset"):
    pass
elif verb in ("upload", "delete-asset"):
    fail(f"{verb} must never be called", 9)
else:
    fail(f"unexpected gh {args}", 9)
save()
'''


class FakeGh:
    def __init__(self, root: Path):
        self.root = root
        self.bin = root / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.state = root / "state" / "state.json"
        self.state.parent.mkdir()
        self.log = root / "gh.log"

    def seed(self, release):
        """release: None or {"draft","prerelease","immutable","assets": {name: bytes}}."""
        if release is not None:
            blobs = self.state.parent / "blobs"
            blobs.mkdir(exist_ok=True)
            assets = {}
            for name, data in release["assets"].items():
                p = blobs / f"seed-{name}"
                p.write_bytes(data)
                assets[name] = str(p)
            release = {**release, "assets": assets}
        self.state.write_text(json.dumps({"release": release}))

    def release(self):
        rel = json.loads(self.state.read_text())["release"]
        if rel is not None:
            rel = {**rel, "assets": {n: Path(b).read_bytes() for n, b in rel["assets"].items()}}
        return rel

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def write_calls(self):
        return [c for c in self.calls() if c[0] == "release" and c[1] in WRITE_VERBS]

    def run(self, argv, **env):
        self.log.unlink(missing_ok=True)
        full_env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FAKE_GH_STATE": str(self.state),
            "FAKE_GH_LOG": str(self.log),
            "HEIMDALL_GH_RETRY_MAX_ATTEMPTS": "3",
            "HEIMDALL_GH_RETRY_DELAY_SECONDS": "0",
            **env,
        }
        return subprocess.run(argv, cwd=self.root, env=full_env, text=True, capture_output=True)


class PublishReleaseTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.gh = FakeGh(self.root)
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.files = {}
        for name in (f"heimdall-local-linux-amd64-{TAG}.tar.gz", f"heimdall-local-windows-amd64-{TAG}.zip",
                     "SHA256SUMS", "heimdall-release-manifest.json"):
            data = os.urandom(512) + name.encode()
            (self.dist / name).write_bytes(data)
            self.files[name] = data
        self.notes = self.root / "notes.md"
        self.notes.write_text("notes\n")

    def publish(self, *extra, **env):
        argv = [str(PUBLISH), "publish", "--tag", TAG, "--commit", "abc123", "--notes-file", str(self.notes),
                *extra, "--", *sorted(str(self.dist / n) for n in self.files)]
        return self.gh.run(argv, **env)

    def assertPublishedExactly(self, files):
        rel = self.gh.release()
        self.assertIsNotNone(rel)
        self.assertFalse(rel["draft"])
        self.assertEqual(rel["assets"], files)

    def test_fresh_tag_is_created_as_draft_verified_then_published(self):
        self.gh.seed(None)
        r = self.publish("--prerelease")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)
        self.assertTrue(self.gh.release()["prerelease"])
        writes = self.gh.write_calls()
        self.assertEqual([c[1] for c in writes], ["create", "edit"])
        self.assertIn("--draft", writes[0])
        self.assertIn("--prerelease", writes[0])
        self.assertNotIn("--clobber", writes[0])
        self.assertEqual(writes[1], ["release", "edit", TAG, "--draft=false"])
        self.assertIn("(draft) holds exactly the 4 verified assets", r.stdout)
        self.assertIn("(published) holds exactly the 4 verified assets", r.stdout)
        self.assertIn("isImmutable=false", r.stdout)

    def test_immutable_release_is_reported(self):
        self.gh.seed(None)
        r = self.publish(FAKE_GH_IMMUTABLE_ON_PUBLISH="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("published and immutable", r.stdout)

    def test_rerun_on_published_tag_fails_and_changes_nothing(self):
        old = {name: b"published bytes of " + name.encode() for name in self.files}
        old["Ninjy-1.2.3-x64.dmg"] = b"intel"
        self.gh.seed({"draft": False, "prerelease": True, "immutable": False, "assets": old})
        before = json.loads(self.gh.state.read_text())["release"]
        r = self.publish("--prerelease")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("already published", r.stderr)
        self.assertEqual(self.gh.write_calls(), [])
        self.assertEqual(self.gh.release()["assets"], old)
        self.assertEqual(json.loads(self.gh.state.read_text())["release"], before)

        r = self.gh.run([str(PUBLISH), "check-unpublished", TAG])
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertEqual(self.gh.write_calls(), [])

    def test_leftover_draft_is_replaced_with_exactly_this_runs_assets(self):
        stale = {name: b"stale" for name in self.files}
        stale["Ninjy-1.2.3-x64.dmg"] = b"intel from an earlier run"
        self.gh.seed({"draft": True, "prerelease": True, "immutable": False, "assets": stale})
        r = self.publish("--prerelease")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)
        self.assertEqual([c[1] for c in self.gh.write_calls()], ["delete", "create", "edit"])
        self.assertEqual(self.gh.write_calls()[0], ["release", "delete", TAG, "--yes"])

    def test_partial_create_is_retried_from_a_clean_draft(self):
        self.gh.seed(None)
        r = self.publish(FAKE_GH_CREATE_FAIL="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)
        self.assertEqual([c[1] for c in self.gh.write_calls()], ["create", "delete", "create", "edit"])

    def test_digest_mismatch_blocks_publishing(self):
        self.gh.seed(None)
        r = self.publish(FAKE_GH_TAMPER="SHA256SUMS")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("does not hold exactly the verified assets", r.stderr)
        self.assertIn("SHA256SUMS", r.stderr)
        self.assertTrue(self.gh.release()["draft"])
        self.assertNotIn("edit", [c[1] for c in self.gh.write_calls()])

    def test_assets_without_api_digest_are_downloaded_and_hashed(self):
        self.gh.seed(None)
        r = self.publish(FAKE_GH_NO_DIGEST="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)
        self.assertGreaterEqual(sum(1 for c in self.gh.calls() if c[1] == "download"), 4)

        self.gh.seed(None)
        r = self.publish(FAKE_GH_NO_DIGEST="1", FAKE_GH_TAMPER=f"heimdall-local-linux-amd64-{TAG}.tar.gz")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertTrue(self.gh.release()["draft"])

    def test_draft_input_leaves_a_verified_draft(self):
        self.gh.seed(None)
        r = self.publish("--draft")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        rel = self.gh.release()
        self.assertTrue(rel["draft"])
        self.assertEqual(rel["assets"], self.files)
        self.assertEqual([c[1] for c in self.gh.write_calls()], ["create"])

    def test_publish_retry_after_server_applied_edit_is_done(self):
        self.gh.seed(None)
        r = self.publish(FAKE_GH_EDIT_FAIL="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)
        self.assertEqual([c[1] for c in self.gh.write_calls()], ["create", "edit"])

    def test_check_unpublished(self):
        self.gh.seed(None)
        self.assertEqual(self.gh.run([str(PUBLISH), "check-unpublished", TAG]).returncode, 0)
        self.gh.seed({"draft": True, "prerelease": True, "immutable": False, "assets": {}})
        r = self.gh.run([str(PUBLISH), "check-unpublished", TAG])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("only as a draft", r.stdout)
        r = self.gh.run([str(PUBLISH), "check-unpublished", TAG], FAKE_GH_VIEW_ERROR="1")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertEqual(self.gh.write_calls(), [])

    def test_usage_errors(self):
        self.gh.seed(None)
        r = self.gh.run([str(PUBLISH), "publish", "--tag", TAG, "--commit", "c", "--notes-file", str(self.notes),
                         "--", str(self.dist / "missing")])
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.gh.calls(), [])
        other = self.root / "other"
        other.mkdir()
        (other / "SHA256SUMS").write_text("x")
        r = self.gh.run([str(PUBLISH), "publish", "--tag", TAG, "--commit", "c", "--notes-file", str(self.notes),
                         "--", str(self.dist / "SHA256SUMS"), str(other / "SHA256SUMS")])
        self.assertEqual(r.returncode, 2)
        self.assertIn("duplicate asset names", r.stderr)


def _load_manifest_tool():
    spec = importlib.util.spec_from_file_location("release_manifest", ROOT / "scripts/release/release-manifest.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@unittest.skipUnless(MINISIGN, "minisign is not installed")
class CheckPromotionTest(unittest.TestCase):
    """check-promotion.sh, run from a copy of scripts/release whose pinned key is a test key."""

    def setUp(self):
        self.rm = _load_manifest_tool()
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.gh = FakeGh(self.root)
        tree = self.root / "src" / "scripts" / "release"
        (tree / "minisign").mkdir(parents=True)
        for name in ("check-promotion.sh", "release-manifest.py"):
            shutil.copy2(ROOT / "scripts/release" / name, tree / name)
        shutil.copy(ROOT / "scripts/release/minisign/manifest-policy.json", tree / "minisign")
        self.script = tree / "check-promotion.sh"
        secrets = self.root / "secrets"
        secrets.mkdir()
        self.pub, self.sec = secrets / "k.pub", secrets / "k.key"
        subprocess.run([MINISIGN, "-G", "-W", "-p", str(self.pub), "-s", str(self.sec)],
                       check=True, capture_output=True, stdin=subprocess.DEVNULL)
        shutil.copy(self.pub, tree / "minisign" / "heimdall-release-test.pub")
        self.bundles = {f"heimdall-local-linux-amd64-{TAG}.tar.gz": os.urandom(256),
                        f"heimdall-local-windows-amd64-{TAG}.zip": os.urandom(256)}

    def signed_release(self, tag=TAG, bundles=None, extra=None):
        bundles = bundles or self.bundles
        stage = self.root / "stage"
        shutil.rmtree(stage, ignore_errors=True)
        stage.mkdir()
        assets = []
        for name, data in bundles.items():
            (stage / name).write_bytes(data)
            target = name[len("heimdall-local-"):].split(f"-{tag}")[0]
            assets.append((target, str(stage / name)))
        policy = self.rm.load_policy(self.rm.DEFAULT_POLICY)
        manifest = self.rm.build_manifest(tag, "0" * 40, self.rm.public_key_id(self.pub), assets, policy)
        mpath = stage / "heimdall-release-manifest.json"
        mpath.write_bytes(self.rm.canonical_json(manifest))
        subprocess.run([MINISIGN, "-S", "-s", str(self.sec), "-m", str(mpath),
                        "-t", self.rm.trusted_comment(manifest, policy, int(time.time()))],
                       check=True, capture_output=True, stdin=subprocess.DEVNULL)
        files = {**bundles, "heimdall-release-manifest.json": mpath.read_bytes(),
                 "heimdall-release-manifest.json.minisig": (stage / "heimdall-release-manifest.json.minisig").read_bytes(),
                 "SHA256SUMS": b"sums"}
        files.update(extra or {})
        return files

    def check(self, files, immutable=False, **env):
        self.gh.seed({"draft": False, "prerelease": True, "immutable": immutable, "assets": files})
        release_json = self.root / "release.json"
        release_json.write_text(json.dumps({"isDraft": False, "isPrerelease": True, "isImmutable": immutable,
                                            "assets": [{"name": n} for n in files]}))
        return self.gh.run([str(self.script), TAG, str(release_json), str(self.root / "work")],
                           GH_REPO="o/r", MINISIGN=MINISIGN, **env)

    def test_valid_candidate_passes(self):
        r = self.check(self.signed_release())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("signed manifest verified", r.stdout)
        self.assertIn("is not an immutable release", r.stdout)
        attested = sorted(Path(c[2]).name for c in self.gh.calls() if c[:2] == ["attestation", "verify"])
        self.assertEqual(attested, sorted([*self.bundles, "heimdall-release-manifest.json"]))
        verify = [c for c in self.gh.calls() if c[:2] == ["attestation", "verify"]][0]
        self.assertEqual(verify[verify.index("--signer-workflow") + 1],
                         "o/r/.github/workflows/release-local-binaries.yml")
        self.assertEqual(self.gh.write_calls(), [])

    def test_immutable_candidate_runs_gh_release_verify(self):
        r = self.check(self.signed_release(), immutable=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        verbs = [c[1] for c in self.gh.calls() if c[0] == "release"]
        self.assertIn("verify", verbs)
        self.assertEqual(verbs.count("verify-asset"), 3)

    def test_missing_manifest_is_rejected(self):
        files = self.signed_release()
        del files["heimdall-release-manifest.json.minisig"]
        r = self.check(files)
        self.assertEqual(r.returncode, 1)
        self.assertIn("missing asset heimdall-release-manifest.json.minisig", r.stderr)

    def test_replaced_bundle_is_rejected(self):
        files = self.signed_release()
        files[f"heimdall-local-linux-amd64-{TAG}.tar.gz"] = b"swapped"
        r = self.check(files)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("does not match the signed manifest", r.stderr)

    def test_bundle_not_in_manifest_is_rejected(self):
        files = self.signed_release(extra={f"heimdall-local-darwin-amd64-{TAG}.tar.gz": b"unsigned"})
        r = self.check(files)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("differ from the signed manifest", r.stderr)

    def test_manifest_for_another_tag_is_rejected(self):
        other = {n.replace(TAG, "v1.2.2"): d for n, d in self.bundles.items()}
        files = self.signed_release(tag="v1.2.2", bundles=other)
        r = self.check(files)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("manifest is for v1.2.2", r.stderr)

    def test_unpinned_key_is_rejected(self):
        files = self.signed_release()
        for pub in (self.script.parent / "minisign").glob("*.pub"):
            pub.unlink()
        other_pub = self.script.parent / "minisign" / "other.pub"
        subprocess.run([MINISIGN, "-G", "-W", "-p", str(other_pub), "-s", str(self.root / "other.key")],
                       check=True, capture_output=True, stdin=subprocess.DEVNULL)
        r = self.check(files)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("is not pinned", r.stderr)

    def test_missing_attestation_is_rejected(self):
        r = self.check(self.signed_release(), FAKE_GH_NO_ATTEST=f"heimdall-local-windows-amd64-{TAG}.zip")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("has no build-provenance attestation", r.stderr)


if __name__ == "__main__":
    unittest.main()
