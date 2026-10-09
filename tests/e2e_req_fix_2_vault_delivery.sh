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
# ===== PORTS: READ THIS BEFORE CHANGING THEM =====
#
# This host runs a PRODUCTION bridge (49323/49324) and a QA stack (8110/8111/49423),
# and scripts/dev-stack.sh's defaults (8080/8081/49323-49324) collide with them.
# Every port here is deliberately outside all of those ranges. Do not "tidy" them
# back to the defaults: doing so kills the production bridge and every agent on it.
# A PATH-scoped fake systemctl restarts only this test's bridge process. Nothing
# in this script touches the installed service.
#
# Usage: tests/e2e_req_fix_2_vault_delivery.sh

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

ODIN_BIN="${ODIN_BIN:-/nix/store/4p3p3dbyygl9xj2j4rspdz7j0hw65s5c-odin-dev-2026-07a/bin/odin}"

WORK_DIR="$(mktemp -d /tmp/ham-fix2-e2e-XXXXXX)"
HUB_BIN="$WORK_DIR/ham-hub"
PROXY_BIN="$WORK_DIR/ham-dev-proxy"
PIDS=()

cleanup() {
  if [ -f "$WORK_DIR/service.pid" ]; then
    kill "$(cat "$WORK_DIR/service.pid")" 2>/dev/null || true
  fi
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
  local token_file="$home_dir/.config/heimdall/bridge-token"
  local service_pid_file="$WORK_DIR/service.pid"
  local service_log="$run_dir/service.log"
  local restart_marker="$run_dir/service-restarted"
  local fake_bin="$run_dir/fake-bin"

  say "[$label] starting hub on $HUB_PORT and proxy on $PROXY_PORT"
  "$HUB_BIN" --listen "127.0.0.1:$HUB_PORT" --db "$hub_db" \
    --trusted-proxy-cidr 127.0.0.1/32 \
    --ui-origin "http://127.0.0.1:$PROXY_PORT" >"$hub_log" 2>&1 &
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

  # Give this user a configured vault before approval. This makes the Hub return
  # vault_delivery_expected=true from the token poll, which is the contract that
  # keeps enrollment alive for the encrypted handoff.
  api POST /api/v1/user/vault '{
    "encrypted_vault_key":"ciphertext",
    "vault_key_nonce":"nonce",
    "vault_key_tag":"tag",
    "kdf_algorithm":"PBKDF2-SHA256",
    "kdf_salt":"salt",
    "kdf_iterations":100000,
    "recovery_encrypted_vault_key":"recovery-ciphertext",
    "recovery_nonce":"recovery-nonce",
    "recovery_tag":"recovery-tag",
    "recovery_salt":"recovery-salt"
  }' >/dev/null || fail "[$label] could not configure the test user vault"

  # Model the installer: register/start the bridge service first. It is allowed
  # to run without an enrollment credential. Enrollment itself opens no local
  # listeners, so both processes coexist until the final service restart.
  env HOME="$home_dir" "$bridge_bin" \
    --hub "http://127.0.0.1:$HUB_PORT" \
    --bridge-token-file "$token_file" \
    --config "$config_file" \
    --port "$BRIDGE_PORT" \
    --local-endpoint-port "$BRIDGE_LOCAL_PORT" \
    --local-run-dir "$run_dir/bridge-run" >"$service_log" 2>&1 &
  local initial_service_pid=$!
  PIDS+=("$initial_service_pid")
  printf '%s\n' "$initial_service_pid" >"$service_pid_file"

  waited=0
  until grep -q 'ham-bridge listening' "$service_log" 2>/dev/null; do
    sleep 0.25; waited=$((waited + 1))
    [ "$waited" -gt 80 ] && { cat "$service_log" >&2; fail "[$label] idle bridge service did not start"; }
    kill -0 "$initial_service_pid" 2>/dev/null || { cat "$service_log" >&2; fail "[$label] idle bridge service exited"; }
  done

  mkdir -p "$fake_bin"
  cat >"$fake_bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ] && [ "$1" = "--user" ] && [ "$2" = "restart" ] && [ "$3" = "heimdall-bridge" ]
old_pid="$(cat "$HAM_E2E_SERVICE_PID_FILE")"
kill "$old_pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  kill -0 "$old_pid" 2>/dev/null || break
  sleep 0.05
done
env HOME="$HAM_E2E_HOME" nohup "$HAM_E2E_BRIDGE_BIN" \
  --hub "$HAM_E2E_HUB_URL" \
  --bridge-token-file "$HAM_E2E_TOKEN_FILE" \
  --config "$HAM_E2E_CONFIG_FILE" \
  --port "$HAM_E2E_BRIDGE_PORT" \
  --local-endpoint-port "$HAM_E2E_LOCAL_PORT" \
  --local-run-dir "$HAM_E2E_RUN_DIR" \
  >>"$HAM_E2E_SERVICE_LOG" 2>&1 &
printf '%s\n' "$!" >"$HAM_E2E_SERVICE_PID_FILE"
: >"$HAM_E2E_RESTART_MARKER"
SYSTEMCTL
  chmod +x "$fake_bin/systemctl"

  # --- the ceremony, driven through the binary under test -------------------
  #
  # HOME is redirected so the default credential path is this run's, never the
  # operator's. --headless skips the loopback callback; polling is the guarantee
  # either way (enroll_device_flow.odin property 3), so this costs latency only.
  say "[$label] running: ham-bridge enroll --hub http://127.0.0.1:$HUB_PORT"
  env HOME="$home_dir" PATH="$fake_bin:$PATH" \
    HAM_E2E_SERVICE_PID_FILE="$service_pid_file" \
    HAM_E2E_HOME="$home_dir" \
    HAM_E2E_BRIDGE_BIN="$bridge_bin" \
    HAM_E2E_HUB_URL="http://127.0.0.1:$HUB_PORT" \
    HAM_E2E_TOKEN_FILE="$token_file" \
    HAM_E2E_CONFIG_FILE="$config_file" \
    HAM_E2E_BRIDGE_PORT="$BRIDGE_PORT" \
    HAM_E2E_LOCAL_PORT="$BRIDGE_LOCAL_PORT" \
    HAM_E2E_RUN_DIR="$run_dir/bridge-run" \
    HAM_E2E_SERVICE_LOG="$service_log" \
    HAM_E2E_RESTART_MARKER="$restart_marker" \
    "$bridge_bin" enroll \
    --hub "http://127.0.0.1:$HUB_PORT" \
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

  # Enrollment must now finish the user-visible workflow: persist the key,
  # restart the registered service, and exit successfully.
  waited=0
  while kill -0 "$enroll_pid" 2>/dev/null && [ "$waited" -lt 120 ]; do
    sleep 0.25; waited=$((waited + 1))
  done
  if kill -0 "$enroll_pid" 2>/dev/null; then
    cat "$enroll_log" >&2
    fail "[$label] enroll did not exit after vault delivery"
  fi
  if ! wait "$enroll_pid"; then
    cat "$enroll_log" >&2
    fail "[$label] enroll exited unsuccessfully"
  fi
  [ -f "$restart_marker" ] || fail "[$label] enroll never restarted the registered service"
  local restarted_service_pid
  restarted_service_pid="$(cat "$service_pid_file")"
  [ "$restarted_service_pid" != "$initial_service_pid" ] || fail "[$label] service PID did not change"
  kill -0 "$restarted_service_pid" 2>/dev/null || { cat "$service_log" >&2; fail "[$label] restarted service is not running"; }
  [ -s "$token_file" ] || fail "[$label] credential was not stored at the standard path"

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
    say "[$label] DELIVERED: enrollment exited and the restarted service reports vault_status=unlocked"
    return 0
  fi

  say "[$label] NOT DELIVERED: vault_status never reached unlocked"
  printf '[e2e] last /bridges payload: %s\n' "${bridges:0:600}" >&2
  grep -aiE "aead|unseal|tag verification" "$enroll_log" | tail -10 >&2 || true
  return 1
}

stop_run() {
  if [ -f "$WORK_DIR/service.pid" ]; then kill "$(cat "$WORK_DIR/service.pid")" 2>/dev/null || true; fi
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
command -v node >/dev/null 2>&1 || fail "node is required for the sealer"

say "building local Hub, proxy, and bridge from the tree under test"
FIX_BIN="$WORK_DIR/ham-bridge-fix"
( cd "$REPO_ROOT" && nix develop --command "$ODIN_BIN" build src/hub -collection:odin_test=src -out:"$HUB_BIN" ) \
  || fail "the Hub under test does not build"
( cd "$REPO_ROOT" && nix develop --command "$ODIN_BIN" build src/dev_proxy -collection:odin_test=src -out:"$PROXY_BIN" ) \
  || fail "the dev proxy under test does not build"
( cd "$REPO_ROOT" && nix develop --command "$ODIN_BIN" build src/bridge -collection:odin_test=src -out:"$FIX_BIN" ) \
  || fail "the bridge under test does not build"
# Freshness is proven, not assumed: a stale binary would make every observation
# below a statement about somebody else's build.
[ "$FIX_BIN" -nt "$REPO_ROOT/src/bridge/main.odin" ] \
  || fail "built binary is not newer than main.odin — refusing to trust a stale artifact"

mkdir -p "$WORK_DIR/fix"
if run_delivery_attempt "fix" "$FIX_BIN" "$WORK_DIR/fix"; then
  say "PASS: local Hub enrollment delivered the vault and handed off to the registered bridge service"
else
  fail "the fix did NOT deliver a vault key — REQ-FIX-2 is not done"
fi
stop_run
say "ALL ASSERTIONS PASSED"
say "measured approve->online: $(cat "$WORK_DIR/fix/approve_to_online_ms" 2>/dev/null || echo '?')ms against the 45000ms page budget"
