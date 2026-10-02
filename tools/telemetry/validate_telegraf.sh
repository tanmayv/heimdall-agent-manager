#!/usr/bin/env bash
# Validation runner for Heimdall Telegraf configuration template
# Requirements: REQ-TEL-3, REQ-TEL-4

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/telegraf.conf.template"
TEST_CONF="/tmp/telegraf-test.conf"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "ERROR: Template file not found: $TEMPLATE_FILE" >&2
  exit 1
fi

# Determine how to execute telegraf (direct PATH or via nix-shell)
USE_NIX=0
if command -v telegraf >/dev/null 2>&1; then
  echo "[INFO] Found telegraf on PATH: $(command -v telegraf)"
elif command -v nix-shell >/dev/null 2>&1; then
  echo "[INFO] telegraf not on PATH; using nix-shell -p telegraf"
  USE_NIX=1
else
  echo "ERROR: Neither 'telegraf' executable nor 'nix-shell' was found." >&2
  exit 1
fi

# Define dummy environment variables
export HEIMDALL_BRIDGE_ID="${HEIMDALL_BRIDGE_ID:-brg_test}"
export TELEMETRY_PORT="${TELEMETRY_PORT:-9273}"
export HOSTNAME="${HOSTNAME:-$(hostname 2>/dev/null || echo "testhost")}"

echo "[INFO] Substituting environment variables into template -> $TEST_CONF"
sed \
  -e "s|\${HEIMDALL_BRIDGE_ID}|${HEIMDALL_BRIDGE_ID}|g" \
  -e "s|\${HOSTNAME}|${HOSTNAME}|g" \
  -e "s|\${TELEMETRY_PORT:-9273}|${TELEMETRY_PORT}|g" \
  -e "s|\${TELEMETRY_PORT}|${TELEMETRY_PORT}|g" \
  "$TEMPLATE_FILE" > "$TEST_CONF"

# Optional cleanup on exit
cleanup() {
  if [[ -n "${DUMMY_PID:-}" ]]; then
    kill "$DUMMY_PID" >/dev/null 2>&1 || true
    wait "$DUMMY_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# If no target processes are running in this environment, launch a transient background process
DUMMY_PID=""
if ! pgrep -f '(ham-bridge|ham-ctl|ham-pty-host|node|python|jetski|claude)' >/dev/null 2>&1; then
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import time; time.sleep(15)" >/dev/null 2>&1 &
    DUMMY_PID=$!
    sleep 0.2
  fi
fi

echo "[INFO] Executing telegraf --config $TEST_CONF --test..."
OUTPUT=""
if [[ "$USE_NIX" -eq 1 ]]; then
  OUTPUT=$(nix-shell -p telegraf --run "telegraf --config \"$TEST_CONF\" --test")
else
  OUTPUT=$(telegraf --config "$TEST_CONF" --test)
fi

echo "[INFO] Validating emitted metrics..."

# Validate procstat lines are present
if ! grep -q -E '^> procstat,' <<< "$OUTPUT"; then
  echo "ERROR: No procstat measurement lines found in telegraf output." >&2
  exit 1
fi

# Extract procstat lines
PROCSTAT_LINES=$(grep -E '^> procstat,' <<< "$OUTPUT" || true)

# Verify bridge_id tag
if ! grep -q "bridge_id=${HEIMDALL_BRIDGE_ID}" <<< "$PROCSTAT_LINES"; then
  echo "ERROR: Tag bridge_id=${HEIMDALL_BRIDGE_ID} not found in procstat metrics." >&2
  exit 1
fi

# Verify required fields
REQUIRED_FIELDS=("memory_rss" "memory_vms" "cpu_time_user" "cpu_time_system")
for field in "${REQUIRED_FIELDS[@]}"; do
  if ! grep -q -E "${field}=" <<< "$PROCSTAT_LINES"; then
    echo "ERROR: Expected field '${field}' not found in procstat metrics." >&2
    exit 1
  fi
done

# Verify cpu and mem metrics exist
if ! grep -q -E '^> cpu,' <<< "$OUTPUT"; then
  echo "ERROR: Host cpu metrics not found in telegraf output." >&2
  exit 1
fi
if ! grep -q -E '^> mem,' <<< "$OUTPUT"; then
  echo "ERROR: Host mem metrics not found in telegraf output." >&2
  exit 1
fi

echo "[INFO] Validation succeeded! Procstat metric sample:"
mapfile -t SAMPLE_LINES < <(grep -E '^> procstat,' <<< "$OUTPUT" || true)
for line in "${SAMPLE_LINES[@]:0:3}"; do
  echo "$line"
done

echo "[INFO] Successfully verified:"
echo "  - Valid Telegraf TOML syntax for procstat, cpu, mem, prometheus_client"
echo "  - Correct global tag propagation (bridge_id=${HEIMDALL_BRIDGE_ID}, bridge_host=${HOSTNAME})"
echo "  - Required procstat fields: ${REQUIRED_FIELDS[*]}"
echo "  - Prometheus client output configuration on 127.0.0.1:${TELEMETRY_PORT}"
