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
# TWO MODES (INSTALL_SMOKE_MODE), because install.sh has two install shapes:
#   sandbox (default) -- the normal `curl | bash` path: ~/.local/bin, everything
#     inside a mktemp HOME, safe to run on a developer machine.
#   sudo (REQ-INST-18) -- the advertised `curl | sudo bash` path: /usr/local/bin
#     with the service file and PATH lines written for SUDO_USER. This one
#     CANNOT be sandboxed and makes real writes, so it refuses to start without
#     an explicit opt-in. See the SUDO MODE section below for why.
#
# REQ-INST-13: in sandbox mode this script NEVER touches the invoking user's real HOME. It
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

# --- mode ---------------------------------------------------------------------
mode="${INSTALL_SMOKE_MODE:-sandbox}"
case "$mode" in
  sandbox|sudo) ;;
  *) die "unknown INSTALL_SMOKE_MODE '$mode' (want 'sandbox' or 'sudo')" ;;
esac

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
  # Second, independent check, and it is about the SANDBOX env specifically, so
  # it applies to sandbox mode only. Under sudo there is no sandbox env to
  # check: install.sh runs as root, and on linux do_uninstall does not invoke
  # systemctl at all when service_user is set (install.sh:1101-1102 only PRINTS
  # the stop advice), so the first check above is the whole defence there.
  if [ "$mode" != "sandbox" ]; then
    ok "sudo mode: no sandbox env to probe (linux uninstall defers the stop to the user's own session, install.sh:1101-1102)"
    return 0
  fi
  # The same one the Python suite makes before its own destructive runs: the env
  # this script will actually hand to install.sh must not resolve to ANY user
  # bus. A verdict of active OR inactive means it reached one.
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
cleanup() {
  exit_status=$?
  trap - EXIT
  set +e
  if [ "${openssl_runner_state_saved:-false}" = true ] && declare -F restore_runner_openssl >/dev/null; then
    restore_runner_openssl
    restore_status=$?
    if [ "$exit_status" -eq 0 ] && [ "$restore_status" -ne 0 ]; then
      exit_status=$restore_status
    fi
  fi
  rm -rf "$sandbox"
  exit "$exit_status"
}
trap cleanup EXIT
real_home="$HOME"
# Captured BEFORE the overrides so assert_no_live_bridge can ask the real
# session whether a bridge is running. See the note there.
real_xdg_runtime_dir="${XDG_RUNTIME_DIR:-}"
real_dbus_address="${DBUS_SESSION_BUS_ADDRESS:-}"
binaries="heimdall ham-bridge ham-pty-host ham-ctl"

# Sandbox mode redirects HOME and everything keyed to it. Sudo mode MUST NOT:
# the branch it tests resolves the home from dscl/getent, so overriding HOME
# here would change nothing about where install.sh writes while making this
# script's own assertions look at the wrong place.
if [ "$mode" = "sandbox" ]; then
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
fi

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

printf 'installer smoke [%s mode]: %s (%s/%s), target %s\n' "$mode" "$uname_s" "$os" "$arch" "$target"
if [ "$mode" = "sandbox" ]; then
  printf 'sandbox HOME: %s\n' "$HOME"
else
  printf 'REAL HOME (sudo mode does not sandbox it): %s\n' "$real_home"
fi
printf 'pinned release for URL assertions: %s\n' "$pin_version"
printf 'bash: %s\n' "$(bash --version | head -n 1)"
# Printed on every run because it is the evidence behind a filed divergence:
# install.sh's download_failed advises "set TMPDIR to a larger filesystem", which
# is only true where mktemp -d actually HONOURS TMPDIR. These two lines say
# whether it does on this host.
probe_tmpdir="$sandbox/tmpdir-probe"
mkdir -p "$probe_tmpdir"
printf 'TMPDIR=%s\n' "${TMPDIR:-(unset)}"
printf 'mktemp -d with TMPDIR=%s gives: %s\n' \
  "$probe_tmpdir" "$(TMPDIR="$probe_tmpdir" mktemp -d)"

# =============================================================================
# SUDO MODE (REQ-INST-18)
# =============================================================================
# Everything below runs only for INSTALL_SMOKE_MODE=sudo and proves the ONE
# branch of install.sh that had never executed on any platform: the
# sudo/SUDO_USER block at install.sh:1241-1267, whose macOS half resolves the
# invoking user's home with `dscl` (:1258-1259) where Linux uses `getent`
# (:1252).
#
# WHY THIS MODE CANNOT BE SANDBOXED, and why that is a property of install.sh
# rather than a shortcut here: when euid is 0 the installer HARDCODES
# install_dir=/usr/local/bin (:1245) and takes service_home from
# dscl/getent -- i.e. the invoking user's REAL home. Neither is influenced by
# HOME, TMPDIR or any other variable this script could set. A sudo run
# therefore writes to the real /usr/local/bin and a real home BY CONSTRUCTION.
# Pretending to isolate it would produce a guard that looks protective and
# is not, so the isolation here is a hard PRECONDITION instead: the mode
# refuses to start unless it is explicitly opted into AND the machine is
# already clean of a heimdall install it could clobber.
#
# And a POST-condition, which is the other half: a precondition only proves we
# started clean. After the run we assert that nothing was left anywhere except
# the paths we expect -- no unit or plist under any home but the invoking
# user's, and nothing at all in root's home. That check exists because the
# opposite already happened on this chain: a test run wrote a real install into
# a live HOME and its stray user unit silently shadowed the production one.
#
# The two REFUSALS are asserted SEPARATELY and deliberately, because they are
# different code paths and only one of them reaches dscl:
#   R1 (:1247-1249) SUDO_USER unset, or literally "root" -- fires BEFORE the
#      `[ "$os" = "linux" ]` test, so it never reaches dscl at all.
#   R2 (:1261-1263) SUDO_USER set and plausible, but dscl/getent yields no home
#      -- the ONLY path that executes dscl on a FAILING lookup.
# Asserting only "SUDO_USER unset" would leave dscl's failure path unexecuted
# while appearing to cover the refusal.

# Owner of a path, portably: BSD stat on darwin, GNU stat on linux. The whole
# point of several assertions below is WHO owns a file, so this must not
# silently return nothing -- an empty answer would make `=` comparisons against
# it pass or fail for the wrong reason.
file_owner() { # <path>
  owner=""
  if [ "$os" = "darwin" ]; then
    owner="$(stat -f '%Su' "$1" 2>/dev/null || true)"
  else
    owner="$(stat -c '%U' "$1" 2>/dev/null || true)"
  fi
  [ -n "$owner" ] || die "could not read the owner of $1 (stat failed); an ownership assertion cannot be evaluated"
  printf '%s\n' "$owner"
}

assert_owner() { # <path> <expected-user> <label>
  got="$(file_owner "$1")"
  if [ "$got" != "$2" ]; then
    die "$3: $1 is owned by '$got', expected '$2'"
  fi
  ok "$3 ($1 owned by $2)"
}

assert_not_owner() { # <path> <forbidden-user> <label>
  got="$(file_owner "$1")"
  if [ "$got" = "$2" ]; then
    die "$3: $1 is owned by '$2' — this is the split-ownership outcome REQ-INST-3 exists to prevent"
  fi
  ok "$3 ($1 is NOT owned by $2; owner is $got)"
}

# Every home directory known to this machine, so the post-condition can look
# for stray installs in homes we never named. Root's homes are appended
# unconditionally: install.sh's own refusal message says "/root", but on darwin
# root's home is /var/root, and a check that trusted the message would look in
# the wrong place on the very platform this task is about.
all_home_dirs() {
  if [ "$os" = "darwin" ]; then
    dscl . -list /Users NFSHomeDirectory 2>/dev/null | awk 'NF >= 2 {print $2}' || true
  else
    getent passwd 2>/dev/null | cut -d: -f6 || true
  fi
  printf '%s\n' /var/root /root
}

# The four names install.sh writes to $install_dir, plus the service file and
# the enrollment dir, checked under one home. Used by both the precondition
# (nothing to clobber) and the post-condition (nothing left behind).
heimdall_traces_under_home() { # <home>
  h="$1"
  for rel in \
    "Library/LaunchAgents/works.earendil.heimdall-bridge.plist" \
    ".config/systemd/user/heimdall-bridge.service" \
    ".local/bin/heimdall" ".local/bin/ham-bridge" \
    ".local/bin/ham-pty-host" ".local/bin/ham-ctl"; do
    if [ -e "$h/$rel" ]; then printf '%s\n' "$h/$rel"; fi
  done
}

sudo_install_dir="/usr/local/bin"

# install.sh once wrote a BUNDLED openssl into $install_dir unconditionally
# (no existence check, no backup), then recorded ITS OWN copy's checksum as
# provenance, so a later --uninstall deleted a pre-existing host openssl on
# the strength of that self-created record. Under sudo $install_dir is the
# SHARED /usr/local/bin, so on a host that already had an openssl there -- an
# Intel Mac with Homebrew is the ordinary case -- `curl | sudo bash` followed
# by --uninstall removed the host's openssl.
# REQ-INST-21 retired that machinery: current install.sh neither writes nor
# removes an openssl by any route, and heimdall update leaves one untouched.
# This mode keeps the guard as the regression detector for exactly that
# defect: the shared openssl is snapshotted before install, any divergence
# FAILS the smoke test, and the runner's original state is restored before the
# process exits.
openssl_path="$sudo_install_dir/openssl"
openssl_pre_existed=false
openssl_pre_sha=""
openssl_runner_state_saved=false
openssl_runner_pre_existed=false
sha_of() { # <path>; empty when it cannot be hashed
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  fi
}
remove_current_openssl_entry() {
  if [ -d "$openssl_path" ] && [ ! -L "$openssl_path" ]; then
    sudo -n rm -rf "$openssl_path" || {
      printf 'REGRESSION CLEANUP ERROR: could not remove replacement directory %s\n' "$openssl_path" >&2
      return 1
    }
  elif [ -e "$openssl_path" ] || [ -L "$openssl_path" ]; then
    sudo -n rm -f "$openssl_path" || {
      printf 'REGRESSION CLEANUP ERROR: could not unlink replacement entry %s\n' "$openssl_path" >&2
      return 1
    }
  fi
  if [ -e "$openssl_path" ] || [ -L "$openssl_path" ]; then
    printf 'REGRESSION CLEANUP ERROR: replacement entry still exists at %s\n' "$openssl_path" >&2
    return 1
  fi
}
snapshot_shared_openssl() {
  if [ -e "$openssl_path" ]; then
    openssl_pre_existed=true
    openssl_pre_sha="$(sha_of "$openssl_path")"
    cp -p "$openssl_path" "$sandbox/openssl-before" 2>/dev/null \
      || die "$openssl_path exists but could not be copied for safekeeping; refusing to run a mode that would overwrite it"
    ok "snapshotted the pre-existing $openssl_path (sha ${openssl_pre_sha:-unknown}) so it can be restored"
  else
    ok "no pre-existing $openssl_path on this host; the guard will verify install.sh does not create one"
  fi
}
seed_shared_openssl_for_ci() {
  if [ "${INSTALL_SMOKE_SUDO_SEED_OPENSSL:-}" != "1" ]; then
    snapshot_shared_openssl
    return 0
  fi

  seed_file="$sandbox/openssl-ci-seed"
  printf '#!/bin/sh\nprintf "heimdall installer smoke openssl sentinel\\n"\n' >"$seed_file"
  chmod 0755 "$seed_file"
  if [ -e "$openssl_path" ] || [ -L "$openssl_path" ]; then
    openssl_runner_pre_existed=true
    sudo -n cp -Pp "$openssl_path" "$sandbox/openssl-runner-before" \
      || die "$openssl_path exists but its original state could not be preserved before seeding"
    ok "preserved the runner's original $openssl_path before seeding"
  else
    ok "the runner arrived without $openssl_path"
  fi
  openssl_runner_state_saved=true
  remove_current_openssl_entry \
    || die "could not clear $openssl_path before installing the CI seed"
  sudo -n install -m 0755 "$seed_file" "$openssl_path" \
    || die "could not seed $openssl_path for the sudo byte-identity assertion"
  ok "seeded distinguishable pre-existing $openssl_path for the sudo cycle"
  snapshot_shared_openssl
  cmp -s "$seed_file" "$sandbox/openssl-before" \
    || die "the pre-install $openssl_path snapshot does not contain the CI seed bytes"
}
report_shared_openssl() {
  if ! "$openssl_pre_existed"; then
    if [ -e "$openssl_path" ] || [ -L "$openssl_path" ]; then
      printf '\nREGRESSION (REQ-INST-21): %s did not pre-exist but was CREATED during install+uninstall.\n' "$openssl_path" >&2
      return 1
    fi
    ok "$openssl_path remains absent after install+uninstall"
    ok "shared openssl absence verified (REQ-INST-21)"
    return 0
  fi
  if [ ! -e "$openssl_path" ] && [ ! -L "$openssl_path" ]; then
    printf '\nREGRESSION (REQ-INST-21): %s pre-existed and is now GONE after install+uninstall.\n' "$openssl_path" >&2
    return 1
  fi
  if cmp -s "$sandbox/openssl-before" "$openssl_path"; then
    now_sha="$(sha_of "$openssl_path")"
    ok "$openssl_path remains byte-identical after install+uninstall (sha ${now_sha:-unknown})"
    ok "shared openssl byte identity verified (REQ-INST-21)"
    return 0
  else
    cmp_status=$?
  fi
  now_sha="$(sha_of "$openssl_path")"
  if [ "$cmp_status" -eq 1 ]; then
    printf '\nREGRESSION (REQ-INST-21):\n  %s was REPLACED during install+uninstall.\n  before: %s\n  after:  %s\n  install.sh must not write or remove a shared openssl by any route.\n' \
      "$openssl_path" "${openssl_pre_sha:-unknown}" "${now_sha:-unknown}" >&2
  else
    printf '\nREGRESSION (REQ-INST-21): %s could not be compared with its pre-install snapshot (cmp exit %s).\n' \
      "$openssl_path" "$cmp_status" >&2
  fi
  return 1
}
restore_shared_openssl() {
  if ! "$openssl_pre_existed"; then
    if [ -e "$openssl_path" ] || [ -L "$openssl_path" ]; then
      remove_current_openssl_entry || return 1
      ok "removed $openssl_path, which this run introduced"
    fi
    return 0
  fi
  if [ -f "$openssl_path" ] && [ ! -L "$openssl_path" ] \
      && cmp -s "$sandbox/openssl-before" "$openssl_path"; then
    ok "$openssl_path needs no pre-install restoration"
    return 0
  fi
  remove_current_openssl_entry || return 1
  sudo -n cp -p "$sandbox/openssl-before" "$openssl_path" || {
    printf 'REGRESSION CLEANUP ERROR: could not recreate the saved pre-install %s\n' "$openssl_path" >&2
    return 1
  }
  if [ ! -f "$openssl_path" ] || [ -L "$openssl_path" ] \
      || ! cmp -s "$sandbox/openssl-before" "$openssl_path"; then
    printf 'REGRESSION CLEANUP ERROR: recreated %s does not match its pre-install snapshot\n' "$openssl_path" >&2
    return 1
  fi
  ok "restored the pre-install $openssl_path this run had replaced"
}
restore_runner_openssl() {
  [ "$openssl_runner_state_saved" = true ] || return 0
  remove_current_openssl_entry || return 1
  if "$openssl_runner_pre_existed"; then
    sudo -n cp -Pp "$sandbox/openssl-runner-before" "$openssl_path" || {
      printf 'REGRESSION CLEANUP ERROR: could not restore the runner original %s\n' "$openssl_path" >&2
      return 1
    }
    if [ -L "$sandbox/openssl-runner-before" ]; then
      if [ ! -L "$openssl_path" ] \
          || [ "$(readlink "$sandbox/openssl-runner-before")" != "$(readlink "$openssl_path")" ]; then
        printf 'REGRESSION CLEANUP ERROR: restored %s does not match the runner original symlink\n' "$openssl_path" >&2
        return 1
      fi
    elif [ ! -f "$openssl_path" ] || [ -L "$openssl_path" ] \
        || ! sudo -n cmp -s "$sandbox/openssl-runner-before" "$openssl_path"; then
      printf 'REGRESSION CLEANUP ERROR: restored %s does not match the runner original bytes\n' "$openssl_path" >&2
      return 1
    fi
  elif [ -e "$openssl_path" ] || [ -L "$openssl_path" ]; then
    printf 'REGRESSION CLEANUP ERROR: %s still exists although the runner arrived without it\n' "$openssl_path" >&2
    return 1
  fi
  openssl_runner_state_saved=false
  ok "restored the runner's original openssl state after the seeded sudo cycle"
}

# --- the invoking user, resolved WITHOUT asking install.sh ---------------------
# These are the independent values every dscl assertion is compared against. If
# they came from the installer's own output the test would be comparing the
# installer to itself.
inv_user="$(id -un)"
inv_uid="$(id -u)"
inv_home="$real_home"

sudo_preconditions() {
  step "sudo mode preconditions (REQ-INST-13: refuse rather than isolate)"

  # 1. Explicit opt-in. This mode makes real writes to /usr/local/bin and a real
  #    home, so it must never be reachable by running the script the ordinary
  #    way. CI sets this; a developer has to mean it.
  if [ "${INSTALL_SMOKE_SUDO_ALLOW_REAL_WRITES:-}" != "1" ]; then
    die "sudo mode makes REAL writes to $sudo_install_dir and to $inv_home (it cannot be sandboxed: uid 0 hardcodes install_dir at install.sh:1245 and takes the home from dscl/getent). Refusing to run without INSTALL_SMOKE_SUDO_ALLOW_REAL_WRITES=1. This is intended for a disposable CI runner, NOT a developer machine or any host with a live bridge."
  fi
  ok "explicit opt-in present (INSTALL_SMOKE_SUDO_ALLOW_REAL_WRITES=1)"

  # 2. We must NOT already be root: the whole branch under test is reached via
  #    sudo, and SUDO_USER has to name a real invoking user.
  if [ "$inv_uid" -eq 0 ]; then
    die "run this mode as a NORMAL user — it invokes sudo itself. Running it as root would leave SUDO_USER naming root (or unset), which install.sh:1247-1249 refuses, so the install half of this mode could never execute."
  fi
  ok "running as a non-root user ($inv_user, uid $inv_uid) that sudo can name in SUDO_USER"

  # 3. Passwordless sudo, asserted rather than discovered halfway through. `-n`
  #    never prompts, so this cannot hang a CI job waiting on a tty.
  command -v sudo >/dev/null 2>&1 || die "sudo is not on PATH; this mode has nothing to test"
  sudo -n true 2>/dev/null || die "sudo requires a password on this host (sudo -n failed). This mode needs passwordless sudo, which the GitHub-hosted runners provide."
  ok "passwordless sudo available (sudo -n true succeeded)"

  # 4. The invoking user's home must be real and must not be root's. If $HOME
  #    disagreed with the account's actual home, every dscl comparison below
  #    would be meaningless.
  [ -d "$inv_home" ] || die "the invoking user's home '$inv_home' is not a directory"
  case "$inv_home" in
    /var/root|/root) die "the invoking user's home is root's home ($inv_home); this mode cannot distinguish the user's files from root's" ;;
  esac
  ok "invoking home is a real, non-root directory: $inv_home"

  # 5. NOTHING TO CLOBBER. This is the check that makes the mode safe to add at
  #    all: if a heimdall install already exists anywhere this run would write,
  #    stop -- because the --uninstall step at the end would then delete
  #    somebody's real install and the "removed it" assertions would pass while
  #    doing damage.
  for b in $binaries; do
    if [ -e "$sudo_install_dir/$b" ]; then
      die "$sudo_install_dir/$b already exists. This mode's --uninstall step would DELETE it, and the assertions would report success. Refusing to run against a host that already has a heimdall install."
    fi
  done
  ok "no heimdall binaries in $sudo_install_dir to clobber"
  if [ -e "$sudo_install_dir/.heimdall-openssl.sha256" ]; then
    die "$sudo_install_dir/.heimdall-openssl.sha256 exists, so a previous install recorded a bundled openssl here. Refusing to run."
  fi
  ok "no bundled-openssl provenance record in $sudo_install_dir"
  pre_existing=""
  while IFS= read -r trace; do
    [ -n "$trace" ] || continue
    pre_existing="$pre_existing$trace
"
  done <<EOF
$(heimdall_traces_under_home "$inv_home")
EOF
  if [ -n "$pre_existing" ]; then
    die "the invoking user's home already carries a heimdall install:
$pre_existing Refusing to run: --uninstall would remove it."
  fi
  ok "no heimdall service file or binaries under $inv_home to clobber"

  # 6. And the live-bridge precondition, which is assert_no_live_bridge's job
  #    and has already run before this function. Restated here only so the log
  #    makes the ordering unambiguous to the next reader.
  ok "live-bridge precondition already passed above (assert_no_live_bridge, unweakened)"

  # 7. CI seeds a distinguishable shared openssl before the installer runs so
  #    the sudo job must execute the byte-identity branch, not merely observe
  #    that the runner happened to arrive without this path.
  seed_shared_openssl_for_ci
}

# --- the rc files we are allowed to touch, and their state BEFORE the run -----
# install.sh picks rc files from the TARGET user's shell, so the set is not
# knowable in advance; all five candidates are tracked. Snapshotting which ones
# existed is what lets the cleanup put the runner back as it was rather than
# leaving a file install.sh created.
inv_rc_files="$inv_home/.bashrc $inv_home/.zshrc $inv_home/.bash_profile $inv_home/.zprofile $inv_home/.profile"
rc_existed_before=""
snapshot_rc_state() {
  for rc in $inv_rc_files; do
    if [ -e "$rc" ]; then
      rc_existed_before="$rc_existed_before$rc
"
      cp -p "$rc" "$sandbox/rc-before-$(basename "$rc")"
    fi
  done
}
rc_pre_existed() { # <path>
  case "
$rc_existed_before" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

# Root's rc files must never gain the installer's PATH line. Checked by content
# (the marker install.sh writes) rather than by mtime, so a pre-existing root rc
# file is not mistaken for a write of ours.
assert_root_rc_untouched() { # <label>
  for rhome in /var/root /root; do
    [ -d "$rhome" ] || continue
    for rc in "$rhome/.bashrc" "$rhome/.zshrc" "$rhome/.bash_profile" "$rhome/.zprofile" "$rhome/.profile" \
              "$rhome/.config/fish/config.fish"; do
      [ -f "$rc" ] || continue
      if sudo -n grep -Fq "# Added by heimdall install.sh" "$rc" 2>/dev/null; then
        die "$1: $rc carries the installer's PATH marker. REQ-INST-3 requires the PATH lines to be written for the INVOKING user, never for root."
      fi
      if sudo -n grep -Fq "export PATH=\"$sudo_install_dir:\$PATH\"" "$rc" 2>/dev/null; then
        die "$1: $rc carries the heimdall PATH line. It must go to $inv_user's rc file, not root's."
      fi
    done
  done
  ok "$1"
}

# Nothing under root's home, on either platform's spelling of it.
assert_root_home_clean() { # <label>
  for rhome in /var/root /root; do
    [ -d "$rhome" ] || continue
    while IFS= read -r trace; do
      [ -n "$trace" ] || continue
      die "$1: found $trace — a sudo install must never write into root's home (install.sh:1248 exists to prevent exactly this)."
    done <<EOF
$(heimdall_traces_under_home "$rhome")
EOF
  done
  ok "$1"
}

# No heimdall binary in the shared install dir.
assert_sudo_install_dir_empty() { # <label>
  for b in $binaries; do
    if [ -e "$sudo_install_dir/$b" ]; then
      die "$1: $sudo_install_dir/$b exists"
    fi
  done
  ok "$1"
}

# Runs install.sh through sudo. PATH is carried over deliberately: sudo's
# secure_path would otherwise drop the socat the workflow installed (Homebrew's
# prefix is not on root's secure_path), and REQ-INST-14 makes every install step
# fatal without it -- the run would fail for a reason that has nothing to do
# with the branch under test.
# `env` options must precede its assignments, so the caller's env-spec comes
# first: `env -u SUDO_USER PATH=... bash` is valid, `env PATH=... -u SUDO_USER`
# would treat -u as the command name.
run_sudo_installer() { # <expected-exit-code> [env-spec...] -- <installer args...>
  expected="$1"; shift
  envargs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envargs+=("$1"); shift; done
  [ "${1:-}" = "--" ] || die "run_sudo_installer: env-spec must be terminated with --"
  shift
  set +e
  out="$(sudo -n env ${envargs[@]+"${envargs[@]}"} "PATH=$PATH" bash "$install_sh" "$@" 2>&1)"
  code=$?
  set -e
  if [ "$code" != "$expected" ]; then
    printf 'FAIL sudo env %s install.sh %s exited %s, expected %s\n--- output ---\n%s\n' \
      "${envargs[*]:-}" "$*" "$code" "$expected" "$out" >&2
    exit 1
  fi
  ok "sudo env ${envargs[*]:-} install.sh $* exited $expected"
}

sudo_smoke() {
  sudo_preconditions
  snapshot_rc_state

  if [ "$os" = "darwin" ]; then
    service_dir="$inv_home/Library/LaunchAgents"
    service_file="$service_dir/works.earendil.heimdall-bridge.plist"
  else
    service_dir="$inv_home/.config/systemd/user"
    service_file="$service_dir/heimdall-bridge.service"
  fi
  config_dir="$inv_home/.config/heimdall"

  # -------------------------------------------------------------------------
  # 1. R1: SUDO_USER unset -> refused before dscl is ever reached.
  # -------------------------------------------------------------------------
  # `env -u SUDO_USER` removes the variable sudo itself sets. This is the shape
  # of a root shell that was not reached through sudo at all -- a cron job, or
  # `su -`. Both refusals precede the socat preflight (:1334-1342) and any
  # download, so this needs neither socat nor network and must write nothing.
  step "R1 SUDO_USER unset: refused, and nothing written (install.sh:1247-1249)"
  run_sudo_installer 1 -u SUDO_USER -- --version "$pin_version"
  assert_contains "refuses to run as root" "refusing to run as root" "$out"
  assert_contains "names SUDO_USER as unset" "SUDO_USER is 'unset'" "$out"
  assert_contains "explains the consequence it is avoiding" "/root where no user session exists" "$out"
  assert_contains "offers the working alternative" "Re-run without sudo" "$out"
  assert_absent "never reached the socat preflight" "socat is not installed" "$out"
  assert_absent "never reached a download" "downloading https://" "$out"
  assert_sudo_install_dir_empty "R1-unset wrote no binaries to $sudo_install_dir"
  assert_root_home_clean "R1-unset wrote nothing into root's home"
  assert_gone "$service_file" "R1-unset wrote no service file for the invoking user"

  # -------------------------------------------------------------------------
  # 2. R1: SUDO_USER=root -> refused. Same refusal, different trigger.
  # -------------------------------------------------------------------------
  # `sudo -u root sudo ...` would produce this naturally; injecting it is the
  # same condition without depending on a nested-sudo policy.
  step "R1 SUDO_USER=root: refused, and nothing written (install.sh:1247-1249)"
  run_sudo_installer 1 SUDO_USER=root -- --version "$pin_version"
  assert_contains "refuses to run as root" "refusing to run as root" "$out"
  assert_contains "names root as the resolved SUDO_USER" "SUDO_USER is 'root'" "$out"
  assert_absent "never reached a download" "downloading https://" "$out"
  assert_sudo_install_dir_empty "R1-root wrote no binaries to $sudo_install_dir"
  assert_root_home_clean "R1-root wrote nothing into root's home"

  # -------------------------------------------------------------------------
  # 3. R2: SUDO_USER names a user that does not exist.
  # -------------------------------------------------------------------------
  # THIS is the one that executes dscl (darwin) / getent (linux) on a FAILING
  # lookup -- the only assertion on this chain that does. R1 above fires two
  # lines earlier and never reaches it, which is why these are separate steps
  # rather than one "refusal" test.
  step "R2 SUDO_USER is a nonexistent user: dscl/getent lookup FAILS and the install is refused (install.sh:1261-1263)"
  ghost_user="heimdall-no-such-user-t16"
  # Assert the user really is absent, so a pass here cannot be an accident of
  # the name happening to exist on some future runner image.
  if [ "$os" = "darwin" ]; then
    if dscl . -read "/Users/$ghost_user" NFSHomeDirectory >/dev/null 2>&1; then
      die "the supposedly nonexistent user '$ghost_user' resolves on this host; pick another name"
    fi
    ok "dscl confirms '$ghost_user' does not exist on this host"
  else
    if getent passwd "$ghost_user" >/dev/null 2>&1; then
      die "the supposedly nonexistent user '$ghost_user' resolves on this host; pick another name"
    fi
    ok "getent confirms '$ghost_user' does not exist on this host"
  fi
  run_sudo_installer 1 "SUDO_USER=$ghost_user" -- --version "$pin_version"
  assert_contains "refused on an unresolvable home" "could not resolve the home directory of SUDO_USER" "$out"
  assert_contains "names the user it could not resolve" "$ghost_user" "$out"
  assert_contains "reports that the lookup returned nothing" "(got 'nothing')" "$out"
  assert_absent "did NOT fall through to the root refusal" "refusing to run as root" "$out"
  assert_absent "never reached a download" "downloading https://" "$out"
  assert_sudo_install_dir_empty "R2 wrote no binaries to $sudo_install_dir"
  assert_root_home_clean "R2 wrote nothing into root's home"
  if [ -e "$inv_home/$ghost_user" ] || [ -e "/Users/$ghost_user" ] || [ -e "/home/$ghost_user" ]; then
    die "R2 created a home directory for the nonexistent user"
  fi
  ok "R2 created no home directory for the nonexistent user"

  # -------------------------------------------------------------------------
  # 4. dscl POSITIVE, cross-checked both ways, with zero side effects.
  # -------------------------------------------------------------------------
  # First ask the directory service ourselves, then make install.sh resolve it
  # under --dry-run and assert its answer equals ours. Neither value is derived
  # from the other, so this cannot pass by comparing the installer to itself --
  # which is the failure mode of asserting a path the installer printed.
  step "dscl/getent resolves the invoking user's home to the same path \$HOME reports"
  if [ "$os" = "darwin" ]; then
    resolved_home="$(dscl . -read "/Users/$inv_user" NFSHomeDirectory 2>/dev/null | cut -d' ' -f2- || true)"
    lookup_tool="dscl"
  else
    resolved_home="$(getent passwd "$inv_user" 2>/dev/null | cut -d: -f6 || true)"
    lookup_tool="getent"
  fi
  [ -n "$resolved_home" ] || die "$lookup_tool returned no home directory for '$inv_user'"
  if [ "$resolved_home" != "$inv_home" ]; then
    die "$lookup_tool says $inv_user's home is '$resolved_home' but \$HOME is '$inv_home'. install.sh:1258 would write the service file and PATH lines to the former."
  fi
  ok "$lookup_tool agrees with \$HOME for $inv_user: $resolved_home"

  step "--dry-run under sudo: install.sh's OWN resolution matches, and writes nothing"
  run_sudo_installer 0 -- --dry-run --version "$pin_version"
  dryrun_out="$out"
  assert_contains "announces the sudo split and the home IT resolved" \
    "sudo detected: binaries go to $sudo_install_dir; the service file and PATH lines will be written for user $inv_user (home: $inv_home)" \
    "$dryrun_out"
  assert_contains "would install to the shared dir, not a home" "to $sudo_install_dir" "$dryrun_out"
  assert_contains "names the service file under the INVOKING user's home" \
    "would write service file $service_file" "$dryrun_out"
  assert_contains "decides PATH from the user's rc files, not the sudo PATH" \
    "decided from $inv_user's rc files, not the sudo PATH" "$dryrun_out"
  if [ "$os" = "darwin" ]; then
    assert_contains "previews a launchd plist" "<!DOCTYPE plist" "$dryrun_out"
    assert_absent "no systemd unit on darwin" "[Unit]" "$dryrun_out"
  else
    assert_contains "previews a systemd unit" "[Unit]" "$dryrun_out"
    assert_absent "no launchd plist on linux" "<!DOCTYPE plist" "$dryrun_out"
  fi
  # A dry run that wrote something would invalidate every later assertion.
  assert_sudo_install_dir_empty "--dry-run wrote no binaries"
  assert_gone "$service_file" "--dry-run wrote no service file"
  assert_root_home_clean "--dry-run wrote nothing into root's home"
  assert_root_rc_untouched "--dry-run touched no rc file of root's"

  # -------------------------------------------------------------------------
  # 5. THE REAL SUDO INSTALL.
  # -------------------------------------------------------------------------
  step "real sudo install: binaries in $sudo_install_dir, service file owned by $inv_user"
  run_sudo_installer 0 -- --version "$pin_version"
  install_out="$out"
  assert_contains "downloaded a tarball" \
    "downloading https://github.com/tanmayv/heimdall-agent-manager/releases/download/" "$install_out"
  assert_contains "verified the checksum BEFORE extracting" "checksum verified" "$install_out"

  # 5a. Binaries: in the shared dir, executable, and ROOT-owned. Root ownership
  #     is the correct outcome, not an oversight: /usr/local/bin is a
  #     system-wide location and take_ownership (install.sh:938-946) is applied
  #     to the service file, its directory and the rc files -- never to the
  #     binaries. Asserting it pins the intended split rather than leaving the
  #     question open.
  for b in $binaries; do
    assert_file "$sudo_install_dir/$b" "installed $b to the shared dir"
    [ -x "$sudo_install_dir/$b" ] || die "$sudo_install_dir/$b is not executable"
    assert_owner "$sudo_install_dir/$b" "root" "binary stays root-owned in the shared dir"
  done
  ok "all four binaries are mode +x in $sudo_install_dir"

  # 5b. THE CENTRAL ASSERTION of this task: the service file landed under the
  #     INVOKING user's home -- the path dscl resolved -- and belongs to THEM.
  #     A root-owned plist in a user's LaunchAgents is the split-ownership
  #     failure REQ-INST-3 exists to prevent, and it is silent: launchd simply
  #     will not load it for that user.
  assert_file "$service_file" "wrote the service file under $inv_home"
  assert_contains "said where it wrote it" "wrote service file $service_file" "$install_out"
  assert_owner "$service_file" "$inv_user" "service file belongs to the invoking user"
  assert_not_owner "$service_file" "root" "service file is NOT root-owned"
  assert_owner "$service_dir" "$inv_user" "service directory belongs to the invoking user"
  assert_dir "$config_dir" "created the enrollment dir under the invoking user's home"
  assert_owner "$config_dir" "$inv_user" "enrollment dir belongs to the invoking user"

  # 5c. The service file must reference the SHARED binaries, not a home path --
  #     the two halves of the sudo split have to agree with each other.
  if [ "$os" = "darwin" ]; then
    plutil -lint "$service_file" || die "plutil -lint rejected the plist written under sudo"
    ok "plutil -lint accepted $service_file"
    grep -Fq "<string>$sudo_install_dir/ham-bridge</string>" "$service_file" \
      || die "the plist does not exec $sudo_install_dir/ham-bridge (the sudo install dir)"
    ok "plist execs $sudo_install_dir/ham-bridge"
    grep -Fq "<string>works.earendil.heimdall-bridge</string>" "$service_file" \
      || die "plist has the wrong label"
    ok "plist carries the expected label"
    # install.sh documents that it registers but never starts the service. Under
    # sudo this matters more, not less: bootstrapping a job into a user's domain
    # from a root process is exactly the reach REQ-INST-13 forbids.
    if launchctl print "gui/$inv_uid/works.earendil.heimdall-bridge" >/dev/null 2>&1; then
      die "the sudo install BOOTSTRAPPED the launchd job into gui/$inv_uid; it documents that it only writes the plist"
    fi
    ok "sudo install did not load the launchd job into the invoking user's domain"
  else
    grep -Fq "ExecStart=$sudo_install_dir/ham-bridge" "$service_file" \
      || die "the systemd unit does not exec $sudo_install_dir/ham-bridge"
    ok "systemd unit execs $sudo_install_dir/ham-bridge"
  fi

  # 5d. PATH: into the INVOKING user's rc file, owned by them, and NOT root's.
  step "PATH lines go to $inv_user's rc file and never to root's"
  sudo_rc_hit=""
  for rc in $inv_rc_files; do
    [ -f "$rc" ] || continue
    if grep -Fq "export PATH=\"$sudo_install_dir:\$PATH\"" "$rc"; then
      sudo_rc_hit="$rc"
      assert_owner "$rc" "$inv_user" "rc file carrying the PATH line belongs to the invoking user"
    fi
  done
  [ -n "$sudo_rc_hit" ] \
    || die "no rc file under $inv_home carries 'export PATH=\"$sudo_install_dir:\$PATH\"'. Under sudo the PATH decision must come from the target user's rc files (install.sh:1010-1060)."
  ok "PATH line written into $sudo_rc_hit"
  assert_root_rc_untouched "no rc file of root's carries the installer marker or PATH line"
  assert_root_home_clean "the real install wrote nothing into root's home"
  assert_contains "onboarding names the user the service was registered for" \
    "Registered for user: $inv_user (home: $inv_home)" "$install_out"

  # -------------------------------------------------------------------------
  # 6. --uninstall under sudo reverses it.
  # -------------------------------------------------------------------------
  # The sentinel makes "keeps enrollment state" provable: a surviving EMPTY
  # directory could be an accident of ordering, a surviving file with content
  # could not.
  step "sudo --uninstall: reverses the install and keeps $config_dir"
  printf 'sentinel written by installer-smoke sudo mode\n' > "$sandbox/sentinel"
  sudo -n cp "$sandbox/sentinel" "$config_dir/config.toml"
  sudo -n chown "$inv_user:" "$config_dir/config.toml"
  run_sudo_installer 0 -- --uninstall
  uninstall_out="$out"
  assert_contains "reported completion" "uninstall complete" "$uninstall_out"
  for b in $binaries; do
    assert_gone "$sudo_install_dir/$b" "removed $b from the shared dir"
  done
  assert_gone "$service_file" "removed the service file from $inv_home"
  assert_file "$config_dir/config.toml" "KEPT the enrollment sentinel"
  grep -Fq 'sentinel written by installer-smoke sudo mode' "$config_dir/config.toml" \
    || die "the kept config.toml was rewritten"
  assert_contains "said what it kept" "kept enrollment state at $config_dir" "$uninstall_out"
  for rc in $inv_rc_files; do
    [ -f "$rc" ] || continue
    if grep -Fq "# Added by heimdall install.sh" "$rc"; then
      die "$rc still carries the installer marker after sudo --uninstall"
    fi
    if grep -Fq "export PATH=\"$sudo_install_dir:\$PATH\"" "$rc"; then
      die "$rc still carries the heimdall PATH line after sudo --uninstall"
    fi
  done
  ok "no installer marker or PATH line left in any rc file under $inv_home"
  # An rc file install.sh rewrote must keep its owner: `cat > "$rc"` writes
  # through the existing inode precisely so a root-run uninstall does not
  # take ownership of a user's dotfile.
  for rc in $inv_rc_files; do
    [ -f "$rc" ] || continue
    assert_owner "$rc" "$inv_user" "rc file still belongs to the invoking user after a root-run uninstall"
  done

  # 6b. REQ-INST-20: BOTH PLATFORMS DEFER THE STOP TO THE USER'S OWN SESSION.
  #     do_uninstall's stop step is now guarded on service_user on darwin as
  #     well as linux (install.sh:1100-1118), so the one contract its comment
  #     states at :1090-1099 holds on both. Before T18 the darwin branch had no
  #     guard: as root it ran `launchctl bootout gui/$(id -u)/...` with id -u
  #     == 0 -- ROOT's GUI domain, not the invoking user's -- and then reported
  #     "stopped ... (best effort)" anyway, asserting an outcome about the
  #     user's bridge that the command could not have produced (REQ-INST-6).
  #     THE FALSE CLAIM IS ASSERTED ABSENT, not merely the advice asserted
  #     present: a "fix" that printed the advice and STILL ran the bootout
  #     would satisfy the presence check and has to fail this one. And the
  #     printed uid is required to be LITERAL, because resolving it while root
  #     would hand the user gui/0 -- the same defect moved into the message.
  assert_contains "uninstall DEFERS the stop to the invoking user's own session" \
    "service runs as $inv_user — stop it as that user" "$uninstall_out"
  if [ "$os" = "darwin" ]; then
    assert_contains 'the deferred command is the launchd bootout, carrying a LITERAL gui/$(id -u) for them to resolve' \
      'stop it as that user: launchctl bootout gui/$(id -u)/works.earendil.heimdall-bridge' "$uninstall_out"
    assert_absent "does NOT claim it stopped the label (as root the bootout would address gui/0, not gui/$inv_uid)" \
      "stopped works.earendil.heimdall-bridge" "$uninstall_out"
    assert_absent "does not hand the user a uid resolved AS ROOT (gui/0)" \
      "gui/0/works.earendil.heimdall-bridge" "$uninstall_out"
  else
    assert_contains "the deferred command is the systemd user stop" \
      "stop it as that user: systemctl --user stop heimdall-bridge" "$uninstall_out"
    assert_absent "does NOT claim it stopped the service" \
      "stopped heimdall-bridge (best effort)" "$uninstall_out"
  fi

  # -------------------------------------------------------------------------
  # 7. POST-CONDITION: we left the machine clean.
  # -------------------------------------------------------------------------
  # A precondition proves we started clean; only this proves we left clean. It
  # exists because the opposite already happened on this chain -- a test run
  # wrote a real install into a live HOME and its stray user unit silently
  # shadowed the production one for hours. So do not trust that the paths we
  # asserted are the only paths written: sweep EVERY home this machine knows.
  step "post-condition: nothing left outside the paths this run owns"
  assert_sudo_install_dir_empty "no heimdall binary left in $sudo_install_dir"
  if [ -e "$sudo_install_dir/.heimdall-openssl.sha256" ]; then
    die "the openssl provenance record was left behind in $sudo_install_dir"
  fi
  ok "no bundled-openssl provenance record left in $sudo_install_dir"
  assert_root_home_clean "root's home is clean (both /var/root and /root)"
  assert_root_rc_untouched "root's rc files carry no installer line"
  stray=""
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    [ -d "$home" ] || continue
    # The invoking user's home is the one home this run is ENTITLED to write,
    # and its expected residue (the kept enrollment dir) is asserted above.
    [ "$home" != "$inv_home" ] || continue
    while IFS= read -r trace; do
      [ -n "$trace" ] || continue
      stray="$stray$trace
"
    done <<EOF
$(heimdall_traces_under_home "$home")
EOF
  done <<EOF
$(all_home_dirs)
EOF
  if [ -n "$stray" ]; then
    die "this run left heimdall files under a home it does not own:
$stray"
  fi
  ok "no heimdall service file or binary under any home but $inv_home"
  # And in the invoking user's own home, only the deliberately-kept enrollment
  # dir may remain.
  while IFS= read -r trace; do
    [ -n "$trace" ] || continue
    die "the invoking user's home still carries $trace after --uninstall"
  done <<EOF
$(heimdall_traces_under_home "$inv_home")
EOF
  ok "$inv_home carries no service file or binary after --uninstall (only the kept enrollment dir)"

  # -------------------------------------------------------------------------
  # 8. Leave the runner as we found it.
  # -------------------------------------------------------------------------
  # --uninstall deliberately KEEPS ~/.config/heimdall, and rc files install.sh
  # created are not its to remove. Both are correct installer behaviour and
  # both are OUR debris, so this mode removes them itself rather than leaving a
  # runner (or a developer who opted in) subtly changed.
  openssl_guard_failed=false
  if ! report_shared_openssl; then
    openssl_guard_failed=true
  fi

  step "cleanup: remove the residue this mode created, not install.sh's job"
  restore_shared_openssl
  restore_runner_openssl
  sudo -n rm -rf "$config_dir"
  assert_gone "$config_dir" "removed the enrollment dir this run created"
  for rc in $inv_rc_files; do
    [ -f "$rc" ] || continue
    if rc_pre_existed "$rc"; then
      before="$sandbox/rc-before-$(basename "$rc")"
      if [ -f "$before" ] && ! cmp -s "$before" "$rc"; then
        # install.sh's uninstall removes the marker and the PATH line but not
        # the blank line it wrote before them, so a pre-existing rc file comes
        # back one newline longer. Restore the byte-exact original rather than
        # leaving cosmetic residue -- and report it, because it is a real (if
        # minor) install/uninstall asymmetry.
        say_diff="$(diff "$before" "$rc" 2>&1 || true)"
        printf 'note: %s was not restored byte-exactly by --uninstall; restoring the original. Diff:\n%s\n' \
          "$rc" "$say_diff"
        cp -p "$before" "$rc"
      fi
      ok "pre-existing $rc restored to its original bytes"
    else
      rm -f "$rc"
      ok "removed $rc, which install.sh created during this run"
    fi
  done
  if "$openssl_guard_failed"; then
    die "shared openssl preservation failed (REQ-INST-21); runner cleanup was attempted before failing"
  fi
}

assert_no_live_bridge

# Dispatch. Sudo mode is a different install shape, not extra steps on top of
# the sandbox one, so it runs to completion here and the sandbox body below is
# left exactly as it was.
if [ "$mode" = "sudo" ]; then
  sudo_smoke
  printf '\nINSTALLER SUDO SMOKE PASSED on %s/%s (%s assertions)\n' "$os" "$arch" "$pass_count"
  exit 0
fi

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

# --- 4a. release resolution, probed rather than depended on -------------------
# The real install below PINS --version, and that is not laziness: the first run
# of this script on macos-14 died here with
#   "api.github.com rejected the request with HTTP 403: the unauthenticated rate
#    limit (60 requests/hour/IP) is exhausted"
# because hosted macOS runners share egress IPs, so the 60/hour anonymous budget
# is routinely already spent by someone else. A gate whose result depends on
# another tenant's API usage is not a gate.
#
# The resolution path still gets EXECUTED here, as a probe with an exhaustive
# list of acceptable outcomes: it either resolves a tag, or it fails with the
# specific, correct diagnosis. What it must never do is blame the network for a
# rate limit (REQ-INST-6) -- so the probe is strict about WHICH failure, not
# about whether it failed.
step "bare --dry-run: release resolution executes and diagnoses itself honestly"
run_installer 0 --dry-run
resolve_out="$out"
case "$resolve_out" in
  *"release: v"*)
    ok "resolved a release tag from api.github.com on this host" ;;
  *"the unauthenticated rate limit (60 requests/hour/IP) is exhausted"*)
    ok "rate-limited, and said so precisely (shared-IP runner; REQ-INST-6c)" ;;
  *)
    printf 'FAIL bare --dry-run neither resolved a tag nor gave a known-good diagnosis\n--- output ---\n%s\n' "$resolve_out" >&2
    exit 1 ;;
esac
assert_absent "never blamed the network for a non-network failure" \
  "could not reach api.github.com" "$resolve_out"

# --- 4b. the real install -----------------------------------------------------
step "real install (--version $pin_version): exit 0 and every file in place"
run_installer 0 --version "$pin_version"
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
run_installer 0 --version "$pin_version"
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
