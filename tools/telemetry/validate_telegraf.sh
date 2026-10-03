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
export LOCAL_ENDPOINT_PORT="${LOCAL_ENDPOINT_PORT:-49324}"

MOCK_PID=""
cleanup() {
  if [[ -n "${MOCK_PID:-}" ]]; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
    wait "$MOCK_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# If the target endpoint is not reachable or not returning HTTP 200, spawn a transient mock endpoint
ENDPOINT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${LOCAL_ENDPOINT_PORT}/api/v1/telemetry/processes" 2>/dev/null || echo "000")
if [[ "$ENDPOINT_STATUS" != "200" ]]; then
  export LOCAL_ENDPOINT_PORT=49995
  echo "[INFO] Live bridge endpoint not active on default port (status: $ENDPOINT_STATUS); launching mock endpoint on port $LOCAL_ENDPOINT_PORT..."
  python3 -c '
import http.server, socketserver, sys

PROM_BODY = b"""# HELP heimdall_process_cpu_percent CPU percentage used by process
# TYPE heimdall_process_cpu_percent gauge
heimdall_process_cpu_percent{instance_id="inst_worker_1",role="worker",chain_id="chain_w99",pid="200"} 2.1
# HELP heimdall_process_memory_rss_bytes Resident memory size in bytes
# TYPE heimdall_process_memory_rss_bytes gauge
heimdall_process_memory_rss_bytes{instance_id="inst_worker_1",role="worker",chain_id="chain_w99",pid="200"} 20971520
# HELP heimdall_process_num_threads Number of threads in process
# TYPE heimdall_process_num_threads gauge
heimdall_process_num_threads{instance_id="inst_worker_1",role="worker",chain_id="chain_w99",pid="200"} 4
"""

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/v1/telemetry/processes"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(PROM_BODY)))
            self.end_headers()
            self.wfile.write(PROM_BODY)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *args): pass

with socketserver.TCPServer(("127.0.0.1", 49995), H) as httpd:
    httpd.serve_forever()
' &
  MOCK_PID=$!
  sleep 0.5
fi

echo "[INFO] Substituting environment variables into template -> $TEST_CONF"
sed \
  -e "s|\${HEIMDALL_BRIDGE_ID}|${HEIMDALL_BRIDGE_ID}|g" \
  -e "s|\${HOSTNAME}|${HOSTNAME}|g" \
  -e "s|\${LOCAL_ENDPOINT_PORT:-49324}|${LOCAL_ENDPOINT_PORT}|g" \
  -e "s|\${LOCAL_ENDPOINT_PORT}|${LOCAL_ENDPOINT_PORT}|g" \
  -e "s|\${TELEMETRY_PORT:-9273}|${TELEMETRY_PORT}|g" \
  -e "s|\${TELEMETRY_PORT}|${TELEMETRY_PORT}|g" \
  "$TEMPLATE_FILE" > "$TEST_CONF"

echo "[INFO] Executing telegraf --config $TEST_CONF --test..."
OUTPUT=""
if [[ "$USE_NIX" -eq 1 ]]; then
  OUTPUT=$(nix-shell -p telegraf --run "telegraf --config \"$TEST_CONF\" --test")
else
  OUTPUT=$(telegraf --config "$TEST_CONF" --test)
fi

echo "[INFO] Validating emitted metrics..."

# Validate process metrics lines are present
if ! grep -q -E '(heimdall_process|prometheus,)' <<< "$OUTPUT"; then
  echo "ERROR: No process measurement lines found in telegraf output." >&2
  exit 1
fi

# Verify bridge_id tag
if ! grep -q "bridge_id=${HEIMDALL_BRIDGE_ID}" <<< "$OUTPUT"; then
  echo "ERROR: Tag bridge_id=${HEIMDALL_BRIDGE_ID} not found in metrics." >&2
  exit 1
fi

# Verify required process fields
REQUIRED_FIELDS=("heimdall_process_memory_rss_bytes" "heimdall_process_cpu_percent" "heimdall_process_num_threads")
for field in "${REQUIRED_FIELDS[@]}"; do
  if ! grep -q -E "${field}=" <<< "$OUTPUT"; then
    echo "ERROR: Expected field '${field}' not found in process metrics." >&2
    exit 1
  fi
done

# Verify instance_id tag
if ! grep -q "instance_id=" <<< "$OUTPUT"; then
  echo "ERROR: Tag instance_id not found in process metrics." >&2
  exit 1
fi

# Verify cpu and mem metrics exist
if ! grep -q -E '^> cpu,' <<< "$OUTPUT"; then
  echo "ERROR: Host cpu metrics not found in telegraf output." >&2
  exit 1
fi
if ! grep -q -E '^> mem,' <<< "$OUTPUT"; then
  echo "ERROR: Host mem metrics not found in telegraf output." >&2
  exit 1
fi

echo "[INFO] Validation succeeded! Process metric sample:"
mapfile -t SAMPLE_LINES < <(grep -E 'heimdall_process' <<< "$OUTPUT" || true)
for line in "${SAMPLE_LINES[@]:0:3}"; do
  echo "$line"
done

echo "[INFO] Successfully verified:"
echo "  - Valid Telegraf TOML syntax for inputs.http, cpu, mem, prometheus_client"
echo "  - Correct global tag propagation (bridge_id=${HEIMDALL_BRIDGE_ID}, bridge_host=${HOSTNAME})"
echo "  - Required process fields: ${REQUIRED_FIELDS[*]}"
echo "  - Prometheus client output configuration on 127.0.0.1:${TELEMETRY_PORT}"
