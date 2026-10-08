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

# --- Test 8: The installer does NOT enroll and does NOT start a bridge (REQ-FIX-3) ---
#
# INVERTED, and this is the inversion that matters most in this file.
#
# This test used to assert the installer ran `ham-bridge enroll` itself and then
# started the unit. That sequence was not a passing test of a working feature --- it
# was a passing test of iss_18dc71789af7a745, executed automatically on every
# install:
#
#   1. `ham-bridge enroll` (process 1) minted the ephemeral ECDH pair whose public
#      half rides in the approval link's `bpk` fragment, wrote the credential, exited.
#   2. The unit started (process 2) and published its OWN, different pair.
#   3. The approval page sealed the vault key to `bpk` --- process 1's dead key ---
#      and the Hub relayed it to the connected bridge, process 2. AEAD tag failure,
#      vault sealed, no fallback (REQ-IMPL-5 removed it deliberately).
#
# So the assertions below are the OPPOSITE of what they were, on purpose. After
# REQ-FIX-2 the enroll process never exits by design, which makes the old
# synchronous call a hang as well as a wrong-key delivery; REQ-FIX-3's answer is
# that the operator runs enrollment and keeps it running, and the installer does
# not start a competing bridge on the same port.
#
# Test 9 is the COMPLEMENT of this test: same harness, same mocks, opposite
# expectations, differing only in whether a credential already exists. The pair is
# what proves the new skip is NARROW --- this test alone would also pass if the
# installer had simply stopped starting the service for everyone.
echo "=== Test 8: Installer does not auto-enroll and starts no bridge (REQ-FIX-3) ==="
reset_mock_home
: > "$MOCK_BRIDGE_ARGV"
# A ham-bridge mock that WOULD succeed, deliberately. "Did not enroll" has to be
# distinguishable from "could not enroll" --- see Test 7's note. If the installer
# reaches for it, the argv log records it and this test fails.
install_mock_ham_bridge success

# systemctl mock that LOGS ITS ARGV. The old mock only printed, which cannot prove a
# negative: "no start command was issued" and "the mock never ran" look identical on
# stdout. is-active reports INACTIVE here so that, if the installer did decide to
# start something, it would take the `enable --now` branch and leave a trace.
MOCK_SYSTEMCTL_ARGV="$TMP_DIR/systemctl_argv.log"
: > "$MOCK_SYSTEMCTL_ARGV"
cat > "$MOCK_BIN/systemctl" <<MOCKEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MOCK_SYSTEMCTL_ARGV"
if [ "\$1" = "--user" ] && [ "\$2" = "is-active" ]; then
  echo "inactive"
  exit 1
fi
exit 0
MOCKEOF
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

    run_interactive_onboarding <<EOF
n
EOF
  ' 2>&1
)"

# ---- POSITIVE CONTROLS, before any negative is believed -----------------------
#
# iss_18dc691c822d9a6e: an empty argv log is worthless as evidence unless a call
# that DID happen would have landed in it. Both mocks are exercised directly here,
# AFTER the run, so the emptiness asserted below means "not invoked" rather than
# "logging silently broken" or "mock not on PATH".
( PATH="$MOCK_BIN:$PATH"; "$MOCK_BIN/ham-bridge" enroll --ui http://positive.control --bridge-token-file "$TMP_DIR/pc-token" >/dev/null 2>&1 || true )
grep -q -- "enroll --ui http://positive.control" "$MOCK_BRIDGE_ARGV" || {
  echo "FAIL: positive control: the ham-bridge mock does not record its argv, so the negative below proves nothing" >&2
  exit 1
}
"$MOCK_BIN/systemctl" --user enable --now positive-control >/dev/null 2>&1 || true
grep -q -- "enable --now positive-control" "$MOCK_SYSTEMCTL_ARGV" || {
  echo "FAIL: positive control: the systemctl mock does not record its argv, so the negative below proves nothing" >&2
  exit 1
}
# With the controls proven, strip them back out so the negatives read only the
# installer's own calls.
grep -v -- "positive.control\|positive-control" "$MOCK_BRIDGE_ARGV" > "$TMP_DIR/bridge_argv_installer" || true
grep -v -- "positive-control" "$MOCK_SYSTEMCTL_ARGV" > "$TMP_DIR/systemctl_argv_installer" || true
rm -f "$TMP_DIR/pc-token"

# ---- THE LOAD-BEARING NEGATIVES ----------------------------------------------
if [ -s "$TMP_DIR/bridge_argv_installer" ]; then
  echo "FAIL: the installer invoked ham-bridge itself --- this is Branch A, the defect REQ-FIX-3 removes:" >&2
  cat "$TMP_DIR/bridge_argv_installer" >&2
  exit 1
fi
if grep -qE -- "enable --now heimdall-bridge|restart heimdall-bridge|start heimdall-bridge" "$TMP_DIR/systemctl_argv_installer"; then
  echo "FAIL: the installer started the bridge service on an unenrolled node --- it would collide on port 49323 with the operator's enroll process:" >&2
  cat "$TMP_DIR/systemctl_argv_installer" >&2
  exit 1
fi
# The unit really does claim 49323, so the collision this test guards is a real one
# and the negative above is not guarding an imaginary conflict.
SVC_FILE_T8="$MOCK_HOME/.config/systemd/user/heimdall-bridge.service"
grep -q -- "--port 49323" "$SVC_FILE_T8" || {
  echo "FAIL: positive control: the unit no longer binds 49323, so the port-collision assertion above is vacuous:" >&2
  cat "$SVC_FILE_T8" >&2
  exit 1
}
# No credential may appear, because nothing enrolled.
if [ -s "$MOCK_HOME/.config/heimdall/bridge-token" ]; then
  echo "FAIL: a credential exists although the installer did not enroll:" >&2
  cat "$MOCK_HOME/.config/heimdall/bridge-token" >&2
  exit 1
fi
# The old success/ceremony claims must be GONE, not merely unchecked. These are the
# strings that reported a working install while the vault was sealed.
for stale in "Enrolling node (browser approval required)" "Node successfully enrolled." "Bridge service started via systemctl" "Enrollment verified: bridge token is present"; do
  if echo "$T8_OUTPUT" | grep -qF "$stale" ; then
    echo "FAIL: installer still claims '$stale' on a node it did not enroll: $T8_OUTPUT" >&2
    exit 1
  fi
done

# ---- WHAT THE OPERATOR MUST BE TOLD -----------------------------------------
# Each of these is an acceptance criterion of REQ-FIX-3, not a style preference.
echo "$T8_OUTPUT" | grep -q "ENROLL THIS NODE" || {
  echo "FAIL: the installer did not hand the operator the enrollment step: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_OUTPUT" | grep -q "LEAVE IT RUNNING" || {
  echo "FAIL: the operator was not told to leave the enroll process running --- stopping it is what loses the vault key: $T8_OUTPUT" >&2
  exit 1
}
# The UI ORIGIN, not the hub api url. `ui_origin_for_hub` relabels a leading `hub.`
# to `heimdall.`, mirroring BridgesPanel's inverse mapping, because `--ui` wants the
# origin a human opens in a browser. Passing the hub url 404s the authorize call on
# every `hub.`-prefixed deployment, and only checking the relabelled form would miss
# it --- hence the matching negative directly below.
echo "$T8_OUTPUT" | grep -q -- "enroll --ui http://heimdall.example.test" || {
  echo "FAIL: enroll command not printed with the UI origin: $T8_OUTPUT" >&2
  exit 1
}
if echo "$T8_OUTPUT" | grep -q -- "enroll --ui http://hub.example.test"; then
  echo "FAIL: enroll command printed the hub API url instead of the UI origin: $T8_OUTPUT" >&2
  exit 1
fi
echo "$T8_OUTPUT" | grep -q -- "--headless" || {
  echo "FAIL: --headless hint missing; a machine with no browser has no way forward: $T8_OUTPUT" >&2
  exit 1
}
# --bridge-token-file must be in the printed command on EVERY install shape, not just
# the --service-user one. Without it the credential's location depends on whose HOME
# ran the command; with it the path is pinned, because the flag beats both
# $HAM_BRIDGE_TOKEN_FILE and the HOME default (enroll_device_flow.odin:1353).
echo "$T8_OUTPUT" | grep -q -- "--bridge-token-file $MOCK_HOME/.config/heimdall/bridge-token" || {
  echo "FAIL: the printed enroll command does not pin --bridge-token-file, so where the credential lands depends on whose HOME runs it: $T8_OUTPUT" >&2
  exit 1
}
# THE DELIVERABLE SENTENCE. The task is explicit that this is a deliverable rather
# than a nicety: the honest awkward instruction beats a smooth flow that silently
# leaves the vault sealed, which is what shipped.
# BOTH mentions are asserted VERBATIM and SEPARATELY, for the same reason as the
# port pair below — and this one was caught by review (inst_18dc4ce22458a459) after I
# had already found and fixed the mechanism nine lines away, which is the whole point:
# a bare `grep -q "Settings → Bridges"` stayed green when ONLY the handover sentence
# was deleted, because the code-path mention satisfied it.
#
# Note why my own disarm variant missed it. I disarmed by replacing EVERY occurrence
# of the string, which fails the test for the wrong reason and proves nothing about
# witness placement. A disarm that cannot distinguish the sites cannot detect an
# assertion that cannot either: delete exactly ONE site per variant.
# Asserted against a WHITESPACE-FLATTENED copy, so each assertion can name its whole
# sentence even though the printed text hard-wraps mid-sentence (the code-path mention
# breaks between "from" and "Settings"). A line-bound `grep -q` would force each
# assertion down to a short fragment, which is how the vacuity below arose in the
# first place; flattening also means an innocent re-wrap of the paragraph does not
# produce a false failure.
T8_FLAT="$(printf '%s' "$T8_OUTPUT" | tr '\n' ' ' | tr -s ' ')"
echo "$T8_FLAT" | grep -q "then unlock the vault again from Settings → Bridges" || {
  echo "FAIL: the HANDOVER block does not say the handover needs an unlock from Settings -> Bridges --- that is the named acceptance criterion, and a smooth flow that leaves the vault sealed is exactly what shipped: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_FLAT" | grep -q "unlock it afterwards from Settings → Bridges" || {
  echo "FAIL: the CODE path does not say to unlock from Settings -> Bridges afterwards; it is the path that leaves the vault locked: $T8_OUTPUT" >&2
  exit 1
}
# BOTH sites must name the port, and they are asserted separately on purpose.
# A single `grep 49323` over the whole output passed when the handover block's
# warning was deleted, because the skip message further up still matched --- found by
# disarming exactly that line (iss_18dc691c822d9a6e, mechanism: one assertion
# satisfied by a different site than the one under test).
echo "$T8_OUTPUT" | grep -q "stop the enroll process first — it and the service both bind port 49323" || {
  echo "FAIL: the handover instructions do not warn that the enroll process and the service share port 49323: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_OUTPUT" | grep -q "Start the service only after you stop it — both bind port 49323." || {
  echo "FAIL: the service-skip message does not say why the service was not started: $T8_OUTPUT" >&2
  exit 1
}
# The two paths must be described as they BEHAVE (enroll_device_flow.odin:1250-1265):
# the link needs no comparison; the code path is the one that asks for a fingerprint
# and leaves the vault locked.
echo "$T8_OUTPUT" | grep -q "Nothing to compare on this path" || {
  echo "FAIL: the link path still asks the operator to compare something: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_OUTPUT" | grep -q "the vault stays LOCKED" || {
  echo "FAIL: the code path does not say the vault stays locked: $T8_OUTPUT" >&2
  exit 1
}
assert_no_deleted_enrollment_surface "manual-enroll instruction" "$T8_OUTPUT"
# REQ-IMPL-6 / audit F2: no credential may be copied into config.toml.
if [ -f "$MOCK_HOME/.config/heimdall/config.toml" ] && \
   grep -q "hba_btk_\|bridge_token" "$MOCK_HOME/.config/heimdall/config.toml"; then
  echo "FAIL: credential leaked into config.toml:" >&2
  cat "$MOCK_HOME/.config/heimdall/config.toml" >&2
  exit 1
fi
echo "PASS: Test 8 passed (Installer does not auto-enroll and starts no competing bridge)!"

# --- Test 9: The service-start skip is NARROW, not a blanket disable (REQ-FIX-3) ---
#
# INVERTED. This test used to model an approval that never happened: the installer
# ran enroll, enroll failed, and the installer printed manual steps. There is no such
# failure to model now --- the installer never runs enroll, so that branch does not
# exist and keeping the old test would have meant keeping the call it tested.
#
# What it guards instead is the regression REQ-FIX-3 actually introduces the risk of.
# Test 8 asserts the installer does not start the bridge. Taken alone, that assertion
# is also satisfied by an installer that never starts the bridge FOR ANYONE ---
# including the upgrade path, where a credential already exists, the vault key was
# delivered long ago, and starting the service is both correct and the only thing the
# operator expects.
#
# So: identical harness to Test 8, identical mocks, one difference --- a credential on
# disk --- and the opposite expectation. Together the two pin the skip to exactly the
# unenrolled case.
echo "=== Test 9: Service-start skip applies only to unenrolled nodes (REQ-FIX-3) ==="
reset_mock_home
: > "$MOCK_BRIDGE_ARGV"
: > "$MOCK_SYSTEMCTL_ARGV"
install_mock_ham_bridge success
# THE ONE DIFFERENCE FROM TEST 8. A device-flow credential, as `ham-bridge enroll`
# would have written it.
echo "hba_btk_already_enrolled_node" > "$MOCK_HOME/.config/heimdall/bridge-token"

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

    run_interactive_onboarding <<EOF
n
EOF
  ' 2>&1
)"

# The service MUST start on this path. is-active reports inactive, so the correct
# branch is `enable --now`.
grep -q -- "enable --now heimdall-bridge" "$MOCK_SYSTEMCTL_ARGV" || {
  echo "FAIL: the service was not started on an already-enrolled node --- the REQ-FIX-3 skip is too broad and breaks the upgrade path:" >&2
  cat "$MOCK_SYSTEMCTL_ARGV" >&2
  echo "$T9_OUTPUT" >&2
  exit 1
}
echo "$T9_OUTPUT" | grep -q "Bridge service started via systemctl --user." || {
  echo "FAIL: service start not reported on an already-enrolled node: $T9_OUTPUT" >&2
  exit 1
}
echo "$T9_OUTPUT" | grep -q "Enrollment verified: bridge token is present" || {
  echo "FAIL: enrollment verification skipped on an already-enrolled node: $T9_OUTPUT" >&2
  exit 1
}
# ...and the manual-enroll instruction must NOT appear, because there is nothing to
# enroll. Printing it here would tell an upgrading operator to re-enroll a node that
# already works.
if echo "$T9_OUTPUT" | grep -q "ENROLL THIS NODE"; then
  echo "FAIL: the manual-enroll instruction was printed to an already-enrolled node: $T9_OUTPUT" >&2
  exit 1
fi
if echo "$T9_OUTPUT" | grep -q "Not starting the bridge service"; then
  echo "FAIL: the installer refused to start the service on an already-enrolled node: $T9_OUTPUT" >&2
  exit 1
fi
# Still no auto-enroll on this path either --- Test 7 asserts the same thing via the
# pre-check; this re-asserts it with the service start enabled, since that is the
# combination the old code got wrong.
if [ -s "$MOCK_BRIDGE_ARGV" ]; then
  echo "FAIL: ran ham-bridge enroll despite an existing credential:" >&2
  cat "$MOCK_BRIDGE_ARGV" >&2
  exit 1
fi
assert_no_deleted_enrollment_surface "already-enrolled service start" "$T9_OUTPUT"
echo "PASS: Test 9 passed (Service-start skip is narrow: already-enrolled nodes still start)!"

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

# --- Test 19: a never-exiting `ham-bridge enroll` does not hang the installer (REQ-FIX-3) ---
#
# THE ACCEPTANCE CRITERION THAT NO STATIC CHECK CAN REACH. Everything above asserts
# the installer does not CALL enroll; this asserts the consequence that made the call
# unsurvivable, by modelling the binary as it actually behaves after REQ-FIX-2
# (074d7781): `ham-bridge enroll` falls through into the ordinary runtime in the same
# process and NEVER EXITS. That is the fix on the bridge side --- the pair that
# produced the approval link's `bpk` fragment has to still be alive to receive the
# seal --- so a synchronous `if "${enroll_cmd[@]}"; then` in the installer is now an
# unbounded block, not merely a wrong-key delivery.
#
# The mock therefore sleeps rather than returning. With the old call restored this
# test does not fail on an assertion: it TIMES OUT, which is exactly the operator
# symptom (an install that never finishes and never starts the service). Verified by
# doing that --- reintroducing the call makes this test exceed the timeout.
#
# `bash -n` passes on the hanging version. This is the test that does not.
echo "=== Test 19: never-exiting enroll does not hang the installer (REQ-FIX-3) ==="
reset_mock_home
: > "$MOCK_SYSTEMCTL_ARGV"
mkdir -p "$MOCK_BIN"
# A `ham-bridge` that behaves like the real post-REQ-FIX-2 binary: prints the
# ceremony, then stays alive forever as the bridge.
cat > "$MOCK_BIN/ham-bridge" <<'MOCKEOF'
#!/usr/bin/env bash
[ "$1" = "enroll" ] || { echo "mock ham-bridge: unexpected subcommand $1" >&2; exit 64; }
echo "Enroll this machine"
echo "  Open this link:  http://heimdall.example.test/enroll/device#bpk=deadbeef"
echo "Waiting for approval (expires in 14m60s)…"
# The point of the mock: enrollment does not terminate. It IS the bridge now.
sleep 3600
MOCKEOF
chmod +x "$MOCK_BIN/ham-bridge"

T19_START=$(date +%s)
set +e
T19_OUTPUT="$(
  timeout 25 env     PATH="$MOCK_BIN:$PATH"     HOME="$MOCK_HOME"     bash -c '
      source "'"$INSTALLER_LIB"'"
      service_home="'"$MOCK_HOME"'"
      install_dir="'"$MOCK_BIN"'"
      os="linux"
      service_user=""
      path_needs_action=false
      hub_url="http://hub.example.test"

      run_interactive_onboarding <<EOF
n
EOF
      echo "ONBOARDING_RETURNED"
    ' 2>&1
)"
T19_RC=$?
set -e
T19_ELAPSED=$(( $(date +%s) - T19_START ))

if [ "$T19_RC" -eq 124 ]; then
  echo "FAIL: the installer HUNG (timed out after ${T19_ELAPSED}s) against a ham-bridge enroll that never exits." >&2
  echo "       This is the REQ-FIX-3 defect: a synchronous enroll call blocks forever and the" >&2
  echo "       service start is never reached. Partial output:" >&2
  echo "$T19_OUTPUT" >&2
  exit 1
fi
echo "$T19_OUTPUT" | grep -q "ONBOARDING_RETURNED" || {
  echo "FAIL: onboarding did not run to completion (rc=$T19_RC, ${T19_ELAPSED}s): $T19_OUTPUT" >&2
  exit 1
}
# Completed, and completed because it never started that process --- not because the
# mock happened to exit early. Proven by the clock: `sleep 3600` cannot have been
# waited on inside a run this short.
if [ "$T19_ELAPSED" -ge 20 ]; then
  echo "FAIL: onboarding returned but took ${T19_ELAPSED}s, so it was waiting on something it should not have started" >&2
  exit 1
fi
# And still no competing bridge service.
if grep -qE -- "enable --now heimdall-bridge|restart heimdall-bridge" "$MOCK_SYSTEMCTL_ARGV"; then
  echo "FAIL: started the bridge service on an unenrolled node:" >&2
  cat "$MOCK_SYSTEMCTL_ARGV" >&2
  exit 1
fi
echo "PASS: Test 19 passed (installer completes in ${T19_ELAPSED}s against a never-exiting enroll)!"

# --- Test 20: --service-user installs get --config and a run-as note (REQ-FIX-3) ---
#
# The auto-enroll call that REQ-FIX-3 removed passed
# `--config <service_home>/.config/heimdall/config.toml` whenever `--service-user` was
# in play, because under `curl | sudo bash` the shell is root's and the service is not.
# Handing the operator a command WITHOUT that flag would quietly write the credential
# and hub URL into root's home while the unit looks for them in the service user's ---
# a node that enrolls successfully and then cannot connect, on the one install shape
# where nobody is watching a terminal.
#
# So the flag did not disappear with the call; it moved into the printed command. This
# test is what keeps it there, since no other test in this file sets service_user.
echo "=== Test 20: --service-user enroll command carries --config (REQ-FIX-3) ==="
reset_mock_home
: > "$MOCK_BRIDGE_ARGV"
install_mock_ham_bridge success

T20_OUTPUT="$(
  PATH="$MOCK_BIN:$PATH"   HOME="$MOCK_HOME"   bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"
    install_dir="'"$MOCK_BIN"'"
    os="linux"
    service_user="svcuser"
    path_needs_action=false
    hub_url="http://hub.example.test"

    run_interactive_onboarding <<EOF
n
EOF
  ' 2>&1
)"

# BOTH flags, in the order printed. This is the shape where getting it wrong is
# invisible: `curl | sudo bash` leaves the shell as root while the service runs as
# someone else, so --config without --bridge-token-file splits the config from the
# credential and the bridge cannot find its own token.
echo "$T20_OUTPUT" | grep -q -- "enroll --ui http://heimdall.example.test --bridge-token-file $MOCK_HOME/.config/heimdall/bridge-token --config $MOCK_HOME/.config/heimdall/config.toml" || {
  echo "FAIL: the printed enroll command does not carry both --bridge-token-file and --config on a --service-user install, so the credential and the config can land in different homes: $T20_OUTPUT" >&2
  exit 1
}
echo "$T20_OUTPUT" | grep -q "Run it as svcuser" || {
  echo "FAIL: the operator was not told which user to run enrollment as: $T20_OUTPUT" >&2
  exit 1
}
# The complement, and the reason this is a separate test rather than an extra line in
# Test 8: --config must NOT appear when there is no service user, or a plain install
# gets a redundant flag pointing at its own default.
echo "$T20_OUTPUT" | grep -q "ENROLL THIS NODE" || {
  echo "FAIL: enroll instruction missing entirely on the --service-user path: $T20_OUTPUT" >&2
  exit 1
}
T20_PLAIN="$(
  PATH="$MOCK_BIN:$PATH" HOME="$MOCK_HOME" bash -c '
    source "'"$INSTALLER_LIB"'"
    service_home="'"$MOCK_HOME"'"; install_dir="'"$MOCK_BIN"'"
    os="linux"; service_user=""; path_needs_action=false
    hub_url="http://hub.example.test"
    run_interactive_onboarding <<EOF
n
EOF
  ' 2>&1
)"
if echo "$T20_PLAIN" | grep -q -- "--config"; then
  echo "FAIL: --config was printed on an install with no service user: $T20_PLAIN" >&2
  exit 1
fi
# ...but the token flag is NOT conditional, and the pair of assertions is what says so.
echo "$T20_PLAIN" | grep -q -- "--bridge-token-file $MOCK_HOME/.config/heimdall/bridge-token" || {
  echo "FAIL: --bridge-token-file was dropped on an install with no service user; it is unconditional on purpose: $T20_PLAIN" >&2
  exit 1
}
if echo "$T20_PLAIN" | grep -q "Run it as "; then
  echo "FAIL: a run-as note was printed on an install with no service user: $T20_PLAIN" >&2
  exit 1
fi
# Still no auto-enroll on either path.
if [ -s "$MOCK_BRIDGE_ARGV" ]; then
  echo "FAIL: the installer invoked ham-bridge on a --service-user install:" >&2
  cat "$MOCK_BRIDGE_ARGV" >&2
  exit 1
fi
assert_no_deleted_enrollment_surface "service-user enroll instruction" "$T20_OUTPUT"
echo "PASS: Test 20 passed (--service-user gets --config and a run-as note; plain installs get neither)!"

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
echo "ALL 19 INSTALLER ONBOARDING AND ENROLLMENT TESTS PASSED SUCCESSFULLY!"
exit 0

