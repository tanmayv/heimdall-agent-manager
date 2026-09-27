#!/usr/bin/env python3
"""Integration tests for the non-hub binary distribution flow (REQ-DIST-6).

Verifies the distribution surfaces end-to-end and hermetically:

1. Tarball packaging: scripts/release/package-local-binary-tarball.sh produces a
   tarball with the required entries (bin/heimdall, bin/ham-bridge,
   bin/ham-pty-host, bin/ham-ctl, README.md, LICENSE, METADATA.json), executable
   modes for binaries, and a valid METADATA.json schema. Stub binaries stand in
   for the Nix outputs (the script only stages files, so stubs exercise it
   fully; the real manager binary is built separately for the CLI checks).
2. Checksum validation: the release-workflow SHA256SUMS layout
   (.github/workflows/release-local-binaries.yml) round-trips — hashlib,
   sha256sum(1) and install.sh's awk lookup all agree — and a tampered tarball
   no longer matches (fail-closed property).
3. Installer: scripts/install.sh passes `bash -n` and its --dry-run output
   matches the documented action plan (offline-safe: the --version/--hub
   resolution paths are asserted; the bare --dry-run only needs exit 0). The
   rendered unit carries --hub only when it was passed (no placeholder hub).
   Full sandboxed runs against a local file:// --hub mirror prove the
   service-file lifecycle (backup of a differing unit, identical re-run is a
   no-op, --force-service skips the backup), and unshare -r dry runs prove the
   sudo path (SUDO_USER resolution + root refusal) with zero writes. Real
   uid-0 runs inside unshare -rm (private mounts) prove the sudo branch writes
   the PATH export into the TARGET user's rc file even when root's PATH
   already contains /usr/local/bin, and that failed chowns warn with path,
   owner and remediation while the install stays non-fatal.
4. heimdall CLI: the binary built from src/manager emits the documented
   --version and status schemas, with the version line pinned to
   src/contracts/protocol.odin.
5. Documentation regression: SELF_HOSTING.md Part 2 documents the curl|bash
   installer and the heimdall CLI as the primary setup path while keeping the
   manual/Nix paths, and Part 1 (hub) headings are intact.

Run: python3 tests/test_binary_distribution.py
Env: HEIMDALL_BIN=<path> skips the odin build and tests that binary instead.
"""
from pathlib import Path
import contextlib
import hashlib
import http.server
import json
import os
import platform
import re
import shlex
import shutil
import socketserver
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE_SCRIPT = ROOT / 'scripts' / 'release' / 'package-local-binary-tarball.sh'
INSTALL_SCRIPT = ROOT / 'scripts' / 'install.sh'
GITHUB_REPO = 'tanmayv/heimdall-agent-manager'


class Skip(Exception):
    pass


def run(argv, cwd=None, timeout=120):
    return subprocess.run(
        [str(a) for a in argv],
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def host_target():
    system = platform.system()
    machine = platform.machine()
    if system == 'Linux':
        os_name = 'linux'
    elif system == 'Darwin':
        os_name = 'darwin'
    else:
        return None
    if machine in ('x86_64', 'amd64'):
        arch = 'amd64'
    elif machine in ('arm64', 'aarch64'):
        arch = 'arm64'
    else:
        return None
    return f'{os_name}-{arch}'


def make_stub_input(base: Path, name: str, binaries: list) -> Path:
    """A fake Nix output directory: <dir>/bin/<binary> per name."""
    out = base / name
    (out / 'bin').mkdir(parents=True)
    for binary in binaries:
        stub = out / 'bin' / binary
        stub.write_text(f'#!/bin/sh\necho "{binary} stub"\n')
        stub.chmod(0o755)
    return out


def package_tarball(base: Path, *, with_pty_host=True, with_openssl=False,
                    ctl_binaries=('ham-ctl',), target='linux-amd64'):
    """Run the packaging script against stub inputs; return (result, tarball)."""
    out_dir = base / 'dist'
    bridge = make_stub_input(base, 'bridge-out',
                             ['ham-bridge'] + (['openssl'] if with_openssl else []))
    ctl = make_stub_input(base, 'ctl-out', list(ctl_binaries))
    manager = make_stub_input(base, 'manager-out', ['heimdall'])
    argv = ['bash', PACKAGE_SCRIPT, target, 'v0.1.0', out_dir,
            bridge, ctl, manager]
    if with_pty_host:
        argv.append(make_stub_input(base, 'ptyhost-out', ['ham-pty-host']))
    res = run(argv, cwd=ROOT)
    return res, out_dir / f'heimdall-local-{target}.tar.gz'


def read_tarball(tarball: Path):
    with tarfile.open(tarball, 'r:gz') as tf:
        names = tf.getnames()
        modes = {m.name: m.mode for m in tf.getmembers()}
        metadata = json.load(tf.extractfile('METADATA.json'))
    return names, modes, metadata


# ---- 1. tarball packaging ----------------------------------------------------

def test_tarball_structure_and_metadata(ctx):
    res, tarball = package_tarball(ctx['work'], with_pty_host=True, with_openssl=True)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    assert tarball.is_file(), f'tarball not created at {tarball}'
    printed = [line for line in res.stdout.splitlines() if line.strip()]
    assert printed[-1] == str(tarball), (
        f'script must print the tarball path; got stdout: {res.stdout!r}')

    names, modes, metadata = read_tarball(tarball)
    required = {
        'bin/heimdall', 'bin/ham-bridge', 'bin/ham-pty-host', 'bin/ham-ctl',
        'README.md', 'LICENSE', 'METADATA.json',
    }
    missing = required - set(names)
    assert not missing, f'tarball missing required entries: {sorted(missing)}'
    assert 'bin/openssl' in names, 'bundled openssl must ship when present in the bridge output'

    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert modes[f'bin/{binary}'] & 0o111, f'bin/{binary} must be executable in the tarball'

    expected_keys = {'product', 'version', 'target', 'commit', 'built_at',
                     'binaries', 'tls_dependency'}
    assert set(metadata.keys()) == expected_keys, (
        f'METADATA.json keys mismatch: {sorted(metadata.keys())}')
    assert metadata['product'] == 'heimdall-local'
    assert metadata['version'] == 'v0.1.0'
    assert metadata['target'] == 'linux-amd64'
    assert isinstance(metadata['commit'], str) and metadata['commit'], 'commit must be non-empty'
    assert isinstance(metadata['built_at'], str) and metadata['built_at'], 'built_at must be non-empty'
    assert sorted(metadata['binaries']) == ['ham-bridge', 'ham-ctl', 'ham-pty-host', 'heimdall'], (
        f'METADATA.json binaries mismatch: {metadata["binaries"]}')
    assert isinstance(metadata['tls_dependency'], str) and metadata['tls_dependency']

    ctx['tarball'] = tarball


def test_tarball_without_pty_host(ctx):
    res, tarball = package_tarball(ctx['work2'], with_pty_host=False)
    assert res.returncode == 0, f'6-arg (no pty-host) invocation failed:\n{res.stderr}'
    names, _, metadata = read_tarball(tarball)
    for entry in ('bin/ham-bridge', 'bin/ham-ctl', 'bin/heimdall',
                  'README.md', 'LICENSE', 'METADATA.json'):
        assert entry in names, f'entry {entry} missing from 6-arg tarball'
    assert 'bin/ham-pty-host' not in names, 'pty-host must not ship when not provided'
    assert 'bin/openssl' not in names, 'openssl must not ship when not bundled'
    assert sorted(metadata['binaries']) == ['ham-bridge', 'ham-ctl', 'heimdall'], (
        f'METADATA.json binaries mismatch: {metadata["binaries"]}')


def test_packaging_error_cases(ctx):
    base = ctx['work'] / 'errors'
    base.mkdir()
    bridge = make_stub_input(base, 'bridge-out', ['ham-bridge'])
    ctl = make_stub_input(base, 'ctl-out', ['ham-ctl'])
    manager = make_stub_input(base, 'manager-out', ['heimdall'])
    out_dir = base / 'dist'
    res = run(['bash', PACKAGE_SCRIPT, 'solaris-sparc64', 'v0.1.0', out_dir,
               bridge, ctl, manager], cwd=ROOT)
    assert res.returncode == 2, f'unsupported target must exit 2, got {res.returncode}'
    assert 'unsupported release target' in res.stderr

    incomplete_ctl = make_stub_input(base, 'ctl-incomplete', [])
    res = run(['bash', PACKAGE_SCRIPT, 'linux-amd64', 'v0.1.0', out_dir,
               bridge, incomplete_ctl, manager], cwd=ROOT)
    assert res.returncode == 1, f'missing input must exit 1, got {res.returncode}'
    assert 'missing required release input' in res.stderr

    res = run(['bash', PACKAGE_SCRIPT, 'linux-amd64', 'v0.1.0', out_dir], cwd=ROOT)
    assert res.returncode == 2, f'wrong argument count must exit 2 (usage), got {res.returncode}'


# ---- 2. SHA256SUMS validation ------------------------------------------------

def test_sha256sums_validation(ctx):
    if 'tarball' not in ctx:
        raise Skip('packaging test did not produce a tarball')
    tarball: Path = ctx['tarball']
    version = 'v0.1.0'
    dist = ctx['work'] / 'checksums'
    dist.mkdir(parents=True)

    # Replicate the release workflow: copy to the versioned asset name, then
    # sha256sum over the versioned names -> SHA256SUMS.
    asset = dist / f'heimdall-local-linux-amd64-{version}.tar.gz'
    shutil.copy(tarball, asset)
    digest = sha256_of(asset)
    sums = dist / 'SHA256SUMS'
    sums.write_text(f'{digest}  {asset.name}\n')

    # Independent recomputation agrees.
    assert sha256_of(asset) == digest
    # The system tool the workflow/installer rely on agrees with hashlib.
    if shutil.which('sha256sum'):
        cli = run(['sha256sum', asset]).stdout.split()[0]
    elif shutil.which('shasum'):
        cli = run(['shasum', '-a', '256', asset]).stdout.split()[0]
    else:
        raise Skip('neither sha256sum nor shasum available')
    assert cli == digest, f'sha256sum CLI {cli} != hashlib {digest}'
    # install.sh's awk lookup finds the hash (GitHub release flow, versioned name).
    got = run(['awk', '-v', f'f={asset.name}', '$2 == f {print $1; exit}', sums]).stdout.strip()
    assert got == digest, f'awk lookup for {asset.name} returned {got!r}'
    # install.sh --hub flow: unversioned target tarball name.
    hub_sums = dist / 'SHA256SUMS-hub'
    hub_name = 'heimdall-local-linux-amd64.tar.gz'
    hub_sums.write_text(f'{digest}  {hub_name}\n')
    got = run(['awk', '-v', f'f={hub_name}', '$2 == f {print $1; exit}', hub_sums]).stdout.strip()
    assert got == digest, f'awk lookup for {hub_name} returned {got!r}'

    # Fail-closed: a tampered tarball no longer matches the recorded checksum.
    tampered = dist / 'tampered.tar.gz'
    data = bytearray(asset.read_bytes())
    data[-1] ^= 0xFF
    tampered.write_bytes(bytes(data))
    assert sha256_of(tampered) != digest, 'tampered tarball must not match SHA256SUMS'


# ---- 3. install.sh -----------------------------------------------------------

def test_install_sh_syntax(ctx):
    res = run(['bash', '-n', INSTALL_SCRIPT])
    assert res.returncode == 0, f'bash -n failed:\n{res.stderr}'
    # REQ-INST-4: main "$@" must be the final line, and nothing may execute at
    # top level before it — not even the shell-options statement.
    text = INSTALL_SCRIPT.read_text(encoding='utf-8')
    lines = [line for line in text.splitlines() if line.strip()]
    assert lines[-1] == 'main "$@"', f'last line must be main "$@", got {lines[-1]!r}'
    for line in text.splitlines():
        assert not line.startswith('set -'), (
            f'"set -" must live inside main(), not at top level: {line!r}')
    assert '\n  set -euo pipefail\n' in text, 'main() must enable set -euo pipefail'


def test_install_sh_help(ctx):
    res = run(['bash', INSTALL_SCRIPT, '--help'])
    assert res.returncode == 0
    assert 'usage: install.sh' in res.stderr
    assert '--version <tag>' in res.stderr and '--hub <url>' in res.stderr
    assert '--dry-run' in res.stderr
    assert '--force-service' in res.stderr, 'usage() must document --force-service'
    assert '--uninstall' in res.stderr, 'usage() must document --uninstall (REQ-INST-8)'


def dry_run_unit_text(res):
    """Slice the rendered service file out of a --dry-run plan."""
    out = res.stdout
    tail = out[out.index('would write service file'):]
    if '[Unit]' in tail:
        start = tail.index('[Unit]')
        end = tail.index('WantedBy=default.target') + len('WantedBy=default.target')
    else:
        start = tail.index('<!DOCTYPE plist')
        end = tail.index('</plist>') + len('</plist>')
    return tail[start:end]


def dry_run_common_asserts(res, target, install_dir_hint):
    assert res.returncode == 0, f'--dry-run failed:\n{res.stderr}'
    out = res.stdout
    assert f'platform: {target.replace("-", "/")}' in out, 'platform line missing'
    for line in ('would download:', 'would verify SHA-256', 'would install'):
        assert line in out, f'dry run must state {line!r}'
    install_line = next(line for line in out.splitlines() if 'would install' in line)
    for binary in ('bin/heimdall', 'bin/ham-bridge', 'bin/ham-pty-host', 'bin/ham-ctl'):
        assert binary in install_line, f'{binary} missing from would-install line'
    assert install_dir_hint in install_line, f'install dir {install_dir_hint} missing'
    assert 'PATH' in out, 'dry run must mention PATH handling'
    assert '--force-service' in out, 'dry run must mention --force-service'
    assert 'heimdall enroll' in out, 'onboarding must show the heimdall enroll command'
    if target.startswith('linux'):
        for marker in ('[Unit]', 'Description=Heimdall Bridge', 'ExecStart=',
                       'Environment=HEIMDALL_HAM_PTY_HOST_BIN=',
                       'WantedBy=default.target'):
            assert marker in out, f'systemd unit missing {marker!r}'
        assert 'systemctl --user enable --now heimdall-bridge' in out
    else:
        for marker in ('<!DOCTYPE plist', 'works.earendil.heimdall-bridge', 'RunAtLoad'):
            assert marker in out, f'launchd plist missing {marker!r}'
        assert 'launchctl bootstrap' in out


def test_install_sh_dry_run_version(ctx):
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh dry-run: {platform.system()}/{platform.machine()}')
    install_dir = '/usr/local/bin' if os.geteuid() == 0 else '.local/bin'
    res = run(['bash', INSTALL_SCRIPT, '--dry-run', '--version', 'v0.1.0'], timeout=60)
    dry_run_common_asserts(res, target, install_dir)
    assert 'release: v0.1.0' in res.stdout
    expected_url = (f'https://github.com/{GITHUB_REPO}/releases/download/v0.1.0/'
                    f'heimdall-local-{target}-v0.1.0.tar.gz')
    assert f'would download: {expected_url}' in res.stdout
    assert 'would download: https://github.com/' + f'{GITHUB_REPO}/releases/download/v0.1.0/SHA256SUMS' in res.stdout
    # REQ-INST-1: no --hub flag and no placeholder hub in the rendered unit
    # when --hub was not passed — the bridge reads config.toml instead.
    unit = dry_run_unit_text(res)
    assert '--hub' not in unit, 'unit must not carry --hub when --hub was not passed'
    assert 'hub.example.com' not in unit, 'placeholder hub must not appear in the unit'
    assert 'hub.example.com' not in res.stdout, 'placeholder hub must not appear anywhere in the dry-run plan'


def test_install_sh_dry_run_hub(ctx):
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh dry-run: {platform.system()}/{platform.machine()}')
    install_dir = '/usr/local/bin' if os.geteuid() == 0 else '.local/bin'
    hub = 'http://hub.example.test'
    res = run(['bash', INSTALL_SCRIPT, '--dry-run', '--hub', hub], timeout=60)
    dry_run_common_asserts(res, target, install_dir)
    assert 'release: custom-hub-release' in res.stdout
    assert f'would download: {hub}/heimdall-local-{target}.tar.gz' in res.stdout
    assert f'would download: {hub}/SHA256SUMS' in res.stdout
    assert f'heimdall enroll hbe_... --hub {hub}' in res.stdout
    # The hub URL must be baked into the rendered service file as well as the
    # download URLs and onboarding text (tarball + sums + unit + onboarding).
    assert res.stdout.count(hub) >= 4, 'hub URL must appear in downloads, unit and onboarding'
    # REQ-INST-1: an explicitly passed --hub is a deliberate operator choice
    # and DOES land in the rendered unit.
    unit = dry_run_unit_text(res)
    assert '--hub' in unit, 'unit must carry --hub when it was explicitly passed'
    assert f'--hub {hub}' in unit, 'the passed hub URL must follow --hub in the unit'


def test_install_sh_dry_run_bare(ctx):
    # Offline-tolerant: even when the latest-tag lookup fails the dry run must
    # still exit 0 and print the plan.
    res = run(['bash', INSTALL_SCRIPT, '--dry-run'], timeout=90)
    assert res.returncode == 0, f'bare --dry-run failed:\n{res.stderr}'
    assert 'platform:' in res.stdout and 'would install' in res.stdout
    assert 'hub.example.com' not in res.stdout, 'placeholder hub must not appear in the dry-run plan'


def need_tool(name):
    if shutil.which(name) is None:
        raise Skip(f'{name} not available')


def make_hub_mirror(base: Path, tarball: Path, target: str) -> str:
    """Stage the --hub mirror layout: unversioned tarball name plus SHA256SUMS.
    install.sh names the files heimdall-local-<target>.tar.gz / SHA256SUMS and
    looks the digest up with awk '$2 == f', so the sums entry must use the
    UNVERSIONED basename or the run reports a checksum mismatch."""
    mirror = base / 'mirror'
    mirror.mkdir(parents=True)
    asset_name = f'heimdall-local-{target}.tar.gz'
    shutil.copy(tarball, mirror / asset_name)
    digest = sha256_of(mirror / asset_name)
    (mirror / 'SHA256SUMS').write_text(f'{digest}  {asset_name}\n')
    return f'file://{mirror}'


# --- REQ-INST-6: hermetic release-resolution harness --------------------------
#
# install.sh resolves the latest tag against https://api.github.com, hard-coded.
# These tests never reach it. The installer runs with PATH pointing at a
# directory holding ONLY symlinks to the utilities the script needs plus a FAKE
# curl or wget, so there is no real downloader on that PATH at all: a request
# that escaped the stub could not be made, rather than quietly succeeding
# against the live API and making the test look like it passed.
#
# Stubbing the TOOL rather than adding an env override to install.sh is
# deliberate. It keeps test-only hooks out of the shipped installer and it
# exercises the real branch logic in api_fetch / resolve_latest_tag, including
# the curl-vs-wget split that is itself one of the bugs under test.
#
# NOTE ON SUCCESS CASES: a stub that resolves a tag successfully is only ever
# driven with --dry-run. A bare REAL run would carry on past resolution into the
# tarball download, and the point of this harness is that nothing reaches the
# network. Failure cases can use a real run safely: they exit at resolution,
# before the downloader guard or any write.

# Utilities install.sh needs on PATH. curl and wget are deliberately ABSENT --
# make_api_stub adds exactly the fake one a given test wants.
SHIM_TOOLS = ['bash', 'sh', 'uname', 'mktemp', 'sed', 'awk', 'head', 'tail', 'cat',
              'cp', 'mv', 'rm', 'ln', 'mkdir', 'rmdir', 'chmod', 'chown', 'touch',
              'grep', 'tr', 'cut', 'sort', 'id', 'date', 'dirname', 'basename',
              'env', 'tee', 'wc', 'stat', 'find', 'readlink', 'expr', 'sleep',
              'tar', 'gzip', 'sha256sum', 'shasum', 'systemctl', 'launchctl',
              'getent', 'whoami', 'install', 'printf', 'test', 'true', 'false']

RELEASE_LATEST_JSON = '{"tag_name": "v9.9.9", "name": "Heimdall v9.9.9"}\n'
# GitHub returns /releases newest-first; install.sh takes the first tag_name.
RELEASE_LIST_PRERELEASE_JSON = (
    '[{"tag_name": "v1.2.3-beta.2", "prerelease": true, "draft": false},\n'
    ' {"tag_name": "v1.2.3-beta.1", "prerelease": true, "draft": false}]\n')


def write_socat_stub(directory: Path) -> Path:
    """Put a no-op `socat` on a PATH entry (REQ-INST-14).

    install.sh resolves socat with `command -v socat` and NEVER executes it --
    presence is the whole contract -- so a stub is an honest stand-in rather
    than a fake. The suite supplying it is what makes every other test
    deterministic on hosts with and without socat installed, instead of the
    fatal preflight silently turning into a host-dependent skip.

    A real socat is deliberately NOT symlinked here: a test must not pass only
    because the machine happened to have the dependency.
    """
    directory.mkdir(parents=True, exist_ok=True)
    stub = directory / 'socat'
    if not stub.exists():
        stub.write_text('#!/bin/sh\n'
                        '# no-op stand-in: install.sh only probes for presence\n'
                        'exit 0\n')
        stub.chmod(0o755)
    return stub


def _shim_dir(base: Path, name: str, *, with_socat: bool = True) -> Path:
    shim = base / name
    shim.mkdir(parents=True, exist_ok=True)
    for tool in SHIM_TOOLS:
        real = shutil.which(tool)
        if real and not (shim / tool).exists():
            (shim / tool).symlink_to(real)
    # stub_env sets PATH to this directory ALONE, so without socat here every
    # test that reaches the REQ-INST-14 preflight would die on it. Tests that
    # want socat ABSENT ask for it with with_socat=False.
    if with_socat:
        write_socat_stub(shim)
    return shim


def make_api_stub(base: Path, name: str, *, tool: str,
                  latest_status: str = '200', latest_body: str = RELEASE_LATEST_JSON,
                  latest_headers: tuple = (),
                  list_status: str = '200', list_body: str = '[]\n',
                  list_headers: tuple = ()) -> Path:
    """Build a PATH dir whose only downloader is a fake `tool` answering the two
    endpoints install.sh asks for. tool=None means NO downloader at all.

    Status '000' makes the stub behave like a host that got no HTTP response
    (curl exit 6 / wget exit 4, nothing on stdout), which is how api_fetch tells
    a dead network apart from an HTTP error.

    *_headers are extra response header lines ('Name: value'), which is how a
    test says whether the server reported an exhausted rate limit. The DEFAULT is
    no headers, because that is what a secondary/abuse-limited 403 looks like --
    the case install.sh must not diagnose as the hourly limit.
    """
    shim = _shim_dir(base, name)
    data = base / (name + '-data')
    data.mkdir(parents=True, exist_ok=True)
    (data / 'latest.json').write_text(latest_body)
    (data / 'list.json').write_text(list_body)
    (data / 'latest.hdr').write_text(''.join(h + '\n' for h in latest_headers))
    (data / 'list.hdr').write_text(''.join(h + '\n' for h in list_headers))
    if tool is None:
        return shim

    bash_path = shutil.which('bash')
    assert bash_path, 'bash is required to build the downloader stub'
    if tool == 'curl':
        script = f"""#!{bash_path}
# Fake curl. Covers api_fetch's `-sS -o BODY -w %{{http_code}} URL` shape.
out=""; url=""; hdr=""; fail_fast=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    # -D is api_fetch's header capture. WITHOUT this arm the -[!-]* cluster arm
    # below eats only the flag and leaves its FILENAME to be read as the URL, so
    # the stub would answer the wrong endpoint and the bug would look like a
    # script bug rather than a stub bug.
    -D) hdr="$2"; shift 2 ;;
    -w|--connect-timeout|--max-time|--speed-limit|--speed-time|--retry) shift 2 ;;
    # A single-dash cluster containing f is -f/-fL/-fsSL: fail-fast. The stub MUST
    # model this. Without it the stub answers an HTTP error identically with and
    # without -f, so the test cannot see that dropping -f is what PRESERVES the
    # status code -- the whole mechanism keeping 403 distinguishable from 404.
    -[!-]*) case "$1" in *f*) fail_fast=1 ;; esac; shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */releases/latest) status="{latest_status}"; src="{data}/latest.json"; hsrc="{data}/latest.hdr" ;;
  */releases)        status="{list_status}";   src="{data}/list.json";   hsrc="{data}/list.hdr" ;;
  *)                 status="404";             src="/dev/null";          hsrc="/dev/null" ;;
esac
if [ "$status" = "000" ]; then
  echo "curl: (6) Could not resolve host: api.github.com" >&2
  exit 6
fi
# Real curl -D writes the status line, the headers, and a blank line, with CRLF
# endings straight off the wire. The CRLF is modelled on purpose: a header parser
# that forgets to strip the CR compares "0\r" against "0" and silently never
# matches, which would make the rate-limit discrimination fail closed in the one
# direction no assertion would notice.
if [ -n "$hdr" ]; then
  {{ printf 'HTTP/1.1 %s stub\r\n' "$status"
    while IFS= read -r line; do printf '%s\r\n' "$line"; done <"$hsrc"
    printf '\r\n'; }} >"$hdr"
fi
if [ "$fail_fast" = 1 ]; then
  case "$status" in
    2*) ;;
    *)  # Real `curl -f`: exit 22, NO body, and NO status on stdout. The code is
        # destroyed, which is precisely why api_fetch must not pass -f.
        echo "curl: (22) The requested URL returned error: $status" >&2
        exit 22 ;;
  esac
fi
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
# Real curl WITHOUT -f exits 0 on an HTTP error and reports the code via -w,
# which is exactly why api_fetch dropped -f.
printf '%s' "$status"
exit 0
"""
    elif tool == 'wget':
        script = f"""#!{bash_path}
# Fake wget. Covers api_fetch's `-q -S -O BODY --tries=1 ... URL` shape; -S puts
# the status line on stderr, which is where api_fetch reads the code from.
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -O) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */releases/latest) status="{latest_status}"; src="{data}/latest.json"; hsrc="{data}/latest.hdr" ;;
  */releases)        status="{list_status}";   src="{data}/list.json";   hsrc="{data}/list.hdr" ;;
  *)                 status="404";             src="/dev/null";          hsrc="/dev/null" ;;
esac
if [ "$status" = "000" ]; then
  echo "wget: unable to resolve host address 'api.github.com'" >&2
  exit 4
fi
# wget -S indents every header line by two spaces and writes them to stderr,
# which is a different shape from curl's -D file. api_fetch feeds both to the
# same parser, so both shapes are exercised here.
echo "  HTTP/1.1 $status stub" >&2
while IFS= read -r line; do echo "  $line" >&2; done <"$hsrc"
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
case "$status" in
  2*) exit 0 ;;
  *)  exit 8 ;;
esac
"""
    else:
        raise AssertionError(f'unknown stub tool {tool!r}')

    stub = shim / tool
    stub.write_text(script)
    stub.chmod(0o755)
    return shim


def stub_env(home: Path, runtime: Path, shim: Path) -> dict:
    env = sandbox_install_env(home, runtime)
    # PATH is the shim ALONE. This is the hermetic guarantee: no real curl or
    # wget is reachable, so no test here can contact api.github.com.
    env['PATH'] = str(shim)
    return env


def run_installer(shim: Path, work: Path, tag: str, *args):
    home = work / f'home-{tag}'
    runtime = work / f'run-{tag}'
    home.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)
    # subprocess.run directly, matching the env-passing idiom the sandboxed
    # tests above already use (run() takes no env).
    return subprocess.run(['bash', str(INSTALL_SCRIPT), *args],
                          env=stub_env(home, runtime, shim),
                          capture_output=True, text=True, timeout=90)


def assert_only_message(res, expected_fragments, forbidden_fragments):
    out = res.stdout + res.stderr
    for fragment in expected_fragments:
        assert fragment in out, f'missing {fragment!r} in:\n{out}'
    for fragment in forbidden_fragments:
        assert fragment not in out, f'unexpected {fragment!r} in:\n{out}'


# Fragments unique to each of the five diagnoses. Every resolution test asserts
# its own AND the absence of the other four, so the causes cannot silently
# re-collapse into one message the way they were before REQ-INST-6.
MSG_NO_DOWNLOADER = 'need curl or wget to resolve the latest release'
MSG_RATE_LIMIT = 'the unauthenticated rate limit (60 requests/hour/IP) is exhausted'
MSG_NO_RELEASES = 'lists no published release for this repository'
MSG_UNREACHABLE = 'could not reach api.github.com (no HTTP response'
MSG_NO_TAG_FIELD = 'answered the latest-release lookup with no tag_name field'
# A 403 that does NOT carry X-RateLimit-Remaining: 0 is its own diagnosis, not the
# rate-limit one. GitHub answers 403 for secondary (abuse) limiting as well, where
# "wait for the window to reset" is wrong advice rather than merely unproven.
MSG_403_UNCONFIRMED = 'did not report an exhausted rate limit'
ALL_RESOLVE_MSGS = [MSG_NO_DOWNLOADER, MSG_RATE_LIMIT, MSG_NO_RELEASES,
                    MSG_UNREACHABLE, MSG_NO_TAG_FIELD, MSG_403_UNCONFIRMED]


def others(mine):
    return [m for m in ALL_RESOLVE_MSGS if m != mine]


def install_sh_code() -> str:
    """install.sh with comment lines stripped.

    Regression checks that assert an OLD construct is gone must not read the
    comments, because install.sh deliberately quotes what it replaced -- the old
    catch-all message and the old unbounded wget call are both recorded verbatim
    in comments explaining why they were wrong.
    """
    return '\n'.join(line for line in INSTALL_SCRIPT.read_text().splitlines()
                     if not line.lstrip().startswith('#'))


def test_resolve_messages_are_distinct(ctx):
    """Structural guard: the five diagnoses must stay mutually exclusive and each
    must carry a next step. Before REQ-INST-6 four causes shared ONE message, so
    a regression that re-merges any two of them is the thing to catch."""
    text = INSTALL_SCRIPT.read_text()
    for msg in ALL_RESOLVE_MSGS:
        assert msg in text, f'diagnosis missing from install.sh: {msg!r}'
    for i, a in enumerate(ALL_RESOLVE_MSGS):
        for b in ALL_RESOLVE_MSGS[i + 1:]:
            assert a not in b and b not in a, f'diagnoses overlap: {a!r} / {b!r}'
    # Each resolve_error must name something the user can actually do next. The
    # `resolve_error=""` reset at the top of the function is not a diagnosis, so
    # the pattern requires a non-empty value.
    for line in re.findall(r'resolve_error="([^"]+)"', text):
        assert ('--version' in line or '--hub' in line or 'install one' in line
                or 'publish it' in line), f'diagnosis has no next step: {line!r}'
    assert 'api.github.com unreachable?' not in install_sh_code(), \
        'the old catch-all message is back'


def test_resolve_no_downloader(ctx):
    """(a) Neither curl nor wget. Diagnosed BEFORE any network attempt, and it
    must NOT claim the network is unreachable -- the network was never tried."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-nodl', tool=None)
    assert shutil.which('curl', path=str(shim)) is None
    assert shutil.which('wget', path=str(shim)) is None

    res = run_installer(shim, work, 'nodl-real')
    assert res.returncode != 0, f'a real run with no downloader must fail:\n{res.stdout}'
    assert_only_message(res, ['error: ' + MSG_NO_DOWNLOADER, '--version <tag>'],
                        others(MSG_NO_DOWNLOADER))

    # The dry run REPORTS the same cause as a warning and still exits 0: the
    # downloader guard stays below the dry-run exit precisely so this works.
    res = run_installer(shim, work, 'nodl-dry', '--dry-run')
    assert res.returncode == 0, f'--dry-run must survive a missing downloader:\n{res.stderr}'
    assert_only_message(res, ['warning: ' + MSG_NO_DOWNLOADER, 'platform:', 'would install'],
                        others(MSG_NO_DOWNLOADER))


def test_resolve_wget_only_host(ctx):
    """(b) curl absent, wget present -- the sharpened REQ-INST-6 root cause.

    resolve_latest_tag used to call curl and ONLY curl, so this host was told
    'api.github.com unreachable?' when the truth was 'curl is not installed'.
    The fix makes the lookup WORK here, so the assertion is success: the tag is
    resolved through wget and no diagnosis is printed at all."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-wgetonly', tool='wget')
    assert shutil.which('curl', path=str(shim)) is None
    assert shutil.which('wget', path=str(shim)) is not None

    res = run_installer(shim, work, 'wgetonly', '--dry-run')
    assert res.returncode == 0, f'wget-only resolution failed:\n{res.stderr}'
    assert_only_message(res, ['release: v9.9.9', 'releases/download/v9.9.9/'],
                        ALL_RESOLVE_MSGS + ['api.github.com unreachable'])


def test_resolve_rate_limited_confirmed(ctx):
    """(c) HTTP 403 WITH X-RateLimit-Remaining: 0 -- the server itself saying the
    hourly limit is exhausted. Only here may the message name that cause, and the
    reset timestamp is included because it is what makes "wait" actionable."""
    work = ctx['work']
    reset = 4102444800  # 2100-01-01T00:00:00Z: fixed, so the assertion cannot flake.
    shim = make_api_stub(work, 'stub-403-confirmed', tool='curl', latest_status='403',
                         latest_body='{"message": "API rate limit exceeded"}\n',
                         latest_headers=('X-RateLimit-Limit: 60',
                                         'X-RateLimit-Remaining: 0',
                                         f'X-RateLimit-Reset: {reset}'))
    res = run_installer(shim, work, 'rl-confirmed')
    assert res.returncode != 0, f'403 must fail the run:\n{res.stdout}'
    assert_only_message(res, ['error: api.github.com rejected the request with HTTP 403',
                              MSG_RATE_LIMIT, 'transient', '--version <tag>'],
                        others(MSG_RATE_LIMIT))
    # The reset time only counts if it was actually rendered from the header.
    out = res.stdout + res.stderr
    if 'resets at' in out:
        assert '2100-01-01 00:00:00Z' in out, f'reset time not rendered from the header:\n{out}'
    else:
        # Neither GNU `date -d @N` nor BSD `date -r N` worked on this host, which
        # epoch_utc is designed to survive silently. It must then print no reset
        # claim at all rather than a raw epoch number.
        assert str(reset) not in out, f'raw epoch leaked into the message:\n{out}'


def test_resolve_403_without_ratelimit_header_does_not_claim_the_limit(ctx):
    """THE NEGATIVE BRANCH, and the reason this test replaced its predecessor.

    The old test stubbed a 403 with NO rate-limit headers and asserted the
    exhausted-limit claim -- so the suite PINNED a message that names a cause the
    response never established. Worse, GitHub answers 403 for secondary (abuse)
    rate limiting too, and for that mechanism "wait for the window to reset" is
    actively wrong: the hourly window is not what is blocking the caller and
    waiting it out does not clear it.

    So a headerless 403 must report only what is known -- the status, what the
    body said, and the --version escape hatch -- and the assertion that matters is
    the ABSENCE of the rate-limit claim."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-403-bare', tool='curl', latest_status='403',
                         latest_body='{"message": "Forbidden - abuse detection"}\n')
    res = run_installer(shim, work, 'rl-bare')
    assert res.returncode != 0, f'403 must fail the run:\n{res.stdout}'
    assert_only_message(res,
                        ['error: api.github.com refused the latest-release lookup with HTTP 403',
                         MSG_403_UNCONFIRMED,
                         'Forbidden - abuse detection',  # the body excerpt, quoted not paraphrased
                         '--version <tag>'],
                        others(MSG_403_UNCONFIRMED) + [
                            # Named explicitly as well as via others(), because these
                            # three are the specific wrong claims being guarded:
                            '60 requests/hour/IP',
                            'is exhausted',
                            'wait for the window to reset',
                        ])


def test_resolve_403_discrimination_also_works_on_a_wget_only_host(ctx):
    """wget -S reports headers on stderr, indented, in a different shape from
    curl's -D file. api_fetch parses both with one reader, so the discrimination
    must hold on a wget-only host too -- otherwise half the hosts in the world get
    the unproven message back."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-403-wget', tool='wget', latest_status='403',
                         latest_body='{"message": "API rate limit exceeded"}\n',
                         latest_headers=('X-RateLimit-Remaining: 0',))
    res = run_installer(shim, work, 'rl-wget')
    assert res.returncode != 0, f'403 must fail the run:\n{res.stdout}'
    assert_only_message(res, [MSG_RATE_LIMIT], others(MSG_RATE_LIMIT))

    bare = make_api_stub(work, 'stub-403-wget-bare', tool='wget', latest_status='403',
                         latest_body='{"message": "Forbidden - abuse detection"}\n')
    res = run_installer(bare, work, 'rl-wget-bare')
    assert res.returncode != 0, f'403 must fail the run:\n{res.stdout}'
    assert_only_message(res, [MSG_403_UNCONFIRMED],
                        others(MSG_403_UNCONFIRMED) + ['wait for the window to reset'])


def test_resolve_prerelease_fallback(ctx):
    """(d) /releases/latest 404s because every release is a prerelease, which is
    how this project cuts them. The /releases list DOES include prereleases, so
    resolution falls back to it, picks the newest, and SAYS it picked a
    prerelease rather than passing it off as a stable release."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-pre', tool='curl',
                         latest_status='404', latest_body='{"message": "Not Found"}\n',
                         list_status='200', list_body=RELEASE_LIST_PRERELEASE_JSON)
    res = run_installer(shim, work, 'pre', '--dry-run')
    assert res.returncode == 0, f'prerelease fallback failed:\n{res.stderr}'
    assert_only_message(res, ['warning: no stable release exists yet',
                              'selected the newest PRERELEASE v1.2.3-beta.2',
                              'release: v1.2.3-beta.2',
                              'releases/download/v1.2.3-beta.2/'],
                        ALL_RESOLVE_MSGS + ['v1.2.3-beta.1'])


def test_resolve_draft_only_repo(ctx):
    """(e) THE LIVE PRODUCTION CASE. Releases here are cut through the GitHub UI
    with the workflow defaults left ticked, and release-local-binaries.yml passes
    both --draft and --prerelease. A DRAFT is invisible to an unauthenticated
    caller entirely: absent from /releases too, not merely excluded from
    /releases/latest. So the fallback finds nothing and this is the error a real
    user of the advertised one-liner hits today.

    Both shapes below are indistinguishable from outside -- an unauthenticated
    caller cannot tell a draft-only repository from a genuinely empty one, which
    is why ONE message covers both and why it must not claim to have enumerated
    the repository. The empty-list shape IS the draft-only shape.
    """
    work = ctx['work']
    for tag, list_body in (('draftonly-empty', '[]\n'),
                           ('draftonly-notags', '[{"name": "unnamed", "draft": true}]\n')):
        shim = make_api_stub(work, 'stub-' + tag, tool='curl',
                             latest_status='404', latest_body='{"message": "Not Found"}\n',
                             list_status='200', list_body=list_body)
        res = run_installer(shim, work, tag)
        assert res.returncode != 0, f'[{tag}] a repo with nothing published must fail:\n{res.stdout}'
        assert_only_message(res, ['error: api.github.com ' + MSG_NO_RELEASES,
                                  'still a DRAFT is invisible to an unauthenticated lookup',
                                  'publish it', '--version <tag>'],
                            others(MSG_NO_RELEASES))
        # Honesty: it reports what the API answered, never a claim about what the
        # repository holds. It cannot see drafts and must not imply it looked.
        out = res.stdout + res.stderr
        for overclaim in ('no releases exist', 'repository is empty',
                          'has no releases at all'):
            assert overclaim not in out, f'[{tag}] overclaims: {overclaim!r}'


def large_release_list(entries: int = 2500, pad: int = 64) -> str:
    """A /releases page whose tag_name lines TOTAL more than one 64K pipe buffer.

    DO NOT "SIMPLIFY" THIS FIXTURE DOWN TO A REALISTIC SIZE. Its size is the only
    thing it is for. parse_tag_name is `sed ... | head -n 1`: head exits after the
    first match, and sed only actually takes SIGPIPE once its REMAINING output
    exceeds the pipe buffer. A realistically-sized response is drained before sed
    ever notices, so a small fixture silently un-tests the property below.
    """
    entry = '{{"tag_name": "v9.{i}.0-{pad}", "prerelease": true, "draft": false}}'
    body = ',\n '.join(entry.format(i=i, pad='x' * pad) for i in range(entries))
    return '[' + body + ']\n'


def test_resolve_large_release_list_does_not_abort(ctx):
    """Resolution must survive a /releases page big enough to make sed take
    SIGPIPE, and still return the NEWEST tag with a complete plan.

    WHAT THIS DOES AND DOES NOT PROVE -- stated because an earlier version of this
    docstring claimed more than the test delivers:

    parse_tag_name is `sed ... | head -n 1`. head exits after the first match, and
    once sed's remaining output exceeds the 64K pipe buffer sed really does take
    SIGPIPE: measured at 141 from a 2500-entry list producing 186K of sed output.
    So this fixture DOES drive the pipeline into that state, which a
    realistically-sized response (GitHub caps a page at 100 entries) would not.
    Keep it oversized; shrinking it stops exercising this path.

    It does NOT prove parse_tag_name's `return 0` is load-bearing, and removing
    that line does NOT make this test fail. The reason is a bash rule worth
    knowing: resolve_latest_tag's only caller invokes it as
    `if resolve_latest_tag; then`, and bash SUSPENDS `set -e` for the whole body
    of a function whose status is being tested, so the 141 goes nowhere today. The
    captured VALUE is correct even at status 141, which is why nothing breaks.
    That line is kept as defence for the day someone calls resolve_latest_tag
    bare -- see the comment on api_fetch in install.sh -- and the mutation harness
    records it as expected-not-caught with that reasoning rather than pretending
    otherwise.

    What this test genuinely guards is the behaviour a user sees: a large,
    prerelease-only release list still resolves to the newest tag, still announces
    that it picked a prerelease, and still prints a whole plan rather than
    stopping part-way.
    """
    work = ctx['work']
    shim = make_api_stub(work, 'stub-biglist', tool='curl',
                         latest_status='404', latest_body='{"message": "Not Found"}\n',
                         list_status='200', list_body=large_release_list())
    res = run_installer(shim, work, 'bigl', '--dry-run')
    assert res.returncode == 0, (
        'resolution aborted on a large release list: parse_tag_name lost its '
        f'`return 0` and pipefail propagated SIGPIPE\nrc={res.returncode}\n{res.stderr}')
    # The newest entry, and a COMPLETE plan rather than one truncated by an abort.
    expected = 'v9.0.0-' + 'x' * 64
    assert_only_message(res, [f'release: {expected}',
                              f'selected the newest PRERELEASE {expected}',
                              'would install'],
                        ALL_RESOLVE_MSGS)


def test_resolve_unreachable(ctx):
    """Only a genuine absence of any HTTP response may blame the network. This is
    the ONE case the old catch-all message was actually right about."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-000', tool='curl', latest_status='000')
    res = run_installer(shim, work, 'net')
    assert res.returncode != 0, f'an unreachable API must fail the run:\n{res.stdout}'
    assert_only_message(res, ['error: ' + MSG_UNREACHABLE, 'check network, DNS, or proxy',
                              '--version <tag>'],
                        others(MSG_UNREACHABLE))


def test_resolve_200_without_tag_is_fail_closed(ctx):
    """FAIL-CLOSED. A 200 that does not parse must be a named failure, never a
    guessed tag: a wrong tag becomes a 404 on the tarball, which is worse and
    more confusing than the error it replaced."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-notag', tool='curl', latest_status='200',
                         latest_body='{"name": "v1.0.0", "assets": []}\n')
    res = run_installer(shim, work, 'notag')
    assert res.returncode != 0, f'an unparseable 200 must fail:\n{res.stdout}'
    assert_only_message(res, ['error: api.github.com ' + MSG_NO_TAG_FIELD],
                        others(MSG_NO_TAG_FIELD))
    # Nothing may have been derived from the unusable body.
    out = res.stdout + res.stderr
    assert 'releases/download' not in out, f'a tag was guessed from a bad body:\n{out}'


# --- REQ-INST-7: bounded downloads --------------------------------------------

def test_download_branches_are_equally_bounded(ctx):
    """Cheap structural regression guard on the flags. It does NOT establish
    equivalence -- test_download_bounds_are_enforced below does that by execution.

    An earlier version of this docstring claimed both paths bound total time on the
    strength of these flags, and that claim was false for BOTH of them: wget's
    --read-timeout bounds one IDLE read, not duration and not throughput, and wget
    has no total-time flag at all; curl's --max-time is per ATTEMPT, so --retry 3
    multiplied its ceiling by four. The operation-wide bounds come from run_bounded,
    so that is what this asserts."""
    text = INSTALL_SCRIPT.read_text()
    body = text.split('\ndownload() {', 1)[1].split('\n}', 1)[0]
    curl_branch, wget_branch = body.split('else', 1)

    for flag in ('--retry 3', '--connect-timeout', '--speed-limit', '--speed-time',
                 '--max-time'):
        assert flag in curl_branch, f'curl download branch lost {flag}:\n{curl_branch}'
    for flag in ('--tries=3', '--connect-timeout=', '--read-timeout='):
        assert flag in wget_branch, f'wget download branch lost {flag}:\n{wget_branch}'
    # BOTH branches must go through the watchdog: neither tool can bound the whole
    # operation on its own, so a branch that skips it is unbounded again.
    for name, branch in (('curl', curl_branch), ('wget', wget_branch)):
        assert 'run_bounded' in branch, \
            f'{name} branch no longer goes through the watchdog:\n{branch}'
    watchdog = text.split('run_bounded() {', 1)[1].split('\n}', 1)[0]
    for bound in ('NET_DOWNLOAD_MAX_TIME', 'NET_STALL_BYTES_PER_SEC', 'NET_STALL_SECONDS'):
        assert bound in watchdog, f'watchdog does not enforce {bound}:\n{watchdog}'
    # The stall WINDOW is derived from the floor, never a second literal: the
    # horizon must stay a multiple of NET_STALL_SECONDS so that retuning the
    # floor retunes the window with it. A hardcoded number here decouples them
    # silently, which is exactly the shape of bug the watchdog exists to stop.
    # Structural on purpose -- this cannot flake, unlike a timing assertion.
    assert 'stall_horizon=$(( NET_STALL_SECONDS * 2 ))' in watchdog, (
        'the stall horizon is no longer derived from NET_STALL_SECONDS:\n'
        f'{watchdog}')
    assert 'wget -O "$out" "$url"' not in install_sh_code(), \
        'the unbounded wget call is back'

    # The API lookup stays bounded too, and keeps the tighter cap: a slow small
    # response is a broken one.
    assert 'NET_API_MAX_TIME=30' in text
    # Values track src/manager/update.odin (60s tarball stall / 20-30s manifest)
    # rather than inventing new numbers for the same two operations.
    assert 'NET_STALL_SECONDS=60' in text
    odin = (ROOT / 'src' / 'manager' / 'update.odin').read_text()
    assert 'MANAGER_UPDATE_TIMEOUT_MS :: 60000' in odin, \
        'update.odin changed; re-justify install.sh download bounds against it'


# --- REQ-INST-7 adversarial download bounds ------------------------------------
# A localhost server that answers a huge Content-Length and then trickles, so a
# download starts healthily and never ends. Hermetic: loopback only, no external
# network, same discipline as the PATH shims above.

class _DribbleHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    chunk = 1
    interval = 0.5

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '100000000')
        self.end_headers()
        try:
            while True:
                self.wfile.write(b'x' * self.chunk)
                self.wfile.flush()
                time.sleep(self.interval)
        except Exception:
            pass  # client hung up: that is the bound firing, which is the point.

    def log_message(self, *a):
        pass


class _SlowFiniteHandler(http.server.BaseHTTPRequestHandler):
    """Serves a SMALL body slowly and then closes -- a successful transfer whose
    average rate is far below the stall floor."""
    protocol_version = 'HTTP/1.1'
    body = b'heimdall' * 12   # 96 bytes

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(self.body)))
        self.end_headers()
        self.wfile.write(self.body)
        self.wfile.flush()

    def log_message(self, *a):
        pass


class _BurstThenTrickleHandler(http.server.BaseHTTPRequestHandler):
    """Sends a large burst fast, then trickles below the floor for ever.

    This is what a connection that dies mid-transfer looks like, and it is the shape
    that distinguishes a floor anchored at the last known-good point from one
    averaged over the whole transfer: the burst keeps a whole-transfer average above
    the floor indefinitely, so an unanchored floor never notices the transfer stopped
    making progress. It trickles rather than going silent on purpose -- a truly idle
    socket is caught by wget's own --read-timeout, which would mask the difference.
    """
    protocol_version = 'HTTP/1.1'
    burst = 512 * 1024

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '100000000')
        self.end_headers()
        try:
            self.wfile.write(b'x' * self.burst)
            self.wfile.flush()
            while True:
                time.sleep(1.0)
                self.wfile.write(b'x')
                self.wfile.flush()
        except Exception:
            pass

    def log_message(self, *a):
        pass


class _DribbleServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


@contextlib.contextmanager
def burst_then_trickle_server():
    srv = _DribbleServer(('127.0.0.1', 0), _BurstThenTrickleHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        yield f'http://127.0.0.1:{srv.server_address[1]}'
    finally:
        srv.shutdown()
        srv.server_close()


@contextlib.contextmanager
def slow_finite_server():
    srv = _DribbleServer(('127.0.0.1', 0), _SlowFiniteHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        yield f'http://127.0.0.1:{srv.server_address[1]}', len(_SlowFiniteHandler.body)
    finally:
        srv.shutdown()
        srv.server_close()


@contextlib.contextmanager
def dribble_server(bytes_per_tick, interval):
    handler = type('H', (_DribbleHandler,),
                   {'chunk': bytes_per_tick, 'interval': interval})
    srv = _DribbleServer(('127.0.0.1', 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        yield f'http://127.0.0.1:{srv.server_address[1]}'
    finally:
        srv.shutdown()
        srv.server_close()


# Real values are minutes; the tests need seconds. Rewriting a COPY keeps the
# production defaults free of test-only env knobs.
# A stall now needs TWO consecutive sub-floor windows (one is write buffering), so
# detection takes ~2 * NET_STALL_SECONDS. The total cap is set well clear of that so
# the two bounds are distinguishable by elapsed time rather than only by message.
FAST_BOUNDS = {
    'NET_CONNECT_TIMEOUT': 5,
    'NET_STALL_SECONDS': 2,
    'NET_STALL_BYTES_PER_SEC': 1024,
    'NET_DOWNLOAD_MAX_TIME': 14,
}


def install_sh_with_fast_bounds(work: Path, name: str) -> Path:
    """install.sh with the NET_* constants shrunk to seconds.

    Each substitution must match EXACTLY once. Without that check a renamed
    constant would silently leave the real 600s value in place and the bound tests
    would pass by timing out somewhere else entirely.
    """
    text = INSTALL_SCRIPT.read_text()
    for const, value in FAST_BOUNDS.items():
        pattern = rf'^{const}=\d+$'
        text, n = re.subn(pattern, f'{const}={value}', text, flags=re.M)
        assert n == 1, f'expected exactly one {const} assignment to rewrite, got {n}'
    path = work / name
    path.write_text(text)
    return path


def run_download_bound(script: Path, work: Path, tag: str, url: str, tool: str):
    """Drive download() directly against $url with only `tool` on PATH.

    Sourcing the script would run main(), so this appends a call instead -- the
    REQ-INST-4 structure (everything in functions, one main "$@" at the end) is
    what makes that possible.
    """
    tool_path = shutil.which(tool)
    assert tool_path, f'{tool} is required for this test'
    shim = _shim_dir(work, f'bound-{tag}')
    if not (shim / tool).exists():
        (shim / tool).symlink_to(tool_path)
    # Everything run_bounded and download_failed shell out to. `kill` is a bash
    # builtin and needs no link.
    for helper in ('date', 'sleep', 'wc', 'tr'):
        real = shutil.which(helper)
        assert real, f'{helper} is required to exercise the download bounds'
        if not (shim / helper).exists():
            (shim / helper).symlink_to(real)

    driver = work / f'driver-{tag}.sh'
    driver.write_text(
        script.read_text().replace('\nmain "$@"\n', '\n')
        + f'\nset -euo pipefail\n'
        + f'download {shlex.quote(url)} {shlex.quote(str(work / ("dl-" + tag + ".bin")))}\n')
    started = time.monotonic()
    # PATH is the shim ALONE. This is what makes the tool selection real: with the
    # host PATH appended, download() found the system curl and took the curl branch
    # even when this test meant to exercise wget, so the wget bound was never
    # actually executed. Same hermetic rule as stub_env above.
    res = subprocess.run(['bash', str(driver)],
                         env={'PATH': str(shim), 'HOME': str(work), 'TMPDIR': str(work)},
                         capture_output=True, text=True, timeout=180)
    return res, time.monotonic() - started


# Worst case for each branch, from the flags download() actually passes. curl
# retries (--retry 3 = up to 4 attempts, with 1+2+4s of backoff) and its native
# --max-time is PER ATTEMPT -- measured: `--retry 3 --max-time 3` against an
# above-floor endless stream took 19s, not 3s. run_bounded is what bounds the whole
# operation, so the ceiling asserted below is the WATCHDOG's, and the retry
# arithmetic only sets how much slack to allow before it fires.
WATCHDOG_TICK_SLACK = 4  # 1s poll + one TERM/teardown tick, for the STALL ceiling

# The stall ceiling above doubles as the LOWER bound that distinguishes "the floor
# fired" from "the deadline fired", so it is deliberately kept tight. The DEADLINE
# ceiling gets its own, wider slack, sized from run_bounded's real worst case rather
# than from the typical one:
#
#   1s poll granularity + the bounded grace loop (5 x 1s, install.sh:535) + teardown
#
# That matters because these assertions are about to run on GitHub-hosted macOS
# runners (T12), which are shared and throttled. MEASURED on this host with the
# suite's own scenarios, idle and under 16 CPU burners on 4 cpus:
#
#            idle        under 4x oversubscription
#   curl     15.4s       14.4s
#   wget     15.3s       17.0s      <-- 1.0s under an 18s ceiling
#
# wget's 17.0s left one second of headroom, so the old `total_s + 4` was genuinely
# too tight: a busier runner fails it while the watchdog is working perfectly, the
# test gets marked flaky, and the bound stops being checked at all. The bounds
# themselves are WALL-CLOCK (`date +%s`), so a slow host does not move them -- only
# the teardown term grows, which is what this slack covers.
#
# ENFORCEMENT, not a precise window, is the requirement: a non-zero exit plus the
# named bound is what proves the watchdog fired, and the endless server means the
# transfer can never end on its own. This ceiling only catches "it ran far past the
# bound", so widening it to the true worst case costs no detection power -- confirmed
# by re-running the mutation sweep against the wider ceiling.
WATCHDOG_KILL_SLACK = 8  # 1s poll + 5s bounded grace loop + teardown


def assert_download_bounds_enforced(ctx, tool):
    """REQ-INST-7 BY EXECUTION: both bounds, against a server that dribbles forever.

    The structural test above only reads flags. This drives a REAL downloader
    against a real endless server, which is the only thing that proves the two
    branches make the SAME promise rather than asserting they do. Both branches run
    the identical assertions; that symmetry IS the requirement.

    Each branch failed differently before run_bounded, and each was measured:
      wget -- no throughput floor and no total-duration flag exist. --read-timeout
        bounds one IDLE read, so real wget 1.25.0 on a 2 B/s trickle was still
        running after 25s having moved 50 bytes.
      curl -- states both bounds natively, but --max-time is PER ATTEMPT:
        `--retry 3 --max-time 3` against an above-floor endless stream took 19s,
        not 3s, so the real ceiling was 4x the constant.

    The curl assertions are on TIME, not on which mechanism named the bound: curl's
    native --speed-limit and --max-time sit at the same values as the watchdog's, so
    the two race and either may win. The wget assertions additionally require the
    watchdog to NAME the bound, because wget has no native equivalent of either and
    nothing else could have fired.
    """
    if not shutil.which(tool):
        raise Skip(f'{tool} is not installed, so its download bounds cannot be executed')

    work = ctx['work']
    script = install_sh_with_fast_bounds(work, f'install-fast-{tool}.sh')
    stall_s = FAST_BOUNDS['NET_STALL_SECONDS']
    total_s = FAST_BOUNDS['NET_DOWNLOAD_MAX_TIME']
    floor = FAST_BOUNDS['NET_STALL_BYTES_PER_SEC']
    ceiling = total_s + WATCHDOG_KILL_SLACK
    # Two consecutive sub-floor windows, plus a tick of slack.
    stall_ceiling = 2 * stall_s + WATCHDOG_TICK_SLACK

    # (a) STALL: 2 B/s against a 1024 B/s floor. The watchdog's absolute deadline
    #     would eventually stop this too, so asserting "it died" proves nothing
    #     about the floor. The floor is what makes it die EARLY, and on a host where
    #     the deadline is 10 minutes that difference is the whole point.
    with dribble_server(1, 0.5) as base:
        res, elapsed = run_download_bound(script, work, f'stall-{tool}',
                                          f'{base}/heimdall.tar.gz', tool)
    out = res.stdout + res.stderr
    assert res.returncode != 0, f'{tool}: a 2 B/s trickle must fail:\n{out}'
    assert 'download failed' in out, f'{tool}: no diagnosis:\n{out}'
    # A throughput floor fired, not the deadline -- asserted by TIME rather than by
    # message, because curl has a native --speed-limit at the same value and either
    # its floor or the watchdog's may win the race. Which one is immaterial; that a
    # sub-floor transfer dies well before the total cap is the requirement.
    assert elapsed < stall_ceiling, (
        f'{tool}: sub-floor trickle ran {elapsed:.1f}s, past the {stall_ceiling}s a '
        f'{floor} B/s floor allows -- nothing enforced it and it was heading for the '
        f'{total_s}s deadline instead:\n{out}')
    if tool == 'wget':
        # wget has NO native throughput floor, so here the watchdog is the only
        # thing that can have fired and it must say so.
        assert 'stalled below' in out, (
            f'wget: the stall was not named, so the floor did not fire '
            f'(elapsed {elapsed:.1f}s):\n{out}')

    # (b) DEADLINE: 4096 B/s, comfortably ABOVE the floor, so the stall check must
    #     never fire -- but the stream never ends. This is the case a watchdog
    #     implementing only the stall half would hang on forever, and the case
    #     curl's per-attempt --max-time multiplied by four.
    with dribble_server(4096, 1.0) as base:
        res, elapsed = run_download_bound(script, work, f'total-{tool}',
                                          f'{base}/heimdall.tar.gz', tool)
    out = res.stdout + res.stderr
    assert res.returncode != 0, f'{tool}: an endless stream must fail:\n{out}'
    assert 'download failed' in out, f'{tool}: no diagnosis:\n{out}'
    assert elapsed < ceiling, (
        f'{tool}: above-floor endless stream ran {elapsed:.1f}s, past the {total_s}s '
        f'cap -- NET_DOWNLOAD_MAX_TIME is not bounding the whole operation:\n{out}')
    assert elapsed > stall_ceiling, (
        f'{tool}: died in {elapsed:.1f}s on an ABOVE-floor stream, inside the window '
        f'a stall would be detected in -- the floor is firing on a transfer that is '
        f'meeting it, which is what write buffering causes when a single window is '
        f'trusted:\n{out}')
    if tool == 'wget':
        # wget has no total-duration flag at all, so only the watchdog can have
        # stopped this, and naming the bound is the difference between a diagnosis
        # and "download failed" for a transfer that was still moving data.
        assert 'total download limit' in out, (
            f'wget: the TOTAL cap was not named (elapsed {elapsed:.1f}s):\n{out}')

    # (c) BURSTY but healthy: 8192 bytes every NET_STALL_SECONDS = 4096 B/s average,
    #     FOUR TIMES the floor, delivered in bursts exactly as far apart as the stall
    #     window. Seconds of zero file growth are guaranteed by construction while the
    #     transfer comfortably meets the floor -- so this is the shape that a
    #     per-window floor gets wrong, and the reason the floor is an average since
    #     the last known-good anchor instead.
    #
    #     The gap is pinned at NET_STALL_SECONDS because that is the tolerance the
    #     implementation can actually claim: measured across gaps of 0.5s, 1s, 2s and
    #     3s at a fixed 4x-floor average, both branches carry the first three to the
    #     deadline, while a 3s gap (75% of the horizon) makes wget's write lag look
    #     like a stall. At the production 60s that edge is a full minute of silence,
    #     which is a stall by any useful definition.
    with dribble_server(2 * 4096, float(FAST_BOUNDS['NET_STALL_SECONDS'])) as base:
        res, elapsed = run_download_bound(script, work, f'bursty-{tool}',
                                          f'{base}/heimdall.tar.gz', tool)
    out = res.stdout + res.stderr
    assert res.returncode != 0, f'{tool}: an endless bursty stream must still fail:\n{out}'
    assert 'stalled below' not in out, (
        f'{tool}: bursty delivery at 4x the floor was called a STALL after '
        f'{elapsed:.1f}s -- a single zero-growth window is write buffering, not a '
        f'stall:\n{out}')
    assert elapsed > stall_ceiling, (
        f'{tool}: bursty above-floor stream died in {elapsed:.1f}s, inside the stall '
        f'detection window:\n{out}')
    assert elapsed < ceiling, (
        f'{tool}: bursty stream ran {elapsed:.1f}s, past the {total_s}s cap:\n{out}')

    if tool != 'wget':
        # curl has a native throughput floor at the same value, and it fires on the
        # trickle below before the watchdog's anchor can be the deciding mechanism.
        # The case is therefore only observable on the branch that has no native
        # floor -- which is also the branch that needs the watchdog.
        return

    # (d) FAST, THEN DEAD: a 512 KB burst followed by a 1 B/s trickle for ever. This
    #     is a connection that dies mid-transfer, and it is the case that proves the
    #     floor is anchored at the last KNOWN-GOOD point rather than averaged over the
    #     whole transfer. An unanchored average keeps the burst in the numerator for
    #     ever, so it never notices the transfer stopped progressing and lets it run to
    #     the total cap instead -- a 10-minute hang in production where the floor
    #     should have caught it in 60 seconds. It trickles rather than going silent
    #     because a truly idle socket is caught by wget's own --read-timeout, which
    #     would hide the difference.
    with burst_then_trickle_server() as base:
        res, elapsed = run_download_bound(script, work, f'burstdead-{tool}',
                                          f'{base}/heimdall.tar.gz', tool)
    out = res.stdout + res.stderr
    assert res.returncode != 0, f'{tool}: a transfer that died must fail:\n{out}'
    assert 'stalled below' in out, (
        f'{tool}: a 512 KB burst followed by 1 B/s was not called a stall after '
        f'{elapsed:.1f}s -- the floor is being averaged over the whole transfer '
        f'instead of since the last known-good point:\n{out}')
    assert elapsed < stall_ceiling, (
        f'{tool}: took {elapsed:.1f}s to notice a dead transfer; the floor should '
        f'catch it within {stall_ceiling}s, not at the {total_s}s cap:\n{out}')


def test_download_floor_does_not_punish_small_files(ctx):
    """The floor is a STALL detector, not a minimum-average-rate requirement.

    SHA256SUMS is a couple of hundred bytes. If the watchdog demanded
    NET_STALL_BYTES_PER_SEC * NET_STALL_SECONDS bytes per window unconditionally,
    every small file would be aborted for the crime of being small, and the message
    would blame a stall for a transfer that was fine.

    This also pins the liveness re-check after the poll sleep. Without it, a
    transfer that finishes during a tick that crosses a window boundary is judged on
    the bytes of its own final fraction of a second, finds them under the floor, and
    reports a stall for a download that had already SUCCEEDED -- a wrong cause on a
    working install.
    """
    tool = 'curl' if shutil.which('curl') else 'wget'
    if not shutil.which(tool):
        raise Skip('neither curl nor wget is installed')

    work = ctx['work']
    script = install_sh_with_fast_bounds(work, f'install-fast-small-{tool}.sh')
    with slow_finite_server() as (base, size):
        res, elapsed = run_download_bound(script, work, f'small-{tool}',
                                          f'{base}/SHA256SUMS', tool)
    out = res.stdout + res.stderr
    assert res.returncode == 0, (
        f'{tool}: a {size}-byte file must download successfully even though its '
        f'average rate is far under the floor:\n{out}')
    assert 'stalled below' not in out, f'{tool}: false stall on a small file:\n{out}'
    assert 'download failed' not in out, f'{tool}: small file reported failure:\n{out}'
    landed = (work / f'dl-small-{tool}.bin')
    assert landed.is_file() and landed.stat().st_size == size, (
        f'{tool}: expected {size} bytes at {landed}, got '
        f'{landed.stat().st_size if landed.is_file() else "no file"}')


def test_download_bounds_curl(ctx):
    """curl states both bounds natively (--speed-limit/--speed-time, --max-time).
    Executed anyway, so the two branches are held to ONE assertion."""
    assert_download_bounds_enforced(ctx, 'curl')


def test_download_bounds_wget(ctx):
    """wget can express NEITHER bound as a flag, so download_with_wget enforces
    both. This is the blocking REQ-INST-7 defect's regression test."""
    assert_download_bounds_enforced(ctx, 'wget')


def test_download_failure_names_url_and_tmpdir(ctx):
    """A failed download must name WHICH url failed -- the installer fetches
    several -- and, when the target sits under TMPDIR, say that a small tmpfs can
    be the real cause, because mktemp -d puts a multi-MB tarball there."""
    work = ctx['work']
    home = work / 'home-dlfail'
    runtime = work / 'run-dlfail'
    tmpdir = work / 'tmp-dlfail'
    for d in (home, runtime, tmpdir):
        d.mkdir(parents=True, exist_ok=True)
    missing = work / 'no-such-mirror'
    env = sandbox_install_env(home, runtime)
    env['TMPDIR'] = str(tmpdir)
    # --hub keeps this off the GitHub API entirely; the url is a local file://
    # that does not exist, so the failure is real and nothing leaves the machine.
    res = subprocess.run(['bash', str(INSTALL_SCRIPT), '--hub', f'file://{missing}'],
                         env=env, capture_output=True, text=True, timeout=90)
    assert res.returncode != 0, f'a missing mirror must fail:\n{res.stdout}'
    out = res.stdout + res.stderr
    assert 'download failed: ' in out, f'failure did not name the url:\n{out}'
    assert f'file://{missing}/heimdall-local-' in out, f'url missing from report:\n{out}'
    assert str(tmpdir) in out and 'tmpfs' in out, f'TMPDIR hint missing:\n{out}'
    assert 'set TMPDIR to a larger filesystem' in out, f'no remediation:\n{out}'


def test_hub_and_version_paths_never_call_the_api(ctx):
    """--hub and --version must not newly reach api.github.com. Proven by giving
    them a PATH whose only downloader is a stub that FAILS every api.github.com
    request: if either path consulted the API, resolution would report one of the
    five diagnoses instead of using the tag it was handed."""
    work = ctx['work']
    shim = make_api_stub(work, 'stub-noapi', tool='curl', latest_status='403',
                         list_status='403')
    res = run_installer(shim, work, 'ver-noapi', '--dry-run', '--version', 'v0.4.2')
    assert res.returncode == 0, f'--version dry run failed:\n{res.stderr}'
    assert_only_message(res, ['release: v0.4.2', 'releases/download/v0.4.2/'],
                        ALL_RESOLVE_MSGS)

    res = run_installer(shim, work, 'hub-noapi', '--dry-run', '--hub',
                        'file:///nonexistent-mirror')
    assert res.returncode == 0, f'--hub dry run failed:\n{res.stderr}'
    assert_only_message(res, ['file:///nonexistent-mirror/heimdall-local-'],
                        ALL_RESOLVE_MSGS + ['api.github.com'])


def test_install_sh_full_run_service_lifecycle(ctx):
    """Prove the service-file lifecycle by real runs against a local file://
    --hub mirror, with HOME sandboxed so nothing touches the real
    ~/.config/systemd/user or ~/.config/heimdall."""
    need_tool('curl')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh full run: {platform.system()}/{platform.machine()}')
    base = ctx['work'] / 'fullrun'
    home = base / 'home'
    (base / 'xdg-runtime').mkdir(parents=True)

    res, tarball = package_tarball(base, target=target)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    hub = make_hub_mirror(base, tarball, target)
    # A second mirror serving the same tarball under a different URL, so a
    # re-run with a different --hub produces a differing unit.
    hub2 = make_hub_mirror(base / 'second', tarball, target)

    env = {**os.environ,
           'HOME': str(home),
           'XDG_CONFIG_HOME': '',
           'XDG_RUNTIME_DIR': str(base / 'xdg-runtime'),
           'SUDO_USER': '',
           'SHELL': ''}

    def install_run(hub_url, *extra):
        return subprocess.run(
            ['bash', str(INSTALL_SCRIPT), '--hub', hub_url, *extra],
            cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=120)

    if target.startswith('linux'):
        service = home / '.config/systemd/user/heimdall-bridge.service'
        hub_in_unit = f'--hub {hub}'
        hub2_in_unit = f'--hub {hub2}'
    else:
        service = home / 'Library/LaunchAgents/works.earendil.heimdall-bridge.plist'
        hub_in_unit = f'<string>{hub}</string>'
        hub2_in_unit = f'<string>{hub2}</string>'

    # Run 1: fresh install. No prior unit exists, so no backup may be created.
    res = install_run(hub)
    assert res.returncode == 0, f'first install failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'
    assert service.is_file(), 'service file not written'
    assert hub_in_unit in service.read_text(), 'explicit --hub must be baked into the unit'
    assert 'wrote service file' in res.stdout
    assert not list(service.parent.glob('*.bak-*')), 'no backup may be created when no prior unit exists'
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert (home / '.local/bin' / binary).is_file(), f'{binary} not installed'
    assert '.local/bin' in (home / '.bashrc').read_text(), 'PATH line missing from sandbox .bashrc'

    # Run 2: identical re-run. The unit is unchanged, so the write must be
    # skipped with a message and no backup created.
    res = install_run(hub)
    assert res.returncode == 0, f'identical re-run failed:\n{res.stderr}'
    assert 'already up to date; leaving it untouched' in res.stdout
    assert not list(service.parent.glob('*.bak-*')), 'identical unit must not produce a backup'

    # Run 3: differing unit (different mirror URL). The old file must be backed
    # up to <service>.bak-<UTC timestamp> and the new unit installed.
    res = install_run(hub2)
    assert res.returncode == 0, f'differing re-run failed:\n{res.stderr}'
    assert 'saved a copy to' in res.stdout
    backups = sorted(service.parent.glob('*.bak-*'))
    assert len(backups) == 1, f'expected exactly one backup, got {[b.name for b in backups]}'
    assert re.fullmatch(r'.*\.bak-\d{8}T\d{6}Z', backups[0].name), (
        f'backup name must carry a UTC timestamp: {backups[0].name}')
    assert hub_in_unit in backups[0].read_text(), 'backup must hold the PREVIOUS unit contents'
    assert hub2_in_unit in service.read_text(), 'new unit must carry the new hub'

    # Run 4: --force-service overwrites a differing unit with NO new backup.
    res = install_run(hub, '--force-service')
    assert res.returncode == 0, f'--force-service run failed:\n{res.stderr}'
    assert 'saved a copy to' not in res.stdout, '--force-service must not back up'
    assert 'wrote service file' in res.stdout
    assert hub_in_unit in service.read_text()
    backups = sorted(service.parent.glob('*.bak-*'))
    assert len(backups) == 1, '--force-service must not add a backup'


def test_install_sh_sudo_paths(ctx):
    """Prove the sudo handling with unshare -r (current user mapped to uid 0 in
    a private user namespace): SUDO_USER resolves the service owner; root
    without a resolvable SUDO_USER refuses to run. Dry runs only — zero writes."""
    if not sys.platform.startswith('linux'):
        raise Skip(f'sudo-path test needs Linux user namespaces (got {sys.platform})')
    need_tool('unshare')
    probe = run(['unshare', '-r', 'id', '-u'])
    if probe.returncode != 0 or probe.stdout.strip() != '0':
        raise Skip('unprivileged user namespaces unavailable (unshare -r id -u != 0)')

    import pwd
    entry = pwd.getpwuid(os.getuid())
    base = ctx['work'] / 'sudo'
    root_home = base / 'root-home'
    root_home.mkdir(parents=True)

    def sudo_run(extra_env):
        env = {**os.environ, 'HOME': str(root_home), **extra_env}
        return subprocess.run(
            ['unshare', '-r', 'env', 'bash', str(INSTALL_SCRIPT),
             '--dry-run', '--version', 'v0.1.0'],
            cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=60)

    # Resolvable SUDO_USER: binaries global, service file + PATH lines planned
    # for that user's home.
    res = sudo_run({'SUDO_USER': entry.pw_name})
    assert res.returncode == 0, f'sudo dry run failed:\n{res.stderr}'
    sudo_line = (f'sudo detected: binaries go to /usr/local/bin; the service '
                 f'file and PATH lines will be written for user {entry.pw_name} '
                 f'(home: {entry.pw_dir})')
    assert sudo_line in res.stdout
    assert f'would write service file {entry.pw_dir}/.config/systemd/user/heimdall-bridge.service' in res.stdout
    assert 'refusing to run as root' not in res.stderr
    assert not any(root_home.iterdir()), 'dry run must not write anything'

    # BLOCKER 1 regression (reviewer repro shape): root's PATH normally
    # contains /usr/local/bin. The sudo branch must decide from the target
    # user's rc files, never from the process PATH, so the "already on PATH"
    # short-circuit must not fire and the target rc files must be named.
    res = sudo_run({'SUDO_USER': entry.pw_name,
                    'PATH': f'/usr/local/bin:{os.environ["PATH"]}'})
    assert res.returncode == 0, f'sudo dry run with /usr/local/bin on PATH failed:\n{res.stderr}'
    assert 'is already on PATH' not in res.stdout, (
        "sudo branch must not decide PATH wiring from the installer's (root's) PATH")
    assert (f"would add /usr/local/bin to PATH in {entry.pw_dir}/.bashrc / .zshrc as needed "
            f"(idempotent; decided from {entry.pw_name}'s rc files, not the sudo PATH)"
            ) in res.stdout, 'sudo dry run must plan the rc write for the target user'

    # SUDO_USER unset or root: refuse with the no-sudo instruction.
    for bad in ('', 'root'):
        res = sudo_run({'SUDO_USER': bad})
        assert res.returncode != 0, f'SUDO_USER={bad!r} must refuse to run as root'
        assert 'refusing to run as root' in res.stderr
        assert 'Re-run without sudo' in res.stderr, 'refusal must tell the user to re-run without sudo'
    assert not any(root_home.iterdir()), 'refused runs must not write anything'


def need_userns_mount():
    """Real uid-0 runs need unshare -rm plus the ability to mount inside it.
    The mounts are namespace-private: nothing is visible outside the process."""
    if not sys.platform.startswith('linux'):
        raise Skip(f'user-namespace tests need Linux (got {sys.platform})')
    need_tool('unshare')
    probe_dir = tempfile.mkdtemp(prefix='heimdall-usrns-probe-')
    probe = run(['unshare', '-rm', 'sh', '-c',
                 f'mount -t tmpfs tmpfs {probe_dir} && umount {probe_dir}'])
    os.rmdir(probe_dir)
    if probe.returncode != 0:
        raise Skip('user namespaces with mount support unavailable (unshare -rm mount failed)')


def sudo_ns_fixture(base: Path):
    """Shared fixture for uid-0 real runs: a stub release whose entries are
    uid-0 (tar runs under unshare -r so the apparent owner is root), a file://
    --hub mirror, and an empty sandbox home. Returns (hub, fake_home, user)."""
    import pwd
    entry = pwd.getpwuid(os.getuid())
    fake_home = base / 'fakehome'
    mirror = base / 'mirror'
    (fake_home / 'bin').mkdir(parents=True)
    mirror.mkdir(parents=True)
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        stub = fake_home / 'bin' / binary
        stub.write_text('#!/bin/sh\n')
        stub.chmod(0o755)
    asset = mirror / 'heimdall-local-linux-amd64.tar.gz'
    res = run(['unshare', '-r', 'tar', '-czf', str(asset), '-C', str(fake_home), 'bin'])
    assert res.returncode == 0, f'uid-0 stub tarball creation failed:\n{res.stderr}'
    (mirror / 'SHA256SUMS').write_text(f'{sha256_of(asset)}  {asset.name}\n')
    return f'file://{mirror}', fake_home, entry


def sudo_ns_install(base: Path, hub: str, entry, path_prefix: str, *extra: str,
                    pre: str = ''):
    """Run install.sh as uid 0 inside a private user+mount namespace:
    a tmpfs over /usr keeps /usr/local/bin writes contained, and the sandbox
    home is bind-mounted over the SUDO_USER's real home (ns-private) so the
    script's getent-based home resolution finds it. The script itself is
    copied under /tmp first — the bind mount shadows the real home, and the
    checkout lives there."""
    script_copy = base / 'install.sh'
    shutil.copy(INSTALL_SCRIPT, script_copy)
    # The tmpfs over /usr is namespace-PRIVATE, so /usr/local/bin starts empty
    # in every invocation — a second call cannot see the first call's binaries.
    # `pre` runs inside the namespace, which is how an uninstall run gets
    # something at /usr/local/bin to act on.
    inner = ('mount -t tmpfs tmpfs /usr && '
             'mkdir -p /usr/local/bin && '
             f'mount --bind {base / "fakehome"} {entry.pw_dir} && '
             + (f'{pre} && ' if pre else '')
             + f'cd {base} && bash {script_copy} --hub {hub}'
             + (' ' + ' '.join(extra) if extra else ''))
    env = {**os.environ,
           'HOME': str(base / 'root-home'),
           'SUDO_USER': entry.pw_name,
           'PATH': f'{path_prefix}:/usr/local/bin:{os.environ["PATH"]}'}
    (base / 'root-home').mkdir(exist_ok=True)
    return subprocess.run(['unshare', '-rm', 'env', 'bash', '-c', inner],
                          cwd=str(base), env=env, capture_output=True, text=True,
                          timeout=120)


def test_install_sh_sudo_path_write(ctx):
    """BLOCKER 1 end-to-end: a real uid-0 install whose (root) PATH contains
    /usr/local/bin must still write the PATH export into the TARGET user's rc
    file — the decision comes from the rc files, not the process PATH."""
    need_userns_mount()
    base = ctx['work'] / 'sudo-write'
    base.mkdir(parents=True)
    hub, fake_home, entry = sudo_ns_fixture(base)

    res = sudo_ns_install(base, hub, entry, path_prefix='/nonexistent-stub')
    assert res.returncode == 0, f'uid-0 install failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'

    service = fake_home / '.config/systemd/user/heimdall-bridge.service'
    assert service.is_file(), 'service file not written into the SUDO_USER home'
    unit = service.read_text()
    assert 'ExecStart=/usr/local/bin/ham-bridge' in unit
    assert f'--hub {hub}' in unit
    expected_rc = '.zshrc' if entry.pw_shell.endswith('zsh') else '.bashrc'
    rc = fake_home / expected_rc
    assert rc.is_file(), f'target user rc file {expected_rc} not written despite root PATH containing /usr/local/bin'
    assert 'export PATH="/usr/local/bin:$PATH"' in rc.read_text()
    # The install announced the target user, not a silent /root fallback.
    assert f'Registered for user: {entry.pw_name}' in res.stdout


def test_install_sh_sudo_chown_failure_warns(ctx):
    """BLOCKER 2: when chown fails (stubbed on PATH ahead of the real one),
    the install stays non-fatal but every failed target is warned with the
    path, intended owner, and remediation — no silent root-owned leftovers."""
    need_userns_mount()
    base = ctx['work'] / 'sudo-chown'
    base.mkdir(parents=True)
    stub_dir = base / 'stub'
    stub_dir.mkdir(parents=True)
    chown_stub = stub_dir / 'chown'
    chown_stub.write_text('#!/bin/sh\nexit 1\n')
    chown_stub.chmod(0o755)
    hub, fake_home, entry = sudo_ns_fixture(base)

    res = sudo_ns_install(base, hub, entry, path_prefix=str(stub_dir))
    assert res.returncode == 0, (
        f'install must stay non-fatal when chown fails:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}')
    service = fake_home / '.config/systemd/user/heimdall-bridge.service'
    assert service.is_file(), 'service file must still be written'

    service_path = f'{entry.pw_dir}/.config/systemd/user/heimdall-bridge.service'
    warnings = [line for line in res.stderr.splitlines() if 'could not chown' in line]
    assert warnings, 'failed chowns must produce warnings, not silence'
    assert len(warnings) >= 3, (
        f'expected warnings for rc file, config dirs and service file; got {len(warnings)}:\n{res.stderr}')
    assert any(service_path in line for line in warnings), (
        f'the service file chown failure must be named:\n{res.stderr}')
    for line in warnings:
        assert f"to {entry.pw_name}" in line, f'warning must name the intended owner: {line!r}'
        assert f"'chown {entry.pw_name}: " in line, f'warning must give the chown remediation: {line!r}'
        assert 'before starting the service' in line, f'warning must say when to remediate: {line!r}'


def sandbox_install_env(home: Path, runtime: Path) -> dict:
    """Env for a hermetic install run: sandbox HOME, no sudo, unknown shell.
    SHELL='' makes path_candidates() take its union branch, which is the
    historical ~/.bashrc-first behaviour.

    XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are NOT cosmetic here: they
    are what keeps `systemctl --user stop heimdall-bridge` inside install.sh's
    uninstall path away from the live session bus. See
    assert_bridge_isolated() — and do not drop either override.
    """
    # REQ-INST-14: socat is a FATAL preflight now, so a sandboxed run needs one
    # on PATH. Prepending our own stub rather than relying on the host's socat
    # keeps the suite deterministic on machines that do not have it -- notably
    # the macOS runners, where neither outcome is guaranteed.
    home.mkdir(parents=True, exist_ok=True)
    socat_dir = home / '.socat-stub'
    write_socat_stub(socat_dir)
    return {**os.environ,
            'PATH': f'{socat_dir}{os.pathsep}' + os.environ.get('PATH', ''),
            'HOME': str(home),
            'XDG_CONFIG_HOME': '',
            'XDG_RUNTIME_DIR': str(runtime),
            # Belt and braces: XDG_RUNTIME_DIR alone is what systemd actually
            # resolves the user bus from today, but blanking the bus address too
            # means the isolation does not depend on that implementation detail.
            'DBUS_SESSION_BUS_ADDRESS': '',
            'SUDO_USER': '',
            'SHELL': ''}


def assert_bridge_isolated(env: dict, work: Path) -> None:
    """REQ-INST-13. HARD precondition before ANY non-dry-run --uninstall.

    install.sh's uninstall path runs `systemctl --user stop heimdall-bridge`,
    and that is the RIGHT command for real users — the unit name in
    scripts/install.sh is the same one that runs the bridge on a developer's own
    machine, which on this project's hosts is the process supervising the
    agents themselves. A test that reached the live user bus would stop the
    bridge, and every agent with it, in the middle of the run.

    So the isolation is the harness's responsibility: production code must not
    grow a test-only escape hatch. This fails (never skips) unless BOTH hold:

      1. env['XDG_RUNTIME_DIR'] is inside the test work dir — in particular it
         must not be /run/user/<uid>, the live session bus; and
      2. `systemctl --user is-active heimdall-bridge`, run with THIS env,
         cannot reach a bus at all. Any verdict it returns — active OR
         inactive — means the env resolves to a real session, and the
         destructive call must not be made.

    If this ever fires, STOP and report it. Do not weaken it to get a green
    run: a firing guard means the suite was about to kill the fleet.
    """
    runtime = env.get('XDG_RUNTIME_DIR') or ''
    assert runtime, (
        'XDG_RUNTIME_DIR must point at a sandbox dir before a real --uninstall; '
        'an empty value lets systemd fall back to the live session bus')
    resolved = Path(runtime).resolve()
    assert not str(resolved).startswith('/run/user/'), (
        f'XDG_RUNTIME_DIR={resolved} is a LIVE session bus directory — a real '
        '--uninstall with this env would stop the running heimdall-bridge')
    work_resolved = work.resolve()
    assert resolved == work_resolved or work_resolved in resolved.parents, (
        f'XDG_RUNTIME_DIR={resolved} is outside the test work dir '
        f'{work_resolved}; refusing to run a destructive --uninstall against a '
        'session this suite does not own')
    assert env.get('DBUS_SESSION_BUS_ADDRESS', '') == '', (
        'DBUS_SESSION_BUS_ADDRESS must be blanked before a real --uninstall; '
        'an inherited address is a second route to the live bus')

    if shutil.which('systemctl') is None:
        return  # nothing can be stopped on a host without systemctl
    probe = subprocess.run(
        ['systemctl', '--user', 'is-active', 'heimdall-bridge'],
        env=env, capture_output=True, text=True, timeout=30)
    combined = f'{probe.stdout}\n{probe.stderr}'
    unreachable = any(marker in combined for marker in (
        'Failed to connect',
        'Failed to get D-Bus connection',
        'No such file or directory',
        'Permission denied',
    ))
    assert unreachable, (
        '`systemctl --user is-active heimdall-bridge` REACHED a user bus with '
        f'the test env (exit={probe.returncode}, stdout={probe.stdout.strip()!r}) — '
        'this env resolves to a live systemd session, so a real --uninstall '
        'would stop the bridge that runs the agents. Aborting BEFORE the '
        'destructive call; fix the sandbox env, do not weaken this guard.')


def test_install_sh_readonly_rc_nonfatal(ctx):
    """REQ-INST-5 (the user's explicit requirement): an rc file that cannot be
    written must NOT fail the install. The original bug aborted under
    `set -euo pipefail` at the bare `printf >> "$rc"` — after the binaries were
    installed but BEFORE the service file was written — so exit 0 alone does
    not prove the fix: the service file must be shown to exist afterwards.

    Runs the real installer against a local file:// --hub mirror with a
    chmod 0444 rc file, then repeats with the mode restored to prove the
    three outcomes (could-not-write / added / already present) and that the
    grep -Fqx duplicate guard survives the failure boundary."""
    if os.getuid() == 0:
        raise Skip('running as root: root bypasses the 0444 mode bits, so a '
                   'read-only rc file cannot be simulated with chmod')
    need_tool('curl')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh full run: {platform.system()}/{platform.machine()}')

    base = ctx['work'] / 'readonly-rc'
    home = base / 'home'
    home.mkdir(parents=True)
    (base / 'xdg-runtime').mkdir(parents=True)
    res, tarball = package_tarball(base, target=target)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    hub = make_hub_mirror(base, tarball, target)
    env = sandbox_install_env(home, base / 'xdg-runtime')

    rc = home / '.bashrc'
    original = '# user rc\nexport EDITOR=vi\n'
    rc.write_text(original)
    rc.chmod(0o444)

    def install_run(*extra):
        return subprocess.run(
            ['bash', str(INSTALL_SCRIPT), '--hub', hub, *extra],
            cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=120)

    if target.startswith('linux'):
        service = home / '.config/systemd/user/heimdall-bridge.service'
    else:
        service = home / 'Library/LaunchAgents/works.earendil.heimdall-bridge.plist'
    install_dir = home / '.local/bin'

    # --- run 1: read-only rc. Must be non-fatal AND must reach the unit. -----
    res = install_run()
    assert res.returncode == 0, (
        'a read-only rc file must NOT fail the install:\n'
        f'stdout:\n{res.stdout}\nstderr:\n{res.stderr}')
    assert service.is_file(), (
        'the install aborted between the binaries and the service file — the '
        'exact REQ-INST-5 bug; exit 0 is not enough on its own')
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert (install_dir / binary).is_file(), f'{binary} not installed'
    assert rc.read_text() == original, 'an unwritable rc file must be left byte-identical'

    # The failure is named, with the file, and reads as a warning not a fatal.
    assert any('could not write' in line and '.bashrc' in line
               for line in res.stderr.splitlines()), (
        f'the unwritable rc file must be named in a warning:\n{res.stderr}')

    # The printed snippet is copy-pasteable and covers all three shapes.
    out = res.stdout
    assert f'export PATH="{install_dir}:$PATH"' in out, 'plain export form missing from snippet'
    assert f'home.sessionPath = [ "{install_dir}" ];' in out, 'home-manager form missing from snippet'
    assert 'home.sessionVariables.PATH' in out, 'home-manager sessionVariables variant missing'
    assert f'fish_add_path {install_dir}' in out, 'fish form missing from snippet'

    # The summary must read as a SUCCESS with one manual step left.
    assert 'the install SUCCEEDED' in out, (
        f'the final summary must not read like a failure:\n{out}')
    assert 'Only PATH still needs your action' in out

    # --- run 2: rc writable. Outcome must switch to "added". ----------------
    rc.chmod(0o644)
    res = install_run()
    assert res.returncode == 0, f'second install failed:\n{res.stderr}'
    assert f'added {install_dir} to PATH in {rc}' in res.stdout, (
        f'a writable rc file must report "added":\n{res.stdout}')
    assert 'the install SUCCEEDED' not in res.stdout, (
        'the PATH-needs-action note must not appear once the rc file was written')
    body = rc.read_text()
    assert body.startswith(original), 'the pre-existing rc content must be preserved'
    assert body.count('# Added by heimdall install.sh') == 1
    assert body.count(f'export PATH="{install_dir}:$PATH"') == 1

    # --- run 3: idempotency. The grep -Fqx guard must prevent a duplicate. ---
    res = install_run()
    assert res.returncode == 0, f'third install failed:\n{res.stderr}'
    assert f'{rc} already adds {install_dir} to PATH' in res.stdout, (
        f'a re-run must report "already adds":\n{res.stdout}')
    assert rc.read_text() == body, 'a re-run must not modify the rc file at all'
    assert rc.read_text().count(f'export PATH="{install_dir}:$PATH"') == 1, (
        'the duplicate guard must survive the read-only failure boundary')


def test_install_sh_uninstall(ctx):
    """REQ-INST-8: --uninstall reverses the install and nothing more. Proves
    the dry run touches nothing, that only the marked PATH lines are removed,
    and that the three categories of user state — enrollment, unit backups,
    and a same-named file this installer did not write — are all KEPT."""
    need_tool('curl')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh full run: {platform.system()}/{platform.machine()}')

    base = ctx['work'] / 'uninstall'
    home = base / 'home'
    home.mkdir(parents=True)
    (base / 'xdg-runtime').mkdir(parents=True)
    res, tarball = package_tarball(base, target=target)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    hub = make_hub_mirror(base, tarball, target)
    env = sandbox_install_env(home, base / 'xdg-runtime')

    rc = home / '.bashrc'
    # A decoy that looks like ours but is NOT under the marker, plus an
    # unrelated export. Neither may be touched.
    decoy = 'export PATH="/opt/other/bin:$PATH"\nexport EDITOR=vi\n'
    rc.write_text(decoy)

    res = subprocess.run(['bash', str(INSTALL_SCRIPT), '--hub', hub],
                         cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=120)
    assert res.returncode == 0, f'install failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'

    install_dir = home / '.local/bin'
    if target.startswith('linux'):
        service = home / '.config/systemd/user/heimdall-bridge.service'
    else:
        service = home / 'Library/LaunchAgents/works.earendil.heimdall-bridge.plist'
    assert service.is_file()

    # A generic-named file this installer did NOT write: must survive. It
    # deliberately MENTIONS heimdall, because the superseded design proved
    # authorship by grepping the file for that string — which would have
    # deleted this stranger. Provenance now comes from the sidecar hash
    # recorded at install time, and no sidecar exists here.
    stranger = install_dir / 'openssl'
    stranger.write_text('#!/bin/sh\n# wrapper used by heimdall, not written by it\n')
    stranger.chmod(0o755)
    assert 'heimdall' in stranger.read_text(), 'fixture sanity: the stranger must mention heimdall'
    assert not (install_dir / '.heimdall-openssl.sha256').exists(), (
        'this install shipped no openssl, so there must be no provenance record')
    # A unit backup (RULING 2: recovery artifact, must survive and be named).
    backup = service.parent / f'{service.name}.bak-20260101T000000Z'
    backup.write_text('[Unit]\n# hand-tuned unit\n')
    # Enrollment state: must survive.
    enrollment = home / '.config/heimdall/config.toml'
    enrollment.parent.mkdir(parents=True, exist_ok=True)
    enrollment.write_text('# bridge token lives here\n')

    binaries = ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl')
    rc_after_install = rc.read_text()

    def uninstall_run(*extra):
        return subprocess.run(['bash', str(INSTALL_SCRIPT), '--uninstall', *extra],
                              cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=120)

    # --- dry run: reports everything, changes nothing (and needs no network) --
    res = uninstall_run('--dry-run')
    assert res.returncode == 0, f'--uninstall --dry-run failed:\n{res.stderr}'
    out = res.stdout
    for binary in binaries:
        assert f'would remove {install_dir / binary}' in out, f'dry run must list {binary}'
    assert f'would remove service file {service}' in out
    assert f'would remove the heimdall PATH lines from {rc}' in out
    assert 'dry run: nothing was removed' in out
    for binary in binaries:
        assert (install_dir / binary).is_file(), 'dry run must not remove a binary'
    assert service.is_file(), 'dry run must not remove the service file'
    assert rc.read_text() == rc_after_install, 'dry run must not touch the rc file'
    assert stranger.is_file() and backup.is_file() and enrollment.is_file()

    # --- real uninstall ------------------------------------------------------
    # REQ-INST-13: the unit name install.sh stops is the SAME one running this
    # agent, so prove the env cannot reach the live session bus before making
    # the destructive call. This is not ceremony — without it a stray
    # XDG_RUNTIME_DIR here stops the bridge and every agent on the host.
    assert_bridge_isolated(env, ctx['work'])
    res = uninstall_run()
    assert res.returncode == 0, f'--uninstall failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'
    out = res.stdout
    for binary in binaries:
        assert not (install_dir / binary).exists(), f'{binary} not removed'
        assert f'removed {install_dir / binary}' in out
    assert not service.exists(), 'service file not removed'

    # Only the marked lines went; the decoys are intact.
    body = rc.read_text()
    assert '# Added by heimdall install.sh' not in body, 'installer marker not removed'
    assert f'export PATH="{install_dir}:$PATH"' not in body, 'installer PATH line not removed'
    assert 'export PATH="/opt/other/bin:$PATH"' in body, 'an unrelated PATH export must survive'
    assert 'export EDITOR=vi' in body, 'unrelated rc content must survive'

    # Kept state, each reported with the path to remove by hand.
    assert stranger.is_file(), 'a generic-named file this installer did not write must be kept'
    assert f'left {stranger} in place' in out, 'the kept stranger file must be named'
    assert 'no record of writing it' in out, (
        f'the reason must be the missing provenance record — the one case where '
        f'denying authorship is actually true:\n{out}')
    assert backup.is_file(), 'unit backups are recovery artifacts and must be kept'
    assert f'kept service file backup {backup}' in out, 'the kept backup must be named'
    assert f'rm -f {service}.bak-*' in out, 'the backup glob must be given for manual removal'
    assert enrollment.is_file(), 'enrollment state must never be removed'
    assert 'kept enrollment state at' in out and str(home / '.config/heimdall') in out
    assert f'rm -rf {home / ".config/heimdall"}' in out, (
        'the enrollment path must be given for manual removal')
    assert 'uninstall complete' in out


def test_uninstall_guard_detects_live_session(ctx):
    """REQ-INST-13: the guard that stands between this suite and the live
    bridge must itself be proven, or it is ceremony. install.sh's uninstall
    path runs `systemctl --user stop heimdall-bridge` — the same unit name that
    supervises the agents on a developer host — so assert_bridge_isolated()
    has to FIRE on a live-session env, not merely pass on a sandbox one.

    Read-only throughout: the strongest thing done here is
    `systemctl --user is-active`, never a stop."""
    base = ctx['work'] / 'isolation-guard'
    home = base / 'home'
    runtime = base / 'xdg-runtime'
    home.mkdir(parents=True)
    runtime.mkdir(parents=True)

    # 1. The sandbox env the destructive tests actually use must be accepted.
    env = sandbox_install_env(home, runtime)
    assert_bridge_isolated(env, ctx['work'])

    def must_fire(bad_env, what):
        try:
            assert_bridge_isolated(bad_env, ctx['work'])
        except AssertionError:
            return
        raise AssertionError(
            f'assert_bridge_isolated did NOT fire for {what}; the guard is not '
            f'protecting the live bridge and a real --uninstall could stop it')

    # 2. The live session runtime dir — the exact value a leaked env would have.
    live = {**env, 'XDG_RUNTIME_DIR': f'/run/user/{os.getuid()}'}
    must_fire(live, 'XDG_RUNTIME_DIR=/run/user/<uid> (the live session bus)')

    # 3. An empty runtime dir lets systemd fall back to the real session.
    must_fire({**env, 'XDG_RUNTIME_DIR': ''}, 'an empty XDG_RUNTIME_DIR')

    # 4. A runtime dir outside the suite's work dir, even if not /run/user.
    must_fire({**env, 'XDG_RUNTIME_DIR': '/tmp'}, 'a runtime dir outside the test work dir')

    # 5. An inherited bus address is a second route to the live bus.
    must_fire({**env, 'DBUS_SESSION_BUS_ADDRESS': f'unix:path=/run/user/{os.getuid()}/bus'},
              'an inherited DBUS_SESSION_BUS_ADDRESS')

    # 6. And the substantive half: with the sandbox env, systemctl --user must
    # be unable to reach ANY bus. If this ever starts succeeding, the sandbox
    # no longer isolates and the guard's probe arm is what catches it.
    if shutil.which('systemctl') is not None:
        probe = subprocess.run(['systemctl', '--user', 'is-active', 'heimdall-bridge'],
                               env=env, capture_output=True, text=True, timeout=30)
        assert probe.stdout.strip() not in ('active', 'inactive', 'activating', 'failed'), (
            f'the sandbox env REACHED a user bus (stdout={probe.stdout.strip()!r}); '
            f'a real --uninstall under it could stop the running bridge')


def test_install_sh_uninstall_removes_bundled_openssl(ctx):
    """REQ-INST-8, the openssl clause. The release bundle DOES ship bin/openssl
    (flake.nix gives ham-bridge one, and package-local-binary-tarball.sh ships
    it whenever present), so the installer writes a file under a GENERIC name.
    Authorship therefore cannot be inferred from content — stock OpenSSL has no
    'heimdall' bytes — so install.sh records the sha256 of the openssl it wrote
    and --uninstall removes it only against that record.

    Asserts both directions with one install each:
      - ours: openssl + sidecar written, then both removed;
      - tampered: the same install with the openssl overwritten afterwards is
        KEPT, named, and reported as no-longer-matching rather than falsely
        called a file this installer never wrote."""
    need_tool('curl')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh full run: {platform.system()}/{platform.machine()}')

    base = ctx['work'] / 'uninstall-openssl'
    base.mkdir(parents=True)
    res, tarball = package_tarball(base, with_openssl=True, target=target)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    names, _, _ = read_tarball(tarball)
    assert 'bin/openssl' in names, 'this test is meaningless unless the bundle ships an openssl'
    hub = make_hub_mirror(base, tarball, target)

    def fresh_install(tag):
        """A full install into its own sandbox HOME; returns (env, install_dir)."""
        home = base / tag
        runtime = base / f'{tag}-xdg'
        home.mkdir(parents=True)
        runtime.mkdir(parents=True)
        env = sandbox_install_env(home, runtime)
        res = subprocess.run(['bash', str(INSTALL_SCRIPT), '--hub', hub],
                             cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=120)
        assert res.returncode == 0, (
            f'install failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}')
        return env, home / '.local/bin', res.stdout

    def uninstall(env, *extra):
        # REQ-INST-13: never make the destructive call against the live bus.
        # install.sh stops the unit name that runs this very agent, so the
        # sandbox env is asserted first, immediately before the call.
        if '--dry-run' not in extra:
            assert_bridge_isolated(env, ctx['work'])
        return subprocess.run(['bash', str(INSTALL_SCRIPT), '--uninstall', *extra],
                              cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=120)

    # --- ours: installed openssl + provenance sidecar are both removed -------
    env, install_dir, install_out = fresh_install('ours')
    openssl = install_dir / 'openssl'
    sidecar = install_dir / '.heimdall-openssl.sha256'
    assert openssl.is_file(), 'the bundled openssl must be installed'
    assert f'installed bundled {openssl}' in install_out
    assert sidecar.is_file(), (
        'install must record the openssl provenance; without it --uninstall can '
        'never prove the file is ours and will leave it behind forever')
    assert sidecar.read_text().split()[0] == sha256_of(openssl), (
        'the recorded hash must match the installed openssl')
    assert str(sidecar) in install_out, 'the provenance record must be named at install time'

    # Dry run lists both and removes neither.
    res = uninstall(env, '--dry-run')
    assert res.returncode == 0, f'--uninstall --dry-run failed:\n{res.stderr}'
    assert f'would remove {openssl}' in res.stdout, (
        f'the openssl this installer wrote must be listed for removal:\n{res.stdout}')
    assert f'would remove {sidecar}' in res.stdout, 'the provenance record must be removed too'
    assert openssl.is_file() and sidecar.is_file(), 'a dry run must remove nothing'

    # Real uninstall: this is the arm that never ran before.
    res = uninstall(env)
    assert res.returncode == 0, f'--uninstall failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'
    assert not openssl.exists(), (
        f'the openssl this installer wrote must be REMOVED:\n{res.stdout}')
    assert not sidecar.exists(), 'the provenance record must not be left behind as debris'
    assert f'removed {openssl}' in res.stdout
    assert f'left {openssl} in place' not in res.stdout, (
        f'our own openssl must not be reported as left in place:\n{res.stdout}')

    # --- tampered: same install, openssl replaced afterwards -> KEPT ---------
    env, install_dir, _ = fresh_install('tampered')
    openssl = install_dir / 'openssl'
    sidecar = install_dir / '.heimdall-openssl.sha256'
    recorded = sidecar.read_text().split()[0]
    # Something else overwrote it after install: a self-update, or the user's
    # package manager. The recorded hash no longer describes the file.
    openssl.write_text('#!/bin/sh\n# replaced after install\n')
    assert sha256_of(openssl) != recorded

    res = uninstall(env)
    assert res.returncode == 0, f'--uninstall failed:\n{res.stderr}'
    assert openssl.is_file(), (
        f'an openssl that no longer matches the record must be KEPT, not deleted:\n{res.stdout}')
    assert f'left {openssl} in place' in res.stdout, 'the kept file must be named'
    assert 'no longer matches the checksum' in res.stdout, (
        f'the reason must be the failed provenance check, not a false claim that '
        f'this installer never wrote it:\n{res.stdout}')
    assert 'no record of writing it' not in res.stdout, (
        'we DID write an openssl here, so the output must not deny authorship')


def test_install_sh_uninstall_unhashable_openssl_nonfatal(ctx):
    """Unreadable files on the removal path must not abort the uninstall, and
    must not make the output lie about provenance. Two shapes, one install each:
    the openssl itself unhashable, and its provenance record unreadable.

    do_uninstall computes the file's current hash before deciding anything, and
    under `set -euo pipefail` an empty answer was not the same as a successful
    one: a failing sha256sum poisons the pipeline through pipefail, so the bare
    assignment killed the script between the binaries and the service file —
    the REQ-INST-5 failure shape again, on the removal side. Exit 0 alone does
    not prove the fix, so this asserts the uninstall RAN TO COMPLETION past the
    openssl step: service file gone, PATH lines gone, kept-state report
    printed, and the unhashable file itself kept and named."""
    need_tool('curl')
    if os.getuid() == 0:
        raise Skip('running as root: root reads a 0000 file, so it cannot be made unhashable')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for install.sh full run: {platform.system()}/{platform.machine()}')

    base = ctx['work'] / 'uninstall-unhashable'
    base.mkdir(parents=True)
    res, tarball = package_tarball(base, with_openssl=True, target=target)
    assert res.returncode == 0, f'packaging failed:\n{res.stderr}'
    hub = make_hub_mirror(base, tarball, target)

    def fresh_install(tag):
        home = base / tag
        runtime = base / f'{tag}-xdg'
        home.mkdir(parents=True)
        runtime.mkdir(parents=True)
        env = sandbox_install_env(home, runtime)
        res = subprocess.run(['bash', str(INSTALL_SCRIPT), '--hub', hub],
                             cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=120)
        assert res.returncode == 0, (
            f'install failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}')
        install_dir = home / '.local/bin'
        if target.startswith('linux'):
            service = home / '.config/systemd/user/heimdall-bridge.service'
        else:
            service = home / 'Library/LaunchAgents/works.earendil.heimdall-bridge.plist'
        rc = home / '.bashrc'
        assert (install_dir / 'openssl').is_file() and service.is_file()
        assert '# Added by heimdall install.sh' in rc.read_text(), (
            'fixture needs the PATH lines present')
        return env, install_dir, service, rc

    def real_uninstall(env):
        # REQ-INST-13: the unit install.sh stops is the same one running this agent.
        assert_bridge_isolated(env, ctx['work'])
        return subprocess.run(['bash', str(INSTALL_SCRIPT), '--uninstall'],
                              cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=120)

    def assert_completed(out, install_dir, service, rc, res):
        """The decider: the uninstall CONTINUED past the openssl step."""
        assert res.returncode == 0, (
            f'an unreadable file must not fail the uninstall; exit={res.returncode}\n'
            f'stdout:\n{out}\nstderr:\n{res.stderr}')
        for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
            assert not (install_dir / binary).exists(), f'{binary} not removed'
        assert not service.exists(), (
            f'the uninstall aborted at the openssl step — the service file survived, which is '
            f'the REQ-INST-5 bug shape on the removal side:\n{out}')
        assert '# Added by heimdall install.sh' not in rc.read_text(), (
            f'the uninstall aborted before the PATH step:\n{out}')
        assert 'kept enrollment state at' in out, (
            f'the kept-state report must still be printed:\n{out}')
        assert 'uninstall complete' in out, f'the uninstall must report completion:\n{out}'

    # --- shape 1: the openssl itself cannot be hashed ------------------------
    env, install_dir, service, rc = fresh_install('openssl-unreadable')
    openssl = install_dir / 'openssl'

    openssl.chmod(0o000)
    assert run(['sha256sum', str(openssl)]).returncode != 0, (
        'fixture sanity: the openssl must actually be unhashable for this test to mean anything')

    res = real_uninstall(env)
    out = res.stdout
    assert_completed(out, install_dir, service, rc, res)
    # Kept, named, and the reason is the failed hash — not a false claim that
    # this installer never wrote it, since a sidecar for it does exist.
    assert openssl.exists(), 'a file we cannot hash must never be deleted'
    assert f'left {openssl} in place' in out, f'the kept file must be named:\n{out}'
    assert 'could not hash it' in out, f'the reason must be the failed hash:\n{out}'
    assert 'no record of writing it' not in out, (
        f'a sidecar exists here, so the output must not deny authorship:\n{out}')

    # --- shape 2: the PROVENANCE RECORD cannot be read ----------------------
    # An existing-but-unreadable sidecar used to fall into the "no record"
    # branch, denying authorship of a file this installer may well have
    # written. Keep the file either way, but say which state we are in.
    env, install_dir, service, rc = fresh_install('sidecar-unreadable')
    openssl = install_dir / 'openssl'
    sidecar = install_dir / '.heimdall-openssl.sha256'
    assert sidecar.is_file(), 'fixture needs the provenance record present'
    sidecar.chmod(0o000)
    assert run(['cat', str(sidecar)]).returncode != 0, (
        'fixture sanity: the sidecar must actually be unreadable')

    res = real_uninstall(env)
    out = res.stdout
    assert_completed(out, install_dir, service, rc, res)
    assert openssl.exists(), 'an openssl whose record we cannot read must be kept'
    assert f'left {openssl} in place' in out, f'the kept file must be named:\n{out}'
    assert 'no record of writing it' not in out, (
        f'a record DOES exist here — it was merely unreadable — so the output must not '
        f'deny authorship:\n{out}')
    assert str(sidecar) in out, f'the unreadable record must be named:\n{out}'
    assert 'could not be read' in out, (
        f'the reason must be that the record exists but was unreadable:\n{out}')


def test_install_sh_sudo_uninstall_dry_run(ctx):
    """The sudo shape of --uninstall: paths must resolve under the TARGET
    user's home (not root's), and the service-stop command must be PRINTED for
    that user rather than run as root. Dry run only — nothing is removed."""
    need_userns_mount()
    base = ctx['work'] / 'sudo-uninstall'
    base.mkdir(parents=True)
    hub, fake_home, entry = sudo_ns_fixture(base)

    res = sudo_ns_install(base, hub, entry, path_prefix='/nonexistent-stub')
    assert res.returncode == 0, f'uid-0 install failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}'
    service = fake_home / '.config/systemd/user/heimdall-bridge.service'
    assert service.is_file(), 'service file not written into the SUDO_USER home'

    # The binaries must be planted inside the namespace: the tmpfs over /usr is
    # private to each unshare invocation, so the install above is not visible
    # here. The real removal is covered by test_install_sh_uninstall; what this
    # run proves is that the SUDO shape resolves the right paths.
    plant = ' && '.join(f'printf "#!/bin/sh\n" > /usr/local/bin/{b} '
                        for b in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'))
    res = sudo_ns_install(base, hub, entry, '/nonexistent-stub', '--uninstall', '--dry-run',
                          pre=plant)
    assert res.returncode == 0, (
        f'sudo --uninstall --dry-run failed:\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}')
    out = res.stdout
    # The stop command is printed for the target user, never run as root.
    assert f'service runs as {entry.pw_name}' in out, (
        f'the stop command must be printed for the target user:\n{out}')
    assert 'systemctl --user stop heimdall-bridge' in out
    # Paths come from the TARGET user's home, not /root.
    assert f'would remove service file {entry.pw_dir}/.config/systemd/user/heimdall-bridge.service' in out, (
        f'the service path must resolve under the SUDO_USER home:\n{out}')
    for binary in ('heimdall', 'ham-bridge', 'ham-pty-host', 'ham-ctl'):
        assert f'would remove /usr/local/bin/{binary}' in out, (
            f'a sudo install lives in /usr/local/bin, so {binary} must be listed there:\n{out}')
    assert f'kept enrollment state at {entry.pw_dir}/.config/heimdall' in out
    assert 'dry run: nothing was removed' in out
    # Nothing was actually removed (the namespace mounts are gone, but the
    # bind-mounted sandbox home is a real directory we can still inspect).
    assert service.is_file(), 'a dry run must not remove the service file'


# ---- 4. heimdall CLI schemas --------------------------------------------------

def version_constants():
    proto = (ROOT / 'src' / 'contracts' / 'protocol.odin').read_text(encoding='utf-8')
    app_version = re.search(r'APP_VERSION :: "([^"]*)"', proto)
    protocol_version = re.search(r'PROTOCOL_VERSION :: (\d+)', proto)
    assert app_version and protocol_version, 'could not parse src/contracts/protocol.odin'
    return app_version.group(1), protocol_version.group(1)


def build_heimdall(ctx):
    override = os.environ.get('HEIMDALL_BIN')
    if override:
        binary = Path(override)
        assert binary.is_file(), f'HEIMDALL_BIN={override} does not exist'
    else:
        out = ctx['work'] / 'heimdall'
        res = run(['nix', 'develop', '--command', 'bash', '-c',
                   f'odin build src/manager -collection:odin_test=src -out:{out}'],
                  cwd=ROOT, timeout=600)
        assert res.returncode == 0, f'odin build failed:\n{res.stderr}'
        assert out.is_file(), f'build produced no binary at {out}'
        binary = out
    ctx['heimdall_bin'] = binary


def test_heimdall_version_schema(ctx):
    if 'heimdall_bin' not in ctx:
        raise Skip('heimdall binary was not built')
    binary = ctx['heimdall_bin']
    app_version, protocol_version = version_constants()
    res = run([binary, '--version'], timeout=30)
    assert res.returncode == 0, f'heimdall --version exited {res.returncode}:\n{res.stderr}'
    expected = f'heimdall {app_version} protocol {protocol_version}'
    assert res.stdout == expected + '\n', f'version line mismatch: {res.stdout!r} != {expected!r}'


def test_heimdall_status_schema(ctx):
    if 'heimdall_bin' not in ctx:
        raise Skip('heimdall binary was not built')
    binary = ctx['heimdall_bin']
    app_version, protocol_version = version_constants()
    config = ctx['work'] / 'missing-home' / 'config.toml'
    res = run([binary, 'status', '--config', str(config)], timeout=60)
    # status is a report, not a gate: it always exits 0.
    assert res.returncode == 0, f'heimdall status exited {res.returncode}:\n{res.stderr}'
    out = res.stdout
    assert out.splitlines()[0] == f'heimdall {app_version} protocol {protocol_version}'
    for section in ('Enrollment', 'Bridge service', 'Hub connection',
                    'Bridge loopback (:49323)', 'Binaries'):
        assert section in out, f'status report missing section {section!r}'
    assert f'config:       {config} (missing)' in out, 'missing config must be reported'
    assert 'hub url:      (not set — run: heimdall enroll hbe_... --hub <url>)' in out
    assert '(this binary)' in out and 'heimdall' in out


def test_heimdall_vault_lifecycle(ctx):
    if 'heimdall_bin' not in ctx:
        raise Skip('heimdall binary was not built')
    binary = ctx['heimdall_bin']
    config = ctx['work'] / 'vault-home' / 'config.toml'
    vault_key_file = config.parent / 'vault_key'
    vault_key = '0123456789abcdef' * 4

    res = run([binary, 'vault', '--help'], timeout=30)
    assert res.returncode == 0, f'heimdall vault --help exited {res.returncode}:\n{res.stderr}'
    for command in ('status', 'set-key', 'show', 'clear'):
        assert f'  {command}' in res.stdout, f'vault help missing {command!r} subcommand'

    res = run([binary, 'vault', 'status', '--config', str(config)], timeout=30)
    assert res.returncode == 0, f'heimdall vault status exited {res.returncode}:\n{res.stderr}'
    for field in ('heimdall vault status', f'key file:    {vault_key_file}',
                  'configured:  no', 'permissions: n/a (file missing)', 'key length:  0'):
        assert field in res.stdout, f'vault status missing {field!r}'

    res = run([binary, 'vault', 'set-key', vault_key, '--config', str(config)], timeout=30)
    assert res.returncode == 0, f'heimdall vault set-key exited {res.returncode}:\n{res.stderr}'
    assert vault_key_file.read_text(encoding='utf-8') == vault_key + '\n'
    assert vault_key_file.stat().st_mode & 0o777 == 0o600, 'vault key file must use mode 0600'

    res = run([binary, 'vault', 'show', '--config', str(config)], timeout=30)
    assert res.returncode == 0, f'heimdall vault show exited {res.returncode}:\n{res.stderr}'
    assert f'key:         {vault_key[:4]}...{vault_key[-4:]}' in res.stdout
    assert vault_key not in res.stdout, 'vault show must mask the full key by default'

    res = run([binary, 'vault', 'show', '--reveal', '--config', str(config)], timeout=30)
    assert res.returncode == 0, f'heimdall vault show --reveal exited {res.returncode}:\n{res.stderr}'
    assert f'key:         {vault_key}' in res.stdout

    res = run([binary, 'vault', 'clear', '--config', str(config)], timeout=30)
    assert res.returncode == 0, f'heimdall vault clear exited {res.returncode}:\n{res.stderr}'
    assert not vault_key_file.exists(), 'vault clear must remove the vault key file'


# ---- 4b. release portability gate (REQ-INST-16) -------------------------------
#
# The release tarballs target stock Linux/macOS hosts with no /nix/store. The
# bug this gate exists for: v0.3.2 shipped bin/ham-bridge as the 652-byte nix
# wrapProgram shell script (shebang AND exec target under /nix/store) and the
# other binaries as dynamically linked ELFs whose interpreter/RUNPATH point
# under /nix/store, so the whole bundle failed on any non-Nix machine.
#
# The gate builds the release-* flake attrs (static glibc for the Odin
# binaries, musl +crt-static for the Rust pty host -- see flake.nix), packages
# a tarball through the REAL packaging script, then:
#   1. scans every shipped binary for /nix/store references (ELF interpreter,
#      dynamic section, Mach-O dylibs/rpaths, script text), and
#   2. EXECUTES every Linux binary in a rootfs without /nix/store (docker
#      scratch if a daemon is up, else a user-namespace chroot; hard failure
#      if neither exists -- this check may never silently skip), and
#   3. proves the execution half has teeth with a negative control that MUST
#      fail to run storeless.

RELEASE_BINARIES = ('ham-bridge', 'ham-ctl', 'heimdall', 'ham-pty-host')
# Release attr per binary; the pty-host out dir name carries the musl target
# triple, so out dirs are matched to binaries by name prefix, not position.
RELEASE_ATTRS = {name: f'release-{name}' for name in RELEASE_BINARIES}


def build_release_attrs(ctx):
    if shutil.which('nix') is None:
        raise Skip('nix not available')
    res = run(['nix', 'build', *[f'.#{a}' for a in RELEASE_ATTRS.values()],
               '--print-out-paths', '--no-link'], cwd=ROOT, timeout=1200)
    assert res.returncode == 0, f'nix build of release-* attrs failed:\n{res.stderr}'
    outs = [l for l in res.stdout.splitlines() if l.startswith('/nix/store/')]
    assert len(outs) == len(RELEASE_BINARIES), (
        f'expected {len(RELEASE_BINARIES)} nix out paths, got: {outs!r}')
    release_outs = {}
    for out in outs:
        # Store dir names are <32-char hash>-<pname>-<version>; drop the hash.
        base = Path(out).name.split('-', 1)[1]
        for name in RELEASE_BINARIES:
            if base.startswith(name) or base.startswith(f'release-{name}'):
                release_outs[name] = Path(out)
                break
    missing = set(RELEASE_BINARIES) - set(release_outs)
    assert not missing, f'could not map nix outs to binaries, missing: {sorted(missing)}'
    for name, out in release_outs.items():
        binary = out / 'bin' / name
        assert binary.is_file(), f'{RELEASE_ATTRS[name]} produced no binary at {binary}'
    ctx['release_outs'] = release_outs


def scan_binary_for_nix_references(binary: Path, name: str):
    """Static half of the gate: no shipped binary may reference /nix/store."""
    head = binary.read_bytes()[:4]
    assert head != b'#!', (
        f'{name} is a shell script, not a binary -- the v0.3.2 nix wrapper '
        'regression is back')
    if platform.system() == 'Linux':
        assert head == b'\x7fELF', f'{name} is not an ELF binary'
        res = run(['readelf', '-l', str(binary)])
        assert res.returncode == 0, f'readelf -l failed on {name}:\n{res.stderr}'
        assert 'Requesting program interpreter' not in res.stdout, (
            f'{name} has a program interpreter; release Linux binaries must be '
            f'fully static:\n{res.stdout}')
        res = run(['readelf', '-d', str(binary)])
        assert res.returncode == 0, f'readelf -d failed on {name}:\n{res.stderr}'
        assert '/nix/store' not in res.stdout, (
            f'{name} references /nix/store in its dynamic section:\n{res.stdout}')
    else:
        res = run(['llvm-objdump', '--macho', '--dylibs-used', str(binary)])
        out = res.stdout + res.stderr
        assert res.returncode == 0, f'llvm-objdump failed on {name}:\n{out}'
        assert '/nix/store' not in out, f'{name} links a nix-store dylib:\n{out}'
        res = run(['llvm-objdump', '--macho', '--rpaths', str(binary)])
        assert res.returncode == 0, f'llvm-objdump --rpaths failed on {name}:\n{res.stderr}'
        assert '/nix/store' not in res.stdout, (
            f'{name} has an rpath under /nix/store:\n{res.stdout}')


def test_release_binaries_have_no_nix_references(ctx):
    if 'release_outs' not in ctx:
        raise Skip('release attrs were not built')
    for name, out in ctx['release_outs'].items():
        scan_binary_for_nix_references(out / 'bin' / name, name)


def _docker_usable():
    if shutil.which('docker') is None:
        return False
    return run(['docker', 'info'], timeout=30).returncode == 0


def _unshare_chroot_usable():
    if shutil.which('unshare') is None:
        return False
    return run(['unshare', '-rm', 'true'], timeout=30).returncode == 0


def storeless_exec(binary: Path, args, work: Path, timeout=60):
    """Execute a binary in an environment with no /nix/store. On Linux this is
    a docker scratch container when a daemon is up, else a user-namespace
    chroot into an empty rootfs; both prove the binary needs nothing from the
    store, not even a dynamic loader. On Darwin the host itself is the clean
    environment (the load-command scan is what proves store independence)."""
    if platform.system() == 'Darwin':
        return run([str(binary), *args], timeout=timeout)
    root = work / f'rootfs-{binary.name}'
    root.mkdir(parents=True, exist_ok=True)
    shutil.copy(binary, root / binary.name)
    if _docker_usable():
        return run(['docker', 'run', '--rm', '-v', f'{root}:/verify:ro',
                    'scratch', f'/verify/{binary.name}', *args], timeout=timeout)
    if _unshare_chroot_usable():
        return run(['unshare', '-rm', 'chroot', str(root), f'/{binary.name}', *args],
                   timeout=timeout)
    raise AssertionError(
        'neither a working docker daemon nor `unshare -rm` is available; '
        'refusing to skip the storeless-execution half of the REQ-INST-16 gate')


def test_release_tarball_is_portable(ctx):
    """Package the freshly built release outs through the REAL packaging
    script, then scan and storeless-execute every binary in the tarball. This
    is the check that would have caught the v0.3.2 wrapper shipment."""
    if 'release_outs' not in ctx:
        raise Skip('release attrs were not built')
    target = host_target()
    if target is None:
        raise Skip(f'unsupported host for portability gate: {platform.system()}/{platform.machine()}')
    out_dir = ctx['work'] / 'release-dist'
    outs = ctx['release_outs']
    res = run(['bash', PACKAGE_SCRIPT, target, 'v0.1.0', out_dir,
               outs['ham-bridge'], outs['ham-ctl'], outs['heimdall'],
               outs['ham-pty-host']], cwd=ROOT, timeout=120)
    assert res.returncode == 0, f'packaging release tarball failed:\n{res.stderr}'
    tarball = out_dir / f'heimdall-local-{target}.tar.gz'
    assert tarball.is_file(), f'no tarball at {tarball}'

    extract = ctx['work'] / 'release-extract'
    extract.mkdir(exist_ok=True)
    res = run(['tar', '-xzf', str(tarball), '-C', str(extract)], timeout=60)
    assert res.returncode == 0, f'tar extract failed:\n{res.stderr}'
    names = sorted(p.name for p in (extract / 'bin').iterdir())
    assert sorted(RELEASE_BINARIES) == names, (
        f'tarball bin/ mismatch: {names!r} != {sorted(RELEASE_BINARIES)!r}')

    for name in RELEASE_BINARIES:
        scan_binary_for_nix_references(extract / 'bin' / name, name)
    # The bundled-openssl era is over: nothing nix-linked may ship.
    assert 'openssl' not in names, (
        'bundled openssl is back in the tarball; it links nix glibc and cannot '
        'run on stock hosts (REQ-INST-16 removed it on purpose)')

    app_version, protocol_version = version_constants()
    expected = {
        'ham-bridge': f'ham-bridge {app_version} protocol {protocol_version} bridge 1 ws 1',
        'ham-ctl': f'ham-ctl {app_version} protocol {protocol_version}',
        'heimdall': f'heimdall {app_version} protocol {protocol_version}',
    }
    exec_work = ctx['work'] / 'storeless'
    exec_work.mkdir(exist_ok=True)
    for name, line in expected.items():
        res = storeless_exec(extract / 'bin' / name, ['--version'], exec_work)
        assert res.returncode == 0, (
            f'{name} --version failed storeless (rc={res.returncode}):\n{res.stderr}')
        assert res.stdout.splitlines()[0] == line, (
            f'{name} version line mismatch storeless: {res.stdout.splitlines()[:1]!r}')
    # ham-pty-host is clap-based: no --version, but --help must load and run.
    res = storeless_exec(extract / 'bin' / 'ham-pty-host', ['--help'], exec_work)
    assert res.returncode == 0, (
        f'ham-pty-host --help failed storeless (rc={res.returncode}):\n{res.stderr}')
    assert res.stdout.strip(), 'ham-pty-host --help printed nothing storeless'


def test_storeless_exec_has_teeth(ctx):
    """Negative control for the execution half. A dynamically linked binary
    MUST fail to execute in the empty rootfs; if it runs, the gate is
    decorative and would pass the exact bug it exists to catch."""
    if platform.system() != 'Linux':
        raise Skip('teeth check is Linux-specific')
    control = Path('/bin/sh')
    if not control.is_file():
        raise Skip('no /bin/sh control binary')
    # Whichever /bin/sh this is (NixOS store bash or a distro dash), it is
    # dynamically linked and its loader is absent from our empty rootfs.
    root = ctx['work'] / 'teeth-rootfs'
    root.mkdir(exist_ok=True)
    shutil.copy(control, root / 'sh')
    if _docker_usable():
        res = run(['docker', 'run', '--rm', '-v', f'{root}:/verify:ro',
                   'scratch', '/verify/sh', '-c', 'true'], timeout=60)
    elif _unshare_chroot_usable():
        res = run(['unshare', '-rm', 'chroot', str(root), '/sh', '-c', 'true'],
                  timeout=60)
    else:
        raise AssertionError(
            'neither docker nor unshare -rm available; refusing to skip the '
            'REQ-INST-16 gate')
    assert res.returncode != 0, (
        'control binary /bin/sh ran inside the empty rootfs; the storeless '
        'exec gate has no teeth and would not catch a nix-linked release')


# ---- 5. documentation regression ----------------------------------------------

def part2_text():
    text = (ROOT / 'SELF_HOSTING.md').read_text(encoding='utf-8')
    start = text.index('## Part 2')
    end = text.index('## Quick-start checklist')
    return text[start:end], text[:start]


def test_self_hosting_documents_installer(ctx):
    part2, part1 = part2_text()
    one_liner = (f'curl -fsSL https://raw.githubusercontent.com/{GITHUB_REPO}/main/'
                 f'scripts/install.sh | bash')
    assert one_liner in part2, 'Part 2 must show the curl|bash one-liner installer'
    assert 'Quick install' in part2 and 'recommended' in part2.lower(), (
        'Part 2 must present the installer as the recommended path')
    for command in ('heimdall enroll', 'heimdall status', 'heimdall update'):
        assert command in part2, f'Part 2 must document {command}'
    assert part2.count('heimdall vault set-key <64-hex>') >= 2, (
        'Part 2 must document vault setup in quick-install and bridge setup flows')
    # Manual/source paths retained as advanced alternatives.
    for marker in ('nix build .#ham-bridge', 'ham-bridge enroll',
                   'Systemd user service', 'launchd agent', 'Home Manager module'):
        assert marker in part2, f'manual path {marker!r} must remain documented'
    # Cross-reference renumbering after the new quick-install section.
    assert 'sections 2.8–2.9' in part2
    # Part 1 (hub) untouched.
    for heading in ('### 1.5 Systemd service (Linux hub)',
                    '### 1.6 NixOS module (hub + nginx)',
                    '### 1.7 Single-user / VPN setup with dev-proxy'):
        assert heading in part1, f'Part 1 heading {heading!r} must be unchanged'


def test_readme_points_at_installer(ctx):
    readme = (ROOT / 'README.md').read_text(encoding='utf-8')
    assert 'install.sh | bash' in readme, 'README Getting started must point at the installer'
    assert 'SELF_HOSTING.md' in readme


# ---- runner --------------------------------------------------------------------

# --- REQ-INST-14: socat is a hard runtime dep, checked at preflight ------------
# socat is the DEFAULT bridge->hub TLS transport (src/lib/ws/ws.odin:286-297
# returns socat_openssl_command for every HAM_TLS_BACKEND except the legacy
# "s_client") and it is NOT bundled in the release tarball. Before this check a
# socat-less host installed cleanly, was told it succeeded, and then never
# reached a TLS hub. These tests pin the four behaviours: fatal by default,
# exempt for --uninstall, exempt for --dry-run, exempt for an explicitly
# plain-HTTP hub.

SOCAT_FATAL_FRAGMENTS = (
    'socat is not installed',
    'sudo apt install socat',
    'brew install socat',
    'default bridge->hub TLS transport',
    'Nothing has been installed',
)


def socat_free_shim(base: Path, name: str) -> Path:
    """A hermetic PATH with every tool install.sh needs EXCEPT socat.

    Absence is simulated by PATH construction, never by touching what is
    installed on this host -- socat is what the live bridge uses to reach the
    hub, so a test that uninstalled it would break the machine it runs on.
    """
    return _shim_dir(base, name, with_socat=False)


def assert_nothing_installed(home: Path) -> None:
    """No binary, no service file, no PATH edit -- the preflight must fire
    before anything is written, not halfway through."""
    install_dir = home / '.local' / 'bin'
    if install_dir.exists():
        stray = sorted(q.name for q in install_dir.iterdir())
        assert not stray, f'preflight failed yet {install_dir} contains {stray}'
    unit = home / '.config' / 'systemd' / 'user' / 'heimdall-bridge.service'
    plist = home / 'Library' / 'LaunchAgents' / 'works.earendil.heimdall-bridge.plist'
    assert not unit.exists(), f'a failed preflight still wrote {unit}'
    assert not plist.exists(), f'a failed preflight still wrote {plist}'
    for rc in ('.bashrc', '.zshrc', '.profile'):
        target = home / rc
        if target.exists():
            assert 'Added by heimdall install.sh' not in target.read_text(), \
                f'a failed preflight still edited {target}'


def test_socat_missing_is_fatal_and_installs_nothing(ctx):
    """REQ-INST-14. The hub is UNKNOWN here (no --hub), which is the common case
    since REQ-INST-1 made the unit read config.toml instead of baking a URL in.
    Unknown must be treated as needing socat: at install time we cannot know the
    eventual hub and it is overwhelmingly a remote TLS one."""
    base = ctx['work'] / 'socat-fatal'
    base.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat')

    res = run_installer(shim, base, 'nosocat', )
    assert res.returncode != 0, (
        f'a missing socat must FAIL the install, got exit 0:\n{res.stdout}')
    out = res.stdout + res.stderr
    for fragment in SOCAT_FATAL_FRAGMENTS:
        assert fragment in out, f'the failure does not say {fragment!r}:\n{out}'

    # It must fire BEFORE the release lookup and before any download -- that is
    # the difference between "nothing happened" and "half a machine". This shim
    # has no curl and no wget, so if the preflight ran late the run would have
    # died with the no-downloader diagnosis instead. Asserting that message is
    # ABSENT is what pins the ordering.
    for other in ALL_RESOLVE_MSGS:
        assert other not in out, (
            f'the socat preflight ran AFTER release resolution -- got {other!r}:\n{out}')
    assert 'downloading' not in out, f'a download was attempted anyway:\n{out}'
    assert_nothing_installed(base / 'home-nosocat')


def test_socat_missing_is_fatal_for_a_tls_hub(ctx):
    """An explicit https:// hub is the unambiguous TLS case: socat is exactly
    what terminates that connection, so this must fail like the unknown one."""
    base = ctx['work'] / 'socat-fatal-tls'
    base.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat-tls')

    res = run_installer(shim, base, 'nosocat-tls', '--hub', 'https://hub.example.com')
    assert res.returncode != 0, (
        f'a missing socat must FAIL against an https:// hub:\n{res.stdout}')
    out = res.stdout + res.stderr
    for fragment in SOCAT_FATAL_FRAGMENTS:
        assert fragment in out, f'the failure does not say {fragment!r}:\n{out}'
    assert 'downloading' not in out, f'a download was attempted anyway:\n{out}'
    assert_nothing_installed(base / 'home-nosocat-tls')


def test_socat_failure_names_the_escape_hatch_but_does_not_take_it(ctx):
    """The message must offer HAM_TLS_BACKEND=s_client as an ADVANCED option --
    a user who knowingly accepts the 16 KB multi-read teardown is not stuck --
    while install.sh itself must never fall back to it automatically. An
    automatic fallback would trade a loud failure for a silent degradation of
    large FS reads and artifact transfers, which is the worse bug."""
    base = ctx['work'] / 'socat-escape'
    base.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat-escape')
    res = run_installer(shim, base, 'nosocat-escape', '--hub', 'https://hub.example.com')
    out = res.stdout + res.stderr
    assert 'HAM_TLS_BACKEND=s_client' in out, \
        f'the failure does not name the manual escape hatch:\n{out}'
    assert 'no automatic fallback' in out, \
        f'the failure does not say the fallback is NOT automatic:\n{out}'

    code = install_sh_code()
    assert 'HAM_TLS_BACKEND=s_client' not in code.replace(
        'HAM_TLS_BACKEND=s_client switches', ''), (
        'install.sh sets HAM_TLS_BACKEND itself somewhere -- the escape hatch is '
        'the operator\'s to take, never the installer\'s')

    # Structural: the preflight must guard on socat's ABSENCE, never silently
    # accept an openssl standing in for it.
    assert 'have_socat()' in code and 'command -v socat' in code


def test_socat_missing_dry_run_previews_instead_of_failing(ctx):
    """REQ-INST-14 exemption: --dry-run writes nothing and exists to PREVIEW, so
    it must still print the plan and exit 0. But the preview has to tell the
    TRUTH about what a real run would do, and what a real run would do is stop --
    so the missing socat is reported at the HEAD of the plan, on stdout, where
    the operator is actually reading, not only beside it on stderr."""
    base = ctx['work'] / 'socat-dry'
    base.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat-dry')

    res = run_installer(shim, base, 'nosocat-dry', '--dry-run', '--version', 'v0.1.0')
    assert res.returncode == 0, (
        f'--dry-run must stay non-fatal when socat is missing:\n'
        f'stdout:\n{res.stdout}\nstderr:\n{res.stderr}')
    assert 'socat is NOT installed' in res.stdout, (
        'the socat problem must appear IN the plan on stdout, not only on '
        f'stderr:\n{res.stdout}')
    assert 'would STOP HERE and install nothing' in res.stdout, (
        f'the preview must say what a real run would do:\n{res.stdout}')
    # The rest of the plan still prints: a preview that stops at the first
    # problem is not a preview.
    assert 'platform:' in res.stdout and 'would install' in res.stdout, (
        f'the plan was truncated by the socat notice:\n{res.stdout}')
    assert 'would download' in res.stdout
    # And the remedy is still spelled out, on stderr with the rest of the detail.
    assert 'sudo apt install socat' in res.stderr, \
        f'the dry run does not say how to fix it:\n{res.stderr}'
    assert_nothing_installed(base / 'home-nosocat-dry')


def test_socat_missing_uninstall_still_works(ctx):
    """REQ-INST-14 exemption: removing files needs no transport, and refusing to
    uninstall over a missing dependency would strand exactly the users who most
    need to get the thing off their machine."""
    base = ctx['work'] / 'socat-uninstall'
    home = base / 'home-nosocat-un'
    runtime = base / 'run-nosocat-un'
    home.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat-un')
    env = stub_env(home, runtime, shim)

    # REQ-INST-13: this is a REAL --uninstall, and install.sh's uninstall path
    # stops `heimdall-bridge` -- the same user unit that supervises the agents on
    # this host. Prove the env cannot reach the live session bus first.
    assert_bridge_isolated(env, ctx['work'])
    res = subprocess.run(['bash', str(INSTALL_SCRIPT), '--uninstall'],
                         env=env, capture_output=True, text=True, timeout=90)
    assert res.returncode == 0, (
        f'--uninstall must not require socat:\nstdout:\n{res.stdout}\n'
        f'stderr:\n{res.stderr}')
    out = res.stdout + res.stderr
    assert 'uninstall complete' in out, f'--uninstall did not complete:\n{out}'
    # Match the MESSAGE, not the bare word: this test's own sandbox paths
    # contain "socat", so `'socat' not in out` passes only by accident of
    # naming and fails as soon as a path is printed -- which it is.
    for fragment in SOCAT_FATAL_FRAGMENTS:
        assert fragment not in out, (
            f'--uninstall raised the socat requirement ({fragment!r}):\n{out}')
    assert 'socat is NOT installed' not in out, (
        f'--uninstall previewed the socat problem:\n{out}')


def test_socat_missing_plain_http_hub_proceeds(ctx):
    """REQ-INST-14 exemption: parse_ws_url (src/lib/ws/ws.odin:347) sets
    secure=true only for wss://, so the plain-HTTP VPN-only deployment
    documented in SELF_HOSTING.md terminates no TLS and genuinely needs no
    socat. An explicitly plain http:// --hub must therefore inform, not fail.

    Proven by ORDERING rather than by a full install: the run is pointed at a
    closed port, so reaching a download failure is proof it got PAST the
    preflight -- which is the whole claim. A socat error would have come first
    and no download would have been attempted at all."""
    base = ctx['work'] / 'socat-plain-http'
    base.mkdir(parents=True, exist_ok=True)
    shim = socat_free_shim(base, 'shim-nosocat-http')
    # curl is what turns the closed port into a download failure rather than a
    # missing-downloader one; without it this test cannot make its point.
    need_tool('curl')
    if not (shim / 'curl').exists():
        (shim / 'curl').symlink_to(shutil.which('curl'))

    res = run_installer(shim, base, 'nosocat-http', '--hub', 'http://127.0.0.1:9/mirror')
    out = res.stdout + res.stderr
    assert 'socat is not installed; continuing because' in out, (
        f'a plain-HTTP hub must INFORM about the missing socat, not stay silent:\n{out}')
    assert 'is plain HTTP' in out
    assert 'downloading http://127.0.0.1:9/mirror' in out, (
        'the run did not get past the preflight to the download it was pointed '
        f'at:\n{out}')
    assert 'Nothing has been installed' not in out, (
        f'the fatal socat message fired for an exempt plain-HTTP hub:\n{out}')
    # It still fails -- on the unreachable mirror, which is the point: the
    # failure that remains is the download one, not the socat one.
    assert res.returncode != 0
    assert 'download failed' in out, f'expected the download to be what failed:\n{out}'


def test_socat_present_keeps_the_installer_silent(ctx):
    """The control: with socat on PATH the preflight says nothing at all. A
    check that narrates on the happy path is noise, and it would also mean the
    dry-run and exemption assertions above could pass for the wrong reason."""
    base = ctx['work'] / 'socat-present'
    base.mkdir(parents=True, exist_ok=True)
    shim = _shim_dir(base, 'shim-socat')  # with_socat=True by default
    res = run_installer(shim, base, 'socat-ok', '--dry-run', '--version', 'v0.1.0')
    assert res.returncode == 0, f'dry run failed with socat present:\n{res.stderr}'
    out = res.stdout + res.stderr
    # Again the message, not the word: the sandbox path contains "socat".
    for fragment in SOCAT_FATAL_FRAGMENTS:
        assert fragment not in out, (
            f'the preflight spoke up although socat is present ({fragment!r}):\n{out}')
    assert 'socat is NOT installed' not in out, (
        f'the dry run reported socat missing although it is present:\n{out}')
    assert 'continuing because' not in out, (
        f'the plain-HTTP exemption fired although socat is present:\n{out}')
    assert 'platform:' in res.stdout and 'would install' in res.stdout


def main() -> int:
    tests = [
        ('tarball structure + METADATA.json schema', test_tarball_structure_and_metadata),
        ('tarball without pty-host (6-arg variant)', test_tarball_without_pty_host),
        ('packaging error cases', test_packaging_error_cases),
        ('SHA256SUMS validation + tamper fail-closed', test_sha256sums_validation),
        ('install.sh syntax (bash -n)', test_install_sh_syntax),
        ('install.sh --help', test_install_sh_help),
        ('install.sh --dry-run --version v0.1.0', test_install_sh_dry_run_version),
        ('install.sh --dry-run --hub <url>', test_install_sh_dry_run_hub),
        ('install.sh --dry-run (bare, offline-tolerant)', test_install_sh_dry_run_bare),
        ('install.sh resolve diagnoses stay distinct (REQ-INST-6)', test_resolve_messages_are_distinct),
        ('resolve: no downloader names the missing tool (REQ-INST-6a)', test_resolve_no_downloader),
        ('resolve: wget-only host resolves a tag (REQ-INST-6b)', test_resolve_wget_only_host),
        ('resolve: 403 + X-RateLimit-Remaining 0 names the rate limit (REQ-INST-6c)',
         test_resolve_rate_limited_confirmed),
        ('resolve: 403 without the header does NOT claim the rate limit (REQ-INST-6c)',
         test_resolve_403_without_ratelimit_header_does_not_claim_the_limit),
        ('resolve: 403 discrimination holds on a wget-only host (REQ-INST-6c)',
         test_resolve_403_discrimination_also_works_on_a_wget_only_host),
        ('resolve: prerelease fallback picks newest and says so (REQ-INST-6d)', test_resolve_prerelease_fallback),
        ('resolve: draft-only repo names the true cause (REQ-INST-6e, live case)', test_resolve_draft_only_repo),
        ('resolve: large list does not abort (pipefail/SIGPIPE contract)', test_resolve_large_release_list_does_not_abort),
        ('resolve: no HTTP response is the only network claim (REQ-INST-6)', test_resolve_unreachable),
        ('resolve: unparseable 200 stays fail-closed (REQ-INST-6)', test_resolve_200_without_tag_is_fail_closed),
        ('download: curl and wget branches equally bounded (REQ-INST-7)', test_download_branches_are_equally_bounded),
        ('download: stall floor does not punish small files (REQ-INST-7)',
         test_download_floor_does_not_punish_small_files),
        ('download: curl bounds enforced vs a real dribbling server (REQ-INST-7)',
         test_download_bounds_curl),
        ('download: wget bounds enforced vs a real dribbling server (REQ-INST-7)',
         test_download_bounds_wget),
        ('download: failure names url + TMPDIR hint (REQ-INST-7)', test_download_failure_names_url_and_tmpdir),
        ('--hub / --version never call the GitHub API (REQ-INST-6)', test_hub_and_version_paths_never_call_the_api),
        ('socat missing is fatal, unknown hub (REQ-INST-14)',
         test_socat_missing_is_fatal_and_installs_nothing),
        ('socat missing is fatal for an https:// hub (REQ-INST-14)',
         test_socat_missing_is_fatal_for_a_tls_hub),
        ('socat failure names s_client but never takes it (REQ-INST-14)',
         test_socat_failure_names_the_escape_hatch_but_does_not_take_it),
        ('socat missing: --dry-run previews, not fails (REQ-INST-14)',
         test_socat_missing_dry_run_previews_instead_of_failing),
        ('socat missing: --uninstall still works (REQ-INST-14)',
         test_socat_missing_uninstall_still_works),
        ('socat missing: plain-http --hub proceeds (REQ-INST-14)',
         test_socat_missing_plain_http_hub_proceeds),
        ('socat present: preflight stays silent (REQ-INST-14)',
         test_socat_present_keeps_the_installer_silent),
        ('install.sh full run: service lifecycle (backup/identical/force)', test_install_sh_full_run_service_lifecycle),
        ('install.sh sudo paths (SUDO_USER resolve + root refusal)', test_install_sh_sudo_paths),
        ('install.sh sudo real run: PATH write for target user', test_install_sh_sudo_path_write),
        ('install.sh sudo real run: chown failure warns', test_install_sh_sudo_chown_failure_warns),
        ('install.sh read-only rc is NOT fatal (REQ-INST-5)', test_install_sh_readonly_rc_nonfatal),
        ('uninstall isolation guard fires on a live session (REQ-INST-13)',
         test_uninstall_guard_detects_live_session),
        ('install.sh --uninstall (dry run + real, keeps user state)', test_install_sh_uninstall),
        ('install.sh --uninstall removes the bundled openssl it recorded',
         test_install_sh_uninstall_removes_bundled_openssl),
        ('install.sh --uninstall survives unreadable openssl/record',
         test_install_sh_uninstall_unhashable_openssl_nonfatal),
        ('install.sh sudo --uninstall --dry-run', test_install_sh_sudo_uninstall_dry_run),
        ('build heimdall (nix develop / odin)', build_heimdall),
        ('heimdall --version schema', test_heimdall_version_schema),
        ('heimdall status schema', test_heimdall_status_schema),
        ('heimdall vault lifecycle', test_heimdall_vault_lifecycle),
        ('build release attrs (nix, REQ-INST-16)', build_release_attrs),
        ('release binaries: no /nix/store references (REQ-INST-16)',
         test_release_binaries_have_no_nix_references),
        ('release tarball: package + storeless execution (REQ-INST-16)',
         test_release_tarball_is_portable),
        ('storeless execution gate has teeth (REQ-INST-16)', test_storeless_exec_has_teeth),
        ('SELF_HOSTING.md Part 2 installer docs', test_self_hosting_documents_installer),
        ('README installer pointer', test_readme_points_at_installer),
    ]

    ctx = {}
    work = Path(tempfile.mkdtemp(prefix='heimdall-dist-test-'))
    ctx['work'] = work
    ctx['work2'] = Path(tempfile.mkdtemp(prefix='heimdall-dist-test2-'))
    try:
        failures = []
        skips = []
        for name, fn in tests:
            try:
                fn(ctx)
                print(f'PASS: {name}')
            except Skip as skipped:
                skips.append((name, str(skipped)))
                print(f'SKIP: {name} ({skipped})')
            except (AssertionError, subprocess.TimeoutExpired, OSError) as exc:
                failures.append((name, str(exc)))
                print(f'FAIL: {name}: {exc}')
        print()
        for name, _ in skips:
            print(f'skipped: {name}')
        if failures:
            print('FAILED:')
            for name, message in failures:
                print(f'- {name}: {message}')
            return 1
        print('BINARY DISTRIBUTION TEST PASSED '
              f'({len(tests) - len(skips)} passed, {len(skips)} skipped)')
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(ctx['work2'], ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
