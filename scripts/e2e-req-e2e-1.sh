#!/usr/bin/env bash
# REQ-E2E-1, agent-driven and local: a local hub plus Bridges A and B
# (scripts/local-hub.sh, scripts/local-bridge.sh), a New-conversation
# coordinator on A sent the REQ-E2E-1 prompt through the UI's API, then
# PASS/FAIL per assertion and an evidence bundle. B has no chain directory and
# observes claude aliases only, so it exercises both .14 gaps.
#
#   scripts/e2e-req-e2e-1.sh [--timeout SECONDS] [--keep] [--bin-dirs HUB_BIN:BRIDGE_BIN]
#   (HUB_BIN needs ham-hub and ham-dev-proxy; BRIDGE_BIN ham-bridge, ham-ctl, ham-pty-host.
#    E2E_TZ_HUB / E2E_TZ_A / E2E_TZ_B set each process's time zone.)
#
# Everything lives under $E2E_ROOT (default: a fresh temp dir) with its own
# HEIMDALL_LOCAL_STATE_ROOT and ports (hub 18181/18180/18190, A 49527/49528,
# B 49537/49538); installed services and other local instances are never
# touched. --keep leaves the processes running for inspection. --bin-dirs reuses
# built binaries (a hub bin dir with ham-hub/ham-dev-proxy and a Bridge bin dir
# with ham-bridge/ham-ctl/ham-pty-host) instead of a nix build.
set -uo pipefail
CHECKOUT=$(cd "$(dirname "$0")/.." && pwd)
TIMEOUT=2400; KEEP=0; HUB_BUILD=(--build nix); BRIDGE_BUILD=(--build nix)
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT=$2; shift 2;;
    --keep) KEEP=1; shift;;
    --bin-dirs) HUB_BUILD=(--bin-dir "${2%%:*}"); BRIDGE_BUILD=(--bin-dir "${2#*:}"); shift 2;;
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
  # local-bridge.sh stop leaves agents (and a pty-host daemon a provider probe
  # started outside the endpoint dir) running: stop whatever still runs from
  # this run's state root or names its Bridges.
  for pat in "$HEIMDALL_LOCAL_STATE_ROOT/" ${BRG_A:+"pty-host-$BRG_A"} ${BRG_B:+"pty-host-$BRG_B"}; do pkill -f -- "$pat" 2>/dev/null; done
  log "stopped $HUB, $A, $B"
}
BRG_A=""; BRG_B=""
trap cleanup EXIT

cd "$CHECKOUT"
log "state root $HEIMDALL_LOCAL_STATE_ROOT; HEAD $(git rev-parse --short HEAD)"
# Bridges in different time zones must work together (user 10:11Z): the Hub
# and Bridge A run in E2E_TZ_HUB/E2E_TZ_A, Bridge B in E2E_TZ_B (inherited by
# each Bridge and its agents). Recorded in the evidence.
TZ_HUB=${E2E_TZ_HUB:-America/Los_Angeles}; TZ_A=${E2E_TZ_A:-America/Los_Angeles}; TZ_B=${E2E_TZ_B:-Asia/Kolkata}
printf 'hub %s\n%s %s\n%s %s\n' "$TZ_HUB" "$A" "$TZ_A" "$B" "$TZ_B" >"$EVIDENCE/timezones.txt"
log "time zones: hub $TZ_HUB, $A $TZ_A, $B $TZ_B"
TZ="$TZ_HUB" bash scripts/local-hub.sh start --name "$HUB" --hub-port 18181 --proxy-port 18180 --oidc-port 18190 --no-ui --no-plan-limits "${HUB_BUILD[@]}" >"$EVIDENCE/hub-start.log" 2>&1 || { log "FAIL hub start"; exit 1; }
for spec in "$A 49527 49528 $TZ_A" "$B 49537 49538 $TZ_B"; do
  set -- $spec
  TZ="$4" bash scripts/local-bridge.sh start --name "$1" --hub "$HUB" --port "$2" --local-endpoint-port "$3" --auto-enroll --providers claude "${BRIDGE_BUILD[@]}" \
    >"$EVIDENCE/$1-start.log" 2>&1 || { log "FAIL bridge $1 start"; exit 1; }
done

HUB_DIR="$HEIMDALL_LOCAL_STATE_ROOT/hubs/$HUB"
env_of() { grep -m1 "^$2=" "$1/instance.env" | cut -d= -f2-; }
API=$(env_of "$HUB_DIR" HUB_URL); DEV_USER=$(env_of "$HUB_DIR" DEV_USER)
export HEIMDALL_LOCAL_UI_ORIGIN=$(env_of "$HUB_DIR" UI_ORIGIN)
bridge_id() { grep -m1 '^daemon_id' "$HEIMDALL_LOCAL_STATE_ROOT/bridges/$1/config.toml" | sed 's/.*= *"\(.*\)"/\1/'; }
BRG_A=$(bridge_id "$A"); BRG_B=$(bridge_id "$B")
[ -n "$BRG_A" ] && [ -n "$BRG_B" ] || { log "FAIL: bridge ids not found"; exit 1; }
# Settings > Bridges: enable claude on both Bridges (fresh local Bridges report
# no enabled provider, and POST /chats then answers 503 provider_unavailable).
for b in "$BRG_A" "$BRG_B"; do
  node scripts/local-runtime/e2e-enable-provider.mjs --api "$API" --bridge "$b" --user "$DEV_USER" \
    >>"$EVIDENCE/provider-status.jsonl" 2>>"$EVIDENCE/provider-enable.err" || { log "FAIL enable claude on $b: $(cat "$EVIDENCE/provider-enable.err")"; exit 1; }
done
# B observes no claude-sonnet-5-5 (no live model probe on a local Bridge): the
# placement must rely on the active account catalog (F4 gap B).
for b in "$A" "$B"; do
  { echo "== $b observed models"; cat "$HEIMDALL_LOCAL_STATE_ROOT/bridges/$b/data/provider_models.json" 2>/dev/null || echo "(none observed)"; } >>"$EVIDENCE/observed-models.txt"
done
LABEL_B=$(sqlite3 -readonly "file:$HUB_DIR/hub.db?mode=ro" "SELECT label FROM bridges WHERE bridge_id='$BRG_B'")
COORD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["seeded"]["sample-coordinator"])' "$HUB_DIR/seed.json")
PROMPT="Create a task with worker and reviewer agent running claude opus on this bridge and claude sonnet on $LABEL_B bridge where task 1 runs on this bridge and task 2 runs on $LABEL_B bridge."
log "hub $API, A $BRG_A, B $BRG_B ($LABEL_B), coordinator agent $COORD"
printf '%s\n' "$PROMPT" >"$EVIDENCE/prompt.txt"

STARTED=$(node --import ./tests/helpers/vaultEndpointHarness.ts scripts/local-runtime/e2e-new-conversation.mjs \
  --api "$API" --key "$HUB_DIR/approver/device.json" --user "$DEV_USER" --agent "$COORD" --bridge "$BRG_A" \
  --provider claude --model claude-opus-5-5 --prompt "$PROMPT" 2>"$EVIDENCE/new-conversation.err") || { log "FAIL new conversation: $(cat "$EVIDENCE/new-conversation.err")"; exit 1; }
printf '%s\n' "$STARTED" >"$EVIDENCE/new-conversation.json"
COORD_INST=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["agent_instance_id"])' "$STARTED")
CONVERSATION=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["conversation_id"])' "$STARTED")
log "coordinator instance $COORD_INST"

# The owner store of Bridge A (isolated HOME): the chain the coordinator created.
owner_db() { find "$HEIMDALL_LOCAL_STATE_ROOT/bridges/$A" -path '*owner-local-*/runtime.sqlite' -not -path '*backup*' 2>/dev/null | head -1; }
q() { local db; db=$(owner_db); [ -n "$db" ] && sqlite3 -readonly -separator ' | ' "file:$db?mode=ro" "$1" 2>/dev/null; }
CHAIN=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("chain_id",""))' "$STARTED")
# Work tasks: every task whose brief does not ask for the user's approval (the
# coordinator's planning task does; the scripted user approves it below).
WORK="SELECT t.task_id FROM tasks t WHERE t.chain_id='$CHAIN' AND coalesce((SELECT json_extract(r.brief_json,'\$.requires_user_approval') FROM task_requirements r WHERE r.chain_id=t.chain_id AND r.task_id=t.task_id ORDER BY r.revision DESC LIMIT 1),0) NOT IN (1,'true')"
AGENT_APPROVED="SELECT count(DISTINCT task_id) FROM local_reviews WHERE chain_id='$CHAIN' AND verdict='approve' AND principal_kind='agent' AND task_id IN ($WORK)"
deadline=$((SECONDS+TIMEOUT))
while [ $SECONDS -lt $deadline ]; do
  [ -z "$CHAIN" ] && CHAIN=$(q "SELECT chain_id FROM local_chain_member_versions WHERE instance_id='$COORD_INST' AND role='coordinator' LIMIT 1")
  if [ -n "$CHAIN" ]; then
    # The scripted user: approve what waits for the user (UI Approve path).
    # A chain proposal still pending after the chat approval would need a UI
    # click: the scripted user approves it (signed chain.decide) as a
    # fallback, and the run records it (S1: chat approval is enough).
    PROPOSAL=""
    if [ -s "$EVIDENCE/user-messages.jsonl" ]; then
      PROPOSAL=$(q "SELECT json_extract(defaults_json,'\$.proposal.proposal_id') FROM local_chain_defaults_versions WHERE chain_id='$CHAIN' AND json_extract(defaults_json,'\$.proposal.status')='pending' ORDER BY accepted_seq DESC LIMIT 1")
      [ -n "$PROPOSAL" ] && { echo "$PROPOSAL" >>"$EVIDENCE/ui-clicks.txt"; log "pending proposal $PROPOSAL after chat approval: scripted user approves it (UI-click fallback)"; }
    fi
    node --import ./tests/helpers/vaultEndpointHarness.ts scripts/local-runtime/e2e-owner-user.mjs \
      --api "$API" --key "$HUB_DIR/approver/device.json" --user "$DEV_USER" --bridge "$BRG_A" --chain "$CHAIN" ${PROPOSAL:+--proposal "$PROPOSAL"} \
      >"$EVIDENCE/user-approvals.last" 2>>"$EVIDENCE/user-approvals.err" || log "scripted user pass failed (see user-approvals.err)"
    if [ -s "$EVIDENCE/user-approvals.last" ]; then
      cat "$EVIDENCE/user-approvals.last" >>"$EVIDENCE/user-approvals.jsonl"
      log "scripted user approved: $(tr '\n' ' ' <"$EVIDENCE/user-approvals.last")"
      # And tells the coordinator in chat, as a user would after Approve.
      node --import ./tests/helpers/vaultEndpointHarness.ts scripts/local-runtime/e2e-new-conversation.mjs \
        --api "$API" --key "$HUB_DIR/approver/device.json" --user "$DEV_USER" --conversation "$CONVERSATION" \
        --prompt "I approved the plan. Go ahead." >>"$EVIDENCE/user-messages.jsonl" 2>>"$EVIDENCE/user-approvals.err"
    fi
    total=$(q "SELECT count(*) FROM ($WORK)")
    # A coordinator may ask for plan approval in chat instead of a planning
    # task: with no work task after ~2 minutes, the user approves in chat once.
    if [ "${total:-0}" = 0 ] && [ ! -s "$EVIDENCE/user-messages.jsonl" ]; then
      IDLE=$((${IDLE:-0}+1))
      if [ "$IDLE" -ge 4 ]; then
        log "no work task yet: scripted user approves the plan in chat"
        node --import ./tests/helpers/vaultEndpointHarness.ts scripts/local-runtime/e2e-new-conversation.mjs \
          --api "$API" --key "$HUB_DIR/approver/device.json" --user "$DEV_USER" --conversation "$CONVERSATION" \
          --prompt "Approved, go ahead with the plan." >>"$EVIDENCE/user-messages.jsonl" 2>>"$EVIDENCE/user-approvals.err"
      fi
    fi
    reviewed=$(q "$AGENT_APPROVED")
    log "chain $CHAIN: work tasks ${total:-0}, agent-approved ${reviewed:-0}"
    [ "${total:-0}" -ge 2 ] && [ "${reviewed:-0}" -ge "${total:-0}" ] && break
  fi
  sleep 30
done

# Evidence.
{
  echo "== fleet policies"; q "SELECT agent_id,seq,provider,model,bridge_id,bridge_models_json FROM local_fleet_policy_versions WHERE chain_id='$CHAIN' ORDER BY seq"
  echo "== members"; q "SELECT instance_id,agent_id,role,enabled,accepted_seq FROM local_chain_member_versions WHERE chain_id='$CHAIN' ORDER BY accepted_seq"
  echo "== task fleet rows"; q "SELECT task_id,instance_id,enabled,json_extract(configuration_command,'\$.method') FROM local_fleet WHERE chain_id='$CHAIN'"
  echo "== tasks (task, lifecycle, latest brief)"; q "SELECT t.task_id,s.state,(SELECT r.brief_json FROM task_requirements r WHERE r.chain_id=t.chain_id AND r.task_id=t.task_id ORDER BY r.revision DESC LIMIT 1) FROM tasks t LEFT JOIN lifecycle_state s USING(chain_id,task_id) WHERE t.chain_id='$CHAIN'"
  echo "== leases"; q "SELECT task_id,instance_id,retired_seq FROM local_leases WHERE chain_id='$CHAIN'"
  echo "== reviews"; q "SELECT task_id,reviewer_agent_id,principal_id,verdict FROM local_reviews WHERE chain_id='$CHAIN'"
  echo "== remote journal"; q "SELECT task_id,instance_id,state FROM owner_execution_journal WHERE chain_id='$CHAIN'"
} >"$EVIDENCE/owner-store.txt"
sqlite3 -readonly -header "file:$HUB_DIR/hub.db?mode=ro" "SELECT agent_instance_id,agent_id,bridge_id,provider,model,project_id,chain_id,runtime_status,run_count,current_task_id,current_task_role FROM agent_instances ORDER BY created_at" >"$EVIDENCE/hub-instances.txt" 2>&1
for b in "$A" "$B"; do for f in "$HEIMDALL_LOCAL_STATE_ROOT/bridges/$b/logs/"*.log; do cp "$f" "$EVIDENCE/$b-$(basename "$f")" 2>/dev/null; done; done
# Claude Code keeps the coordinator's session under the isolated HOME, keyed by
# its run directory (.../endpoint/instances/<instance>).
find "$HEIMDALL_LOCAL_STATE_ROOT/bridges/$A/home/.claude/projects" -path "*${COORD_INST//_/-}*" -name '*.jsonl' -exec cat {} + >"$EVIDENCE/coordinator-transcript.jsonl" 2>/dev/null

# Assertions.
FAILS=0
check() { if [ "$2" = 1 ]; then log "PASS $1"; else log "FAIL $1${3:+: $3}"; FAILS=$((FAILS+1)); fi; }
# Task-agent fleet rows only: a coordinator may also give itself a fleet row.
agents=$(q "SELECT count(DISTINCT agent_id) FROM local_fleet_policy_versions WHERE chain_id='$CHAIN' AND agent_id<>'$COORD'")
check "one agent id per role with per-Bridge models (2 fleet agents, each with a $BRG_B bridge_models entry)" \
  "$([ "${agents:-0}" = 2 ] && [ "$(q "SELECT count(DISTINCT agent_id) FROM local_fleet_policy_versions WHERE chain_id='$CHAIN' AND bridge_models_json LIKE '%$BRG_B%'")" = 2 ] && echo 1)" "fleet agents ${agents:-0}"
check "two work tasks created" "$([ "$(q "SELECT count(*) FROM ($WORK)")" = 2 ] && echo 1)" "$(q "SELECT count(*) FROM ($WORK)") work tasks"
# Instance records (hub.db, as the UI lists them): the task agents that ran.
hq() { sqlite3 -readonly -separator ' | ' "file:$HUB_DIR/hub.db?mode=ro" "$1" 2>/dev/null; }
ran() { hq "SELECT count(DISTINCT agent_id) FROM agent_instances WHERE bridge_id='$1' AND model='$2' AND agent_id<>'$COORD' AND run_count>0"; }
check "task 1 worker+reviewer ran on A ($BRG_A) with claude-opus-5-5" "$([ "$(ran "$BRG_A" claude-opus-5-5)" -ge 2 ] && echo 1)" "$(ran "$BRG_A" claude-opus-5-5) agents"
# B's task agents are remote executor launches (not in the hub's instance
# list): B's executor store records each issuance with its configuration, and
# B's log records each launch ('bridge startup: <instance>').
bdb=$(find "$HEIMDALL_LOCAL_STATE_ROOT/bridges/$B" -path '*executor-local-*/runtime.sqlite' -not -path '*backup*' 2>/dev/null | head -1)
b_issued=$([ -n "$bdb" ] && sqlite3 -readonly "file:$bdb?mode=ro" "SELECT instance_id FROM executor_issuances WHERE json_extract(json_extract(result_json,'\$.configuration'),'\$.model')='claude-sonnet-5-5'" 2>/dev/null)
b_launched=0; for i in $b_issued; do grep -q "bridge startup: $i " "$EVIDENCE/$B-bridge.log" 2>/dev/null && b_launched=$((b_launched+1)); done
{ echo "== B executor issuances (instance, chain, task, configuration)"; [ -n "$bdb" ] && sqlite3 -readonly "file:$bdb?mode=ro" "SELECT instance_id,chain_id,task_id,json_extract(result_json,'\$.configuration') FROM executor_issuances"; } >>"$EVIDENCE/owner-store.txt" 2>&1
check "task 2 agents issued and launched on B ($BRG_B) with claude-sonnet-5-5" "$([ "$b_launched" -ge 1 ] && echo 1)" "$(echo $b_issued | wc -w) issued, $b_launched launched"
# R1 FIX A: B's reviewer is launched through the Hub (local_native) and
# relays its owner verbs, so it is in the hub's instance list, not an issuance.
b_hub=$(ran "$BRG_B" claude-sonnet-5-5)
check "task 2 worker+reviewer both ran on B with claude-sonnet-5-5" "$([ $((b_launched+${b_hub:-0})) -ge 2 ] && echo 1)" "$b_launched executor launched, ${b_hub:-0} hub-launched"
check "a task's worker placed on B ($BRG_B) by fleet.reserve" "$([ "$(q "SELECT count(*) FROM local_fleet WHERE chain_id='$CHAIN' AND json_extract(configuration_command,'\$.method')='fleet.reserve' AND enabled=1")" -ge 1 ] && echo 1)"
check "both work tasks agent-reviewed (approve)" "$([ "$(q "$AGENT_APPROVED")" = 2 ] && echo 1)" "$(q "$AGENT_APPROVED") agent-approved"
bad=$(cat "$EVIDENCE/$A-bridge.log" "$EVIDENCE/$B-bridge.log" 2>/dev/null | grep -cE 'invalid_resources|invalid_scope')
check "no invalid_resources/invalid_scope in either Bridge log" "$([ "$bad" = 0 ] && echo 1)" "$bad lines"
TX=scripts/local-runtime/e2e-transcript.py
python3 "$TX" --attach <"$EVIDENCE/coordinator-transcript.jsonl" >"$EVIDENCE/coordinator-attach.txt" 2>/dev/null
check "coordinator attached no project/directory" "$([ ! -s "$EVIDENCE/coordinator-attach.txt" ] && echo 1)" "$(head -2 "$EVIDENCE/coordinator-attach.txt" | tr '\n' ';')"
python3 "$TX" --errors <"$EVIDENCE/coordinator-transcript.jsonl" >"$EVIDENCE/coordinator-errors.txt" 2>/dev/null
check "no coordinator ham-ctl errors" "$([ ! -s "$EVIDENCE/coordinator-errors.txt" ] && echo 1)" "$(wc -l <"$EVIDENCE/coordinator-errors.txt") error replies: $(grep -oE '"code":"[a-z_]+"' "$EVIDENCE/coordinator-errors.txt" | sort | uniq -c | tr -s ' \n' ' ')"
# Every Bridge delivery to the coordinator (owner notices such as the user's
# verdict, chat messages) must reach it: a live coordinator never stays pending.
undelivered=$(grep -hE "pending \(coordinator not live\).*$COORD_INST|pending/no-agent-subscription $COORD_INST" "$EVIDENCE/$A-bridge.log" 2>/dev/null | sort | uniq -c | sort -rn)
check "Bridge A delivered notices and user messages to the live coordinator" "$([ -z "$undelivered" ] && echo 1)" "$(printf '%s' "$undelivered" | head -3 | tr '\n' ';')"
python3 "$TX" <"$EVIDENCE/coordinator-transcript.jsonl" >"$EVIDENCE/coordinator-transcript.txt" 2>/dev/null
# S1 (user 10:45Z): chat approval is enough; the coordinator auto-approves its
# own proposal, so the user is never asked to click Approve in the UI.
check "no UI approval click was needed (chat approval was enough)" "$([ ! -s "$EVIDENCE/ui-clicks.txt" ] && echo 1)" "pending proposals approved by the scripted user: $(sort -u "$EVIDENCE/ui-clicks.txt" 2>/dev/null | tr '\n' ' ')"
log "evidence: $EVIDENCE ($FAILS failed)"
exit $([ "$FAILS" = 0 ] && echo 0 || echo 1)
