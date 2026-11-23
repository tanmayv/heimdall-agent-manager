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
REPO = "o/r"

# Stateful fake of the GitHub REST calls (`gh api`) and `gh release`/`gh
# attestation` subcommands the scripts use. State lives in $FAKE_GH_STATE:
# {"next_id": n, "releases": [{"id", "tag", "draft", "prerelease", "immutable",
#  "assets": [{"id", "name", "blob"}]}]}. Faults via env:
#   FAKE_GH_CREATE_FAIL=1    the first create is applied, then answers HTTP 502
#   FAKE_GH_UPLOAD_FAIL=1    the 2nd upload of the run fails once with HTTP 502
#   FAKE_GH_PATCH_FAIL=1     the first PATCH is applied, then answers HTTP 502
#   FAKE_GH_RACE=1           right after publish's pre-PATCH read, another run
#                            deletes our draft and creates its own for the tag
#   FAKE_GH_TAMPER=<name>    uploads of that asset store different bytes
#   FAKE_GH_NO_DIGEST=1      release JSON has no asset digests
#   FAKE_GH_LIST_ERROR=1     listing releases fails with a non-transient error
#   FAKE_GH_IMMUTABLE_ON_PUBLISH=1  published releases report immutable
#   FAKE_GH_NO_ATTEST=<name> attestation verify fails for that file
#   FAKE_GH_ATTEST_REF=<ref> attestation verify passes only with --source-ref <ref>
FAKE_GH = r'''#!/usr/bin/env python3
import hashlib, json, os, re, shutil, sys
from pathlib import Path

args = sys.argv[1:]
state_path = Path(os.environ["FAKE_GH_STATE"])
blobs = state_path.parent / "blobs"
blobs.mkdir(exist_ok=True)
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
state = json.loads(state_path.read_text())
counters = state.setdefault("counters", {})
REPO = "o/r"

def save():
    state_path.write_text(json.dumps(state))

def fail(msg, code=1):
    save()
    sys.stderr.write(msg + "\n")
    sys.exit(code)

def count(key):
    counters[key] = counters.get(key, 0) + 1
    return counters[key]

def by_id(rid):
    return next((r for r in state["releases"] if r["id"] == rid), None)

def by_tag(tag):
    rs = [r for r in state["releases"] if r["tag"] == tag]
    pub = [r for r in rs if not r["draft"]]
    return (pub or rs or [None])[0]

def store(data):
    p = blobs / f"b{len(list(blobs.iterdir()))}"
    p.write_bytes(data)
    return str(p)

def new_release(tag, draft, prerelease):
    rid = state["next_id"]; state["next_id"] += 1
    r = {"id": rid, "tag": tag, "draft": draft, "prerelease": prerelease, "immutable": False, "assets": []}
    state["releases"].append(r)
    return r

def to_json(r):
    out = {"id": r["id"], "tag_name": r["tag"], "draft": r["draft"], "prerelease": r["prerelease"],
           "immutable": r["immutable"], "assets": [],
           "upload_url": f"https://uploads.github.com/repos/{REPO}/releases/{r['id']}/assets{{?name,label}}"}
    for a in r["assets"]:
        d = {"id": a["id"], "name": a["name"]}
        if not os.environ.get("FAKE_GH_NO_DIGEST"):
            d["digest"] = "sha256:" + hashlib.sha256(Path(a["blob"]).read_bytes()).hexdigest()
        out["assets"].append(d)
    return out

group = args[0]
if group == "api":
    method, headers, fields, inp, endpoint, paginate = "GET", [], {}, None, None, False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "-X": method = args[i + 1]; i += 2
        elif a == "-H": headers.append(args[i + 1]); i += 2
        elif a in ("-f", "-F"):
            k, v = args[i + 1].split("=", 1)
            if a == "-F" and v.startswith("@"): v = Path(v[1:]).read_text()
            elif a == "-F" and v in ("true", "false"): v = v == "true"
            fields[k] = v; i += 2
        elif a == "--input": inp = args[i + 1]; i += 2
        elif a == "--paginate": paginate = True; i += 1
        else: endpoint = a; i += 1
    base = f"repos/{REPO}/releases"
    m_up = re.fullmatch(rf"https://uploads\.github\.com/repos/{REPO}/releases/(\d+)/assets\?name=(.+)", endpoint)
    from urllib.parse import unquote_plus
    m_id = re.fullmatch(rf"{base}/(\d+)", endpoint)
    m_asset = re.fullmatch(rf"{base}/assets/(\d+)", endpoint)
    if method == "GET" and endpoint == f"{base}?per_page=100":
        if os.environ.get("FAKE_GH_LIST_ERROR"):
            fail("gh: Bad credentials (HTTP 401)")
        rs = [to_json(r) for r in state["releases"]]
        # two pages, like --paginate prints them
        print(json.dumps(rs[:1])); print(json.dumps(rs[1:]))
    elif method == "POST" and endpoint == base:
        if fields.get("draft") is not True:
            fail("create must be a draft", 9)
        r = new_release(fields["tag_name"], True, fields["prerelease"] is True)
        r["target"] = fields["target_commitish"]; r["body"] = fields["body"]
        if os.environ.get("FAKE_GH_CREATE_FAIL") and count("create") == 1:
            fail("gh: Bad Gateway (HTTP 502)")
        print(json.dumps(to_json(r)))
    elif method == "POST" and m_up:
        r = by_id(int(m_up.group(1)))
        if r is None: fail("gh: Not Found (HTTP 404)")
        if not r["draft"]: fail("upload to a published release", 9)
        n = count("upload")
        if os.environ.get("FAKE_GH_UPLOAD_FAIL") and n == 2:
            fail("gh: Bad Gateway (HTTP 502)")
        name = unquote_plus(m_up.group(2))  # how GitHub decodes the query
        data = Path(inp).read_bytes() + (b"tampered" if name == os.environ.get("FAKE_GH_TAMPER") else b"")
        aid = state["next_id"]; state["next_id"] += 1
        r["assets"].append({"id": aid, "name": name, "blob": store(data)})
        print(json.dumps({"id": aid}))
    elif m_id and method == "GET":
        r = by_id(int(m_id.group(1)))
        if r is None: fail("gh: Not Found (HTTP 404)")
        print(json.dumps(to_json(r)))
        # The 2nd read by id is publish's pre-PATCH read: right after it
        # answers, another run deletes our draft and creates its own.
        if os.environ.get("FAKE_GH_RACE") and count("get_id") == 2:
            state["releases"].remove(r)
            other = new_release(r["tag"], True, True)
            other["assets"].append({"id": 999, "name": "half-uploaded", "blob": store(b"x")})
    elif m_id and method == "DELETE":
        r = by_id(int(m_id.group(1)))
        if r is None: fail("gh: Not Found (HTTP 404)")
        if not r["draft"]: fail("delete of a published release", 9)
        state["releases"].remove(r)
    elif m_id and method == "PATCH":
        rid = int(m_id.group(1))
        n = count("patch")
        r = by_id(rid)
        if r is None: fail("gh: Not Found (HTTP 404)")
        if fields.get("draft") is False:
            r["draft"] = False
            r["immutable"] = bool(os.environ.get("FAKE_GH_IMMUTABLE_ON_PUBLISH"))
        if os.environ.get("FAKE_GH_PATCH_FAIL") and n == 1:
            fail("gh: Bad Gateway (HTTP 502)")
        print(json.dumps(to_json(r)))
    elif m_asset and method == "GET":
        for r in state["releases"]:
            for a in r["assets"]:
                if a["id"] == int(m_asset.group(1)):
                    sys.stdout.buffer.write(Path(a["blob"]).read_bytes()); save(); sys.exit(0)
        fail("gh: Not Found (HTTP 404)")
    else:
        fail(f"unexpected gh {args}", 9)
elif group == "attestation" and args[1] == "verify":
    if Path(args[2]).name == os.environ.get("FAKE_GH_NO_ATTEST"):
        fail("no attestations found")
    want = os.environ.get("FAKE_GH_ATTEST_REF")
    if want and (("--source-ref" not in args) or args[args.index("--source-ref") + 1] != want):
        fail("verification failed: source ref mismatch")
elif group == "release" and args[1] == "download":
    r = by_tag(args[2])
    if r is None: fail("release not found")
    out = Path(args[args.index("--dir") + 1])
    out.mkdir(parents=True, exist_ok=True)
    for p in [args[i + 1] for i, a in enumerate(args) if a == "--pattern"]:
        a = next((a for a in r["assets"] if a["name"] == p), None)
        if a is None: fail(f"no assets match {p}")
        shutil.copyfile(a["blob"], out / p)
elif group == "release" and args[1] in ("verify", "verify-asset"):
    pass
else:
    fail(f"unexpected gh {args}", 9)
save()
'''

WRITE_METHODS = {"POST", "PATCH", "DELETE", "PUT"}


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

    def seed(self, releases):
        """releases: [{"draft","prerelease","immutable","assets": {name: bytes}}, ...], all for TAG."""
        blobs = self.state.parent / "blobs"
        blobs.mkdir(exist_ok=True)
        out, next_id = [], 100
        for rel in releases:
            assets = []
            for name, data in rel["assets"].items():
                p = blobs / f"seed-{next_id}"
                p.write_bytes(data)
                assets.append({"id": next_id, "name": name, "blob": str(p)})
                next_id += 1
            out.append({"id": next_id, "tag": rel.get("tag", TAG), "draft": rel["draft"],
                        "prerelease": rel["prerelease"], "immutable": rel["immutable"], "assets": assets})
            next_id += 1
        self.state.write_text(json.dumps({"next_id": 1000, "releases": out}))

    def releases(self):
        """[(id, draft, {name: bytes})] for every release."""
        rs = json.loads(self.state.read_text())["releases"]
        return [(r["id"], r["draft"], {a["name"]: Path(a["blob"]).read_bytes() for a in r["assets"]}) for r in rs]

    def raw_releases(self):
        return json.loads(self.state.read_text())["releases"]

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def write_calls(self):
        """(METHOD, endpoint) of every write API call, in order."""
        out = []
        for c in self.calls():
            if c[0] != "api":
                if c[0] == "release" and c[1] not in ("download", "verify", "verify-asset", "view"):
                    out.append(("RELEASE", c[1]))
                continue
            method = c[c.index("-X") + 1] if "-X" in c else "GET"
            if method in WRITE_METHODS:
                endpoint = [a for i, a in enumerate(c[1:], 1)
                            if not a.startswith("-") and c[i - 1] not in ("-X", "-H", "-f", "-F", "--input")][0]
                out.append((method, endpoint))
        return out

    def run(self, argv, **env):
        self.log.unlink(missing_ok=True)
        full_env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FAKE_GH_STATE": str(self.state),
            "FAKE_GH_LOG": str(self.log),
            "GH_REPO": REPO,
            "HEIMDALL_GH_RETRY_MAX_ATTEMPTS": "3",
            "HEIMDALL_GH_RETRY_DELAY_SECONDS": "0",
            **env,
        }
        return subprocess.run(argv, cwd=self.root, env=full_env, text=True, capture_output=True)


def verbs(writes):
    """Compress write calls: create / upload / patch / delete."""
    out = []
    for method, endpoint in writes:
        if method == "POST" and endpoint.startswith("https://uploads."):
            out.append("upload")
        elif method == "POST":
            out.append("create")
        else:
            out.append(method.lower())
    return out


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
        rels = self.gh.releases()
        self.assertEqual(len(rels), 1, rels)
        _, draft, assets = rels[0]
        self.assertFalse(draft)
        self.assertEqual(assets, files)

    def test_fresh_tag_is_created_as_draft_verified_then_published(self):
        self.gh.seed([])
        r = self.publish("--prerelease")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)
        rel = self.gh.raw_releases()[0]
        self.assertTrue(rel["prerelease"])
        self.assertEqual(rel["target"], "abc123")
        self.assertEqual(rel["body"], "notes\n")
        writes = self.gh.write_calls()
        self.assertEqual(verbs(writes), ["create", "upload", "upload", "upload", "upload", "patch"])
        rid = rel["id"]
        self.assertEqual(writes[-1], ("PATCH", f"repos/{REPO}/releases/{rid}"))
        for method, endpoint in writes[1:5]:
            self.assertTrue(endpoint.startswith(f"https://uploads.github.com/repos/{REPO}/releases/{rid}/assets?name="))
        self.assertFalse(any("--clobber" in c for c in self.gh.calls()))
        self.assertIn(f"id {rid} (draft) holds exactly the 4 verified assets", r.stdout)
        self.assertIn(f"id {rid} (published) holds exactly the 4 verified assets", r.stdout)
        self.assertIn("immutable=false", r.stdout)

    def test_immutable_release_is_reported(self):
        self.gh.seed([])
        r = self.publish(FAKE_GH_IMMUTABLE_ON_PUBLISH="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("published and immutable", r.stdout)

    def test_rerun_on_published_tag_fails_and_changes_nothing(self):
        old = {name: b"published bytes of " + name.encode() for name in self.files}
        old["Ninjy-1.2.3-x64.dmg"] = b"intel"
        # A stale draft for the same tag must not be touched either.
        self.gh.seed([{"draft": False, "prerelease": True, "immutable": False, "assets": old},
                      {"draft": True, "prerelease": True, "immutable": False, "assets": {"x": b"y"}}])
        before = self.gh.raw_releases()
        r = self.publish("--prerelease")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("already published", r.stderr)
        self.assertEqual(self.gh.write_calls(), [])
        self.assertEqual(self.gh.raw_releases(), before)
        self.assertEqual(self.gh.releases()[0][2], old)

        r = self.gh.run([str(PUBLISH), "check-unpublished", TAG])
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertEqual(self.gh.write_calls(), [])

    def test_every_leftover_draft_is_deleted_by_id(self):
        stale = {name: b"stale" for name in self.files}
        stale["Ninjy-1.2.3-x64.dmg"] = b"intel from an earlier run"
        self.gh.seed([{"draft": True, "prerelease": True, "immutable": False, "assets": stale},
                      {"draft": True, "prerelease": True, "immutable": False, "assets": {"other": b"z"}},
                      {"tag": "v1.2.2", "draft": True, "prerelease": True, "immutable": False, "assets": {}}])
        ids = [r["id"] for r in self.gh.raw_releases()]
        r = self.publish("--prerelease")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        writes = self.gh.write_calls()
        self.assertEqual(writes[:2], [("DELETE", f"repos/{REPO}/releases/{ids[0]}"),
                                      ("DELETE", f"repos/{REPO}/releases/{ids[1]}")])
        rels = [r for r in self.gh.raw_releases() if r["tag"] == TAG]
        self.assertEqual(len(rels), 1)
        self.assertFalse(rels[0]["draft"])
        self.assertEqual({a["name"] for a in rels[0]["assets"]}, set(self.files))
        # Another tag's draft is left alone.
        self.assertIn(ids[2], [r["id"] for r in self.gh.raw_releases()])

    def test_failed_upload_is_retried_from_a_new_draft(self):
        self.gh.seed([])
        r = self.publish(FAKE_GH_UPLOAD_FAIL="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)
        self.assertEqual(verbs(self.gh.write_calls()),
                         ["create", "upload", "upload", "delete", "create"] + ["upload"] * 4 + ["patch"])

    def test_create_applied_but_answering_502_leaves_no_orphan_draft(self):
        self.gh.seed([])
        r = self.publish(FAKE_GH_CREATE_FAIL="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)  # exactly one release, published, no drafts
        self.assertEqual(verbs(self.gh.write_calls())[:3], ["create", "delete", "create"])

    def test_asset_names_are_percent_encoded(self):
        name = f"heimdall-local-linux-amd64-{TAG}+build.1.tar.gz"
        data = b"plus"
        (self.dist / name).write_bytes(data)
        self.files[name] = data
        self.gh.seed([])
        r = self.publish()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)
        self.assertTrue(any(e.endswith("+build.1.tar.gz".replace("+", "%2B")) for _, e in self.gh.write_calls()))

    def test_draft_replaced_by_another_run_is_never_published(self):
        """Another run deletes our draft and creates its own before we publish."""
        self.gh.seed([])
        r = self.publish(FAKE_GH_RACE="1")
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        rels = self.gh.raw_releases()
        self.assertEqual(len(rels), 1)
        self.assertTrue(rels[0]["draft"], "the other run's unverified draft must stay unpublished")
        self.assertIn("this run published nothing", r.stderr)
        patches = [w for w in self.gh.write_calls() if w[0] == "PATCH"]
        self.assertTrue(patches)
        self.assertTrue(all(not e.endswith(f"/{rels[0]['id']}") for _, e in patches))

    def test_digest_mismatch_blocks_publishing(self):
        self.gh.seed([])
        r = self.publish(FAKE_GH_TAMPER="SHA256SUMS")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("does not hold exactly the verified assets", r.stderr)
        self.assertIn("SHA256SUMS", r.stderr)
        self.assertTrue(self.gh.releases()[0][1])
        self.assertNotIn("patch", verbs(self.gh.write_calls()))

    def test_assets_without_api_digest_are_downloaded_and_hashed(self):
        self.gh.seed([])
        r = self.publish(FAKE_GH_NO_DIGEST="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)
        downloads = [c for c in self.gh.calls() if c[0] == "api" and "Accept: application/octet-stream" in c]
        self.assertGreaterEqual(len(downloads), 8)  # draft check + published check

        self.gh.seed([])
        r = self.publish(FAKE_GH_NO_DIGEST="1", FAKE_GH_TAMPER=f"heimdall-local-linux-amd64-{TAG}.tar.gz")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertTrue(self.gh.releases()[0][1])

    def test_draft_input_leaves_a_verified_draft(self):
        self.gh.seed([])
        r = self.publish("--draft")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        (_, draft, assets), = self.gh.releases()
        self.assertTrue(draft)
        self.assertEqual(assets, self.files)
        self.assertNotIn("patch", verbs(self.gh.write_calls()))

    def test_publish_retry_after_server_applied_patch_is_done(self):
        self.gh.seed([])
        r = self.publish(FAKE_GH_PATCH_FAIL="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertPublishedExactly(self.files)
        self.assertEqual(verbs(self.gh.write_calls()).count("patch"), 1)

    def test_check_unpublished(self):
        self.gh.seed([])
        self.assertEqual(self.gh.run([str(PUBLISH), "check-unpublished", TAG]).returncode, 0)
        self.gh.seed([{"draft": True, "prerelease": True, "immutable": False, "assets": {}},
                      {"tag": "v1.2.4", "draft": False, "prerelease": True, "immutable": False, "assets": {}}])
        r = self.gh.run([str(PUBLISH), "check-unpublished", TAG])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("only as 1 draft(s)", r.stdout)
        r = self.gh.run([str(PUBLISH), "check-unpublished", TAG], FAKE_GH_LIST_ERROR="1")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertEqual(self.gh.write_calls(), [])

    def test_usage_errors(self):
        self.gh.seed([])
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
        r = self.gh.run([str(PUBLISH), "check-unpublished", "v1;rm"])
        self.assertEqual(r.returncode, 2)
        r = self.gh.run([str(PUBLISH), "check-unpublished", TAG], GH_REPO="bad repo")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.gh.calls(), [])


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
        self.gh.seed([{"draft": False, "prerelease": True, "immutable": immutable, "assets": files}])
        release_json = self.root / "release.json"
        release_json.write_text(json.dumps({"isDraft": False, "isPrerelease": True, "isImmutable": immutable,
                                            "assets": [{"name": n} for n in files]}))
        return self.gh.run([str(self.script), TAG, str(release_json), str(self.root / "work")],
                           GH_REPO="o/r", DEFAULT_BRANCH="main", MINISIGN=MINISIGN, **env)

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

    def test_attestation_must_come_from_the_tag_or_the_default_branch(self):
        files = self.signed_release()
        r = self.check(files, FAKE_GH_ATTEST_REF=f"refs/tags/{TAG}")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"built from refs/tags/{TAG}", r.stdout)
        r = self.check(files, FAKE_GH_ATTEST_REF="refs/heads/main")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("built from refs/heads/main", r.stdout)
        # Provenance from a dry run on a throwaway branch does not count.
        r = self.check(files, FAKE_GH_ATTEST_REF="refs/heads/ci/manifest-dryrun")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("has no build-provenance attestation", r.stderr)

    def test_missing_attestation_is_rejected(self):
        r = self.check(self.signed_release(), FAKE_GH_NO_ATTEST=f"heimdall-local-windows-amd64-{TAG}.zip")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("has no build-provenance attestation", r.stderr)


if __name__ == "__main__":
    unittest.main()
