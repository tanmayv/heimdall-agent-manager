"""T8 / REQ-SIGN-1: scripts/release/verify-macos-signatures.sh.

Drives the verifier against a fake `codesign` (CODESIGN=...) so every
rejection rule is exercised on any OS. The real codesign path runs in release
CI on the macOS build runner and on a clean runner (verify-storeless).
"""

from pathlib import Path
import os
import subprocess
import tarfile
import tempfile
import textwrap

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/release/verify-macos-signatures.sh"
MACHO = bytes.fromhex("cffaedfe") + b"\0" * 60
IDS = {
    "ham-bridge": "works.earendil.heimdall.bridge",
    "ham-ctl": "works.earendil.heimdall.ctl",
    "ham-pty-host": "works.earendil.heimdall.pty-host",
    "ham-launcher": "works.earendil.heimdall.launcher",
    "ham-supervisor": "works.earendil.heimdall.supervisor",
}

FAKE = textwrap.dedent(r'''
    #!/usr/bin/env bash
    # Fake codesign: details come from $FAKE_DIR/<name>.details,
    # entitlements from <name>.ent, verify failure from <name>.badverify.
    f="${@: -1}"; n="$(basename "$f")"
    case "$1" in
      --verify) [ -e "$FAKE_DIR/$n.badverify" ] && { echo "$f: invalid signature" >&2; exit 1; }
                case " $* " in *" --check-notarization "*)
                  [ -e "$FAKE_DIR/$n.notnotarized" ] && { echo "$f: not notarized" >&2; exit 3; }
                  [ "$4" = "--test-requirement==notarized" ] || exit 65 ;;
                esac
                echo "$f: valid on disk" >&2; exit 0 ;;
      -d) if [ "$2" = "--entitlements" ]; then cat "$FAKE_DIR/$n.ent" 2>/dev/null; exit 0; fi
          cat "$FAKE_DIR/$n.details" >&2; exit 0 ;;
    esac
    exit 64
''').lstrip()


def details(name, team="ABCDE12345", flags="0x10000(runtime)", timestamp=True,
            leaf="Developer ID Application: Example Ltd (ABCDE12345)", ident=None):
    lines = [
        f"Executable=/x/bin/{name}",
        f"Identifier={ident or IDS[name]}",
        "Format=Mach-O thin (arm64)",
        f"CodeDirectory v=20500 size=1234 flags={flags} hashes=30+7 location=embedded",
        f"Authority={leaf}",
        "Authority=Developer ID Certification Authority",
        "Authority=Apple Root CA",
    ]
    lines.append("Timestamp=Nov 22, 2026 at 6:42:17 PM" if timestamp
                 else "Signed Time=Nov 22, 2026 at 6:42:17 PM")
    lines += ["Info.plist=not bound", f"TeamIdentifier={team}"]
    return "\n".join(lines) + "\n"


class Fixture:
    def __init__(self, names=("ham-bridge", "ham-ctl", "ham-pty-host", "ham-launcher", "ham-supervisor")):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.bin = root / "bin"
        self.fake = root / "fake"
        self.bin.mkdir()
        self.fake.mkdir()
        (root / "codesign").write_text(FAKE)
        (root / "codesign").chmod(0o755)
        self.codesign = root / "codesign"
        for n in names:
            (self.bin / n).write_bytes(MACHO)
            self.set(n, details(n))
        (self.bin / "README.txt").write_text("not a Mach-O\n")

    def set(self, name, text):
        (self.fake / f"{name}.details").write_text(text)

    def run(self, target=None, team=None, notarized=False):
        env = dict(os.environ, CODESIGN=str(self.codesign), FAKE_DIR=str(self.fake))
        env.pop("HEIMDALL_EXPECTED_TEAM_ID", None)
        env["HEIMDALL_REQUIRE_NOTARIZED"] = "1" if notarized else "0"
        if team:
            env["HEIMDALL_EXPECTED_TEAM_ID"] = team
        return subprocess.run(["bash", str(SCRIPT), str(target or self.bin)],
                              env=env, text=True, capture_output=True, timeout=60)


def expect_fail(fx, needle, **kw):
    r = fx.run(**kw)
    assert r.returncode != 0, r.stdout + r.stderr
    assert needle in r.stderr, r.stderr


def test_valid_bundle_passes_dir_and_tarball():
    fx = Fixture()
    r = fx.run()
    assert r.returncode == 0, r.stdout + r.stderr
    assert "verified 5 Developer ID" in r.stdout
    tgz = Path(fx.tmp.name) / "b.tar.gz"
    with tarfile.open(tgz, "w:gz") as t:
        t.add(fx.bin, arcname="bin")
    r = fx.run(target=tgz, team="ABCDE12345")
    assert r.returncode == 0, r.stdout + r.stderr


def test_pty_host_optional_but_bridge_and_ctl_required():
    fx = Fixture(names=("ham-bridge", "ham-ctl"))
    assert fx.run().returncode == 0
    fx = Fixture(names=("ham-bridge",))
    expect_fail(fx, "ham-ctl is missing")


def test_rejects_missing_hardened_runtime():
    fx = Fixture()
    fx.set("ham-ctl", details("ham-ctl", flags="0x0(none)"))
    expect_fail(fx, "ham-ctl: hardened runtime is not enabled")


def test_rejects_missing_secure_timestamp():
    fx = Fixture()
    fx.set("ham-bridge", details("ham-bridge", timestamp=False))
    expect_fail(fx, "no secure timestamp")


def test_rejects_non_developer_id_leaf():
    fx = Fixture()
    fx.set("ham-bridge", details("ham-bridge", leaf="Apple Development: dev@example.com (XYZ)"))
    expect_fail(fx, "not Developer ID Application")


def test_rejects_wrong_identifier_and_team_mismatch():
    fx = Fixture()
    fx.set("ham-ctl", details("ham-ctl", ident="a.out"))
    expect_fail(fx, "identifier is 'a.out'")
    fx = Fixture()
    fx.set("ham-pty-host", details("ham-pty-host", team="ZZZZZ99999"))
    expect_fail(fx, "differs from")
    fx = Fixture()
    expect_fail(fx, "expected QQQQQ11111", team="QQQQQ11111")


def test_rejects_failed_verify_and_get_task_allow():
    fx = Fixture()
    (fx.fake / "ham-bridge.badverify").write_text("")
    expect_fail(fx, "signature does not verify")
    fx = Fixture()
    (fx.fake / "ham-ctl.ent").write_text(
        "<plist><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>")
    expect_fail(fx, "get-task-allow")


def test_notarization_required_only_when_asked():
    fx = Fixture()
    (fx.fake / "ham-pty-host.notnotarized").write_text("")
    assert fx.run().returncode == 0
    expect_fail(fx, "ham-pty-host: not notarized", notarized=True)
    (fx.fake / "ham-pty-host.notnotarized").unlink()
    r = fx.run(notarized=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "timestamp + notarization signatures" in r.stdout


NOTARIZE = ROOT / "scripts/release/notarize-macos-binaries.sh"
FAKE_NOTARY = textwrap.dedent(r'''
    #!/usr/bin/env bash
    # Fake notarytool: replies with $FAKE_NOTARY_REPLY, exit $FAKE_NOTARY_RC.
    echo "$*" >> "$FAKE_NOTARY_CALLS"
    case "$1" in
      submit) [ -f "$2" ] || exit 9
              unzip -l "$2" | grep -q 'bin/ham-bridge' || exit 8
              printf '%s' "$FAKE_NOTARY_REPLY"; exit "${FAKE_NOTARY_RC:-0}" ;;
      log) echo "issues: hardened runtime missing"; exit 0 ;;
    esac
    exit 64
''').lstrip()


def run_notarize(reply, rc=0, creds=True):
    tmp = tempfile.TemporaryDirectory()
    root = Path(tmp.name)
    (root / "bin").mkdir()
    (root / "bin/ham-bridge").write_bytes(MACHO)
    tgz = root / "b.tar.gz"
    with tarfile.open(tgz, "w:gz") as t:
        t.add(root / "bin", arcname="bin")
    fake = root / "notarytool"
    fake.write_text(FAKE_NOTARY)
    fake.chmod(0o755)
    calls = root / "calls"
    env = dict(os.environ, NOTARYTOOL=str(fake), FAKE_NOTARY_REPLY=reply,
               FAKE_NOTARY_RC=str(rc), FAKE_NOTARY_CALLS=str(calls))
    for k in ("APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID"):
        env.pop(k, None)
        if creds:
            env[k] = "x-" + k.lower()
    before = tgz.read_bytes()
    r = subprocess.run(["bash", str(NOTARIZE), str(tgz)], env=env, text=True,
                       capture_output=True, timeout=60)
    assert tgz.read_bytes() == before, "notarization must not modify the tarball"
    log = calls.read_text() if calls.exists() else ""
    tmp.cleanup()
    return r, log


def test_notarize_accepts_only_accepted_status():
    r, calls = run_notarize('{"id":"abc","status":"Accepted"}')
    assert r.returncode == 0, r.stdout + r.stderr
    assert "--wait --output-format json" in calls and "--team-id x-apple_team_id" in calls
    assert " log " not in f" {calls} "
    for rc in (0, 1):  # exit code alone never decides
        r, calls = run_notarize('{"id":"abc","status":"Invalid"}', rc=rc)
        assert r.returncode != 0 and "status is 'Invalid'" in r.stderr, r.stderr
        assert "log abc" in calls and "hardened runtime missing" in r.stderr


def test_notarize_fails_closed():
    r, _ = run_notarize("Error: HTTP 401", rc=1)
    assert r.returncode != 0 and "returned no status" in r.stderr, r.stderr
    r, calls = run_notarize('{"id":"abc","status":"Accepted"}', creds=False)
    assert r.returncode != 0 and "APPLE_ID is required" in r.stderr and calls == ""


if __name__ == "__main__":
    cases = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for case in cases:
        case()
        print(f"ok {case.__name__}")
    print(f"{len(cases)} passed")
