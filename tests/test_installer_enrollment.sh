#!/usr/bin/env bash
# tests/test_installer_enrollment.sh
# Automated regression tests for scripts/install.sh onboarding, enrollment,
# bridge startup, client vault encryption, and non-interactive invariants
# (REQ-INST-ENROLL-1 through REQ-INST-ENROLL-6).

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

reset_mock_home() {
  rm -rf "$MOCK_HOME"
  mkdir -p "$MOCK_HOME/.config/heimdall"
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
echo "$T1_OUTPUT" | grep -q "heimdall enroll hbe_... --hub" || {
  echo "FAIL: print_onboarding instructions not found in non-interactive output" >&2
  exit 1
}
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
echo "$T6_OUTPUT" | grep -q "heimdall enroll hbe_... --hub" || {
  echo "FAIL: Expected fallback onboarding instructions when Hub URL is empty: $T6_OUTPUT" >&2
  exit 1
}
echo "PASS: Test 6 passed (Empty Hub URL cleanly falls back to manual steps)!"

# --- Test 7: Bridge token pre-check skips enrollment (REQ-INST-ENROLL-2) ---
echo "=== Test 7: Bridge token pre-check (REQ-INST-ENROLL-2) ==="
reset_mock_home
echo "hbe_already_enrolled_sample" > "$MOCK_HOME/.config/heimdall/bridge-token"

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
if echo "$T7_OUTPUT" | grep -q "Enter one-time enrollment token"; then
  echo "FAIL: Prompted for enrollment token when already enrolled: $T7_OUTPUT" >&2
  exit 1
fi
echo "PASS: Test 7 passed (Pre-existing bridge token cleanly skips enrollment)!"

# --- Test 8: Interactive enrollment ceremony & bridge startup (REQ-INST-ENROLL-3) ---
echo "=== Test 8: Enrollment ceremony & bridge startup (REQ-INST-ENROLL-3) ==="
reset_mock_home

# Create mock heimdall and systemctl in MOCK_BIN
cat <<'EOF' > "$MOCK_BIN/heimdall"
#!/usr/bin/env bash
if [ "$1" = "enroll" ]; then
  token="$2"
  shift 2
  mkdir -p "$HOME/.config/heimdall"
  echo "bridge_token_for_$token" > "$HOME/.config/heimdall/bridge-token"
  echo "mock: heimdall enrolled successfully with $token"
  exit 0
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

    # Input: token "hbe_one_time_key", then vault "n"
    run_interactive_onboarding <<EOF
hbe_one_time_key
n
EOF
  ' 2>&1
)"

echo "$T8_OUTPUT" | grep -q "Enter one-time enrollment token (hbe_...):" || {
  echo "FAIL: Enrollment prompt missing: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_OUTPUT" | grep -q "Node successfully enrolled." || {
  echo "FAIL: Enrollment success message missing: $T8_OUTPUT" >&2
  exit 1
}
echo "$T8_OUTPUT" | grep -q "Bridge service started via systemctl --user." || {
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
echo "PASS: Test 8 passed (Enrollment ceremony and bridge startup verified)!"

# --- Test 9: Empty enrollment token skip (REQ-INST-ENROLL-3) ---
echo "=== Test 9: Empty enrollment token skip (REQ-INST-ENROLL-3) ==="
reset_mock_home

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

    # Input: empty token
    run_interactive_onboarding <<EOF

EOF
  ' 2>&1
)"

echo "$T9_OUTPUT" | grep -q "No enrollment token provided; skipping automatic enrollment." || {
  echo "FAIL: Missing warning for empty enrollment token: $T9_OUTPUT" >&2
  exit 1
}
echo "$T9_OUTPUT" | grep -q "heimdall enroll hbe_... --hub" || {
  echo "FAIL: Fallback instructions not printed on empty enrollment token: $T9_OUTPUT" >&2
  exit 1
}
echo "PASS: Test 9 passed (Empty enrollment token handled gracefully)!"

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

# --- Test 14: Piped /dev/tty prompting when piped to bash (curl | bash) (REQ-INST-ENROLL-5) ---
echo "=== Test 14: Piped /dev/tty prompting when piped to bash (REQ-INST-ENROLL-5) ==="
reset_mock_home
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
        "service_home=\"'"$MOCK_HOME"'\"\n"
        "install_dir=\"'"$MOCK_BIN"'\"\n"
        "os=linux\n"
        "service_user=\n"
        "path_needs_action=false\n"
        "hub_url=\n"
        "run_interactive_onboarding\n"
        "'\''"
    )
    os.system(cmd)
    os._exit(0)
else:
    os.close(slave)
    buf = b""
    while b"Enter Hub URL: " not in buf:
        r, _, _ = select.select([master], [], [], 3.0)
        if not r: break
        try:
            chunk = os.read(master, 1024)
        except OSError:
            break
        if not chunk: break
        buf += chunk
    out_buf = buf.decode(errors="replace")
    assert b"Enter Hub URL: " in buf, "Hub URL prompt not received: " + out_buf
    os.write(master, b"https://piped-hub.example.com\n")

    buf2 = b""
    while b"Enter one-time enrollment token" not in buf2:
        r, _, _ = select.select([master], [], [], 3.0)
        if not r: break
        try:
            chunk = os.read(master, 1024)
        except OSError:
            break
        if not chunk: break
        buf2 += chunk
    out_buf2 = buf2.decode(errors="replace")
    assert b"Enter one-time enrollment token" in buf2, "Enrollment token prompt not received: " + out_buf2
    os.write(master, b"\n")

    rest = b""
    while True:
        r, _, _ = select.select([master], [], [], 3.0)
        if not r: break
        try:
            chunk = os.read(master, 1024)
        except OSError:
            break
        if not chunk: break
        rest += chunk
    os.close(master)
    os.waitpid(pid, 0)
    out = (buf + buf2 + rest).decode(errors="replace")
    assert "https://piped-hub.example.com" in out, "Hub URL was not captured from /dev/tty"
' || {
  echo "FAIL: Interactive prompting from /dev/tty failed when piped" >&2
  exit 1
}
echo "PASS: Test 14 passed (Piped /dev/tty prompting works seamlessly)!"

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

echo ""
echo "ALL 15 INSTALLER ONBOARDING AND ENROLLMENT TESTS PASSED SUCCESSFULLY!"
exit 0

