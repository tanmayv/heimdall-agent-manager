#!/usr/bin/env bash
# Smoke test: real pi wrappers + task/review/message interoperability
#
# What this covers:
#   1. Start isolated ham-daemon + two real ham-wrapper(pi) agents
#   2. Create a task chain with assignee/reviewer tasks and dependencies
#   3. Activate the chain and verify auto-promotion / auto-claim
#   4. Send agent-to-agent messages and verify inbox delivery both directions
#   5. Submit task 1 for review and verify review_ready gating
#   6. Approve task 1 and verify dependent task 2 auto-promotes
#   7. Verify task log / daemon log event trail
#
# Notes:
#   - Uses a temporary data dir, config, port, and tmux session.
#   - Requires a working `pi` binary on PATH.
#   - Does not touch the user's normal Heimdall data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PI_BIN="$(command -v pi || true)"
if [ -z "$PI_BIN" ]; then
  echo "SKIP: pi binary not found on PATH"
  exit 0
fi

TMP="$(mktemp -d /tmp/heimdall-pi-agents.XXXXXX)"
PORT="${HEIMDALL_PI_SMOKE_PORT:-49572}"
SESSION="pi-smoke-${RANDOM}-$$"

cleanup() {
  set +e
  [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null || true
  [ -n "${P1:-}" ] && kill "$P1" 2>/dev/null || true
  [ -n "${P2:-}" ] && kill "$P2" 2>/dev/null || true
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  echo "ARTIFACTS=$TMP"
}
trap cleanup EXIT

OUTS="$(nix build "$REPO_DIR"#ham-daemon "$REPO_DIR"#ham-wrapper "$REPO_DIR"#ham-ctl --no-link --print-out-paths)"
D="$(echo "$OUTS" | sed -n '1p')/bin/ham-daemon"
W="$(echo "$OUTS" | sed -n '2p')/bin/ham-wrapper"
C="$(echo "$OUTS" | sed -n '3p')/bin/ham-ctl"

cat > "$TMP/config.toml" <<EOF
[daemon]
bind_host = "127.0.0.1"
advertise_host = "127.0.0.1"
port = $PORT
data_dir = "$TMP/data"
wrapper_bin = "$W"
nudge_enabled = true
nudge_interval_seconds = 2
nudge_ready_after_seconds = 2
nudge_review_after_seconds = 2
nudge_working_stale_after_seconds = 30
nudge_cooldown_seconds = 2
nudge_restart_grace_seconds = 0
nudge_send_escape_prefix = false

[wrapper]
daemon_url = "http://127.0.0.1:$PORT"
ham_ctl_bin = "$C"
default_agent = "pi"
agent_name = "pi"
command = ["$PI_BIN"]
tmux_session = "$SESSION"
tmux_window_prefix = "agent"
agent_run_dir = "$TMP/runs"
project = "heimdall-system"

[wrapper.agent-cmd.pi]
command = ["$PI_BIN"]
prompt_flags = []
yolo_flags = []
starter_prompt = ""
project = "heimdall-system"

[wrapper.agent-cmd.pi.startup_detection]
enabled = false

[ctl]
daemon_url = "http://127.0.0.1:$PORT"
EOF

json_field() {
  python3 - <<'PY' "$1" "$2"
import json,sys
cur=json.loads(sys.argv[1])
for p in sys.argv[2].split('.'):
    cur=cur[p]
print(cur)
PY
}

get_token() {
  python3 - <<'PY' "$1"
import re,sys
s=open(sys.argv[1]).read()
m=re.findall(r'"agent_token":"([^"]+)"', s)
print(m[-1] if m else '')
PY
}

wait_log() {
  local log="$1" needle="$2"
  for _ in $(seq 1 120); do
    grep -q "$needle" "$log" && return 0
    sleep 1
  done
  echo "missing '$needle' in $log"
  tail -n 120 "$log" || true
  exit 1
}

note() { echo "[*] $*"; }
pass() { echo "[+] $*"; }

note "Starting isolated ham-daemon on $PORT"
"$D" --config "$TMP/config.toml" > "$TMP/daemon.log" 2>&1 &
DPID=$!
for i in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break
  sleep 1
  [ "$i" -eq 30 ] && { cat "$TMP/daemon.log"; exit 1; }
done
pass "daemon healthy"

note "Starting pi assignee wrapper"
"$W" --config "$TMP/config.toml" --agent pi pi-assignee@smoke > "$TMP/assignee.log" 2>&1 &
P1=$!
wait_log "$TMP/assignee.log" 'ws connected'

note "Starting pi reviewer wrapper"
"$W" --config "$TMP/config.toml" --agent pi pi-reviewer@smoke > "$TMP/reviewer.log" 2>&1 &
P2=$!
wait_log "$TMP/reviewer.log" 'ws connected'

ATOK="$(get_token "$TMP/assignee.log")"
RTOK="$(get_token "$TMP/reviewer.log")"
[ -n "$ATOK" ] && [ -n "$RTOK" ]
pass "wrapper registration tokens captured"

note "Creating interoperability task chain"
CHAIN="$($C --config "$TMP/config.toml" task-chains create --token "$ATOK" --title "PI agent interoperability smoke" --description "Validate agent messaging, task events, review flow, and dependency promotion using real pi wrappers." --coordinator pi-assignee@smoke)"
CID="$(json_field "$CHAIN" chain_id)"

T1="$($C --config "$TMP/config.toml" tasks create --token "$ATOK" --chain-id "$CID" --title "Implementation: send reviewer context and submit for review" --description "Assignee task for interoperability smoke. Evidence should include a message to reviewer and a completion summary." --assignee pi-assignee@smoke)"
T1ID="$(json_field "$T1" task_id)"
"$C" --config "$TMP/config.toml" tasks participant --token "$ATOK" --task-id "$T1ID" --agent-instance-id pi-reviewer@smoke --role lgtm_required >/dev/null

T2="$($C --config "$TMP/config.toml" tasks create --token "$ATOK" --chain-id "$CID" --title "Reviewer follow-up: acknowledge approval back to assignee" --description "Reviewer-owned follow-up task that should auto-promote only after task 1 is approved." --assignee pi-reviewer@smoke --depends-on "$T1ID")"
T2ID="$(json_field "$T2" task_id)"
"$C" --config "$TMP/config.toml" tasks participant --token "$ATOK" --task-id "$T2ID" --agent-instance-id pi-assignee@smoke --role lgtm_required >/dev/null
pass "chain + tasks created"

note "Activating chain"
"$C" --config "$TMP/config.toml" task-chains activate --token "$ATOK" --chain-id "$CID" >/dev/null
sleep 5

SHOW1="$($C --config "$TMP/config.toml" tasks show --token "$ATOK" --task-id "$T1ID")"
SHOW2="$($C --config "$TMP/config.toml" tasks show --token "$ATOK" --task-id "$T2ID")"
python3 - <<'PY' "$SHOW1" "$SHOW2"
import json,sys
j1=json.loads(sys.argv[1])['task']
j2=json.loads(sys.argv[2])['task']
assert j1['status']=='in_progress', j1
assert j2['status'] in ('planning','queued'), j2
assert j2.get('not_actionable_reason','') in ('waiting_for_promotion',) or j2.get('not_actionable_reason','').startswith('deps_unmet:')
PY
pass "task 1 auto-claimed; task 2 still waiting on dependency"

note "Sending assignee -> reviewer message"
"$C" --config "$TMP/config.toml" send --token "$ATOK" --to pi-reviewer@smoke --body "Interop smoke: task $T1ID is ready for your later review." >/dev/null
sleep 2
INBOX_R1="$($C --config "$TMP/config.toml" inbox --token "$RTOK" --json)"
python3 - <<'PY' "$INBOX_R1" "$T1ID"
import json,sys
j=json.loads(sys.argv[1])
msgs=j.get('messages',[])
bodies='\n'.join(m.get('body','') for m in msgs)
assert sys.argv[2] in bodies, bodies
PY
pass "reviewer inbox received assignee message"

note "Submitting task 1 for review"
"$C" --config "$TMP/config.toml" tasks done --token "$ATOK" --task-id "$T1ID" --comment "Completed interoperability preparation. Sent reviewer message. Evidence: reviewer inbox contains task reference." >/dev/null
sleep 4
SHOW1R="$($C --config "$TMP/config.toml" tasks show --token "$ATOK" --task-id "$T1ID")"
python3 - <<'PY' "$SHOW1R"
import json,sys
j=json.loads(sys.argv[1])['task']
assert j['status']=='review_ready', j
assert j.get('not_actionable_reason','').startswith('awaiting_review:'), j
PY
pass "task 1 moved to review_ready"

note "Reviewer approves task 1"
"$C" --config "$TMP/config.toml" tasks vote --token "$RTOK" --task-id "$T1ID" --result lgtm --comment "Looks good. Message delivery and task workflow verified." >/dev/null
sleep 5
SHOW1A="$($C --config "$TMP/config.toml" tasks show --token "$ATOK" --task-id "$T1ID")"
SHOW2A="$($C --config "$TMP/config.toml" tasks show --token "$RTOK" --task-id "$T2ID")"
python3 - <<'PY' "$SHOW1A" "$SHOW2A"
import json,sys
j1=json.loads(sys.argv[1])['task']
j2=json.loads(sys.argv[2])['task']
assert j1['status']=='approved', j1
assert j2['status']=='in_progress', j2
PY
pass "approval auto-promoted dependent reviewer task"

note "Sending reviewer -> assignee message"
"$C" --config "$TMP/config.toml" send --token "$RTOK" --to pi-assignee@smoke --body "Interop smoke: approved $T1ID and now working on $T2ID." >/dev/null
sleep 2
INBOX_A1="$($C --config "$TMP/config.toml" inbox --token "$ATOK" --json)"
python3 - <<'PY' "$INBOX_A1" "$T2ID"
import json,sys
j=json.loads(sys.argv[1])
msgs=j.get('messages',[])
bodies='\n'.join(m.get('body','') for m in msgs)
assert sys.argv[2] in bodies, bodies
PY
pass "assignee inbox received reviewer message"

note "Verifying task log and daemon event trail"
LOG1="$($C --config "$TMP/config.toml" tasks log --token "$ATOK" --task-id "$T1ID")"
LOG2="$($C --config "$TMP/config.toml" tasks log --token "$RTOK" --task-id "$T2ID")"
python3 - <<'PY' "$LOG1" "$LOG2"
import json,sys
l1=json.loads(sys.argv[1]).get('events',[])
l2=json.loads(sys.argv[2]).get('events',[])
assert any(e.get('kind')=='Task_Status_Changed' and e.get('status')=='queued' for e in l1)
assert any(e.get('kind')=='Task_Status_Changed' and e.get('status')=='in_progress' for e in l1)
assert any(e.get('kind')=='Task_Status_Changed' and e.get('status')=='review_ready' for e in l1)
assert any(e.get('kind')=='Task_Status_Changed' and e.get('status')=='approved' for e in l1)
assert any(e.get('kind')=='Task_Review_Vote' for e in l1)
assert any(e.get('kind')=='Task_Status_Changed' and e.get('status')=='in_progress' for e in l2)
PY
rg -n "Task_Status_Changed .*Status: queued|Task_Status_Changed .*Status: in_progress|Task_Status_Changed .*Status: review_ready|Task_Review_Vote|Task_Status_Changed .*Status: approved" "$TMP/daemon.log" >/dev/null
pass "task log and daemon log captured expected lifecycle events"

echo
echo "PASS: PI agent interoperability smoke"
echo "ARTIFACTS=$TMP"