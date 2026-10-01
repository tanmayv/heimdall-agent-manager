#!/usr/bin/env bash
# tests/test_bridge_update_supervisor.sh
# Synthetic tests for scripts/apply-bridge-update.sh
# Covers:
# 1. Healthcheck timeout -> automated rollback to bin.bak
# 2. Process crash on restart -> automated rollback to bin.bak
# 3. Successful update -> atomic replacement and cleanup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUPERVISOR="$REPO_ROOT/scripts/apply-bridge-update.sh"

[ -x "$SUPERVISOR" ] || { echo "FAIL: $SUPERVISOR is not executable" >&2; exit 1; }

TMP_DIR="$(mktemp -d /tmp/ham-sup-test-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== Test 1: Healthcheck timeout triggers automated rollback ==="
mkdir -p "$TMP_DIR/t1/data/bin" "$TMP_DIR/t1/stage/bin"
echo "original-v1.0" > "$TMP_DIR/t1/data/bin/ham-bridge"
echo "unresponsive-v2.0" > "$TMP_DIR/t1/stage/bin/ham-bridge"

set +e
"$SUPERVISOR" \
  --data-dir "$TMP_DIR/t1/data" \
  --stage-dir "$TMP_DIR/t1/stage" \
  --bridge-port 58901 \
  --health-timeout 2 \
  --stop-cmd "true" \
  --restart-cmd "true"
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -ne 1 ]; then
  echo "FAIL: Expected exit code 1 on timeout, got $EXIT_CODE" >&2
  exit 1
fi

RESTORED=$(cat "$TMP_DIR/t1/data/bin/ham-bridge")
if [ "$RESTORED" != "original-v1.0" ]; then
  echo "FAIL: Expected rollback to original-v1.0, got: $RESTORED" >&2
  exit 1
fi

if [ ! -f "$TMP_DIR/t1/data/logs/update_rollback.log" ]; then
  echo "FAIL: Rollback log was not written" >&2
  exit 1
fi
echo "PASS: Test 1 passed!"

echo "=== Test 2: Process crash on restart triggers automated rollback ==="
mkdir -p "$TMP_DIR/t2/data/bin" "$TMP_DIR/t2/stage/bin"
echo "stable-v1.0" > "$TMP_DIR/t2/data/bin/ham-bridge"
echo "crashing-v2.0" > "$TMP_DIR/t2/stage/bin/ham-bridge"

# Restart command that simulates the new binary crashing with exit 1
CRASH_CMD='if [ "$(cat '"$TMP_DIR"'/t2/data/bin/ham-bridge 2>/dev/null)" = "crashing-v2.0" ]; then false; else true; fi'

set +e
"$SUPERVISOR" \
  --data-dir "$TMP_DIR/t2/data" \
  --stage-dir "$TMP_DIR/t2/stage" \
  --bridge-port 58902 \
  --health-timeout 2 \
  --stop-cmd "true" \
  --restart-cmd "$CRASH_CMD"
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -ne 1 ]; then
  echo "FAIL: Expected exit code 1 on crash, got $EXIT_CODE" >&2
  exit 1
fi

RESTORED_CRASH=$(cat "$TMP_DIR/t2/data/bin/ham-bridge")
if [ "$RESTORED_CRASH" != "stable-v1.0" ]; then
  echo "FAIL: Expected rollback to stable-v1.0, got: $RESTORED_CRASH" >&2
  exit 1
fi

if [ ! -f "$TMP_DIR/t2/data/logs/update_rollback.log" ]; then
  echo "FAIL: Rollback log was not written on crash" >&2
  exit 1
fi
echo "PASS: Test 2 passed!"

echo "=== Test 3: Successful update applies atomically and cleans up ==="
# Start temporary healthcheck server
python3 -c "
import http.server, socketserver
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{\"ok\":true}')
with socketserver.TCPServer(('127.0.0.1', 58903), Handler) as httpd:
    httpd.handle_request()
" &
SERVER_PID=$!
sleep 0.5

mkdir -p "$TMP_DIR/t3/data/bin" "$TMP_DIR/t3/stage/bin"
echo "old-v1.0" > "$TMP_DIR/t3/data/bin/ham-bridge"
echo "verified-v2.0" > "$TMP_DIR/t3/stage/bin/ham-bridge"

"$SUPERVISOR" \
  --data-dir "$TMP_DIR/t3/data" \
  --stage-dir "$TMP_DIR/t3/stage" \
  --bridge-port 58903 \
  --health-timeout 5 \
  --stop-cmd "true" \
  --restart-cmd "true"

APPLIED=$(cat "$TMP_DIR/t3/data/bin/ham-bridge")
if [ "$APPLIED" != "verified-v2.0" ]; then
  echo "FAIL: Expected verified-v2.0 to be applied, got: $APPLIED" >&2
  exit 1
fi

if [ -d "$TMP_DIR/t3/data/bin.bak" ]; then
  echo "FAIL: bin.bak should be deleted after success" >&2
  exit 1
fi

if [ -d "$TMP_DIR/t3/stage" ]; then
  echo "FAIL: staging dir should be deleted after success" >&2
  exit 1
fi

wait $SERVER_PID 2>/dev/null || true
echo "PASS: Test 3 passed!"

echo "ALL SUPERVISOR TESTS PASSED SUCCESSFULLY!"
