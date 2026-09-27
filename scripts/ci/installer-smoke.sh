#!/usr/bin/env bash
# REQ-INST-15: EXECUTE scripts/install.sh on a real host of each supported
# platform and assert what the installer is responsible for.
#
# Why this exists at all: until this script ran, the macOS half of install.sh
# had never executed anywhere. tests/test_binary_distribution.py derives its
# target from the REAL host (host_target(), which reads platform.system()), so
# on a Linux developer box and a Linux CI runner every darwin branch of the
# installer -- ~/Library/LaunchAgents, render_launchd_plist, the `launchctl
# bootout` in do_uninstall -- sat in an else-branch that nothing ever entered.
# The only darwin coverage that executed on Linux was the plist RENDER
# assertion, which proves the template is well-formed and proves nothing about
# installing, re-installing or uninstalling on a Mac.
#
# So this is deliberately NOT a unit test: it is the same script the README
# tells users to pipe into bash, run against the same public release they would
# download, on the darwin runners .github/workflows/release-local-binaries.yml
# already builds on.
#
# WHAT IT ASSERTS, and nothing beyond it: exit codes, the files install.sh
# places, the validity of the service file it renders, that a missing socat
# stops a real run before anything is written, and that --uninstall reverses
# exactly what was placed while KEEPING ~/.config/heimdall.
#
# WHAT IT DELIBERATELY DOES NOT ASSERT: that the installed binaries RUN. The
# published darwin tarballs are Nix closures whose files reference /nix/store,
# and bin/ham-bridge is a wrapper whose exec target is not in the tarball at
# all -- that payload-portability gate is REQ-INST-16's, not this one's. A
# `heimdall --version` assertion here would fail for a reason that has nothing
# to do with install.sh and would entangle the two.
#
# REQ-INST-13: this script NEVER touches the invoking user's real HOME. It
# installs into a sandbox HOME under a mktemp dir, exactly as the Python
# suite's sandboxed runs do, and it refuses to start if a heimdall service is
# actually loaded on the host (see assert_no_live_bridge). That makes it safe
# to run on a developer machine -- including one whose own heimdall-bridge is
# supervising live agents -- and not only on a disposable runner.
set -euo pipefail

# --- where we are ------------------------------------------------------------
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
install_sh="$repo_root/scripts/install.sh"
[ -f "$install_sh" ] || { printf 'error: %s not found\n' "$install_sh" >&2; exit 2; }

# The release used for the OFFLINE-shaped assertions (exact download URLs in
# the --dry-run plan). Overridable so a future release can be pinned without
# editing this file. The REAL install below deliberately does NOT pass
# --version: it resolves the latest release the way a `curl | bash` user does,
# which is also the only way resolve_latest_tag's curl path gets executed on
# darwin at all.
pin_version="${INSTALL_SMOKE_VERSION:-v0.3.2}"

pass_count=0
step() { printf '\n=== %s\n' "$*"; }
ok()   { pass_count=$((pass_count + 1)); printf 'ok   %s\n' "$*"; }
die()  { printf 'FAIL %s\n' "$*" >&2; exit 1; }

# Assertion helpers. Each one prints the captured output on failure: a CI log
# that says only "assertion failed" costs the next reader a second run.
assert_contains() { # <label> <needle> <haystack>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) printf 'FAIL %s\n  expected to find: %s\n--- output ---\n%s\n' "$1" "$2" "$3" >&2; exit 1 ;;
  esac
}
assert_absent() { # <label> <needle> <haystack>
  case "$3" in
    *"$2"*) printf 'FAIL %s\n  must NOT contain: %s\n--- output ---\n%s\n' "$1" "$2" "$3" >&2; exit 1 ;;
    *) ok "$1" ;;
  esac
}
assert_file()   { [ -f "$1" ] || die "expected file $1 to exist ($2)"; ok "$2"; }
# if/then, never `[ -e ] && die`: a bare && list whose TEST fails returns
# non-zero from the function, and under `set -e` that aborts the script at the
# call site -- turning every passing assertion into a silent early exit. Same
# trap the installer's own comments call out twice.
assert_gone()   { if [ -e "$1" ]; then die "expected $1 to be GONE ($2)"; fi; ok "$2"; }
assert_dir()    { [ -d "$1" ] || die "expected directory $1 to exist ($2)"; ok "$2"; }

# --- platform, derived the same way install.sh derives it --------------------
uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "$uname_m" in
  x86_64|amd64)  arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) die "unsupported architecture '$uname_m'" ;;
esac
case "$uname_s" in
  Linux)  os="linux" ;;
  Darwin) os="darwin" ;;
  *) die "unsupported operating system '$uname_s'" ;;
esac
target="$os-$arch"

# --- REQ-INST-13 precondition -------------------------------------------------
# do_uninstall stops the service best-effort. On Linux the Python suite isolates
# that by pointing XDG_RUNTIME_DIR at a sandbox, which is enough because
# `systemctl --user` resolves the bus from it. On darwin there is NO such lever:
# `launchctl bootout gui/<uid>/works.earendil.heimdall-bridge` addresses the
# per-user launchd domain, which a sandboxed HOME does not scope. So the
# isolation on darwin has to be a PRECONDITION rather than an override: if that
# label is loaded on this host, this script must not run at all.
# Both halves probe with the REAL session, deliberately: asking
# `systemctl --user is-active` with the SANDBOX XDG_RUNTIME_DIR already in force
# would answer "cannot reach a bus" on a host whose bridge is very much running,
# and the guard would pass by accident of its own isolation. The real values are
# captured before the sandbox exports below overwrite them.
assert_no_live_bridge() {
  if [ "$os" = "darwin" ]; then
    # launchctl addresses the per-user launchd domain, which HOME does not
    # scope, so on darwin this is the ONLY line of defence for the
    # `launchctl bootout` inside do_uninstall.
    if command -v launchctl >/dev/null 2>&1 \
       && launchctl print "gui/$(id -u)/works.earendil.heimdall-bridge" >/dev/null 2>&1; then
      die "works.earendil.heimdall-bridge is LOADED in this user's launchd domain. This script's --uninstall step would bootout the live bridge (a sandboxed HOME does not scope launchctl). Refusing to run; unload it by hand first if that is really what you want."
    fi
    ok "no heimdall-bridge loaded in this launchd domain (REQ-INST-13 precondition)"
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    ok "no systemctl on this host: nothing --uninstall could stop (REQ-INST-13)"
    return 0
  fi
  if env XDG_RUNTIME_DIR="$real_xdg_runtime_dir" \
         DBUS_SESSION_BUS_ADDRESS="$real_dbus_address" \
         systemctl --user is-active heimdall-bridge >/dev/null 2>&1; then
    die "heimdall-bridge is ACTIVE in this user's real systemd session, and --uninstall runs 'systemctl --user stop heimdall-bridge'. Refusing to run (REQ-INST-13). The sandbox XDG_RUNTIME_DIR below would very likely keep that call off the live bus, but 'very likely' is not the standard for a command that would stop the process supervising the agents. To rehearse this script on such a host, shadow systemctl with a stub on PATH."
  fi
  ok "no active heimdall-bridge in the real systemd session (REQ-INST-13 precondition)"
  # Second, independent check, the same one the Python suite makes before its
  # own destructive runs: the env this script will actually hand to install.sh
  # must not resolve to ANY user bus. A verdict of active OR inactive means it
  # reached one.
  probe="$(env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="" \
    systemctl --user is-active heimdall-bridge 2>&1 || true)"
  case "$probe" in
    *"Failed to connect"*|*"Failed to get D-Bus connection"*|*"No such file or directory"*|*"Permission denied"*)
      ok "the sandbox env cannot reach a user bus at all (REQ-INST-13)" ;;
    *)
      die "the sandbox env REACHED a user bus (systemctl said '$probe'), so install.sh's uninstall step could stop a real service. Refusing to continue; fix the sandbox, do not weaken this check."
      ;;
  esac
}

# --- sandbox ------------------------------------------------------------------
sandbox="$(mktemp -d)"
cleanup() { rm -rf "$sandbox"; }
trap cleanup EXIT
real_home="$HOME"
# Captured BEFORE the overrides so assert_no_live_bridge can ask the real
# session whether a bridge is running. See the note there.
real_xdg_runtime_dir="${XDG_RUNTIME_DIR:-}"
real_dbus_address="${DBUS_SESSION_BUS_ADDRESS:-}"
export HOME="$sandbox/home"
export XDG_CONFIG_HOME=""
export XDG_RUNTIME_DIR="$sandbox/xdg-runtime"
export DBUS_SESSION_BUS_ADDRESS=""
export SUDO_USER=""
export SHELL=""
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
case "$HOME" in
  "$real_home"|"$real_home"/*) die "sandbox HOME $HOME is inside the real HOME $real_home" ;;
esac

install_dir="$HOME/.local/bin"
config_dir="$HOME/.config/heimdall"
if [ "$os" = "darwin" ]; then
  service_file="$HOME/Library/LaunchAgents/works.earendil.heimdall-bridge.plist"
else
  service_file="$HOME/.config/systemd/user/heimdall-bridge.service"
fi
binaries="heimdall ham-bridge ham-pty-host ham-ctl"

# Runs install.sh and captures stdout+stderr and the exit code, WITHOUT letting
# `set -e` abort on a run we expect to fail.
run_installer() { # <expected-exit-code> <args...>
  expected="$1"; shift
  set +e
  out="$(bash "$install_sh" "$@" 2>&1)"
  code=$?
  set -e
  if [ "$code" != "$expected" ]; then
    printf 'FAIL install.sh %s exited %s, expected %s\n--- output ---\n%s\n' \
      "$*" "$code" "$expected" "$out" >&2
    exit 1
  fi
  ok "install.sh $* exited $expected"
}

printf 'installer smoke: %s (%s/%s), target %s\n' "$uname_s" "$os" "$arch" "$target"
printf 'sandbox HOME: %s\n' "$HOME"
printf 'pinned release for URL assertions: %s\n' "$pin_version"
printf 'bash: %s\n' "$(bash --version | head -n 1)"

assert_no_live_bridge

# --- 1. --help ----------------------------------------------------------------
step "--help exits 0 and documents both platforms"
run_installer 0 --help
assert_contains "usage block printed" "usage: install.sh" "$out"
assert_contains "macOS named as supported" "Platforms: Linux" "$out"
assert_contains "socat named as a prerequisite" "Requires socat" "$out"

# --- 2. socat missing is FATAL before anything is written (REQ-INST-14) -------
# A PATH shim rather than uninstalling the host's socat: the check has to be
# deterministic on a runner image whose socat may or may not be preinstalled,
# and removing a system package to test a preflight is not a thing CI should do.
# curl IS on the shim on purpose -- if the preflight failed to fire, the run
# would reach a real download and really install, which the "nothing written"
# assertions below would then catch.
step "socat missing: a real install STOPS before writing anything (REQ-INST-14)"
shim="$sandbox/shim-nosocat"
mkdir -p "$shim"
for tool in bash sh env uname mktemp id date sed awk grep cat cut tr head tail \
            printf test true false mkdir rmdir rm cp mv ln chmod chown touch \
            dirname basename install tar gzip sort wc stat find readlink expr \
            sleep tee curl sha256sum shasum launchctl systemctl getent whoami cmp; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  if [ -n "$real" ] && [ ! -e "$shim/$tool" ]; then ln -s "$real" "$shim/$tool"; fi
done
if [ -e "$shim/socat" ]; then die "the no-socat shim must not contain socat"; fi
set +e
nosocat_out="$(PATH="$shim" bash "$install_sh" --version "$pin_version" 2>&1)"
nosocat_code=$?
set -e
[ "$nosocat_code" -ne 0 ] || die "a real install with no socat on PATH exited 0; it must be fatal (REQ-INST-14)"
ok "install.sh --version $pin_version with no socat exited $nosocat_code (non-zero)"
assert_contains "names the missing dependency" "socat is not installed" "$nosocat_out"
assert_contains "states nothing was written" "Nothing has been installed; no files were written." "$nosocat_out"
assert_contains "names the macOS remedy" "brew install socat" "$nosocat_out"
assert_absent "never reached a download" "downloading https://" "$nosocat_out"
for b in $binaries; do
  if [ -e "$install_dir/$b" ]; then
    die "a failed socat preflight still installed $install_dir/$b"
  fi
done
assert_gone "$service_file" "no service file written by the failed preflight"
ok "no binaries written by the failed preflight"

# From here on socat must be present; the workflow installs it. Asserting it
# rather than skipping: a smoke run that silently degraded into the
# missing-socat path would prove nothing about the install it claims to test.
command -v socat >/dev/null 2>&1 \
  || die "socat is not on PATH. Install it before this script (brew install socat / sudo apt install socat); every step below is an INSTALL step and REQ-INST-14 makes them all fail without it."
ok "socat present for the install steps: $(command -v socat)"

# --- 3. --dry-run writes nothing and names the right platform + URLs ---------
step "--dry-run --version $pin_version: exit 0, correct target, no writes"
run_installer 0 --dry-run --version "$pin_version"
assert_contains "platform line names this host" "platform: $os/$arch (release target $target)" "$out"
assert_contains "tarball URL is the darwin/linux asset for this host" \
  "would download: https://github.com/tanmayv/heimdall-agent-manager/releases/download/$pin_version/heimdall-local-$target-$pin_version.tar.gz" "$out"
assert_contains "SHA256SUMS URL" \
  "would download: https://github.com/tanmayv/heimdall-agent-manager/releases/download/$pin_version/SHA256SUMS" "$out"
assert_contains "verifies before extracting" "would verify SHA-256" "$out"
assert_contains "names the install dir" "to $install_dir" "$out"
assert_contains "names the service file it would write" "would write service file $service_file" "$out"
if [ "$os" = "darwin" ]; then
  assert_contains "previews a launchd plist" "<!DOCTYPE plist" "$out"
  assert_contains "previews the launchd label" "works.earendil.heimdall-bridge" "$out"
  assert_absent "no systemd unit on darwin" "[Unit]" "$out"
else
  assert_contains "previews a systemd unit" "[Unit]" "$out"
  assert_absent "no launchd plist on linux" "<!DOCTYPE plist" "$out"
fi
if [ -e "$install_dir" ]; then die "--dry-run created $install_dir"; fi
assert_gone "$service_file" "--dry-run wrote no service file"
ok "--dry-run wrote nothing"

# --- 4. the real install ------------------------------------------------------
# No --version: this resolves the latest GitHub release exactly as the
# documented `curl -fsSL ... | bash` invocation does, which is also what puts
# resolve_latest_tag's curl path and api_fetch on a darwin host under test.
step "real install (latest release, no --version): exit 0 and every file in place"
run_installer 0
install_out="$out"
assert_contains "downloaded a tarball" "downloading https://github.com/tanmayv/heimdall-agent-manager/releases/download/" "$install_out"
assert_contains "verified the checksum BEFORE extracting" "checksum verified" "$install_out"
for b in $binaries; do
  assert_file "$install_dir/$b" "installed $b"
  [ -x "$install_dir/$b" ] || die "$install_dir/$b is not executable"
done
ok "all four binaries are mode +x"
assert_file "$service_file" "wrote the service file for $os"
assert_contains "said so" "wrote service file $service_file" "$install_out"
assert_dir "$config_dir" "created the enrollment dir $config_dir"

# The service file must be the right KIND of file for this platform, and on
# darwin it must be a plist launchd will actually accept -- plutil is the
# authority, not a grep for angle brackets.
if [ "$os" = "darwin" ]; then
  plutil -lint "$service_file" || die "plutil -lint rejected the rendered plist"
  ok "plutil -lint accepted $service_file"
  grep -q '<key>Label</key>' "$service_file" || die "plist has no Label key"
  grep -q '<string>works.earendil.heimdall-bridge</string>' "$service_file" || die "plist has the wrong label"
  grep -q '<key>RunAtLoad</key>' "$service_file" || die "plist has no RunAtLoad key"
  ok "plist carries Label / RunAtLoad"
  # install.sh documents that it registers the service and does NOT start it.
  # Assert that: a bootstrapped job here would be a REQ-INST-13 hazard as well
  # as a broken promise.
  if launchctl print "gui/$(id -u)/works.earendil.heimdall-bridge" >/dev/null 2>&1; then
    die "install.sh BOOTSTRAPPED the launchd job; it documents that it only registers the service"
  fi
  ok "installer did not load the launchd job (it only writes the plist)"
  assert_contains "onboarding tells the user how to start it" "launchctl bootstrap" "$install_out"
else
  grep -q '^\[Unit\]' "$service_file" || die "systemd unit has no [Unit] section"
  grep -q 'ham-bridge' "$service_file" || die "systemd unit does not exec ham-bridge"
  ok "systemd unit carries [Unit] and ham-bridge"
fi

# PATH wiring. With SHELL='' path_candidates() takes its union branch, so the
# line lands in the sandbox .bashrc -- created, because the sandbox home has no
# rc files at all.
rc_hit=false
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  if grep -Fq "export PATH=\"$install_dir:\$PATH\"" "$rc"; then rc_hit=true; fi
done
"$rc_hit" || die "no rc file in the sandbox home carries the PATH export"
ok "PATH export written into a sandbox rc file"

# --- 5. re-run is a no-op on the service file --------------------------------
step "identical re-run: exit 0, service file left untouched"
run_installer 0
assert_contains "identical unit detected" "already up to date; leaving it untouched" "$out"
if ls "$service_file".bak-* >/dev/null 2>&1; then
  die "an identical re-run created a backup: $(ls "$service_file".bak-*)"
fi
ok "no .bak-* file from an identical re-run"

# --- 6. --uninstall reverses the install and KEEPS enrollment state ----------
# The sentinel is what makes the "keeps ~/.config/heimdall" claim provable: an
# empty directory surviving could be an accident of ordering, a file with
# content surviving could not.
step "--uninstall: exit 0, removes what it placed, keeps $config_dir"
printf 'sentinel written by installer-smoke\n' > "$config_dir/config.toml"
run_installer 0 --uninstall
uninstall_out="$out"
assert_contains "reported completion" "uninstall complete" "$uninstall_out"
for b in $binaries; do
  assert_gone "$install_dir/$b" "removed $b"
done
assert_gone "$service_file" "removed the service file"
assert_file "$config_dir/config.toml" "KEPT the enrollment sentinel"
grep -q 'sentinel written by installer-smoke' "$config_dir/config.toml" \
  || die "the kept config.toml was rewritten"
assert_contains "said what it kept" "kept enrollment state at $config_dir" "$uninstall_out"
if [ "$os" = "darwin" ]; then
  assert_contains "stopped the launchd label best-effort" "stopped works.earendil.heimdall-bridge" "$uninstall_out"
fi
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  if grep -Fq "# Added by heimdall install.sh" "$rc"; then
    die "$rc still carries the installer marker after --uninstall"
  fi
done
ok "no installer PATH marker left in any rc file"

printf '\nINSTALLER SMOKE PASSED on %s/%s (%s assertions)\n' "$os" "$arch" "$pass_count"
