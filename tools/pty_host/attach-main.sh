#!/usr/bin/env bash
# Reliably attach to your "main" bridge's ham-pty-host daemon.
#
# The socket path a bridge uses is DETERMINISTIC (see pty_host_socket_path /
# pty_host_bridge_identity in src/bridge/pty_host_client.odin):
#
#     <local_run_dir>/pty-host.sock when a directory component is <identity>;
#     otherwise <local_run_dir>/pty-host-<identity>.sock
#     Paths over 103 bytes use /tmp/heimdall-<uid>/<path-hash>.sock.
#     identity = daemon_id (if set & != local-daemon)
#              | port-<local_endpoint_port>
#              | default
#
# Because it never changes across restarts, we can compute it once and then
# loop: if the daemon or bridge restarts, we just wait for the socket and
# re-attach. Ctrl-C twice (or F10 in the TUI, then Ctrl-C) to really quit.
set -euo pipefail

# --- Point these at YOUR main bridge (defaults = the local dev bridge) --------
RUN_DIR="${HAM_LOCAL_RUN_DIR:-/tmp/heimdall-bridge-local}"
PORT="${HAM_LOCAL_ENDPOINT_PORT:-49324}"
DAEMON_ID="${HAM_DAEMON_ID:-local-daemon}"   # leave as local-daemon to key on port

# --- Derive the identity exactly like the bridge does -------------------------
if [[ -n "$DAEMON_ID" && "$DAEMON_ID" != "local-daemon" ]]; then
  # bridge_runtime_safe_part: keep [A-Za-z0-9_-@.], replace the rest with _
  IDENTITY="$(printf '%s' "$DAEMON_ID" | sed 's/[^A-Za-z0-9_@.-]/_/g')"
elif [[ "$PORT" != "0" && -n "$PORT" ]]; then
  IDENTITY="port-${PORT}"
else
  IDENTITY="default"
fi

# Match the bridge and Rust client, including byte limits (not character counts).
SOCKET="$(python3 - "$RUN_DIR" "$IDENTITY" <<'PY_SOCKET'
import os, sys
base, identity = sys.argv[1:]
base = base.rstrip('/') or '/tmp/heimdall-bridge-local'
name = 'pty-host.sock' if identity in base.split('/') else 'pty-host-'+identity+'.sock'
path = base+'/'+name
if len(path.encode()) > 103:
    h = 14695981039346656037
    for b in path.encode(): h = ((h ^ b) * 1099511628211) & ((1 << 64)-1)
    path = f'/tmp/heimdall-{os.geteuid()}/{h:016x}.sock'
print(path)
PY_SOCKET
)"
echo "[attach-main] target socket: $SOCKET"

# --- IMPORTANT: use the SAME ham-pty-host build the bridge launched -----------
# A version mismatch decodes garbage and the TUI exits instantly
# ("dashboard exited (agents still running)" / "string body truncated").
# Override with HAM_PTY_HOST=/path/to/ham-pty-host if `which` is wrong.
PTY_HOST="${HAM_PTY_HOST:-$(command -v ham-pty-host)}"
echo "[attach-main] using client: $PTY_HOST"

while true; do
  # Wait for the socket to exist (covers bridge/daemon restart windows).
  until [[ -S "$SOCKET" ]]; do
    echo "[attach-main] waiting for $SOCKET ..."
    sleep 1
  done

  # Attach the multi-agent dashboard. Returns when the daemon drops the
  # connection (restart) or you quit the TUI.
  "$PTY_HOST" --socket "$SOCKET" attach || true

  echo "[attach-main] detached; reconnecting in 1s (Ctrl-C to stop) ..."
  sleep 1
done
