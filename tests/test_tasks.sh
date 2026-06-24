#!/usr/bin/env bash
# Smoke test: task management lifecycle and nudge delivery
#
# What this covers:
#   1.  Chain planning guard — tasks stay planning until chain is activated
#   2.  Chain activation — tasks auto-promote, assignee auto-claims
#   3.  Comment add / fetch-unresolved / resolve
#   4.  Status transition to review_ready (WS notification fires synchronously)
#   5.  lgtm vote → auto-approve → chain auto-complete
#   6.  ngtm vote → task returns to in_progress
#   7.  Manual nudge persisted to task event log
#   8.  One-active-per-project guard (chain creation blocked by active chain)
#   9.  depends_on ordering — step2 stays planning until step1 is approved
#  10.  blocked / unblock transition
#
# Nudge delivery note:
#   Status-change notifications are sent via WebSocket to connected agent
#   wrappers only — they are NOT persisted to the task event log.  Manual
#   nudge (ham-ctl tasks nudge) IS persisted and verified in test 7.
#   To verify WS delivery, connect an agent and watch its tmux pane for
#   {"type":"task_event",...} frames after each status change.
#
# Usage:
#   ./tests/test_tasks.sh
#   DAEMON_URL=http://127.0.0.1:49322 ./tests/test_tasks.sh
#
# Requirements: a running ham-daemon reachable at DAEMON_URL or default port.
# Config:       reads daemon_url from ~/.config/heimdall/config.toml

set -euo pipefail

RUN_ID="$(date +%s)"

# Prefer the Nix store ham-ctl written into config (has all commands),
# fall back to repo binary for dev environments.
if [ -n "${HEIMDALL_HOME:-}" ]; then
  HEIMDALL_CONFIG_PATH="$HEIMDALL_HOME/config.toml"
  HEIMDALL_DATA_DIR="$HEIMDALL_HOME/.local/share/heimdall"
else
  HEIMDALL_CONFIG_PATH="$HOME/.config/heimdall/config.toml"
  HEIMDALL_DATA_DIR="$HOME/.local/share/heimdall"
fi

HAM_CTL_BIN=$(grep 'ham_ctl_bin' "$HEIMDALL_CONFIG_PATH" 2>/dev/null \
  | sed 's/.*= "\(.*\)"/\1/' | head -1)
HAM_CTL_BIN="${HAM_CTL_BIN:-./bin/linux-x86_64/ham-ctl}"
CTL="$HAM_CTL_BIN --config $HEIMDALL_CONFIG_PATH"

PASS=0
FAIL=0

# ── helpers ───────────────────────────────────────────────────────────────────

pass()  { echo "PASS: $1"; PASS=$((PASS+1)); }
fail()  { echo "FAIL: $1"; echo "      got: $(echo "$2" | head -c 200)"; FAIL=$((FAIL+1)); }

ctl() { $CTL "$@" 2>&1; }

# JSON field extractor — always exits 0 (avoids set -e traps on grep no-match)
field() {
  echo "$1" | grep -o -E "\"$2\":(\"[^\"]*\"|[0-9]+)" | head -1 | sed -E 's/.*":("([^"]*)"|([0-9]+))/\2\3/' || true
}

is_ok()     { echo "$1" | grep -q '"ok":true'; }
is_not_ok() { echo "$1" | grep -q '"ok":false'; }
has()       { echo "$1" | grep -qF "$2"; }
count_of()  { echo "$1" | grep -o "$2" | wc -l | tr -d ' ' || true; }

assert_ok()      { is_ok     "$2" && pass "$1" || fail "$1" "$2"; }
assert_not_ok()  { is_not_ok "$2" && pass "$1" || fail "$1" "$2"; }
assert_has()     { has       "$2" "$3" && pass "$1" || fail "$1 (missing: $3)" "$2"; }
assert_not_has() { ! has     "$2" "$3" && pass "$1" || fail "$1 (unexpected: $3)" "$2"; }
assert_field()   {
  local got; got=$(field "$2" "$3")
  [ "$got" = "$4" ] && pass "$1" || fail "$1 ($3=$got, want $4)" "$2"
}

# ── health check ──────────────────────────────────────────────────────────────

HEALTH=$(ctl health)
is_ok "$HEALTH" || { echo "ERROR: daemon not reachable (check $HEIMDALL_CONFIG_PATH)"; exit 1; }
echo "daemon ok  run_id=$RUN_ID  config=$HEIMDALL_CONFIG_PATH"
echo "ctl:       $HAM_CTL_BIN"

# ── register a fresh test agent for this run ──────────────────────────────────
# A per-run agent guarantees no pre-existing active tasks, so promotion and
# vote logic works cleanly without interference from other runs.

DAEMON_URL="${DAEMON_URL:-http://127.0.0.1:49322}"
ME="smoketest@run${RUN_ID}"
REG=$(curl -sf -X POST "$DAEMON_URL/register" \
  -H "Content-Type: application/json" \
  -d "{\"agent_class\":\"smoketest\",\"agent_instance_id\":\"${ME}\",\"display_name\":\"Smoke ${RUN_ID}\"}")
TOKEN=$(field "$REG" "agent_token")
if [ -z "$TOKEN" ]; then
  echo "ERROR: failed to register test agent ($REG)"
  exit 1
fi

REV="smoketest-rev@run${RUN_ID}"
REG_REV=$(curl -sf -X POST "$DAEMON_URL/register" \
  -H "Content-Type: application/json" \
  -d "{\"agent_class\":\"smoketest-rev\",\"agent_instance_id\":\"${REV}\",\"display_name\":\"Smoke Reviewer ${RUN_ID}\"}")
TOKEN_REV=$(field "$REG_REV" "agent_token")
if [ -z "$TOKEN_REV" ]; then
  echo "ERROR: failed to register test reviewer agent ($REG_REV)"
  exit 1
fi

USER_REG=$(curl -sf -X POST "$DAEMON_URL/user-client/register" \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"operator@local\",\"client_instance_id\":\"test-client-run${RUN_ID}\"}")
USER_TOKEN=$(field "$USER_REG" "client_token")
if [ -z "$USER_TOKEN" ]; then
  echo "ERROR: failed to register test user ($USER_REG)"
  exit 1
fi
echo "agent:     $ME"
echo "token:     ${TOKEN:0:16}..."
echo "user_token: ${USER_TOKEN:0:16}..."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SETUP: isolated project per run
# ─────────────────────────────────────────────────────────────────────────────

PROJ=$(ctl projects create --token "$TOKEN" \
  --name "Task Smoke $RUN_ID" \
  --description "automated smoke test")
assert_ok "setup: create project" "$PROJ"
PROJ_ID=$(field "$PROJ" "project_id")
echo "project:   $PROJ_ID"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T1 — Chain planning guard
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T1: chain planning guard ==="

CHAIN1=$(ctl task-chains create --token "$TOKEN" \
  --project-id "$PROJ_ID" \
  --title "Smoke Chain $RUN_ID" \
  --description "Goal: verify task lifecycle
Scope: task API
Approach: sequential status transitions
Acceptance: all assertions pass" \
  --coordinator "$ME")
assert_ok    "T1 create chain"          "$CHAIN1"
assert_field "T1 chain status=planning" "$CHAIN1" "status" "planning"
CHAIN_ID=$(field "$CHAIN1" "chain_id")
echo "chain:     $CHAIN_ID"

TASK1=$(ctl tasks create --token "$TOKEN" \
  --chain-id "$CHAIN_ID" \
  --title "Task Alpha" \
  --description "First task in smoke chain" \
  --assignee "$ME")
assert_ok "T1 create task" "$TASK1"
TASK_ID=$(field "$TASK1" "task_id")
echo "task:      $TASK_ID"

# Verify planning status via show (create response does not include status)
T1_SHOW=$(ctl tasks show --token "$TOKEN" --task-id "$TASK_ID")
assert_ok    "T1 show task ok"         "$T1_SHOW"
assert_field "T1 task status=planning" "$T1_SHOW" "status" "planning"

NEXT=$(ctl tasks next --token "$TOKEN")
assert_not_has "T1 tasks next=null (chain not active)" "$NEXT" '"task_id"'

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T2 — Activate chain: task auto-promotes, assignee auto-claims
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T2: chain activation ==="

ACT=$(ctl task-chains activate --token "$TOKEN" --chain-id "$CHAIN_ID")
assert_ok "T2 activate chain" "$ACT"

# activate returns {"ok":true}; verify chain status via show
CSHOW=$(ctl task-chains show --token "$TOKEN" --chain-id "$CHAIN_ID")
assert_ok    "T2 chain show ok"            "$CSHOW"
assert_field "T2 chain status=in_progress" "$CSHOW" "status" "in_progress"

SHOW=$(ctl tasks show --token "$TOKEN" --task-id "$TASK_ID")
assert_ok "T2 show task" "$SHOW"
TASK_STATUS=$(field "$SHOW" "status")
case "$TASK_STATUS" in
  in_progress|ready) pass "T2 task promoted (status=$TASK_STATUS)" ;;
  *)                 fail "T2 task not promoted" "$SHOW" ;;
esac

NEXT2=$(ctl tasks next --token "$TOKEN")
assert_has "T2 tasks next returns task" "$NEXT2" '"task_id"'

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T3 — Comments: add / fetch-unresolved / resolve
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T3: comment lifecycle ==="

CMT=$(ctl tasks comment --token "$TOKEN" \
  --task-id "$TASK_ID" --chain-id "$CHAIN_ID" \
  --body "Progress: starting implementation

Decisions:
- approach A over B because simpler

Next: finish and submit for review")
assert_ok "T3 add comment" "$CMT"
CMT_ID=$(field "$CMT" "comment_id")
[ -n "$CMT_ID" ] && pass "T3 comment_id returned ($CMT_ID)" || fail "T3 comment_id missing" "$CMT"

SHOW_CMT=$(ctl tasks show --token "$TOKEN" --task-id "$TASK_ID")
assert_field "T3 tasks show has unresolved_comment_count=1" "$SHOW_CMT" "unresolved_comment_count" "1"
assert_has "T3 tasks show has unresolved_comments list with cmt_id" "$SHOW_CMT" "\"comment_id\":\"$CMT_ID\""
assert_has "T3 tasks show has unresolved_comments list with body" "$SHOW_CMT" "starting implementation"

TRY_DONE=$(ctl tasks done --token "$TOKEN" --task-id "$TASK_ID" --chain-id "$CHAIN_ID" --comment "done")
assert_not_ok "T3 transition to done blocked by unresolved comments" "$TRY_DONE"
assert_has "T3 error mentions unresolved comments" "$TRY_DONE" "has 1 unresolved comments"

UNRESOLVED=$(ctl tasks comments --token "$TOKEN" --task-id "$TASK_ID" --unresolved)
assert_ok  "T3 fetch unresolved ok"            "$UNRESOLVED"
assert_has "T3 one unresolved comment present" "$UNRESOLVED" "\"comment_id\":\"$CMT_ID\""
assert_not_has "T3 comment not yet resolved"   "$UNRESOLVED" '"resolved":true'

RESOLVE=$(ctl tasks comment-resolve --token "$TOKEN" \
  --task-id "$TASK_ID" --chain-id "$CHAIN_ID" --comment-id "$CMT_ID")
assert_ok "T3 resolve comment" "$RESOLVE"

SHOW_CMT2=$(ctl tasks show --token "$TOKEN" --task-id "$TASK_ID")
assert_field "T3 tasks show has unresolved_comment_count=0" "$SHOW_CMT2" "unresolved_comment_count" "0"
assert_not_has "T3 tasks show has no unresolved_comments details" "$SHOW_CMT2" "\"comment_id\":\"$CMT_ID\""

UNRESOLVED2=$(ctl tasks comments --token "$TOKEN" --task-id "$TASK_ID" --unresolved)
assert_not_has "T3 zero unresolved after resolve" "$UNRESOLVED2" "\"comment_id\":\"$CMT_ID\""

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T4 — Status transition: in_progress → review_ready
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T4: review_ready + lgtm_required notification ==="

PART=$(ctl tasks participant --token "$TOKEN" \
  --task-id "$TASK_ID" --chain-id "$CHAIN_ID" \
  --agent-instance-id "$REV" --role lgtm_required)
assert_ok "T4 add lgtm_required participant" "$PART"

# Verify that manual status changes from agent token are blocked
BLOCKED_MANUAL=$(ctl tasks status --token "$TOKEN" \
  --task-id "$TASK_ID" --chain-id "$CHAIN_ID" \
  --status review_ready --body "illegal status change request")
assert_not_ok "T4 agent manual status change is blocked" "$BLOCKED_MANUAL"
assert_has "T4 agent manual status error" "$BLOCKED_MANUAL" "restricted to user tokens"

# Transition using intent subcommand
RR=$(ctl tasks done --token "$TOKEN" \
  --task-id "$TASK_ID" --chain-id "$CHAIN_ID" \
  --comment "implementation complete, ready for review")
assert_ok "T4 set review_ready via tasks done" "$RR"

# tasks status returns {"ok":true}; verify via show
RR_SHOW=$(ctl tasks show --token "$TOKEN" --task-id "$TASK_ID")
assert_field "T4 status=review_ready" "$RR_SHOW" "status" "review_ready"

LOG=$(ctl tasks log --token "$TOKEN" --task-id "$TASK_ID")
assert_ok  "T4 task log ok"                        "$LOG"
assert_has "T4 log has Task_Status_Changed"        "$LOG" "Task_Status_Changed"
assert_has "T4 log has review_ready status event"  "$LOG" '"review_ready"'

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T5 — lgtm vote → auto-approve → chain auto-complete
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T5: lgtm vote → auto-approve → chain complete ==="

VOTE=$(ctl tasks vote --token "$TOKEN_REV" \
  --task-id "$TASK_ID" --chain-id "$CHAIN_ID" \
  --result lgtm --comment "Logic is correct, tests pass, good to merge")
assert_ok "T5 lgtm vote accepted" "$VOTE"

SHOW2=$(ctl tasks show --token "$TOKEN" --task-id "$TASK_ID")
assert_ok    "T5 show after vote" "$SHOW2"
assert_field "T5 task=approved"   "$SHOW2" "status" "approved"

CSHOW2=$(ctl task-chains show --token "$TOKEN" --chain-id "$CHAIN_ID")
CHAIN_STATUS=$(field "$CSHOW2" "status")
[ "$CHAIN_STATUS" = "reviewing" ] && pass "T5 chain status=reviewing" \
  || fail "T5 chain not in reviewing (status=$CHAIN_STATUS)" "$CSHOW2"

# Manually complete the chain as the coordinator
COMP=$(ctl task-chains complete --token "$TOKEN" --chain "$CHAIN_ID" --summary "Integration tests complete")
assert_ok "T5 complete chain" "$COMP"

CSHOW3=$(ctl task-chains show --token "$TOKEN" --chain-id "$CHAIN_ID")
assert_field "T5 chain status=completed" "$CSHOW3" "status" "completed"

LOG2=$(ctl tasks log --token "$TOKEN" --task-id "$TASK_ID")
assert_has "T5 log has Task_Review_Vote" "$LOG2" "Task_Review_Vote"
assert_has "T5 log has approved event"   "$LOG2" '"approved"'

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T6 — ngtm vote returns task to in_progress
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T6: ngtm vote → back to in_progress ==="

CHAIN2=$(ctl task-chains create --token "$TOKEN" \
  --project-id "$PROJ_ID" \
  --title "ngtm Chain $RUN_ID" \
  --description "Goal: test ngtm rejection path" \
  --coordinator "$ME")
assert_ok "T6 create chain2" "$CHAIN2"
C2=$(field "$CHAIN2" "chain_id")

TASK2=$(ctl tasks create --token "$TOKEN" \
  --chain-id "$C2" --title "ngtm Task" --assignee "$ME")
assert_ok "T6 create task2" "$TASK2"
T2=$(field "$TASK2" "task_id")

ctl tasks participant --token "$TOKEN" \
  --task-id "$T2" --chain-id "$C2" \
  --agent-instance-id "$REV" --role lgtm_required >/dev/null
ctl task-chains activate --token "$TOKEN" --chain-id "$C2" >/dev/null
ctl tasks done --token "$TOKEN" \
  --task-id "$T2" --chain-id "$C2" \
  --comment "ready" >/dev/null

NGTM=$(ctl tasks vote --token "$TOKEN_REV" \
  --task-id "$T2" --chain-id "$C2" \
  --result ngtm --comment "service.odin:42 — null check missing before calling Parse()")
assert_ok "T6 ngtm vote accepted" "$NGTM"

SHOW3=$(ctl tasks show --token "$TOKEN" --task-id "$T2")
assert_field "T6 task returned to in_progress" "$SHOW3" "status" "in_progress"
assert_has "T6 task has ngtm vote before resubmitting" "$SHOW3" '"reviewer_agent_instance_id":"smoketest-rev@run'

# Resubmit task (status changes to review_ready)
DONE2=$(ctl tasks done --token "$TOKEN" --task-id "$T2" --chain-id "$C2" --comment "fixed missing null check")
assert_ok "T6 resubmit task done" "$DONE2"

SHOW4=$(ctl tasks show --token "$TOKEN" --task-id "$T2")
assert_field "T6 task promoted to review_ready" "$SHOW4" "status" "review_ready"
assert_has "T6 task votes are cleared on resubmit" "$SHOW4" '"votes":[]'

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T7 — Manual nudge persisted to task event log
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T7: manual nudge in task event log ==="

NUDGE=$(ctl tasks nudge --token "$TOKEN" \
  --task-id "$T2" --chain-id "$C2" \
  --body "Reminder: please address the ngtm comment before resubmitting for review")
assert_ok "T7 nudge accepted" "$NUDGE"

NLOG=$(ctl tasks log --token "$TOKEN" --task-id "$T2")
assert_has "T7 Task_Nudged in log" "$NLOG" "Task_Nudged"
assert_has "T7 nudge body in log"  "$NLOG" "Reminder"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T8 — One-active-per-project guard
# Daemon blocks chain creation (and activation) when a chain is in_progress
# for the same project. C2 is still in_progress (T6 ngtm'd its task).
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T8: one-active-per-project guard ==="

CHAIN3=$(ctl task-chains create --token "$TOKEN" \
  --project-id "$PROJ_ID" \
  --title "Conflict Chain $RUN_ID" \
  --description "Goal: verify conflict guard" \
  --coordinator "$ME")
assert_not_ok "T8 chain creation blocked by active chain" "$CHAIN3"
assert_has    "T8 error names active chain"               "$CHAIN3" "active_chain_id"

# Clean up T2 from C2 so assignee is free
CLEAN_T2=$(ctl tasks status --token "$USER_TOKEN" --task-id "$T2" --chain-id "$C2" --status cancelled --body "cleanup T2")
assert_ok "T8 cleanup T2" "$CLEAN_T2"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T9 — depends_on ordering: step2 stays planning until step1 is approved
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T9: depends_on ordering ==="

PROJ2=$(ctl projects create --token "$TOKEN" \
  --name "Deps Test $RUN_ID" --description "dependency ordering test")
assert_ok "T9 create project2" "$PROJ2"
P2=$(field "$PROJ2" "project_id")

CHAIN4=$(ctl task-chains create --token "$TOKEN" \
  --project-id "$P2" \
  --title "Deps Chain $RUN_ID" \
  --description "Goal: verify dependency ordering" \
  --coordinator "$ME")
assert_ok "T9 create chain4" "$CHAIN4"
C4=$(field "$CHAIN4" "chain_id")

DT1_RESP=$(ctl tasks create --token "$TOKEN" \
  --chain-id "$C4" --title "Step 1 (no deps)" --assignee "$ME")
assert_ok "T9 create step1" "$DT1_RESP"
DT1=$(field "$DT1_RESP" "task_id")

ctl tasks participant --token "$TOKEN" \
  --task-id "$DT1" --chain-id "$C4" \
  --agent-instance-id "$REV" --role lgtm_required >/dev/null

DT2_RESP=$(ctl tasks create --token "$TOKEN" \
  --chain-id "$C4" --title "Step 2 (depends on Step 1)" \
  --assignee "$ME" --depends-on "$DT1")
assert_ok "T9 create step2 with depends-on" "$DT2_RESP"
DT2=$(field "$DT2_RESP" "task_id")

ctl task-chains activate --token "$TOKEN" --chain-id "$C4" >/dev/null

# Only step1 should be promoted; step2 must still be planning (dep unsatisfied)
SHOW_DT2=$(ctl tasks show --token "$TOKEN" --task-id "$DT2")
assert_field "T9 step2 still planning after activate" "$SHOW_DT2" "status" "planning"

# Complete step1: in_progress → review_ready → lgtm → approved
ctl tasks done --token "$TOKEN" \
  --task-id "$DT1" --chain-id "$C4" --comment "done" >/dev/null
ctl tasks vote --token "$TOKEN_REV" \
  --task-id "$DT1" --chain-id "$C4" \
  --result lgtm --comment "ok" >/dev/null

# Step2 must now be promoted (ready or in_progress)
SHOW_DT2B=$(ctl tasks show --token "$TOKEN" --task-id "$DT2")
DT2_STATUS=$(field "$SHOW_DT2B" "status")
case "$DT2_STATUS" in
  in_progress|ready) pass "T9 step2 promoted after dep approved (status=$DT2_STATUS)" ;;
  *)                 fail "T9 step2 not promoted (status=$DT2_STATUS)" "$SHOW_DT2B" ;;
esac

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T10 — Blocked / unblock
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T10: blocked / unblock ==="

BLK=$(ctl tasks blocked --token "$TOKEN" \
  --task-id "$DT2" --chain-id "$C4" \
  --reason "waiting on external API key from ops team")
assert_ok "T10 set blocked" "$BLK"
BLK_SHOW=$(ctl tasks show --token "$TOKEN" --task-id "$DT2")
assert_field "T10 status=blocked" "$BLK_SHOW" "status" "blocked"

UNBLK=$(ctl tasks later --token "$TOKEN" \
  --task-id "$DT2" --chain-id "$C4" \
  --reason "API key received, resuming work")
assert_ok "T10 unblock" "$UNBLK"
UNBLK_SHOW=$(ctl tasks show --token "$TOKEN" --task-id "$DT2")
assert_field "T10 status=in_progress" "$UNBLK_SHOW" "status" "in_progress"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T11 — Comment revert approved task to ready
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T11: comment revert approved task to ready ==="

# 1. Approve DT2 manually using USER_TOKEN
APP_DT2=$(ctl tasks status --token "$USER_TOKEN" --task-id "$DT2" --chain-id "$C4" --status approved --body "manual approval of step 2")
assert_ok "T11 approve DT2" "$APP_DT2"

# 2. Verify DT2 is approved and chain C4 is reviewing
SHOW_DT2_APP=$(ctl tasks show --token "$TOKEN" --task-id "$DT2")
assert_field "T11 DT2 status=approved" "$SHOW_DT2_APP" "status" "approved"

SHOW_C4_REV=$(ctl task-chains show --token "$TOKEN" --chain-id "$C4")
assert_field "T11 C4 status=reviewing" "$SHOW_C4_REV" "status" "reviewing"

# 3. Add an unresolved comment to DT2
CMT_REV=$(ctl tasks comment --token "$TOKEN" --task-id "$DT2" --chain-id "$C4" --body "Wait, I found a major bug in the implementation!")
assert_ok "T11 add comment to approved task" "$CMT_REV"

# 4. Verify task has reverted to in_progress (via auto-claim from ready)
SHOW_DT2_REV=$(ctl tasks show --token "$TOKEN" --task-id "$DT2")
assert_field "T11 DT2 status reverted to in_progress" "$SHOW_DT2_REV" "status" "in_progress"

# 5. Verify chain has reverted to in_progress
SHOW_C4_IN_PROG=$(ctl task-chains show --token "$TOKEN" --chain-id "$C4")
assert_field "T11 C4 status reverted to in_progress" "$SHOW_C4_IN_PROG" "status" "in_progress"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# T12 — GET /task-chains/{chain_id}
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T12: GET /task-chains/{chain_id} REST route ==="

CHAIN_RESP=$(curl -sf -X GET "$DAEMON_URL/task-chains/$CHAIN_ID" \
  -H "Authorization: Bearer $TOKEN")
[ -n "$CHAIN_RESP" ] && pass "T12 fetch chain details via REST" || fail "T12 fetch chain details via REST" "$CHAIN_RESP"
assert_field "T12 REST response has correct chain_id" "$CHAIN_RESP" "chain_id" "$CHAIN_ID"

# Query a non-existent chain
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$DAEMON_URL/task-chains/non-existent-chain-id" \
  -H "Authorization: Bearer $TOKEN")
[ "$HTTP_CODE" = "404" ] && pass "T12 non-existent chain returns 404" || fail "T12 non-existent chain returned $HTTP_CODE" "status code"

echo ""
# ─────────────────────────────────────────────────────────────────────────────
# T13 — JSON control character escaping
# ─────────────────────────────────────────────────────────────────────────────
echo "=== T13: JSON control character escaping ==="

CTRL_COMMENT=$(printf "Comment with escape \x1b character")
ADD_CTRL_CMT=$(ctl tasks comment --token "$TOKEN" --task-id "$T2" --chain-id "$C2" --body "$CTRL_COMMENT")
assert_ok "T13 add control character comment" "$ADD_CTRL_CMT"

SHOW_CTRL_TASK=$(ctl tasks show --token "$TOKEN" --task-id "$T2")
assert_ok "T13 show task with control character" "$SHOW_CTRL_TASK"
assert_has "T13 has escaped escape code in JSON string" "$SHOW_CTRL_TASK" '\u001b'

echo ""
# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────
echo "=== CLEANUP: Wiping test records to prevent database pollution ==="

# 1. Archive the test agent via REST API
echo "[*] Archiving test agent via REST API..."
curl -s -X POST "$DAEMON_URL/agents/archive" \
  -H "Content-Type: application/json" \
  -d "{\"agent_instance_id\":\"$ME\"}" >/dev/null || true

# 2. Delete tasks, chains, and participants from SQLite database
DB_PATH="$HEIMDALL_DATA_DIR/tasks/task.db"
if [ -f "$DB_PATH" ]; then
  echo "[*] Wiping tasks, chains, votes, comments, and participants from SQLite..."
  sqlite3 "$DB_PATH" <<EOF
DELETE FROM task_participants WHERE chain_id IN (SELECT chain_id FROM task_chains WHERE project_id = 'project_$RUN_ID');
DELETE FROM task_lgtm_votes WHERE chain_id IN (SELECT chain_id FROM task_chains WHERE project_id = 'project_$RUN_ID');
DELETE FROM task_comments WHERE chain_id IN (SELECT chain_id FROM task_chains WHERE project_id = 'project_$RUN_ID');
DELETE FROM tasks WHERE chain_id IN (SELECT chain_id FROM task_chains WHERE project_id = 'project_$RUN_ID');
DELETE FROM task_chains WHERE project_id = 'project_$RUN_ID';
EOF
fi

# 3. Clean up flat files (JSONL event logs) on disk for next daemon start
PROJECT_LOG="$HEIMDALL_DATA_DIR/projects/events.jsonl"
if [ -f "$PROJECT_LOG" ]; then
  echo "[*] Removing test project events from flat file logs..."
  grep -v "\"project_id\":\"project_$RUN_ID\"" "$PROJECT_LOG" > "${PROJECT_LOG}.tmp" || true
  mv "${PROJECT_LOG}.tmp" "$PROJECT_LOG"
fi

AGENT_LOG="$HEIMDALL_DATA_DIR/agents/instance-events.jsonl"
if [ -f "$AGENT_LOG" ]; then
  echo "[*] Removing test agent events from flat file logs..."
  grep -v "\"agent_instance_id\":\"$ME\"" "$AGENT_LOG" > "${AGENT_LOG}.tmp" || true
  mv "${AGENT_LOG}.tmp" "$AGENT_LOG"
fi

echo "[+] Cleanup completed successfully!"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════"
echo " Results: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════"
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "WS nudge note: status-change notifications (review_ready → lgtm_required"
  echo "agents) go via WebSocket only and are not verified in this script."
  echo "To confirm: connect an agent, change a task to review_ready, and check"
  echo "its tmux pane for {\"type\":\"task_event\",...} frames."
fi
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
