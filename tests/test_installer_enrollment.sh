#!/usr/bin/env bash
# tests/test_installer_enrollment.sh
# Automated regression tests for scripts/install.sh onboarding, enrollment,
# bridge startup, client vault encryption, and non-interactive invariants
# (REQ-INST-ENROLL-1 through REQ-INST-ENROLL-6).
#
# ENROLLMENT HERE IS BROWSER-APPROVED (REQ-ENROLL-9, REQ-IMPL-6). The one-time
# `hbe_` token the installer used to prompt for is DELETED, along with
# `heimdall enroll <token>` and `POST /api/v1/bridges/enroll`. The installer now
# shells out to `ham-bridge enroll --ui <origin>`, which prints a link and a short
# code for a human to approve, and receives the credential directly.
#
# This file was INVERTED rather than deleted: its subject is the installer's
# operator story, and that story is a deliverable, not an incidental. So every
# place that used to assert the token ceremony now asserts the device-flow
# ceremony AND asserts the deleted form is ABSENT. The absence half is the half
# that catches a revert or a half-applied merge reintroducing the prompt --- a
# presence-only suite would pass happily with both flows in the file.
#
# Note what a syntax check cannot do for you here: `bash -n` passes on a stale
# string assertion, because the assertion is well-formed and merely false. These
# tests must actually be RUN.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/install.sh"

[ -x "$INSTALLER" ] || { echo "FAIL: $INSTALLER is not executable" >&2; exit 1; }

TMP_DIR="$(mktemp -d /tmp/ham-inst-enroll-test-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Helper to extract functions from install.sh without running main "$@"
extract_installer_lib() {
  local dest="$1"
  sed '/^main "\$@"/d' "$INSTALLER" > "$dest"
}

INSTALLER_LIB="$TMP_DIR/installer_lib.sh"
extract_installer_lib "$INSTALLER_LIB"

# Set up hermetic mock sandbox
MOCK_HOME="$TMP_DIR/mock_home"
MOCK_RUNTIME="$TMP_DIR/xdg-runtime"
MOCK_BIN="$TMP_DIR/mock_bin"
mkdir -p "$MOCK_HOME/.config/heimdall" "$MOCK_RUNTIME" "$MOCK_BIN"

# ============================================================================
# SUITE-LEVEL FAIL-CLOSED SERVICE GUARD (REQ-INST-13, iss_18dc67e1ce0bf31f)
# ============================================================================
#
# WHY THIS EXISTS. On 2026-10-08 this suite restarted the PRODUCTION bridge on a
# developer host TWICE, killing every agent running on it. install.sh's onboarding
# ends in `systemctl --user is-active heimdall-bridge` (install.sh:1387) and, when
# that says active, `systemctl --user restart heimdall-bridge` (:1388). Those are
# the RIGHT commands for a real operator and must not grow a test-only escape
# hatch -- so the isolation is this harness's job.
#
# WHAT WENT WRONG was the SHAPE of the old safety, not any one test. Isolation was
# per-test opt-in: a test was safe if it remembered `PATH="$MOCK_BIN:$PATH"`. Ten
# sites remembered. Four (Tests 4, 5, 6, 7) did not, and a *missing line* is
# invisible to review and undetectable by `bash -n`. Measured with a logging shim,
# those four produced NINE live-bus calls before the suite reached Test 8:
# 3x `daemon-reload`, 4x `is-active heimdall-bridge`, 2x `enable --now heimdall-bridge`.
# Same class of defect as the `== "enforce"` fail-open this task deleted from
# wiring.odin: safety contingent on someone typing the right thing.
#
# SO THE GUARD IS FAIL-CLOSED AND SUITE-WIDE. Two independent layers:
#
#   1. PATH -- a logging, non-acting `systemctl`/`launchctl` shim is prepended
#      here, before any test runs. A test that forgets its own mock gets this
#      instead of the host's binary. Tests that DO install a mock still win:
#      they prepend MOCK_BIN later, so MOCK_BIN resolves first. No test's
#      semantics change.
#   2. ENV -- XDG_RUNTIME_DIR is moved inside TMP_DIR and DBUS_SESSION_BUS_ADDRESS
#      is blanked, so even a call that BYPASSES PATH (an absolute
#      /run/current-system/sw/bin/systemctl, say) cannot reach the live session bus.
#
# Layer 2 is what makes "zero real-bus calls" structural rather than hopeful, and
# `assert_service_guard` below PROVES it by running the host's real systemctl under
# the suite env and requiring it to fail to connect.
GUARD_BIN="$TMP_DIR/guard_bin"
GUARD_LOG="$TMP_DIR/service_guard.log"
mkdir -p "$GUARD_BIN"
: > "$GUARD_LOG"

# Captured BEFORE the shim is on PATH, so the assertion below probes the host's
# real binary rather than our own shim.
REAL_SYSTEMCTL="$(command -v systemctl 2>/dev/null || true)"

for _guard_tool in systemctl launchctl; do
  cat > "$GUARD_BIN/$_guard_tool" <<GUARD_SHIM
#!/usr/bin/env bash
# Fail-closed guard shim. Records the attempt; never touches a real service.
echo "\$(basename "\$0") \$*" >> "$GUARD_LOG"
exit 1
GUARD_SHIM
  chmod +x "$GUARD_BIN/$_guard_tool"
done

export PATH="$GUARD_BIN:$PATH"
export XDG_RUNTIME_DIR="$MOCK_RUNTIME"
export DBUS_SESSION_BUS_ADDRESS=""

# Asserts the guard is actually in force. Called before the first test AND after
# the last one -- a guard verified only at startup is one `export PATH=...` away
# from being silently gone for the rest of the run.
#
# NOTE ON WHAT IS *NOT* ASSERTED, deliberately: not "the shim was never called".
# It IS called -- nine times, by design, and those calls are the guard WORKING.
# Asserting zero invocations would be false and would have to be deleted by the
# next person, which is how vacuous assertions get established. What is asserted
# is the property that actually matters: no call can reach a real bus, because the
# shim intercepts PATH lookups and the env defeats absolute-path bypasses.
assert_service_guard() {
  local phase="$1"

  local resolved
  resolved="$(command -v systemctl 2>/dev/null || true)"
  [ "$resolved" = "$GUARD_BIN/systemctl" ] || {
    echo "FAIL [$phase]: service guard not in force -- systemctl resolves to '$resolved', expected '$GUARD_BIN/systemctl'" >&2
    exit 1
  }

  case "${XDG_RUNTIME_DIR:-}" in
    "$MOCK_RUNTIME") ;;
    /run/user/*)
      echo "FAIL [$phase]: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR is a LIVE session bus directory" >&2
      exit 1 ;;
    *)
      echo "FAIL [$phase]: XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>} is not the suite sandbox $MOCK_RUNTIME" >&2
      exit 1 ;;
  esac

  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || {
    echo "FAIL [$phase]: DBUS_SESSION_BUS_ADDRESS is set ('$DBUS_SESSION_BUS_ADDRESS') -- a second route to the live bus" >&2
    exit 1
  }

  # The substantive half: the HOST's real systemctl, run under this suite's env,
  # must be unable to reach any user bus. This is the check that makes an
  # absolute-path bypass harmless. It fails, never skips, when a bus is reachable.
  if [ -n "$REAL_SYSTEMCTL" ]; then
    local probe
    probe="$("$REAL_SYSTEMCTL" --user is-active heimdall-bridge 2>&1 || true)"
    case "$probe" in
      *"Failed to connect"*|*"Failed to get D-Bus connection"*|*"No such file or directory"*|*"Permission denied"*|*"Argument list too long"*) ;;
      *)
        echo "FAIL [$phase]: the real systemctl REACHED a user bus under the suite env (said: '$probe')." >&2
        echo "  A test that bypasses PATH could restart the production bridge and kill every agent on this host." >&2
        echo "  Fix the sandbox env. Do NOT weaken this guard." >&2
        exit 1 ;;
    esac
  fi
}

assert_service_guard "startup"


# Every mock `ham-bridge` invocation appends its argv here. Asserting on the
# RECORDED ARGV is the only way to prove the installer actually drove the device
# flow: stdout can be made to say anything, but the flags passed to the binary are
# the behaviour under test. It is also how a test proves a NEGATIVE --- that
# enrollment was deliberately skipped, rather than the binary merely being absent.
MOCK_BRIDGE_ARGV="$TMP_DIR/ham_bridge_argv.log"
: > "$MOCK_BRIDGE_ARGV"

reset_mock_home() {
  rm -rf "$MOCK_HOME"
  mkdir -p "$MOCK_HOME/.config/heimdall"
}

# install_mock_ham_bridge [success|fail] --- stand in for `ham-bridge enroll --ui`.
#
# The real binary asks the Hub for a user code, prints a link plus that code and a
# key fingerprint, waits for a human to approve in a browser, and writes the
# returned credential to --bridge-token-file. There is nothing to feed it on stdin,
# which is precisely the point of the change: the deleted flow needed a secret typed
# in, this one needs an approval elsewhere.
#
# `fail` models the approval never happening (nobody opened the link, or it timed
# out) --- a non-zero exit with no credential written.
install_mock_ham_bridge() {
  local outcome="${1:-success}"
  mkdir -p "$MOCK_BIN"
  cat > "$MOCK_BIN/ham-bridge" <<MOCKEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MOCK_BRIDGE_ARGV"
# Refuse anything but the device-flow subcommand, so a regression that reaches for
# a deleted form (\`--enrollment-token\`, a positional token) fails loudly here
# instead of passing against a permissive stub.
[ "\$1" = "enroll" ] || { echo "mock ham-bridge: unexpected subcommand \$1" >&2; exit 64; }
token_file=""
saw_ui=false
while [ \$# -gt 0 ]; do
  case "\$1" in
    --bridge-token-file) token_file="\$2"; shift 2 ;;
    --ui) saw_ui=true; shift 2 ;;
    --enrollment-token) echo "mock ham-bridge: --enrollment-token is deleted" >&2; exit 64 ;;
    *) shift ;;
  esac
done
"\$saw_ui" || { echo "mock ham-bridge: enroll without --ui" >&2; exit 64; }
echo "Open this link on any device to approve:  http://hub.example.test/enroll/device"
echo "User code: WDJB-MJHT"
echo "Key fingerprint: SHA256:mockmockmockmockmockmockmockmockmockmockmoc"
if [ "$outcome" != "success" ]; then
  echo "mock ham-bridge: enrollment was not approved in time" >&2
  exit 1
fi
mkdir -p "\$(dirname "\$token_file")"
echo "hba_btk_mock_device_credential" > "\$token_file"
echo "approved; credential written to \$token_file"
exit 0
MOCKEOF
  chmod +x "$MOCK_BIN/ham-bridge"
}

# assert_no_deleted_enrollment_surface <label> <output> --- the shared absence half.
#
# Asserted on EVERY captured onboarding output, not just the enrollment tests,
# because a reintroduced prompt would most likely surface on a path nobody thought
# to re-check.
assert_no_deleted_enrollment_surface() {
  local label="$1" out="$2"
  if printf '%s' "$out" | grep -q "hbe_"; then
    echo "FAIL: $label still names the deleted one-time token (hbe_): $out" >&2
    exit 1
  fi
  if printf '%s' "$out" | grep -q "Enter one-time enrollment token"; then
    echo "FAIL: $label still prompts for the deleted enrollment token: $out" >&2
    exit 1
  fi
  if printf '%s' "$out" | grep -q "heimdall enroll"; then
    echo "FAIL: $label still names the deleted 'heimdall enroll' command: $out" >&2
    exit 1
  fi
}

# --- Test 1: Non-interactive pipeline / subshell bypass (REQ-INST-ENROLL-5) ---
echo "=== Test 1: Non-interactive pipeline / subshell bypass (REQ-INST-ENROLL-5) ==="
reset_mock_home
T1_OUTPUT="$(
  HOME="$MOCK_HOME" \
  XDG_RUNTIME_DIR="$MOCK_RUNTIME" \
  DBUS_SESSION_BUS_ADDRESS="" \
  bash -c '
    source "'"$INSTALLER_LIB"'"
    dry_run=false
    uninstall=false
    if is_interactive; then
      echo "UNEXPECTED_INTERACTIVE"
    else
      echo "CONFIRMED_NON_INTERACTIVE"
      print_onboarding
    fi
  ' < /dev/null 2>&1
)"

echo "$T1_OUTPUT" | grep -q "CONFIRMED_NON_INTERACTIVE" || {
  echo "FAIL: is_interactive did not recognize non-interactive stdin" >&2
  exit 1
}
# INVERTED (REQ-ENROLL-9): was `grep -q "heimdall enroll hbe_... --hub"`.
# The manual fallback must now hand the operator the device-flow command, and the
# ceremony description, because with no hub url there is nothing else to go on.
echo "$T1_OUTPUT" | grep -q "ham-bridge enroll --ui" || {
  echo "FAIL: print_onboarding did not show the device-flow enroll command: $T1_OUTPUT" >&2
  exit 1
}
echo "$T1_OUTPUT" | grep -q "prints a link and a short code" || {
  echo "FAIL: print_onboarding did not describe the browser-approval ceremony: $T1_OUTPUT" >&2
  exit 1
}
echo "$T1_OUTPUT" | grep -q "NO enrollment token to create" || {
  echo "FAIL: print_onboarding did not state that no enrollment token is needed: $T1_OUTPUT" >&2
  exit 1
}
assert_no_deleted_enrollment_surface "print_onboarding" "$T1_OUTPUT"
echo "PASS: Test 1 passed (Non-interactive subshell/pipe cleanly bypassed)!"

# --- Test 2: Non-interactive environment variables (REQ-INST-ENROLL-5) ---
echo "=== Test 2: Non-interactive environment variables (REQ-INST-ENROLL-5) ==="
bash -c '
  source "'"$INSTALLER_LIB"'"
  dry_run=false
  uninstall=false

  # HEIMDALL_NON_INTERACTIVE=1 must force non-interactive
  HEIMDALL_NON_INTERACTIVE=1 HEIMDALL_INTERACTIVE=1 is_interactive && exit 1

  # DEBIAN_FRONTEND=noninteractive must force non-interactive
  DEBIAN_FRONTEND=noninteractive is_interactive && exit 1

  # HEIMDALL_INTERACTIVE=1 without noninteractive overrides allows interactive
  HEIMDALL_NON_INTERACTIVE=0 HEIMDALL_INTERACTIVE=1 is_interactive || exit 1

  exit 0
' || {
  echo "FAIL: Environment variable override flags failed" >&2
  exit 1
}
echo "PASS: Test 2 passed (Environment flags correctly guard interactivity)!"

# --- Test 3: Dry-run and uninstall non-interactive invariants (REQ-INST-ENROLL-5) ---
echo "=== Test 3: Dry-run and uninstall invariants (REQ-INST-ENROLL-5) ==="
bash -c '
  source "'"$INSTALLER_LIB"'"

  dry_run=true uninstall=false HEIMDALL_FORCE_INTERACTIVE=1 is_interactive && exit 1
  dry_run=false uninstall=true HEIMDALL_FORCE_INTERACTIVE=1 is_interactive && exit 1
  exit 0
' || {
  echo "FAIL: dry_run or uninstall did not force non-interactive state" >&2
  exit 1
}
echo "PASS: Test 3 passed (dry_run and uninstall always non-interactive)!"

# --- Test 4: Hub URL flag --hub and --hub-url normalization (REQ-INST-ENROLL-1) ---
echo "=== Test 4: Hub URL flag normalization and prompt bypass (REQ-INST-ENROLL-1) ==="
reset_mock_home
echo "token_abc" > "$MOCK_HOME/.config/heimdall/bridge-token"

T4_OUTPUT="$(
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false

    hub_url="https://central-hub.example.com///"
    hub_url="${hub_url%/}"
    while [ "${hub_url%/}" != "$hub_url" ]; do hub_url="${hub_url%/}"; done

    # Feed "n" to vault prompt
    run_interactive_onboarding <<EOF
n
EOF
    echo "FINAL_HUB_URL: $hub_url"
  ' 2>&1
)"

echo "$T4_OUTPUT" | grep -q "FINAL_HUB_URL: https://central-hub.example.com" || {
  echo "FAIL: Hub URL trailing slashes were not stripped: $T4_OUTPUT" >&2
  exit 1
}
if echo "$T4_OUTPUT" | grep -q "Enter Hub URL:"; then
  echo "FAIL: Prompted for Hub URL when --hub was already provided" >&2
  exit 1
fi
echo "PASS: Test 4 passed (Hub URL flag handled and slashes normalized)!"

# --- Test 5: Interactive Hub URL prompt and normalization (REQ-INST-ENROLL-1) ---
echo "=== Test 5: Interactive Hub URL prompt (REQ-INST-ENROLL-1) ==="
reset_mock_home

T5_OUTPUT="$(
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false

    hub_url=""
    # Enter URL with leading/trailing spaces and slashes, empty token to exit early
    run_interactive_onboarding <<EOF
  http://prompted-hub.internal:8080/  

EOF
    echo "CAPTURED_HUB_URL: $hub_url"
  ' 2>&1
)"

echo "$T5_OUTPUT" | grep -q "Enter Hub URL:" || {
  echo "FAIL: Expected 'Enter Hub URL:' prompt not found: $T5_OUTPUT" >&2
  exit 1
}
echo "$T5_OUTPUT" | grep -q "CAPTURED_HUB_URL: http://prompted-hub.internal:8080" || {
  echo "FAIL: Prompted Hub URL was not properly cleaned: $T5_OUTPUT" >&2
  exit 1
}
echo "PASS: Test 5 passed (Interactive Hub URL prompt correctly parsed)!"

# --- Test 6: Interactive Hub URL prompt empty input fallback (REQ-INST-ENROLL-1) ---
echo "=== Test 6: Hub URL prompt empty input fallback (REQ-INST-ENROLL-1) ==="
reset_mock_home

T6_OUTPUT="$(
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false

    hub_url=""
    run_interactive_onboarding <<EOF

EOF
  ' 2>&1
)"

echo "$T6_OUTPUT" | grep -q "No Hub URL provided; skipping interactive enrollment." || {
  echo "FAIL: Missing warning when Hub URL is empty: $T6_OUTPUT" >&2
  exit 1
}
# INVERTED (REQ-ENROLL-9): was `grep -q "heimdall enroll hbe_... --hub"`.
echo "$T6_OUTPUT" | grep -q "ham-bridge enroll --ui" || {
  echo "FAIL: Expected device-flow fallback instructions when Hub URL is empty: $T6_OUTPUT" >&2
  exit 1
}
assert_no_deleted_enrollment_surface "empty-hub-url fallback" "$T6_OUTPUT"
echo "PASS: Test 6 passed (Empty Hub URL cleanly falls back to manual steps)!"

# --- Test 7: Bridge token pre-check skips enrollment (REQ-INST-ENROLL-2) ---
echo "=== Test 7: Bridge token pre-check (REQ-INST-ENROLL-2) ==="
reset_mock_home
# A device-flow credential, not an `hbe_` one: `hbe_` tokens no longer exist, and a
# fixture that still looked like one would quietly keep the deleted vocabulary alive
# in the suite that is supposed to prove it is gone.
echo "hba_btk_already_enrolled_sample" > "$MOCK_HOME/.config/heimdall/bridge-token"
# Install a WORKING mock and then assert it was never called. Without the mock
# present, "did not enroll" would be indistinguishable from "could not enroll",
# and the pre-check this test is named for would go unproven.
install_mock_ham_bridge success
: > "$MOCK_BRIDGE_ARGV"

T7_OUTPUT="$(
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false
    hub_url="http://hub.example.test"

    # Send "n" for vault encryption
    run_interactive_onboarding <<EOF
n
EOF
  ' 2>&1
)"

echo "$T7_OUTPUT" | grep -q "Found existing bridge token at .*bridge-token; node is already enrolled." || {
  echo "FAIL: Did not detect existing bridge token: $T7_OUTPUT" >&2
  exit 1
}
assert_no_deleted_enrollment_surface "already-enrolled pre-check" "$T7_OUTPUT"
# The load-bearing assertion: enrollment was SKIPPED, not merely silent.
if [ -s "$MOCK_BRIDGE_ARGV" ]; then
  echo "FAIL: ran ham-bridge enroll despite an existing credential:" >&2
  cat "$MOCK_BRIDGE_ARGV" >&2
  exit 1
fi
echo "PASS: Test 7 passed (Pre-existing bridge token cleanly skips enrollment)!"

# --- Test 8: Browser-approved enrollment ceremony & bridge startup (REQ-INST-ENROLL-3, REQ-ENROLL-9) ---
echo "=== Test 8: Browser-approved enrollment ceremony & bridge startup (REQ-INST-ENROLL-3) ==="
reset_mock_home
: > "$MOCK_BRIDGE_ARGV"
install_mock_ham_bridge success

# Create mock heimdall and systemctl in MOCK_BIN.
#
# The mock's `enroll` branch used to accept a token and write a credential. It now
# FAILS the way the real binary does, so that a regression routing enrollment back
# through `heimdall enroll` shows up as a test failure instead of succeeding against
# a stub that is more permissive than production.
cat <<'EOF' > "$MOCK_BIN/heimdall"
#!/usr/bin/env bash
if [ "$1" = "enroll" ]; then
  echo "heimdall enroll has been replaced by browser-approved enrollment." >&2
  exit 1
elif [ "$1" = "vault" ]; then
  if [ "${2:-}" = "--help" ]; then
    echo "Usage: heimdall vault [options]"
    echo "Commands:"
    echo "  master-password  Set or update master vault password"
    exit 0
  fi
fi
exit 0
EOF
chmod +x "$MOCK_BIN/heimdall"

cat <<'EOF' > "$MOCK_BIN/systemctl"
#!/usr/bin/env bash
if [ "$1" = "--user" ] && [ "$2" = "enable" ] && [ "$3" = "--now" ] && [ "$4" = "heimdall-bridge" ]; then
  echo "mock: bridge service enabled and started"
  exit 0
elif [ "$1" = "--user" ] && [ "$2" = "restart" ] && [ "$3" = "heimdall-bridge" ]; then
  echo "mock: bridge service restarted"
  exit 0
elif [ "$1" = "--user" ] && [ "$2" = "is-active" ] && [ "$3" = "heimdall-bridge" ]; then
  echo "active"
  exit 0
elif [ "$1" = "--user" ] && [ "$2" = "daemon-reload" ]; then
  exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/systemctl"

T8_OUTPUT="$(
  PATH="$MOCK_BIN:$PATH" \
  HOME="$MOCK_HOME" \
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false
    hub_url="http://hub.example.test"

    # Input: vault "n" only. There is NOTHING to type for enrollment any more --
    # that is the whole point of REQ-ENROLL-9, and the shrinking of this heredoc
    # from two lines to one is the clearest statement of it in the suite.
    run_interactive_onboarding <<EOF
n
EOF
  ' 2>&1
)"

# INVERTED (REQ-ENROLL-9): was `grep -q "Enter one-time enrollment token (hbe_...):"`.
# The operator is told what will happen before it happens -- a link, a short code, a
# fingerprint to compare -- because an unexplained code on screen is indistinguishable
# from a phishing prompt.
echo "$T8_OUTPUT" | grep -q "Enrolling node (browser approval required)" || {
  echo "FAIL: Device-flow enrollment banner missing: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_OUTPUT" | grep -q "This machine will print a link and a short code" || {
  echo "FAIL: Browser-approval ceremony not explained to the operator: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_OUTPUT" | grep -q "Nothing secret is copied between machines" || {
  echo "FAIL: Onboarding did not state that no secret is copied: $T8_OUTPUT" >&2
  exit 1
}
# The ceremony the bridge itself prints must reach the operator's terminal, not be
# swallowed by the installer -- an approval code nobody can see cannot be approved.
echo "$T8_OUTPUT" | grep -q "User code: WDJB-MJHT" || {
  echo "FAIL: ham-bridge's user code was not surfaced to the operator: $T8_OUTPUT" >&2
  exit 1
}
# ARGV, not stdout: proof the device flow was actually invoked, with the UI ORIGIN
# (not the hub api url) and the credential destination.
#
# hub_url above is `http://hub.example.test`, and the expected origin here is
# `http://heimdall.example.test` --- NOT a typo. `ui_origin_for_hub`
# (install.sh:1186) relabels a leading `hub.` to `heimdall.`, mirroring the UI's own
# inverse mapping in BridgesPanel, because `--ui` wants the origin a human opens in a
# browser rather than the hub API host. Asserting the un-relabelled hub url here is
# what this assertion did until 2026-10-08, and it was simply wrong: it contradicted
# the sentence directly above it.
grep -q -- "enroll --ui http://heimdall.example.test" "$MOCK_BRIDGE_ARGV" || {
  echo "FAIL: ham-bridge was not invoked as 'enroll --ui <ui-origin>':" >&2
  cat "$MOCK_BRIDGE_ARGV" >&2
  exit 1
}
# The absence half, and the regression this pair actually guards: passing the HUB API
# url to `--ui` would 404 on the authorize call for every `hub.`-prefixed deployment.
# A presence-only assertion cannot catch that, because the relabelled and
# un-relabelled forms are different strings and only one of them is checked.
if grep -q -- "enroll --ui http://hub.example.test" "$MOCK_BRIDGE_ARGV"; then
  echo "FAIL: installer passed the hub API url to --ui instead of the UI origin:" >&2
  cat "$MOCK_BRIDGE_ARGV" >&2
  exit 1
fi
grep -q -- "--bridge-token-file" "$MOCK_BRIDGE_ARGV" || {
  echo "FAIL: ham-bridge enroll was not told where to write the credential:" >&2
  cat "$MOCK_BRIDGE_ARGV" >&2
  exit 1
}
if grep -q -- "--enrollment-token" "$MOCK_BRIDGE_ARGV"; then
  echo "FAIL: installer passed the deleted --enrollment-token flag:" >&2
  cat "$MOCK_BRIDGE_ARGV" >&2
  exit 1
fi
assert_no_deleted_enrollment_surface "enrollment ceremony" "$T8_OUTPUT"
echo "$T8_OUTPUT" | grep -q "Node successfully enrolled." || {
  echo "FAIL: Enrollment success message missing: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_OUTPUT" | grep -qE "Bridge service (started|restarted) via systemctl --user." || {
  echo "FAIL: Bridge service startup missing: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_OUTPUT" | grep -q "Enrollment verified: bridge token is present" || {
  echo "FAIL: Bridge token verification missing: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_OUTPUT" | grep -q "Bridge service is running (active)." || {
  echo "FAIL: Bridge service active status missing: $T8_OUTPUT" >&2
  exit 1
}
[ -s "$MOCK_HOME/.config/heimdall/bridge-token" ] || {
  echo "FAIL: Bridge token file was not created" >&2
  exit 1
}
grep -q "^hba_btk_" "$MOCK_HOME/.config/heimdall/bridge-token" || {
  echo "FAIL: credential on disk is not a device-flow access token:" >&2
  cat "$MOCK_HOME/.config/heimdall/bridge-token" >&2
  exit 1
}
# REQ-IMPL-6 / audit F2: the credential must NOT be copied into config.toml. It
# expires and rotates, so a copy there is a stale second source of truth.
if [ -f "$MOCK_HOME/.config/heimdall/config.toml" ] && \
   grep -q "hba_btk_\|bridge_token" "$MOCK_HOME/.config/heimdall/config.toml"; then
  echo "FAIL: credential leaked into config.toml:" >&2
  cat "$MOCK_HOME/.config/heimdall/config.toml" >&2
  exit 1
fi
echo "PASS: Test 8 passed (Enrollment ceremony and bridge startup verified)!"

# --- Test 9: Enrollment that is never approved falls back to manual steps (REQ-INST-ENROLL-3, REQ-ENROLL-9) ---
#
# INVERTED. This was "empty enrollment token skip": the operator pressed enter at the
# token prompt and the installer printed manual instructions. There is no token to
# leave empty any more, so the equivalent operator outcome is an approval that never
# happens -- nobody opens the link, or it times out. The installer must say so, hand
# over the exact retry command including --headless, and leave NO credential behind;
# a node that is half-enrolled is worse than one that is not enrolled.
echo "=== Test 9: Unapproved enrollment falls back to manual steps (REQ-INST-ENROLL-3) ==="
reset_mock_home
: > "$MOCK_BRIDGE_ARGV"
install_mock_ham_bridge fail

T9_OUTPUT="$(
  PATH="$MOCK_BIN:$PATH" \
  HOME="$MOCK_HOME" \
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false
    hub_url="http://hub.example.test"

    # Nothing to type: the installer aborts before the vault prompt is reached.
    run_interactive_onboarding < /dev/null
  ' 2>&1
)"

echo "$T9_OUTPUT" | grep -q "Enrollment did not complete. You can retry manually with:" || {
  echo "FAIL: Missing warning when enrollment was not approved: $T9_OUTPUT" >&2
  exit 1
}
# The UI ORIGIN again, not the hub api url --- see the note on Test 8's argv
# assertion. A retry command an operator can paste must carry the origin that will
# actually authorize; printing the hub url here would hand them a command that 404s.
echo "$T9_OUTPUT" | grep -q "ham-bridge enroll --ui http://heimdall.example.test" || {
  echo "FAIL: Retry command not printed with the UI origin on failed enrollment: $T9_OUTPUT" >&2
  exit 1
}
if echo "$T9_OUTPUT" | grep -q "ham-bridge enroll --ui http://hub.example.test"; then
  echo "FAIL: retry command printed the hub API url instead of the UI origin: $T9_OUTPUT" >&2
  exit 1
fi
echo "$T9_OUTPUT" | grep -q -- "--headless" || {
  echo "FAIL: --headless hint missing; a machine with no browser has no way forward: $T9_OUTPUT" >&2
  exit 1
}
echo "$T9_OUTPUT" | grep -q "Next steps:" || {
  echo "FAIL: print_onboarding fallback not reached on failed enrollment: $T9_OUTPUT" >&2
  exit 1
}
if echo "$T9_OUTPUT" | grep -q "Node successfully enrolled."; then
  echo "FAIL: reported success for an enrollment that was never approved: $T9_OUTPUT" >&2
  exit 1
fi
assert_no_deleted_enrollment_surface "failed-enrollment fallback" "$T9_OUTPUT"
# Fail-closed: no credential may be left on disk.
if [ -s "$MOCK_HOME/.config/heimdall/bridge-token" ]; then
  echo "FAIL: credential written despite enrollment failing:" >&2
  cat "$MOCK_HOME/.config/heimdall/bridge-token" >&2
  exit 1
fi
echo "PASS: Test 9 passed (Unapproved enrollment handled gracefully)!"

# --- Test 10: Client vault encryption opt-out (REQ-INST-ENROLL-4) ---
echo "=== Test 10: Client vault encryption opt-out (REQ-INST-ENROLL-4) ==="
reset_mock_home
echo "token" > "$MOCK_HOME/.config/heimdall/bridge-token"

T10_OUTPUT="$(
  PATH="$MOCK_BIN:$PATH" \
  HOME="$MOCK_HOME" \
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false
    hub_url="http://hub.example.test"

    run_interactive_onboarding <<EOF
N
EOF
  ' 2>&1
)"

echo "$T10_OUTPUT" | grep -q "Do you wish to enable client vault encryption? \[y/N\]:" || {
  echo "FAIL: Vault encryption prompt missing: $T10_OUTPUT" >&2
  exit 1
}
echo "$T10_OUTPUT" | grep -q "Client vault encryption skipped." || {
  echo "FAIL: Vault opt-out message missing: $T10_OUTPUT" >&2
  exit 1
}
echo "PASS: Test 10 passed (Client vault encryption opt-out verified)!"

# --- Test 11: Vault encryption with unsupported local tooling (REQ-INST-ENROLL-4) ---
echo "=== Test 11: Vault encryption unsupported tooling (REQ-INST-ENROLL-4) ==="
reset_mock_home
echo "token" > "$MOCK_HOME/.config/heimdall/bridge-token"

cat <<'EOF' > "$MOCK_BIN/heimdall"
#!/usr/bin/env bash
if [ "$1" = "vault" ] && [ "${2:-}" = "--help" ]; then
  echo "Usage: heimdall vault (read-only inspect commands)"
  exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/heimdall"

T11_OUTPUT="$(
  PATH="$MOCK_BIN:$PATH" \
  HOME="$MOCK_HOME" \
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false
    hub_url="http://hub.example.test"

    run_interactive_onboarding <<EOF
y
EOF
  ' 2>&1
)"

echo "$T11_OUTPUT" | grep -q "Master password setup is not currently supported by local tooling" || {
  echo "FAIL: Missing unsupported tooling message: $T11_OUTPUT" >&2
  exit 1
}
echo "PASS: Test 11 passed (Unsupported vault tooling handled gracefully)!"

# --- Test 12: Vault encryption password mismatch and success (REQ-INST-ENROLL-4) ---
echo "=== Test 12: Vault encryption password mismatch and setup (REQ-INST-ENROLL-4) ==="
reset_mock_home
echo "token" > "$MOCK_HOME/.config/heimdall/bridge-token"

cat <<'EOF' > "$MOCK_BIN/heimdall"
#!/usr/bin/env bash
if [ "$1" = "vault" ]; then
  if [ "${2:-}" = "--help" ]; then
    echo "Commands:"
    echo "  master-password  Configure vault master password"
    exit 0
  elif [ "${2:-}" = "master-password" ]; then
    read -r pwd_input
    echo "configured:$pwd_input" > "$HOME/.config/heimdall/vault_configured"
    exit 0
  fi
fi
exit 0
EOF
chmod +x "$MOCK_BIN/heimdall"

# 12A: Mismatched passwords
T12A_OUTPUT="$(
  PATH="$MOCK_BIN:$PATH" \
  HOME="$MOCK_HOME" \
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false
    hub_url="http://hub.example.test"

    run_interactive_onboarding <<EOF
y
passA
passB
EOF
  ' 2>&1
)"

echo "$T12A_OUTPUT" | grep -q "Passwords do not match; skipping vault encryption setup." || {
  echo "FAIL: Password mismatch warning missing: $T12A_OUTPUT" >&2
  exit 1
}

# 12B: Matching passwords
reset_mock_home
echo "token" > "$MOCK_HOME/.config/heimdall/bridge-token"
rm -f "$MOCK_HOME/.config/heimdall/vault_configured"

T12B_OUTPUT="$(
  PATH="$MOCK_BIN:$PATH" \
  HOME="$MOCK_HOME" \
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false
    hub_url="http://hub.example.test"

    run_interactive_onboarding <<EOF
y
secret123
secret123
EOF
  ' 2>&1
)"

echo "$T12B_OUTPUT" | grep -q "Vault encryption successfully configured." || {
  echo "FAIL: Vault success message missing: $T12B_OUTPUT" >&2
  exit 1
}
[ -f "$MOCK_HOME/.config/heimdall/vault_configured" ] || {
  echo "FAIL: Mock vault configuration file not created" >&2
  exit 1
}
grep -q "configured:secret123" "$MOCK_HOME/.config/heimdall/vault_configured" || {
  echo "FAIL: Password was not delivered to vault tool" >&2
  exit 1
}
echo "PASS: Test 12 passed (Vault password verification and key configuration succeeded)!"

# --- Test 13: Piped terminal execution detection in is_interactive (REQ-INST-ENROLL-5) ---
echo "=== Test 13: Piped terminal execution detection in is_interactive (REQ-INST-ENROLL-5) ==="
python3 -c '
import pty, os, select, sys

master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    import fcntl, termios
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(slave)
    cmd = (
        "sed '\''/^main \"\\$@\"/d'\'' \"'"$INSTALLER"'\" | bash -c '\''"
        "source /dev/stdin\n"
        "dry_run=false\n"
        "uninstall=false\n"
        "if is_interactive; then echo INTERACTIVE_PIPED_DETECTED; else echo NON_INTERACTIVE_FAILED; fi\n"
        "'\''"
    )
    os.system(cmd)
    os._exit(0)
else:
    os.close(slave)
    buf = b""
    while True:
        r, _, _ = select.select([master], [], [], 3.0)
        if not r: break
        try:
            chunk = os.read(master, 1024)
        except OSError:
            break
        if not chunk: break
        buf += chunk
    os.close(master)
    os.waitpid(pid, 0)
    out = buf.decode(errors="replace")
    assert "INTERACTIVE_PIPED_DETECTED" in out, f"Failed to detect interactive piped session: {out}"
' || {
  echo "FAIL: is_interactive did not detect interactive terminal when piped to bash" >&2
  exit 1
}
echo "PASS: Test 13 passed (is_interactive accurately detects piped interactive terminal)!"

# --- Test 14: DELETED (was: piped /dev/tty prompting when piped to bash) ---
#
# DELETED 2026-10-08 on the user's explicit instruction, because it RESTARTED THE
# PRODUCTION BRIDGE AND KILLED EVERY AGENT ON THE HOST. Twice. Do not reinstate it in
# this shape.
#
# WHAT IT DID: it ran install.sh's `run_interactive_onboarding` inside a pty child via
# `os.system`, which inherits the LIVE environment -- real `PATH`, live
# `XDG_RUNTIME_DIR`, live `DBUS_SESSION_BUS_ADDRESS`. It overrode only `service_home`,
# `install_dir`, `os`, `service_user`, `path_needs_action` and `hub_url`, so `systemctl`
# was the host's real binary addressing the real user session. Onboarding therefore ran
# `systemctl --user daemon-reload` (install.sh:1162) and then
# `systemctl --user restart heimdall-bridge` (install.sh:1388) for real.
#
# Journal evidence, both events minutes apart on 2026-10-08:
#   00:07:05 systemd[817]: Reload requested from client PID 822108 ('systemctl') (unit heimdall-bridge.service)...
#   00:07:05 systemd[817]: Stopping Heimdall bridge connected to hub.mundus.in...
#   00:42:59 systemd[817]: Reload requested from client PID 836029 ('systemctl') ...
#   00:43:00 systemd[817]: Stopping Heimdall bridge connected to hub.mundus.in...
#
# WHY IT ONLY BIT NOW: the test claimed hermeticity via `install_mock_ham_bridge fail`,
# but MOCK_BIN was NEVER on the pty child's PATH, so that mock was inert -- the comment
# asserting the mitigation was wrong about its own mechanism. The test survived at HEAD
# only by ACCIDENT: it blocked on a second /dev/tty read, "Enter one-time enrollment
# token", and onboarding died there, ABOVE the service-start step. REQ-ENROLL-9 deleted
# that prompt, so the accidental abort went with it and onboarding ran to completion.
#
# COVERAGE LOST, stated plainly: nothing in this suite now proves that under
# `curl ... | bash` a prompt reads from /dev/tty instead of silently consuming the
# installer's own source (REQ-INST-ENROLL-5). Test 13 still proves `is_interactive`
# DETECTS that situation, and Test 16 still exercises the Hub URL prompt, but neither
# covers the piped-/dev/tty read itself. That gap is deliberate and accepted here: the
# only way to cover it is to run real onboarding, and onboarding reaches `systemctl`.
#
# IF IT IS EVER REINSTATED: the pty child needs MOCK_BIN FIRST on its PATH, an
# XDG_RUNTIME_DIR inside the test work dir, and a blanked DBUS_SESSION_BUS_ADDRESS --
# and it must assert, BEFORE running onboarding, that `systemctl --user` cannot reach
# any bus at all. `assert_bridge_isolated()` in tests/test_binary_distribution.py is
# exactly that check and is the thing to port; note it currently guards only
# `--uninstall` call sites, not the install path that caused this.

# --- Test 15: Piped non-terminal stdout fallback to non-interactive (REQ-INST-ENROLL-5) ---
echo "=== Test 15: Piped non-terminal stdout fallback (REQ-INST-ENROLL-5) ==="
T15_OUTPUT="$(
  cat "$INSTALLER" | bash -s -- --dry-run
)"
if echo "$T15_OUTPUT" | grep -q "Enter Hub URL:"; then
  echo "FAIL: Prompted for Hub URL when stdout redirected / non-interactive" >&2
  exit 1
fi
if echo "$T15_OUTPUT" | grep -q "Enter one-time enrollment token"; then
  echo "FAIL: Prompted for enrollment token when stdout redirected / non-interactive" >&2
  exit 1
fi
echo "$T15_OUTPUT" | grep -q "Next steps:" || {
  echo "FAIL: Fallback instructions missing from non-interactive output" >&2
  exit 1
}
echo "PASS: Test 15 passed (Piped non-terminal execution cleanly falls back to non-interactive)!"

# --- Test 16: Interactive Hub URL prompt writes --hub to service file (REQ-HUB-URL-1, REQ-HUB-URL-5a) ---
echo "=== Test 16: Interactive Hub URL prompt writes --hub to service file (REQ-HUB-URL-1, REQ-HUB-URL-5a) ==="
reset_mock_home
rm -rf "$MOCK_BIN"
mkdir -p "$MOCK_BIN"
cat <<'EOF' > "$MOCK_BIN/systemctl"
#!/usr/bin/env bash
if [ "$1" = "--user" ] && [ "$2" = "daemon-reload" ]; then
  echo "mock: daemon-reload called"
  exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/systemctl"

T16_OUTPUT="$(
  PATH="$MOCK_BIN:$PATH" \
  HOME="$MOCK_HOME" \
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false

    hub_url=""
    # Enter the hub URL. MOCK_BIN was wiped above and holds no ham-bridge, so
    # enrollment aborts straight after -- deliberately: this test is about the
    # service file and daemon-reload, which both happen BEFORE enrollment.
    run_interactive_onboarding <<EOF
http://interactive-hub.domain:9999
EOF
  ' 2>&1
)"

SVC_FILE="$MOCK_HOME/.config/systemd/user/heimdall-bridge.service"
[ -f "$SVC_FILE" ] || {
  echo "FAIL: Service file $SVC_FILE was not written after Hub URL prompt: $T16_OUTPUT" >&2
  exit 1
}
grep -q -- '--hub "http://interactive-hub.domain:9999"' "$SVC_FILE" || {
  echo "FAIL: --hub \"http://interactive-hub.domain:9999\" not found in $SVC_FILE:" >&2
  cat "$SVC_FILE" >&2
  exit 1
}
echo "$T16_OUTPUT" | grep -q "systemd user unit registered" || {
  echo "FAIL: daemon-reload was not executed after service file update: $T16_OUTPUT" >&2
  exit 1
}
echo "PASS: Test 16 passed (Interactive Hub prompt wrote --hub to service file and ran daemon-reload)!"

# --- Test 17: Existing token pre-check still ensures config.toml has daemon_url (REQ-HUB-URL-2, REQ-HUB-URL-5b) ---
echo "=== Test 17: Existing token pre-check ensures config.toml has daemon_url (REQ-HUB-URL-2, REQ-HUB-URL-5b) ==="
reset_mock_home
mkdir -p "$MOCK_HOME/.config/heimdall"
echo "hba_btk_pre_existing_token" > "$MOCK_HOME/.config/heimdall/bridge-token"
cat <<'EOF' > "$MOCK_HOME/.config/heimdall/config.toml"
# My existing config
[wrapper]
daemon_url = "http://127.0.0.1:49322"
extra_wrapper_field = "preserved"

[daemon]
daemon_id = "brg_existing_node"
data_dir = "~/.local/share/heimdall"
EOF

T17_OUTPUT="$(
  PATH="$MOCK_BIN:$PATH" \
  HOME="$MOCK_HOME" \
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false
    hub_url="https://new-central-hub.corp:8443"

    run_interactive_onboarding <<EOF
n
EOF
  ' 2>&1
)"

CFG_FILE="$MOCK_HOME/.config/heimdall/config.toml"
[ -f "$CFG_FILE" ] || {
  echo "FAIL: config.toml $CFG_FILE missing: $T17_OUTPUT" >&2
  exit 1
}
grep -q 'daemon_url = "https://new-central-hub.corp:8443"' "$CFG_FILE" || {
  echo "FAIL: Updated daemon_url not found in $CFG_FILE:" >&2
  cat "$CFG_FILE" >&2
  exit 1
}
grep -q '\[ctl\]' "$CFG_FILE" || {
  echo "FAIL: [ctl] section not ensured in $CFG_FILE:" >&2
  cat "$CFG_FILE" >&2
  exit 1
}
grep -q 'extra_wrapper_field = "preserved"' "$CFG_FILE" || {
  echo "FAIL: Existing fields in config.toml were not preserved:" >&2
  cat "$CFG_FILE" >&2
  exit 1
}
grep -q 'daemon_id = "brg_existing_node"' "$CFG_FILE" || {
  echo "FAIL: Existing daemon_id in config.toml was not preserved:" >&2
  cat "$CFG_FILE" >&2
  exit 1
}
echo "PASS: Test 17 passed (Pre-existing enrollment updated config.toml with new Hub URL)!"

# --- Test 18: Service is properly restarted/reloaded when already active (REQ-HUB-URL-4, REQ-HUB-URL-5c) ---
echo "=== Test 18: Active service is restarted during onboarding (REQ-HUB-URL-4, REQ-HUB-URL-5c) ==="
reset_mock_home
rm -rf "$MOCK_BIN"
mkdir -p "$MOCK_BIN" "$MOCK_HOME/.config/heimdall"
echo "token_present" > "$MOCK_HOME/.config/heimdall/bridge-token"
LOG_SYSTEMCTL="$TMP_DIR/systemctl_invocations.log"
rm -f "$LOG_SYSTEMCTL"

cat <<EOF > "$MOCK_BIN/systemctl"
#!/usr/bin/env bash
echo "\$*" >> "$LOG_SYSTEMCTL"
if [ "\$1" = "--user" ] && [ "\$2" = "is-active" ] && [ "\$3" = "heimdall-bridge" ]; then
  exit 0
elif [ "\$1" = "--user" ] && [ "\$2" = "restart" ] && [ "\$3" = "heimdall-bridge" ]; then
  echo "mock: restarted heimdall-bridge"
  exit 0
elif [ "\$1" = "--user" ] && [ "\$2" = "daemon-reload" ]; then
  exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/systemctl"

T18_OUTPUT="$(
  PATH="$MOCK_BIN:$PATH" \
  HOME="$MOCK_HOME" \
  bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user=""
    path_needs_action=false
    hub_url="https://restarted-hub.corp"

    run_interactive_onboarding <<EOF
n
EOF
  ' 2>&1
)"

echo "$T18_OUTPUT" | grep -q "Bridge service restarted via systemctl --user." || {
  echo "FAIL: Expected restart message not found: $T18_OUTPUT" >&2
  exit 1
}
grep -q -- "--user restart heimdall-bridge" "$LOG_SYSTEMCTL" || {
  echo "FAIL: systemctl --user restart heimdall-bridge was not called:" >&2
  cat "$LOG_SYSTEMCTL" >&2
  exit 1
}
echo "PASS: Test 18 passed (Active service restarted via systemctl --user restart)!"

# The guard is re-asserted AFTER the last test, not just before the first. A suite
# that verified isolation only at startup would be one `export PATH=...` or one
# `export XDG_RUNTIME_DIR=...` inside a test away from having run the rest of itself
# unprotected --- and it would still print a green banner.
assert_service_guard "teardown"

echo ""
echo "Service guard held: systemctl/launchctl calls intercepted (none reached a real bus):"
if [ -s "$GUARD_LOG" ]; then
  sed 's/^/  /' "$GUARD_LOG"
else
  echo "  (none --- every test used its own mock)"
fi

echo ""
echo "ALL 17 INSTALLER ONBOARDING AND ENROLLMENT TESTS PASSED SUCCESSFULLY!"
exit 0

