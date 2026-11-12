#!/usr/bin/env bash
# REQ-E2E-1, agent-driven and local: a local hub plus Bridges A and B
# (scripts/local-hub.sh, scripts/local-bridge.sh), a New-conversation
# coordinator on A sent the REQ-E2E-1 prompt through the UI's API, then
# PASS/FAIL per assertion and an evidence bundle. B has no chain directory and
# observes claude aliases only, so it exercises both .14 gaps.
#
#   scripts/e2e-req-e2e-1.sh [--timeout SECONDS] [--keep]
#
# Everything lives under $E2E_ROOT (default: a fresh temp dir) with its own
# HEIMDALL_LOCAL_STATE_ROOT and ports (hub 18181/18180/18190, A 49527/49528,
# B 49537/49538); installed services and other local instances are never
# touched. --keep leaves the processes running for inspection.
set -uo pipefail
CHECKOUT=$(cd "$(dirname "$0")/.." && pwd)
TIMEOUT=2400; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT=$2; shift 2;;
    --keep) KEEP=1; shift;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
E2E_ROOT=${E2E_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/req-e2e-1.XXXXXX")}
export HEIMDALL_LOCAL_STATE_ROOT="$E2E_ROOT/state"
EVIDENCE="$E2E_ROOT/evidence"; mkdir -p "$EVIDENCE"
HUB=e2e1; A=e2e1-a; B=e2e1-b
log() { printf '[req-e2e-1] %s\n' "$*" | tee -a "$EVIDENCE/run.log" >&2; }

cleanup() {
  [ "$KEEP" = 1 ] && { log "--keep: leaving $HUB, $A, $B running (state $E2E_ROOT)"; return; }
  (cd "$CHECKOUT" && bash scripts/local-bridge.sh stop --name "$B" >/dev/null 2>&1
   bash scripts/local-bridge.sh stop --name "$A" >/dev/null 2>&1
   bash scripts/local-hub.sh stop --name "$HUB" >/dev/null 2>&1)
  log "stopped $HUB, $A, $B"
}
trap cleanup EXIT

cd "$CHECKOUT"
log "state root $HEIMDALL_LOCAL_STATE_ROOT; HEAD $(git rev-parse --short HEAD)"
bash scripts/local-hub.sh start --name "$HUB" --hub-port 18181 --proxy-port 18180 --oidc-port 18190 --no-ui --no-plan-limits --build nix >"$EVIDENCE/hub-start.log" 2>&1 || { log "FAIL hub start"; exit 1; }
for spec in "$A 49527 49528" "$B 49537 49538"; do
  set -- $spec
  bash scripts/local-bridge.sh start --name "$1" --hub "$HUB" --port "$2" --local-endpoint-port "$3" --auto-enroll --providers claude --build nix \
    >"$EVIDENCE/$1-start.log" 2>&1 || { log "FAIL bridge $1 start"; exit 1; }
done

HUB_DIR="$HEIMDALL_LOCAL_STATE_ROOT/hubs/$HUB"
env_of() { grep -m1 "^$2=" "$1/instance.env" | cut -d= -f2-; }
API=$(env_of "$HUB_DIR" HUB_URL); DEV_USER=$(env_of "$HUB_DIR" DEV_USER)
export HEIMDALL_LOCAL_UI_ORIGIN=$(env_of "$HUB_DIR" UI_ORIGIN)
bridge_id() { grep -m1 '^daemon_id' "$HEIMDALL_LOCAL_STATE_ROOT/bridges/$1/config.toml" | sed 's/.*= *"\(.*\)"/\1/'; }
BRG_A=$(bridge_id "$A"); BRG_B=$(bridge_id "$B")
[ -n "$BRG_A" ] && [ -n "$BRG_B" ] || { log "FAIL: bridge ids not found"; exit 1; }
COORD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["seeded"]["sample-coordinator"])' "$HUB_DIR/seed.json")
PROMPT="Create a task with worker and reviewer agent running claude opus on this bridge and claude sonnet on $B bridge where task 1 runs on this bridge and task 2 runs on $B bridge."
log "hub $API, A $BRG_A, B $BRG_B ($B), coordinator agent $COORD"
printf '%s\n' "$PROMPT" >"$EVIDENCE/prompt.txt"

STARTED=$(node --import ./tests/helpers/vaultEndpointHarness.ts scripts/local-runtime/e2e-new-conversation.mjs \
  --api "$API" --key "$HUB_DIR/approver/device.json" --user "$DEV_USER" --agent "$COORD" --bridge "$BRG_A" \
  --provider claude --model claude-opus-5-5 --prompt "$PROMPT" 2>"$EVIDENCE/new-conversation.err") || { log "FAIL new conversation: $(cat "$EVIDENCE/new-conversation.err")"; exit 1; }
printf '%s\n' "$STARTED" >"$EVIDENCE/new-conversation.json"
COORD_INST=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["agent_instance_id"])' "$STARTED")
log "coordinator instance $COORD_INST"

# The owner store of Bridge A (isolated HOME): the chain the coordinator created.
owner_db() { find "$HEIMDALL_LOCAL_STATE_ROOT/bridges/$A" -path '*owner-local-*/runtime.sqlite' -not -path '*backup*' 2>/dev/null | head -1; }
q() { local db; db=$(owner_db); [ -n "$db" ] && sqlite3 -readonly -separator ' | ' "file:$db?mode=ro" "$1" 2>/dev/null; }
CHAIN=""
deadline=$((SECONDS+TIMEOUT))
while [ $SECONDS -lt $deadline ]; do
  [ -z "$CHAIN" ] && CHAIN=$(q "SELECT chain_id FROM local_chain_member_versions WHERE instance_id='$COORD_INST' AND role='coordinator' LIMIT 1")
  if [ -n "$CHAIN" ]; then
    total=$(q "SELECT count(*) FROM tasks WHERE chain_id='$CHAIN'")
    reviewed=$(q "SELECT count(DISTINCT task_id) FROM local_reviews WHERE chain_id='$CHAIN' AND verdict='approve'")
    log "chain $CHAIN: tasks ${total:-0}, agent-approved ${reviewed:-0}"
    [ "${total:-0}" -ge 2 ] && [ "${reviewed:-0}" -ge 2 ] && break
  fi
  sleep 30
done

# Evidence.
{
  echo "== fleet policies"; q "SELECT agent_id,seq,provider,model,bridge_id,bridge_models_json FROM local_fleet_policy_versions WHERE chain_id='$CHAIN' ORDER BY seq"
  echo "== members"; q "SELECT instance_id,agent_id,role,enabled,accepted_seq FROM local_chain_member_versions WHERE chain_id='$CHAIN' ORDER BY accepted_seq"
  echo "== task fleet rows"; q "SELECT task_id,instance_id,enabled,json_extract(configuration_command,'\$.method') FROM local_fleet WHERE chain_id='$CHAIN'"
  echo "== tasks"; q "SELECT t.task_id,s.state,json_extract(r.brief_json,'\$.run_bridge_id') FROM tasks t LEFT JOIN lifecycle_state s USING(chain_id,task_id) LEFT JOIN (SELECT chain_id,task_id,'' AS brief_json FROM tasks) r USING(chain_id,task_id) WHERE t.chain_id='$CHAIN'"
  echo "== leases"; q "SELECT task_id,instance_id,retired_seq FROM local_leases WHERE chain_id='$CHAIN'"
  echo "== reviews"; q "SELECT task_id,reviewer_agent_id,principal_id,verdict FROM local_reviews WHERE chain_id='$CHAIN'"
  echo "== remote journal"; q "SELECT task_id,instance_id,state FROM owner_execution_journal WHERE chain_id='$CHAIN'"
} >"$EVIDENCE/owner-store.txt"
for b in "$A" "$B"; do cp "$HEIMDALL_LOCAL_STATE_ROOT/bridges/$b/logs/"*.log "$EVIDENCE/" 2>/dev/null; done
find "$HEIMDALL_LOCAL_STATE_ROOT/bridges/$A/agent-runs" -path "*$COORD_INST*" -name '*.jsonl' -exec cat {} + >"$EVIDENCE/coordinator-transcript.jsonl" 2>/dev/null

# Assertions.
FAILS=0
check() { if [ "$2" = 1 ]; then log "PASS $1"; else log "FAIL $1${3:+: $3}"; FAILS=$((FAILS+1)); fi; }
agents=$(q "SELECT count(DISTINCT agent_id) FROM local_fleet_policy_versions WHERE chain_id='$CHAIN'")
check "one agent id per role with per-Bridge models (2 fleet agents, each with a $BRG_B bridge_models entry)" \
  "$([ "${agents:-0}" = 2 ] && [ "$(q "SELECT count(DISTINCT agent_id) FROM local_fleet_policy_versions WHERE chain_id='$CHAIN' AND bridge_models_json LIKE '%$BRG_B%'")" = 2 ] && echo 1)" "fleet agents ${agents:-0}"
check "two tasks created" "$([ "$(q "SELECT count(*) FROM tasks WHERE chain_id='$CHAIN'")" = 2 ] && echo 1)"
check "a task's worker placed on B ($BRG_B) by fleet.reserve" "$([ "$(q "SELECT count(*) FROM local_fleet WHERE chain_id='$CHAIN' AND json_extract(configuration_command,'\$.method')='fleet.reserve' AND enabled=1")" -ge 1 ] && echo 1)"
check "both tasks agent-reviewed (approve)" "$([ "$(q "SELECT count(DISTINCT task_id) FROM local_reviews WHERE chain_id='$CHAIN' AND verdict='approve'")" = 2 ] && echo 1)"
bad=$(cat "$EVIDENCE"/*.log 2>/dev/null | grep -cE 'invalid_resources|invalid_scope')
check "no invalid_resources/invalid_scope in either Bridge log" "$([ "$bad" = 0 ] && echo 1)" "$bad lines"
attach=$(grep -ciE 'project attach|--project|attach.*(project|directory)' "$EVIDENCE/coordinator-transcript.jsonl" 2>/dev/null)
check "coordinator attached no project/directory" "$([ "${attach:-0}" = 0 ] && echo 1)" "${attach:-0} matches"
errs=$(grep -cE '"ok":false' "$EVIDENCE/coordinator-transcript.jsonl" 2>/dev/null)
check "no coordinator ham-ctl errors" "$([ "${errs:-0}" = 0 ] && echo 1)" "${errs:-0} error replies"
log "evidence: $EVIDENCE ($FAILS failed)"
exit $([ "$FAILS" = 0 ] && echo 0 || echo 1)
