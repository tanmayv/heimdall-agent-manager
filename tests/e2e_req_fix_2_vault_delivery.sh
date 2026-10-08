#!/usr/bin/env bash
# tests/e2e_req_fix_2_vault_delivery.sh
#
# REQ-FIX-2 end-to-end: does approving an enrollment ACTUALLY DELIVER A VAULT KEY
# to the bridge? (iss_18dc71789af7a745)
#
# ===== WHAT THIS TEST IS FOR =====
#
# The defect it pins is NOT a wiring bug and cannot be caught by a unit test.
# `ham-bridge enroll` minted an ephemeral, in-memory, per-process ECDH pair, put
# the public half in the approval link's `bpk` fragment, and then EXITED. The
# approval screen seals the vault key to that fragment key with no fallback (that
# fallback was removed on purpose by REQ-IMPL-5), and delivery is relayed to a
# CONNECTED bridge — which was always a different, later process holding its own
# different pair. So the envelope was always addressed to a key no live process
# held, and delivery could not succeed on ANY path.
#
# A unit test cannot see this: the exit lived in `main.odin`'s control flow, and
# inside one test process the enroll key and the runtime key are trivially the same
# object. THE ONLY THING THAT CATCHES IT IS DRIVING THE REAL BINARY, which is what
# this does. It is the same standard REQ-FIX-1 was held to, for the same reason:
# four review gates passed the dead-input-field bug because nothing drove the real
# path.
#
# ===== WHAT IS REAL HERE AND WHAT IS SUBSTITUTED =====
#
# Real: the ham-bridge binary built from the tree under test, a real ham-hub, a real
# dev-proxy, the real `/api/v1/device/*` device-grant ceremony, the real ECDH +
# HKDF + AES-GCM seal computed by an independent WebCrypto implementation
# (tests/helpers/req_fix_2_seal.mjs), the real Hub->bridge WS relay, and the
# bridge's OWN self-reported vault status read back off the wire.
#
# Substituted: the human clicking Approve becomes a POST to /api/v1/device/approve
# as the authenticated owner — which is exactly what the browser does — and the
# vault key is a fixed test key instead of one derived from a master password.
# NOT substituted anywhere: the keys, the envelope, the relay, or the bridge.
# Browser-level concerns (the S6 fragment cross-check, the approval UI) are covered
# by REQ-IMPL-7's S5/S6 and are deliberately out of scope here.
#
# ===== THE ASSERTION, AND WHY IT IS THIS ONE =====
#
# PASS requires the bridge's `vault_status` to reach `unlocked` in `GET
# /api/v1/bridges`. That value is the BRIDGE's own report of its own state, sent
# after it decrypted the envelope and stored the key (`bridge_vault_status`,
# bridge_handlers.odin:1703). It is not the HTTP status of the unseal call and not
# this script's opinion: a 200 that the bridge then failed to act on does not pass.
#
# ===== NON-VACUITY =====
#
# Run with `--prove-non-vacuity`. The script reverts the fix in a SCRATCH COPY of
# the tree — never in the working tree — by restoring the `return` that ended the
# enroll process, rebuilds, and re-runs. That run MUST fail at the delivery step.
# A test that passes both with and against the fix proves nothing, so the script
# exits non-zero if the reverted run somehow passes.
#
# ===== PORTS: READ THIS BEFORE CHANGING THEM =====
#
# This host runs a PRODUCTION bridge (49323/49324) and a QA stack (8110/8111/49423),
# and scripts/dev-stack.sh's defaults (8080/8081/49323-49324) collide with them.
# Every port here is deliberately outside all of those ranges. Do not "tidy" them
# back to the defaults: doing so kills the production bridge and every agent on it.
# Nothing in this script ever touches systemd or the installed service.
#
# Usage:
#   tests/e2e_req_fix_2_vault_delivery.sh                     # fix must deliver
#   tests/e2e_req_fix_2_vault_delivery.sh --prove-non-vacuity # + reverted must fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HUB_PORT="${HUB_PORT:-8191}"
PROXY_PORT="${PROXY_PORT:-8190}"
BRIDGE_PORT="${BRIDGE_PORT:-49525}"
BRIDGE_LOCAL_PORT="${BRIDGE_LOCAL_PORT:-49526}"
TEST_USER="${TEST_USER:-tanmay}"

# A valid 64-char-hex vault key. Fixed, so a failure is reproducible.
VAULT_KEY_HEX="00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

HUB_BIN="$REPO_ROOT/result-hub/bin/ham-hub"
PROXY_BIN="$REPO_ROOT/result-ham-dev-proxy/bin/ham-dev-proxy"
ODIN_BIN="${ODIN_BIN:-/nix/store/4p3p3dbyygl9xj2j4rspdz7j0hw65s5c-odin-dev-2026-07a/bin/odin}"

PROVE_NON_VACUITY=false
[ "${1:-}" = "--prove-non-vacuity" ] && PROVE_NON_VACUITY=true

WORK_DIR="$(mktemp -d /tmp/ham-fix2-e2e-XXXXXX)"
PIDS=()

cleanup() {
  for pid in ${PIDS+"${PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

say()  { printf '\n[e2e] %s\n' "$*"; }
fail() { printf '\n[e2e] FAIL: %s\n' "$*" >&2; exit 1; }

require_free_port() {
  # A port already held would make this test report on somebody else's process.
  if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$1 "; then
    fail "port $1 is already in use; refusing to run (it would attach to another process)"
  fi
}

api() { # api <METHOD> <PATH> [BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "http://127.0.0.1:$PROXY_PORT$path" \
      -H 'Content-Type: application/json' --data "$body" 2>/dev/null
  else
    curl -fsS -X "$method" "http://127.0.0.1:$PROXY_PORT$path" 2>/dev/null
  fi
}

json_field() { # json_field <json> <key> -- string or number, first match
  printf '%s' "$1" | grep -oP "\"$2\"\\s*:\\s*\"?\\K[^\",}]+" | head -1
}

now_ms() { date +%s%3N; }

# ---------------------------------------------------------------------------
# One full run against a given ham-bridge binary.
# Returns 0 if the vault key was delivered, 1 if it was not.
# ---------------------------------------------------------------------------
run_delivery_attempt() { # run_delivery_attempt <label> <bridge_binary> <run_dir>
  local label="$1" bridge_bin="$2" run_dir="$3"
  local home_dir="$run_dir/home"
  mkdir -p "$home_dir/.config/heimdall" "$home_dir/.local/share/heimdall"

  local hub_db="$run_dir/hub.db"
  local hub_log="$run_dir/hub.log"
  local proxy_log="$run_dir/proxy.log"
  local enroll_log="$run_dir/enroll.log"
  local config_file="$home_dir/.config/heimdall/config.toml"
  local token_file="$home_dir/.local/share/heimdall/bridge-credential"

  say "[$label] starting hub on $HUB_PORT and proxy on $PROXY_PORT"
  "$HUB_BIN" --listen "127.0.0.1:$HUB_PORT" --db "$hub_db" \
    --trusted-proxy-cidr 127.0.0.1/32 >"$hub_log" 2>&1 &
  PIDS+=($!)
  local hub_pid="${PIDS[-1]}"

  # Readiness is "it answered HTTP at all". There is deliberately no /health
  # route on the hub, and probing one that does not exist would have made this
  # loop time out on a perfectly healthy hub — so any status code counts, and
  # only curl's 000 (no response) means not yet.
  local waited=0
  until [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HUB_PORT/api/v1/bridges" 2>/dev/null)" != "000" ]; do
    sleep 0.5; waited=$((waited + 1))
    [ "$waited" -gt 60 ] && { tail -20 "$hub_log" >&2; fail "[$label] hub did not become healthy"; }
    kill -0 "$hub_pid" 2>/dev/null || { tail -20 "$hub_log" >&2; fail "[$label] hub exited"; }
  done

  "$PROXY_BIN" --listen "127.0.0.1:$PROXY_PORT" \
    --hub-url "http://127.0.0.1:$HUB_PORT" --default-user "$TEST_USER" >"$proxy_log" 2>&1 &
  PIDS+=($!)
  local proxy_pid="${PIDS[-1]}"

  waited=0
  until [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT/api/v1/bridges" 2>/dev/null)" != "000" ]; do
    sleep 0.5; waited=$((waited + 1))
    [ "$waited" -gt 60 ] && { tail -20 "$proxy_log" >&2; fail "[$label] proxy did not come up"; }
    kill -0 "$proxy_pid" 2>/dev/null || { tail -20 "$proxy_log" >&2; fail "[$label] proxy exited"; }
  done

  # --- the ceremony, driven through the binary under test -------------------
  #
  # HOME is redirected so the default credential path is this run's, never the
  # operator's. --headless skips the loopback callback; polling is the guarantee
  # either way (enroll_device_flow.odin property 3), so this costs latency only.
  say "[$label] running: ham-bridge enroll --ui http://127.0.0.1:$PROXY_PORT"
  env HOME="$home_dir" "$bridge_bin" enroll \
    --ui "http://127.0.0.1:$PROXY_PORT" \
    --bridge-token-file "$token_file" \
    --config "$config_file" \
    --port "$BRIDGE_PORT" \
    --local-endpoint-port "$BRIDGE_LOCAL_PORT" \
    --local-run-dir "$run_dir/bridge-run" \
    --headless >"$enroll_log" 2>&1 &
  PIDS+=($!)
  local enroll_pid="${PIDS[-1]}"

  # --- read bpk and the user code out of the link it printed ---------------
  waited=0
  until grep -aq "bpk=" "$enroll_log" 2>/dev/null; do
    sleep 0.5; waited=$((waited + 1))
    [ "$waited" -gt 120 ] && { cat "$enroll_log" >&2; fail "[$label] enroll never printed an approval link"; }
    kill -0 "$enroll_pid" 2>/dev/null || { cat "$enroll_log" >&2; fail "[$label] enroll exited before printing a link"; }
  done

  local bpk user_code
  bpk="$(grep -ao "bpk=[0-9a-f]*" "$enroll_log" | head -1 | cut -d= -f2)"
  user_code="$(grep -aoP 'enter the code\s+\K\S+' "$enroll_log" | head -1)"
  [ -n "$bpk" ] || { cat "$enroll_log" >&2; fail "[$label] could not read bpk from the approval link"; }
  [ -n "$user_code" ] || { cat "$enroll_log" >&2; fail "[$label] could not read the user code"; }
  [ "${#bpk}" -eq 130 ] || fail "[$label] bpk is ${#bpk} chars, expected 130 (65-byte point in hex)"
  say "[$label] approval link carries bpk=${bpk:0:16}…${bpk: -16} code=$user_code"

  # --- approve, exactly as the browser does -------------------------------
  local approve_ms approve_resp
  approve_ms="$(now_ms)"
  approve_resp="$(api POST /api/v1/device/approve \
    "{\"user_code\":\"$user_code\",\"approve\":true}")" \
    || { cat "$enroll_log" >&2; fail "[$label] approve call failed"; }

  local bridge_id
  bridge_id="$(json_field "$approve_resp" bridge_id)"
  [ -n "$bridge_id" ] || fail "[$label] approve returned no bridge_id: $approve_resp"
  say "[$label] approved; bridge_id=$bridge_id"

  # --- wait for the bridge to be ONLINE -----------------------------------
  #
  # This is the window BRIDGE_ONLINE_TIMEOUT_SECONDS=45 bounds in the approval
  # page. We MEASURE it rather than assume it; the number is reported so a
  # regression in it is visible instead of silently eating the operator's margin.
  local online=false online_ms delta_ms bridges
  waited=0
  while [ "$waited" -lt 120 ]; do
    bridges="$(api GET /api/v1/bridges || true)"
    if printf '%s' "$bridges" | tr ',' '\n' | grep -a "$bridge_id" >/dev/null 2>&1 \
       && printf '%s' "$bridges" | grep -a "\"status\":\"online\"" >/dev/null 2>&1; then
      online=true; online_ms="$(now_ms)"; break
    fi
    sleep 0.5; waited=$((waited + 1))
  done

  if [ "$online" != true ]; then
    say "[$label] bridge never came online — nothing to relay a sealed key to"
    tail -25 "$enroll_log" >&2 || true
    return 1
  fi
  delta_ms=$((online_ms - approve_ms))
  say "[$label] MEASURED approve->online: ${delta_ms}ms (page budget: 45000ms)"
  printf '%s\n' "$delta_ms" > "$run_dir/approve_to_online_ms"

  # --- seal the vault key to the FRAGMENT key and deliver it ---------------
  say "[$label] sealing a vault key to the link's bpk and POSTing the unseal"
  local payload unseal_resp
  payload="$(node "$SCRIPT_DIR/helpers/req_fix_2_seal.mjs" "$bridge_id" "$bpk" "$VAULT_KEY_HEX")" \
    || fail "[$label] the sealer itself failed — harness bug, not a product result"
  unseal_resp="$(api POST "/api/v1/bridges/$bridge_id/unseal" "$payload" || true)"
  say "[$label] unseal response: ${unseal_resp:0:240}"

  # --- THE ASSERTION: the bridge's own report of its own vault state -------
  local unlocked=false
  waited=0
  while [ "$waited" -lt 60 ]; do
    bridges="$(api GET /api/v1/bridges || true)"
    if printf '%s' "$bridges" | grep -a "\"vault_status\":\"unlocked\"" >/dev/null 2>&1; then
      unlocked=true; break
    fi
    sleep 0.5; waited=$((waited + 1))
  done

  if [ "$unlocked" = true ]; then
    say "[$label] DELIVERED: the bridge reports vault_status=unlocked"
    return 0
  fi

  say "[$label] NOT DELIVERED: vault_status never reached unlocked"
  printf '[e2e] last /bridges payload: %s\n' "${bridges:0:600}" >&2
  grep -aiE "aead|unseal|tag verification" "$enroll_log" | tail -10 >&2 || true
  return 1
}

stop_run() {
  for pid in ${PIDS+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  PIDS=()
  sleep 1
}

# ===========================================================================
# 1. The fix must deliver.
# ===========================================================================
for p in "$HUB_PORT" "$PROXY_PORT" "$BRIDGE_PORT" "$BRIDGE_LOCAL_PORT"; do
  require_free_port "$p"
done
[ -x "$HUB_BIN" ]   || fail "no hub binary at $HUB_BIN"
[ -x "$PROXY_BIN" ] || fail "no proxy binary at $PROXY_BIN"
command -v node >/dev/null 2>&1 || fail "node is required for the sealer"

say "building ham-bridge from the tree under test"
FIX_BIN="$WORK_DIR/ham-bridge-fix"
( cd "$REPO_ROOT" && "$ODIN_BIN" build src/bridge -collection:odin_test=src -out:"$FIX_BIN" ) \
  || fail "the bridge under test does not build"
# Freshness is proven, not assumed: a stale binary would make every observation
# below a statement about somebody else's build.
[ "$FIX_BIN" -nt "$REPO_ROOT/src/bridge/main.odin" ] \
  || fail "built binary is not newer than main.odin — refusing to trust a stale artifact"

mkdir -p "$WORK_DIR/fix"
if run_delivery_attempt "fix" "$FIX_BIN" "$WORK_DIR/fix"; then
  say "PASS (1/2): the fix delivers a vault key end to end"
else
  fail "the fix did NOT deliver a vault key — REQ-FIX-2 is not done"
fi
stop_run

[ "$PROVE_NON_VACUITY" = true ] || {
  say "ALL ASSERTIONS PASSED (re-run with --prove-non-vacuity to also prove the test can fail)"
  exit 0
}

# ===========================================================================
# 2. Non-vacuity: with the fix reverted, delivery MUST fail.
#
# The revert happens in a scratch copy of the tree. The working tree is never
# modified by this script.
# ===========================================================================
say "building a REVERTED bridge (the enroll process exits again) to prove this test can fail"
REVERT_TREE="$WORK_DIR/revert-tree"
mkdir -p "$REVERT_TREE"
cp -r "$REPO_ROOT/src" "$REVERT_TREE/src"
# src/bridge `#load`s two files from OUTSIDE src (`src/prompts/bootstrap_agents.md`
# is inside, `tools/telemetry/telegraf.conf.template` is not), and #load is resolved
# at COMPILE time relative to the source file. Copying only src/ therefore fails the
# build rather than the test — which is a harness defect that looks exactly like the
# reverted build being broken. Enumerated with:
#   grep -rn '#load(' --include=*.odin src/bridge/
cp -r "$REPO_ROOT/tools" "$REVERT_TREE/tools"

# Restore the exit that REQ-FIX-2 removed: put `return` back after the enroll call.
python3 - "$REVERT_TREE/src/bridge/main.odin" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()
needle = "\t\tif !bridge_enroll_device_command(os.args) do os.exit(1)\n"
if needle not in src:
    sys.exit("revert failed: could not find the enroll dispatch line")
# The pre-REQ-FIX-2 shape: exit the process as soon as enrollment finishes.
src = src.replace(needle, needle + "\t\treturn\n", 1)
open(path, "w").write(src)
PY
grep -A1 "if !bridge_enroll_device_command" "$REVERT_TREE/src/bridge/main.odin" | grep -q "return" \
  || fail "revert did not apply — a non-vacuity check that did not revert anything proves nothing"

REVERT_BIN="$WORK_DIR/ham-bridge-reverted"
( cd "$REVERT_TREE" && "$ODIN_BIN" build src/bridge -collection:odin_test=src -out:"$REVERT_BIN" ) \
  || fail "the reverted tree does not build"

mkdir -p "$WORK_DIR/revert"
if run_delivery_attempt "reverted" "$REVERT_BIN" "$WORK_DIR/revert"; then
  fail "THE REVERTED BUILD ALSO DELIVERED. This test does not actually test the fix — do not trust run 1."
else
  say "PASS (2/2): with the fix reverted, delivery fails as it must"
fi
stop_run

say "ALL ASSERTIONS PASSED — delivery works with the fix, and fails without it"
say "measured approve->online: $(cat "$WORK_DIR/fix/approve_to_online_ms" 2>/dev/null || echo '?')ms against the 45000ms page budget"
