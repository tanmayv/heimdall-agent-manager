#!/usr/bin/env bash
# Integration test runner for task status and enum changes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1. Create a temporary home directory
TEMP_HOME=$(mktemp -d)
echo "[*] Created temporary HEIMDALL_HOME: $TEMP_HOME"

# 2. Write a temporary config.toml pointing to port 49325 and temp data dir
cat <<EOF > "$TEMP_HOME/config.toml"
[daemon]
bind_host = "127.0.0.1"
port = 49325
data_dir = "$TEMP_HOME/data"
wrapper_bin = "$REPO_DIR/result-wrapper/bin/ham-wrapper"

[ctl]
daemon_url = "http://127.0.0.1:49325"
ham_ctl_bin = "$REPO_DIR/result-ctl/bin/ham-ctl"

[wrapper]
daemon_url = "http://127.0.0.1:49325"
credentials_path = "$TEMP_HOME/data/wrapper-credentials.json"
agent_name = "pi"
default_agent = "pi"
display_name = "{instance}"
requested_access_mode = "main"
command = ["pi"]
tmux_session = "ham-agents"
tmux_window_prefix = "agent"
agent_run_dir = "$TEMP_HOME/data/agent-runs"
project = "default"
memory_templates = []
EOF

# 3. Start the daemon in the background
echo "[*] Starting ham-daemon on port 49325..."
"$REPO_DIR/result-daemon/bin/ham-daemon" --config "$TEMP_HOME/config.toml" > "$TEMP_HOME/daemon.log" 2>&1 &
DAEMON_PID=$!

cleanup() {
  echo "[*] Shutting down ham-daemon (PID: $DAEMON_PID)..."
  kill "$DAEMON_PID" || true
  wait "$DAEMON_PID" 2>/dev/null || true
  echo "[*] Cleaning up temporary directory..."
  rm -rf "$TEMP_HOME"
}
trap cleanup EXIT

# 4. Wait for daemon to be healthy
echo "[*] Waiting for daemon to start..."
for i in {1..10}; do
  if curl -sf http://127.0.0.1:49325/health >/dev/null; then
    echo "[*] Daemon is healthy!"
    break
  fi
  if [ "$i" -eq 10 ]; then
    echo "[-] Error: Daemon failed to start. Logs:"
    cat "$TEMP_HOME/daemon.log"
    exit 1
  fi
  sleep 0.5
done

# 5. Run the existing tasks smoke tests pointing to our temp daemon and new ham-ctl
echo "[*] Running tasks smoke test..."
export HEIMDALL_HOME="$TEMP_HOME"
export HAM_CTL_BIN="$REPO_DIR/result-ctl/bin/ham-ctl"
export DAEMON_URL="http://127.0.0.1:49325"

# Run tests/test_tasks.sh
if ! bash "$SCRIPT_DIR/test_tasks.sh" > "$TEMP_HOME/test_tasks.log" 2>&1; then
  echo "[-] Error: test_tasks.sh failed! Full test logs:"
  cat "$TEMP_HOME/test_tasks.log" || true
  exit 1
fi

echo "[*] Running duplicate connection preference test..."
if ! python3 "$SCRIPT_DIR/test_duplicate_connection.py" > "$TEMP_HOME/test_dup.log" 2>&1; then
  echo "[-] Error: test_duplicate_connection.py failed! Full test logs:"
  cat "$TEMP_HOME/test_dup.log" || true
  echo "[-] Daemon logs:"
  cat "$TEMP_HOME/daemon.log" || true
  exit 1
fi

echo "[*] Running templates seeding integration test..."
if ! python3 "$SCRIPT_DIR/test_templates_seeding.py" > "$TEMP_HOME/test_templates.log" 2>&1; then
  echo "[-] Error: test_templates_seeding.py failed! Full test logs:"
  cat "$TEMP_HOME/test_templates.log" || true
  echo "[-] Daemon logs:"
  cat "$TEMP_HOME/daemon.log" || true
  exit 1
fi

echo "[*] Running reconnect token integration test..."
if ! python3 "$SCRIPT_DIR/test_reconnect_token.py" > "$TEMP_HOME/test_reconnect.log" 2>&1; then
  echo "[-] Error: test_reconnect_token.py failed! Full test logs:"
  cat "$TEMP_HOME/test_reconnect.log" || true
  echo "[-] Daemon logs:"
  cat "$TEMP_HOME/daemon.log" || true
  exit 1
fi

echo "[*] Running bootstrap preferences integration test..."
if ! python3 "$SCRIPT_DIR/test_bootstrap_preferences.py" > "$TEMP_HOME/test_bootstrap.log" 2>&1; then
  echo "[-] Error: test_bootstrap_preferences.py failed! Full test logs:"
  cat "$TEMP_HOME/test_bootstrap.log" || true
  echo "[-] Daemon logs:"
  cat "$TEMP_HOME/daemon.log" || true
  exit 1
fi

echo "[*] Running template edit and save integration test..."
if ! python3 "$SCRIPT_DIR/test_template_edit_save.py" > "$TEMP_HOME/test_template_edit_save.log" 2>&1; then
  echo "[-] Error: test_template_edit_save.py failed! Full test logs:"
  cat "$TEMP_HOME/test_template_edit_save.log" || true
  echo "[-] Daemon logs:"
  cat "$TEMP_HOME/daemon.log" || true
  exit 1
fi

echo "[*] Integration tests completed successfully!"

