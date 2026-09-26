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
   resolution paths are asserted; the bare --dry-run only needs exit 0).
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
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

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
                    ctl_binaries=('ham-ctl',)):
    """Run the packaging script against stub inputs; return (result, tarball)."""
    out_dir = base / 'dist'
    bridge = make_stub_input(base, 'bridge-out',
                             ['ham-bridge'] + (['openssl'] if with_openssl else []))
    ctl = make_stub_input(base, 'ctl-out', list(ctl_binaries))
    manager = make_stub_input(base, 'manager-out', ['heimdall'])
    argv = ['bash', PACKAGE_SCRIPT, 'linux-amd64', 'v0.1.0', out_dir,
            bridge, ctl, manager]
    if with_pty_host:
        argv.append(make_stub_input(base, 'ptyhost-out', ['ham-pty-host']))
    res = run(argv, cwd=ROOT)
    return res, out_dir / 'heimdall-local-linux-amd64.tar.gz'


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


def test_install_sh_help(ctx):
    res = run(['bash', INSTALL_SCRIPT, '--help'])
    assert res.returncode == 0
    assert 'usage: install.sh' in res.stderr
    assert '--version <tag>' in res.stderr and '--hub <url>' in res.stderr
    assert '--dry-run' in res.stderr


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


def test_install_sh_dry_run_bare(ctx):
    # Offline-tolerant: even when the latest-tag lookup fails the dry run must
    # still exit 0 and print the plan.
    res = run(['bash', INSTALL_SCRIPT, '--dry-run'], timeout=90)
    assert res.returncode == 0, f'bare --dry-run failed:\n{res.stderr}'
    assert 'platform:' in res.stdout and 'would install' in res.stdout


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
        ('build heimdall (nix develop / odin)', build_heimdall),
        ('heimdall --version schema', test_heimdall_version_schema),
        ('heimdall status schema', test_heimdall_status_schema),
        ('heimdall vault lifecycle', test_heimdall_vault_lifecycle),
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
