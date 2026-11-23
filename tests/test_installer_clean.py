#!/usr/bin/env python3
"""Hermetic tests of the thin bootstraps (scripts/install.sh, scripts/install.ps1).

install.sh only resolves a release, downloads + SHA-256 verifies the bundle and
runs `ham-bridge setup --headless` with the remaining flags. A mock `curl` on
PATH serves a fake GitHub release list and release assets from a temp dir, and the
bundle's bin/ham-bridge is a stub that records its argv, so nothing is downloaded,
installed or enrolled.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'scripts/install.sh'
INSTALLER_PS1 = ROOT / 'scripts/install.ps1'
REPO = 'tanmayv/heimdall-agent-manager'
# The bash that runs install.sh; CI sets /bin/bash on macOS (bash 3.2).
BASH = shutil.which(os.environ.get('INSTALLER_BASH', 'bash')) or 'bash'

MOCK_CURL = r'''#!/usr/bin/env bash
# Maps the URLs install.sh fetches onto $MOCK_ROOT/www; anything else is a 404.
url='' out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --connect-timeout|--max-time|--speed-limit|--speed-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$MOCK_ROOT/curl.log"
case "$url" in
  https://api.github.com/repos/*/releases/latest) src="$MOCK_ROOT/www/latest.json" ;;
  https://api.github.com/repos/*/releases\?*) src="$MOCK_ROOT/www/releases.json" ;;
  https://github.com/*/releases/download/*) src="$MOCK_ROOT/www/download/${url#*/releases/download/}" ;;
  *) src='' ;;
esac
[ -n "$src" ] && [ -f "$src" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "$src" "$out"
'''

# The stub records its argv. With STUB_STDIN_LOG it records what ham-bridge
# would see on stdin: a terminal, or how many bytes it could read. With
# STUB_INSTALLED it also applies setup's S8c rule: an older --version than the
# installed one exits 5 unless --allow-downgrade (the real check lives in
# bridgesvc.classify_install).
STUB_BRIDGE = r'''#!/bin/sh
printf "%s\n" "$*" >> "$MOCK_ROOT/ham-bridge.log"
if [ -n "${STUB_STDIN_LOG:-}" ]; then
  if [ -t 0 ]; then echo tty > "$STUB_STDIN_LOG"; else printf 'bytes %s\n' "$(wc -c | tr -d ' ')" > "$STUB_STDIN_LOG"; fi
fi
if [ -n "${STUB_INSTALLED:-}" ]; then
  req='' allow=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version) req="${2#v}"; shift ;;
      --allow-downgrade) allow=1 ;;
    esac
    shift
  done
  inst="${STUB_INSTALLED#v}"
  if [ -n "$req" ] && [ -z "$allow" ] && [ "$req" != "$inst" ] &&
     [ "$(printf '%s\n%s\n' "$req" "$inst" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$req" ]; then
    echo "ham-bridge setup: runs v$inst, newer than requested v$req; pass --allow-downgrade to downgrade" >&2
    exit 5
  fi
fi
exit "${STUB_EXIT:-0}"
'''


def host_target():
    os_name = {'Linux': 'linux', 'Darwin': 'darwin'}[platform.system()]
    arch = {'x86_64': 'amd64', 'amd64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}[platform.machine()]
    return f'{os_name}-{arch}'


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='heimdall-bootstrap-test-')
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home with spaces'
        self.home.mkdir()
        mock = self.root / 'mock'
        mock.mkdir()
        (mock / 'curl').write_text(MOCK_CURL)
        (mock / 'curl').chmod(0o755)
        self.target = host_target()
        base = {k: v for k, v in os.environ.items() if not k.startswith('HEIMDALL_') and k not in ('TERMUX_VERSION', 'PREFIX')}
        self.env = dict(base, HOME=str(self.home), PATH=f'{mock}:{os.environ["PATH"]}',
                        MOCK_ROOT=str(self.root), TMPDIR=str(self.root))
        self.releases = []

    def tearDown(self):
        self.tmp.cleanup()

    def bundle_bytes(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w:gz') as tf:
            data = STUB_BRIDGE.encode()
            info = tarfile.TarInfo('bin/ham-bridge')
            info.size, info.mode = len(data), 0o755
            tf.addfile(info, io.BytesIO(data))
        return buf.getvalue()

    def publish(self, tag, *, prerelease=False, draft=False, sums=True, bundle=True, tamper=False):
        name = f'heimdall-local-{self.target}-{tag}.tar.gz'
        d = self.root / 'www' / 'download' / tag
        d.mkdir(parents=True)
        data = self.bundle_bytes()
        assets = []
        if bundle:
            (d / name).write_bytes(data + (b'x' if tamper else b''))
            assets.append({'name': name})
        if sums:
            (d / 'SHA256SUMS').write_text(f'{hashlib.sha256(data).hexdigest()}  {name}\n')
            assets.append({'name': 'SHA256SUMS'})
        self.releases.append({'tag_name': tag, 'draft': draft, 'prerelease': prerelease, 'assets': assets})
        self.write_listing()
        return d / name, d / 'SHA256SUMS'

    def write_listing(self):
        """The release list, and /releases/latest: like GitHub, the first
        non-draft, non-prerelease release (404 when there is none)."""
        www = self.root / 'www'
        www.mkdir(exist_ok=True)
        (www / 'releases.json').write_text(json.dumps(self.releases))
        latest = next((r for r in self.releases if not r['draft'] and not r['prerelease']), None)
        if latest is None:
            (www / 'latest.json').unlink(missing_ok=True)
        else:
            (www / 'latest.json').write_text(json.dumps(latest, indent=2))

    def run_installer(self, *args, stdin_script=False, extra_env=None, stdin_data=None):
        env = dict(self.env, **(extra_env or {}))
        if stdin_script:
            return subprocess.run([BASH, '-s', '--', *args], input=INSTALLER.read_text() + (stdin_data or ''),
                                  env=env, capture_output=True, text=True, timeout=60)
        if stdin_data is not None:
            return subprocess.run([BASH, str(INSTALLER), *args], input=stdin_data, env=env,
                                  capture_output=True, text=True, timeout=60)
        return subprocess.run([BASH, str(INSTALLER), *args], env=env, capture_output=True,
                              text=True, timeout=60, stdin=subprocess.DEVNULL)

    def bridge_calls(self):
        log = self.root / 'ham-bridge.log'
        return log.read_text().splitlines() if log.exists() else []

    def assert_clean(self):
        # The temporary download/unpack directory is always removed.
        self.assertEqual([p.name for p in self.root.glob('heimdall-install.*')], [])

    def test_latest_promoted_release_runs_setup_with_passthrough(self):
        self.publish('v1.1.0', prerelease=True)
        self.publish('v1.0.0')
        res = self.run_installer('--hub', 'https://hub.example.com', '--name', 'bob', '--new-bridge')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['setup --headless --hub https://hub.example.com --profile bob --keep-version --new-bridge'])
        self.assertIn(f'releases/download/v1.0.0/heimdall-local-{self.target}-v1.0.0.tar.gz',
                      (self.root / 'curl.log').read_text())
        self.assert_clean()

    def test_curl_pipe_bash(self):
        self.publish('v1.0.0')
        res = self.run_installer('--hub', 'https://hub.example.com', stdin_script=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['setup --headless --hub https://hub.example.com --keep-version'])

    def test_ham_bridge_gets_no_stdin_when_piped(self):
        """REQ-INSTALL-2 (no TTY): under `curl | bash` stdin is the script itself;
        ham-bridge must get an empty stdin (never what follows on the pipe, never a
        prompt source), piped or run as a file with input waiting on stdin."""
        self.publish('v1.0.0')
        seen = self.root / 'stdin.log'
        for piped in (True, False):
            with self.subTest(piped=piped):
                res = self.run_installer('--hub', 'https://h', stdin_script=piped, stdin_data='y\ny\n',
                                         extra_env={'STUB_STDIN_LOG': str(seen)})
                self.assertEqual(res.returncode, 0, res.stderr)
                self.assertEqual(seen.read_text().strip(), 'bytes 0')

    def test_explicit_version_may_be_prerelease(self):
        self.publish('v1.0.0')
        self.publish('v1.1.0-rc1', prerelease=True)
        res = self.run_installer('--version', 'v1.1.0-rc1', '--hub', 'https://h')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn('/v1.1.0-rc1/', (self.root / 'curl.log').read_text())
        # An explicit release may move an installed bridge: no --keep-version (S8b),
        # and setup gets the TAG so an older one is refused (S8c).
        self.assertEqual(self.bridge_calls(), ['setup --headless --hub https://h --version v1.1.0-rc1'])

    def test_tampered_bundle_is_refused_before_ham_bridge_runs(self):
        self.publish('v1.0.0', tamper=True)
        res = self.run_installer('--hub', 'https://h')
        self.assertEqual(res.returncode, 3)
        self.assertIn('SHA-256 verification failed', res.stderr)
        self.assertEqual(self.bridge_calls(), [])
        self.assert_clean()

    def test_unknown_or_unverifiable_release_is_refused(self):
        self.publish('v1.0.0')
        res = self.run_installer('--version', 'v9.9.9', '--hub', 'https://h')
        self.assertEqual(res.returncode, 3)
        self.assertIn('no SHA256SUMS', res.stderr)
        res = self.run_installer('--version', '../x', '--hub', 'https://h')
        self.assertEqual(res.returncode, 2)
        self.assertIn('Invalid release tag', res.stderr)
        self.assertEqual(self.bridge_calls(), [])

    def test_stable_release_without_target_assets_never_falls_back(self):
        """Spec §5.1: the release /releases/latest names must carry SHA256SUMS and
        this target's bundle; an older complete release is never used instead."""
        self.publish('v1.0.0', sums=False)
        self.publish('v0.9.0')
        res = self.run_installer('--hub', 'https://h')
        self.assertEqual(res.returncode, 3)
        self.assertIn(f'[ERROR] Stable release v1.0.0 has no SHA256SUMS for {self.target}; pass --version TAG.', res.stderr)
        self.releases = []
        (self.root / 'www' / 'download').rename(self.root / 'old-download')
        self.publish('v1.0.0', bundle=False)
        self.publish('v0.9.0')
        res = self.run_installer('--hub', 'https://h')
        self.assertEqual(res.returncode, 3)
        self.assertIn(f'[ERROR] Stable release v1.0.0 has no bundle for {self.target}; pass --version TAG.', res.stderr)
        self.assertNotIn('/v0.9.0/', (self.root / 'curl.log').read_text())
        self.assertEqual(self.bridge_calls(), [])
        self.assert_clean()

    def test_no_promoted_release_at_all(self):
        self.publish('v1.0.0', prerelease=True)
        res = self.run_installer('--hub', 'https://h')
        self.assertEqual(res.returncode, 3)
        self.assertIn('[ERROR] Cannot resolve the stable release from GitHub (The requested URL returned error: 404); pass --version TAG.', res.stderr)
        self.assertEqual(self.bridge_calls(), [])
        self.assert_clean()

    def test_stable_response_that_is_not_a_release(self):
        www = self.root / 'www'
        www.mkdir()
        for body, why in (('[]', 'the response is not a release'), ('{"message": "API rate limit exceeded"}', 'no tag_name in the response')):
            (www / 'latest.json').write_text(body)
            res = self.run_installer('--hub', 'https://h')
            self.assertEqual(res.returncode, 3, res.stderr)
            self.assertIn(f'Cannot resolve the stable release from GitHub ({why}); pass --version TAG.', res.stderr)
        self.assertEqual(self.bridge_calls(), [])

    def test_latest_promoted_release_beyond_one_hundred_releases(self):
        """F9: 130 prereleases above the promoted release; never read from a list page."""
        for i in range(129, -1, -1):
            self.releases.append({'tag_name': f'v1.1.{i}', 'draft': False, 'prerelease': True,
                                  'assets': [{'name': f'heimdall-local-{self.target}-v1.1.{i}.tar.gz'}, {'name': 'SHA256SUMS'}]})
        self.publish('v1.0.0')
        for i in range(18, -1, -1):
            self.releases.append({'tag_name': f'v0.9.{i}', 'draft': False, 'prerelease': False, 'assets': []})
        self.write_listing()
        self.assertEqual(len(self.releases), 150)
        res = self.run_installer('--hub', 'https://h')
        self.assertEqual(res.returncode, 0, res.stderr)
        log = (self.root / 'curl.log').read_text()
        self.assertIn(f'releases/download/v1.0.0/heimdall-local-{self.target}-v1.0.0.tar.gz', log)
        self.assertNotIn('/releases?', log)

    def test_uninstall_runs_ham_bridge_uninstall(self):
        self.publish('v1.0.0')
        res = self.run_installer('--uninstall', '--hub', 'https://h', '--purge')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['uninstall --hub https://h --purge'])

    def test_local_bundle_is_verified_and_target_checked(self):
        bundle, sums = self.publish('v1.0.0')
        res = self.run_installer('--bundle', str(bundle), '--checksum-file', str(sums), '--hub', 'https://h')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertFalse((self.root / 'curl.log').exists(), 'a local bundle needs no download')
        # An explicit bundle means "install this bundle" (S8b): no --keep-version.
        self.assertEqual(self.bridge_calls(), ['setup --headless --hub https://h'])
        other = self.root / 'heimdall-local-plan9-amd64-v1.0.0.tar.gz'
        other.write_bytes(bundle.read_bytes())
        res = self.run_installer('--bundle', str(other), '--checksum-file', str(sums), '--hub', 'https://h')
        self.assertEqual(res.returncode, 3)
        self.assertIn('not for this machine', res.stderr)

    def test_desktop_installer_bundle_runs_interactive_setup(self):
        """REQ-ENR-4: the desktop installers stage the bundle unversioned and pass
        --interactive, so ham-bridge setup runs without --headless (browser approval)."""
        bundle, sums = self.publish('v1.0.0')
        staged = self.root / f'heimdall-local-{self.target}.tar.gz'
        staged.write_bytes(bundle.read_bytes())
        staged_sums = self.root / 'STAGED_SHA256SUMS'
        staged_sums.write_text(sums.read_text().replace(bundle.name, staged.name))
        res = self.run_installer('--bundle', str(staged), '--checksum-file', str(staged_sums),
                                 '--hub', 'https://h', '--interactive')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['setup --hub https://h'])
        res = self.run_installer('--bundle', str(staged), '--checksum-file', str(staged_sums), '--hub', 'https://h')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls()[-1], 'setup --headless --hub https://h')

    def test_macos_pkg_postinstall_upgrades_an_installed_bridge(self):
        """The .pkg postinstall (scripts/release/macos-pkg-bridge-postinstall.sh)
        runs install.sh --bundle --checksum-file --hub --interactive and no
        --version. setup must get no --keep-version, so its default (S8: install
        the bundle when it differs from bin/) upgrades an older healthy bridge."""
        postinstall = (ROOT / 'scripts/release/macos-pkg-bridge-postinstall.sh').read_text()
        call = postinstall[postinstall.index('"$work/install.sh"'):]
        call = call[:call.index('|| bridge_failed')]
        self.assertIn('--bundle', call)
        self.assertNotIn('--version', call)
        self.assertNotIn('--keep-version', call)
        bundle, sums = self.publish('v1.0.0')
        staged = self.root / f'heimdall-local-{self.target}.tar.gz'
        staged.write_bytes(bundle.read_bytes())
        staged_sums = self.root / 'STAGED_SHA256SUMS'
        staged_sums.write_text(sums.read_text().replace(bundle.name, staged.name))
        # HEIMDALL_VERSION=latest in the user's environment counts as no release;
        # the bundle alone still decides.
        res = self.run_installer('--bundle', str(staged), '--checksum-file', str(staged_sums),
                                 '--hub', 'https://h', '--interactive', extra_env={'HEIMDALL_VERSION': 'latest'})
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['setup --hub https://h'])
        self.assertFalse((self.root / 'curl.log').exists(), 'the .pkg bundle needs no download')

    def test_keep_version_only_when_the_script_resolves_the_release(self):
        """Spec §7: --keep-version iff neither --bundle nor --version is given
        (`latest` counts as none, from the flag or HEIMDALL_VERSION)."""
        bundle, sums = self.publish('v1.0.0')
        self.publish('v1.1.0-rc1', prerelease=True)
        b = ('--bundle', str(bundle), '--checksum-file', str(sums))
        cases = [
            ((), {}, True),
            (('--version', 'latest'), {}, True),
            ((), {'HEIMDALL_VERSION': 'latest'}, True),
            (('--version', 'v1.1.0-rc1'), {}, False),
            ((), {'HEIMDALL_VERSION': 'v1.1.0-rc1'}, False),
            (b, {}, False),
            (b + ('--version', 'v1.0.0'), {}, False),
            (b + ('--version', 'latest'), {}, False),
        ]
        for args, env, keep in cases:
            with self.subTest(args=args, env=env):
                res = self.run_installer('--hub', 'https://h', *args, extra_env=env)
                self.assertEqual(res.returncode, 0, res.stderr)
                self.assertEqual(self.bridge_calls()[-1].split(' --version ')[0],
                                 'setup --headless --hub https://h' + (' --keep-version' if keep else ''))

    def test_explicit_version_is_forwarded_to_setup(self):
        """Spec §7: setup gets --version TAG iff the user named a concrete TAG
        (flag or HEIMDALL_VERSION); never for latest, a release the script
        resolved, or --bundle alone. With --bundle the TAG is still forwarded and
        setup checks it names that bundle."""
        bundle, sums = self.publish('v1.0.0')
        self.publish('v1.1.0-rc1', prerelease=True)
        b = ('--bundle', str(bundle), '--checksum-file', str(sums))
        cases = [
            ((), {}, None),
            (('--version', 'latest'), {}, None),
            ((), {'HEIMDALL_VERSION': 'latest'}, None),
            (b, {}, None),
            (b + ('--version', 'latest'), {}, None),
            (('--version', 'v1.1.0-rc1'), {}, 'v1.1.0-rc1'),
            ((), {'HEIMDALL_VERSION': 'v1.1.0-rc1'}, 'v1.1.0-rc1'),
            (('--version', 'v1.0.0'), {'HEIMDALL_VERSION': 'v1.1.0-rc1'}, 'v1.0.0'),
            (b + ('--version', 'v1.0.0'), {}, 'v1.0.0'),
            (b, {'HEIMDALL_VERSION': 'v1.0.0'}, 'v1.0.0'),
        ]
        for args, env, tag in cases:
            with self.subTest(args=args, env=env):
                res = self.run_installer('--hub', 'https://h', *args, extra_env=env)
                self.assertEqual(res.returncode, 0, res.stderr)
                call = self.bridge_calls()[-1].split()
                if tag is None:
                    self.assertNotIn('--version', call)
                else:
                    self.assertEqual(call.count('--version'), 1, call)
                    self.assertEqual(call[call.index('--version') + 1], tag)
        # Uninstall never gets --version.
        res = self.run_installer('--uninstall', '--version', 'v1.0.0', '--yes')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls()[-1], 'uninstall --yes')

    def test_older_explicit_version_is_refused_unless_allow_downgrade(self):
        """S8c: an installed v1.2.0 and an explicit older TAG -> setup refuses
        with exit 5, returned unchanged; --allow-downgrade installs it (S8b). A
        newer TAG and the self-resolved release are unchanged."""
        self.publish('v1.0.0')
        self.publish('v1.3.0-rc1', prerelease=True)
        installed = {'STUB_INSTALLED': 'v1.2.0'}
        for args, env in ((('--version', 'v1.0.0'), installed),
                          ((), dict(installed, HEIMDALL_VERSION='v1.0.0'))):
            with self.subTest(args=args, env=env):
                res = self.run_installer('--hub', 'https://h', *args, extra_env=env)
                self.assertEqual(res.returncode, 5, res.stderr)
                self.assertIn('runs v1.2.0, newer than requested v1.0.0; pass --allow-downgrade to downgrade', res.stderr)
        res = self.run_installer('--hub', 'https://h', '--version', 'v1.0.0', '--allow-downgrade', extra_env=installed)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls()[-1], 'setup --headless --hub https://h --version v1.0.0 --allow-downgrade')
        res = self.run_installer('--hub', 'https://h', '--version', 'v1.3.0-rc1', extra_env=installed)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls()[-1], 'setup --headless --hub https://h --version v1.3.0-rc1')
        # The resolved stable release (v1.0.0, older) keeps the installed version.
        res = self.run_installer('--hub', 'https://h', extra_env=installed)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls()[-1], 'setup --headless --hub https://h --keep-version')
        self.assert_clean()

    def test_ham_bridge_exit_code_is_returned_unchanged(self):
        self.publish('v1.0.0')
        for code in ('1', '4', '5', '6', '7'):
            res = self.run_installer('--hub', 'https://h', extra_env={'STUB_EXIT': code})
            self.assertEqual(res.returncode, int(code))
        self.assert_clean()

    def test_environment_configures_the_pipe_form(self):
        """`curl ... | HEIMDALL_HUB=... bash`: no TTY, no arguments, env only."""
        self.publish('v1.0.0')
        self.publish('v1.1.0-rc1', prerelease=True)
        env = {'HEIMDALL_HUB': 'https://env.example', 'HEIMDALL_BRIDGE_NAME': 'envprof', 'HEIMDALL_VERSION': 'v1.1.0-rc1'}
        res = self.run_installer(stdin_script=True, extra_env=env)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['setup --headless --hub https://env.example --profile envprof --version v1.1.0-rc1'])
        self.assertIn('/v1.1.0-rc1/', (self.root / 'curl.log').read_text())

    def test_flags_win_over_environment_and_reach_ham_bridge_once(self):
        self.publish('v1.0.0')
        self.publish('v1.1.0-rc1', prerelease=True)
        env = {'HEIMDALL_HUB': 'https://env.example', 'HEIMDALL_BRIDGE_NAME': 'envprof', 'HEIMDALL_VERSION': 'v1.1.0-rc1'}
        res = self.run_installer('--hub-url', 'https://flag.example', '--name', 'flagprof', '--version', 'latest',
                                 '--reenroll', extra_env=env)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['setup --headless --hub https://flag.example --profile flagprof --keep-version --reenroll'])
        self.assertIn('/v1.0.0/', (self.root / 'curl.log').read_text())

    def test_usage_errors_exit_2_before_anything_is_fetched(self):
        self.publish('v1.0.0')
        cases = [
            ((), 'No hub given: pass --hub URL or set HEIMDALL_HUB'),
            (('--hub',), '--hub requires a value.'),
            (('--hub', 'https://h', '--profile', 'Bad_Name'), 'Invalid profile "Bad_Name"'),
            (('--hub', 'https://h', '--version', 'a b'), 'Invalid release tag'),
            (('--hub', 'https://h', '--bundle', '/nonexistent', '--checksum-file', '/nonexistent'), 'must both name regular files'),
        ]
        for args, msg in cases:
            res = self.run_installer(*args)
            self.assertEqual(res.returncode, 2, (args, res.stderr))
            self.assertIn(msg, res.stderr)
        self.assertFalse((self.root / 'curl.log').exists())
        self.assertEqual(self.bridge_calls(), [])

    def test_uninstall_needs_no_hub(self):
        self.publish('v1.0.0')
        res = self.run_installer('--uninstall', '--service', 'heimdall-bridge-h', '--yes')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.bridge_calls(), ['uninstall --service heimdall-bridge-h --yes'])

    def test_missing_prerequisite_is_a_clear_bootstrap_failure(self):
        empty = self.root / 'emptybin'
        empty.mkdir()
        res = self.run_installer('--hub', 'https://h', extra_env={'PATH': str(empty)})
        self.assertEqual(res.returncode, 3, res.stderr)
        self.assertIn('[ERROR] curl is required but was not found on PATH', res.stderr)
        self.assertEqual(self.bridge_calls(), [])

    def test_help_documents_the_headless_one_liner(self):
        res = self.run_installer('--help')
        self.assertEqual(res.returncode, 0)
        self.assertIn('curl -fsSL https://install.ninjy.ai | bash -s -- --hub', res.stdout)
        self.assertIn('HEIMDALL_HUB=https://hub.example.com bash', res.stdout)
        ps1 = INSTALLER_PS1.read_text()
        self.assertIn("irm https://install.ninjy.ai/ps1 | iex", ps1)

    def test_bootstraps_hold_no_install_logic(self):
        """REQ-ENR-5: download + verify + exec only; the lifecycle lives in ham-bridge."""
        sh = INSTALLER.read_text()
        for word in ('systemctl', 'launchctl', 'LaunchAgents', 'enroll.sh', 'sv-enable', 'apply-bridge-update', '/public/'):
            self.assertNotIn(word, sh)
        self.assertEqual([l for l in sh.splitlines() if l.strip()][-1], 'main "$@"')
        ps1 = INSTALLER_PS1.read_text()
        self.assertTrue(ps1.isascii(), 'install.ps1 must be pure ASCII (PowerShell 5.1)')
        for word in ('Register-ScheduledTask', 'schtasks', 'enroll.ps1', 'apply-bridge-update', 'Set-Acl'):
            self.assertNotIn(word, ps1)
        self.assertIn("'setup', '--headless'", ps1)
        # Standalone interactive CLI installation still supports browser approval.
        self.assertIn("elseif ($isInteractive) { $argv += 'setup' }", ps1)
        # Both read the stable release directly, never a list page (F9).
        self.assertIn('/releases/latest"', ps1)
        self.assertIn('/releases/latest"', sh)
        for text in (sh, ps1):
            self.assertNotIn('releases?', text)
            self.assertNotIn('per_page', text)
        # The same messages on both sides (spec §5.1).
        for msg in ('has no SHA256SUMS for', 'has no bundle for', 'Cannot resolve the stable release from GitHub',
                    'No hub given: pass ', 'or set HEIMDALL_HUB', 'Invalid profile', 'SHA-256 verification failed; nothing installed.'):
            self.assertIn(msg, sh)
            self.assertIn(msg, ps1)


if __name__ == '__main__':
    unittest.main()
