#!/usr/bin/env bash
# TEST-1 / LOG-1 local end-to-end: proves bridge bootstrap cache HIT vs hub FETCH
# against a LOCAL hub, for all three scenarios:
#   (1) COLD        : manifest 200 (MISS) + every object FETCH(hub)
#   (2) WARM        : manifest 304 (HIT)  + zero fetches (all disk HIT)
#   (3) AFTER_MEMORY: manifest 200 (MISS) + exactly ONE FETCH (memories) + rest HIT,
#                     and the new memory present in the assembled AGENTS.md.
#
# Requires: nix (to build), a free port. Builds ham-hub + the bridge bootstrap
# harness, stands up a throwaway local hub (own db/port/tokens), enrolls a bridge,
# creates an agent, and drives the REAL bridge bootstrap code path
# (bridge_bootstrap_conditional_manifest) so its HIT/FETCH log lines are the
# acceptance signal.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

PORT="${E2E_HUB_PORT:-8091}"
H="127.0.0.1:$PORT"
DB="$(mktemp -t e2e-hub-XXXX.db)"
CACHE="$(mktemp -d -t e2e-bridge-cache-XXXX)"
TOKF="$(mktemp -t e2e-bridge-token-XXXX)"
ODIN_BIN="${ODIN:-odin}"
HARNESS="$(mktemp -t e2e-harness-XXXX)"
LOG="$(mktemp -t e2e-hub-log-XXXX)"

cleanup() { [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null || true; rm -rf "$DB" "$CACHE" "$TOKF" "$HARNESS" "$LOG"; }
trap cleanup EXIT

echo "[e2e] building ham-hub + ham-bridge via nix"
nix build "$ROOT#ham-hub" -o result-hub >/dev/null
nix build "$ROOT#ham-bridge" -o result-bridge >/dev/null
echo "[e2e] building bootstrap harness"
"$ODIN_BIN" build tests/e2e_bridge_bootstrap_cache_harness.odin -file -collection:odin_test=src -out:"$HARNESS"

echo "[e2e] starting local hub on $H"
./result-hub/bin/ham-hub --listen "$H" --db "$DB" \
  --migrations-dir src/hub/repository/sqlite/migrations \
  --trusted-proxy-cidr 127.0.0.1/32 >"$LOG" 2>&1 &
HUB_PID=$!
sleep 2

U=(-H "X-authentik-username:alice")
curl -sf -m5 "${U[@]}" "http://$H/api/v1/me" >/dev/null
ENR=$(curl -sf -m5 "${U[@]}" -X POST "http://$H/api/v1/bridge-enrollments" -H 'Content-Type: application/json' -d '{"label":"e2e"}')
ETOK=$(printf '%s' "$ENR" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["enrollment_token"])')
./result-bridge/bin/ham-bridge enroll --hub "http://$H" --enrollment-token "$ETOK" --bridge-token-file "$TOKF" >/dev/null 2>&1
BT=$(cat "$TOKF")
AG=$(curl -sf -m5 "${U[@]}" -X POST "http://$H/api/v1/agents" -H 'Content-Type: application/json' \
  -d '{"name":"E2E Agent","slug":"e2e","default_provider":"claude","default_tier":"normal","instructions":"You are the e2e test agent."}')
AID=$(printf '%s' "$AG" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["agent_id"])')
echo "[e2e] agent=$AID bridge_token=${BT:0:12}..."

fail() { echo "FAIL: $1"; exit 1; }

echo "######## (1) COLD ########"
OUT1=$("$HARNESS" "http://$H" "$BT" "$AID" "$CACHE" cold 2>&1); echo "$OUT1"
echo "$OUT1" | grep -q "manifest MISS (200)" || fail "cold: expected manifest MISS(200)"
[ "$(echo "$OUT1" | grep -c "blob FETCH (hub)")" -ge 4 ] || fail "cold: expected blob FETCHes"
echo "$OUT1" | grep -q "blob HIT (disk)" && fail "cold: must have zero disk HITs" || true

echo "######## (2) WARM ########"
OUT2=$("$HARNESS" "http://$H" "$BT" "$AID" "$CACHE" warm 2>&1); echo "$OUT2"
echo "$OUT2" | grep -q "manifest HIT (304)" || fail "warm: expected manifest HIT(304)"
[ "$(echo "$OUT2" | grep -c "blob FETCH (hub)")" -eq 0 ] || fail "warm: expected ZERO blob fetches"
[ "$(echo "$OUT2" | grep -c "blob HIT (disk)")" -ge 4 ] || fail "warm: expected disk HITs"

echo "[e2e] adding an agent-scoped memory"
curl -sf -m5 "${U[@]}" -X POST "http://$H/api/v1/memories" -H 'Content-Type: application/json' \
  -d "{\"type\":\"fact\",\"title\":\"E2E Rule\",\"body\":\"Always cite the run id.\",\"agent_id\":\"$AID\",\"status\":\"active\"}" >/dev/null

echo "######## (3) AFTER_MEMORY ########"
OUT3=$("$HARNESS" "http://$H" "$BT" "$AID" "$CACHE" after_memory 2>&1); echo "$OUT3"
echo "$OUT3" | grep -q "manifest MISS (200)" || fail "after_memory: expected manifest MISS(200)"
[ "$(echo "$OUT3" | grep -c "blob FETCH (hub)")" -eq 1 ] || fail "after_memory: expected EXACTLY ONE blob FETCH"
echo "$OUT3" | grep -q "contains_new_memory= true" || fail "after_memory: new memory must be in AGENTS.md"

echo
echo "PASS: TEST-1 all three scenarios (COLD 200+FETCH / WARM 304+0 fetch / AFTER_MEMORY 200+1 FETCH + memory present)"
