#!/usr/bin/env bash
# Regression check for vote -> approved -> dependent promotion.
# Requires a running ham-daemon. Uses HAM_CTL_BIN if set, otherwise configured ham_ctl_bin.
set -euo pipefail

if [ -n "${HEIMDALL_HOME:-}" ]; then
  HEIMDALL_CONFIG_PATH="$HEIMDALL_HOME/config.toml"
else
  HEIMDALL_CONFIG_PATH="$HOME/.config/heimdall/config.toml"
fi

HAM_CTL_BIN="${HAM_CTL_BIN:-$(grep 'ham_ctl_bin' "$HEIMDALL_CONFIG_PATH" 2>/dev/null | sed 's/.*= "\(.*\)"/\1/' | head -1)}"
HAM_CTL_BIN="${HAM_CTL_BIN:-ham-ctl}"
DAEMON_URL="${DAEMON_URL:-$(grep 'daemon_url' "$HEIMDALL_CONFIG_PATH" 2>/dev/null | sed 's/.*= "\(.*\)"/\1/' | head -1)}"
DAEMON_URL="${DAEMON_URL:-http://127.0.0.1:49322}"
CTL=("$HAM_CTL_BIN" --config "$HEIMDALL_CONFIG_PATH")
RUN_ID="$(date +%s)-$$"
CODER="vote-coder@$RUN_ID"
REVIEWER="vote-reviewer@$RUN_ID"

json_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

task_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)["task"].get(sys.argv[1], ""))' "$1"
}

register_agent_token() {
  local id="$1" cls="${1%@*}"
  python3 - <<PY
import json, urllib.request
req=urllib.request.Request('$DAEMON_URL/register', data=json.dumps({'agent_class':'$cls','agent_instance_id':'$id','display_name':'$id'}).encode(), headers={'Content-Type':'application/json'}, method='POST')
print(json.loads(urllib.request.urlopen(req).read())['agent_token'])
PY
}

CODER_TOKEN="$(register_agent_token "$CODER")"
REVIEWER_TOKEN="$(register_agent_token "$REVIEWER")"

CHAIN_RES="$("${CTL[@]}" task-chains create --token "$CODER_TOKEN" --title "vote auto approval regression $RUN_ID" --coordinator "$CODER")"
[ "$(printf '%s' "$CHAIN_RES" | json_field ok)" = "True" ] || { echo "chain create failed: $CHAIN_RES" >&2; exit 1; }
CHAIN_ID="$(printf '%s' "$CHAIN_RES" | json_field chain_id)"

T1_RES="$("${CTL[@]}" tasks create --token "$CODER_TOKEN" --chain-id "$CHAIN_ID" --title "producer $RUN_ID" --description "producer" --assignee "$CODER")"
[ "$(printf '%s' "$T1_RES" | json_field ok)" = "True" ] || { echo "task1 create failed: $T1_RES" >&2; exit 1; }
T1="$(printf '%s' "$T1_RES" | json_field task_id)"

T2_RES="$("${CTL[@]}" tasks create --token "$CODER_TOKEN" --chain-id "$CHAIN_ID" --title "dependent $RUN_ID" --description "dependent" --assignee "$CODER" --depends-on "$T1")"
[ "$(printf '%s' "$T2_RES" | json_field ok)" = "True" ] || { echo "task2 create failed: $T2_RES" >&2; exit 1; }
T2="$(printf '%s' "$T2_RES" | json_field task_id)"

"${CTL[@]}" tasks participant --token "$CODER_TOKEN" --task-id "$T1" --agent-instance-id "$REVIEWER" --role lgtm_required >/dev/null
"${CTL[@]}" task-chains activate --token "$CODER_TOKEN" --chain-id "$CHAIN_ID" >/dev/null

DONE_RES="$("${CTL[@]}" tasks done --token "$CODER_TOKEN" --task-id "$T1" --comment "ready for vote regression")"
[ "$(printf '%s' "$DONE_RES" | json_field ok)" = "True" ] || { echo "done failed: $DONE_RES" >&2; exit 1; }
[ "$(printf '%s' "$DONE_RES" | json_field status)" = "review_ready" ] || { echo "done did not report review_ready: $DONE_RES" >&2; exit 1; }

VOTE_RES="$("${CTL[@]}" tasks vote --token "$REVIEWER_TOKEN" --task-id "$T1" --result lgtm --comment "LGTM regression")"
[ "$(printf '%s' "$VOTE_RES" | json_field ok)" = "True" ] || { echo "vote failed: $VOTE_RES" >&2; exit 1; }
[ "$(printf '%s' "$VOTE_RES" | json_field status)" = "approved" ] || { echo "vote did not report status=approved: $VOTE_RES" >&2; exit 1; }

T1_SHOW="$("${CTL[@]}" tasks show --token "$CODER_TOKEN" --task-id "$T1")"
[ "$(printf '%s' "$T1_SHOW" | task_field status)" = "approved" ] || { echo "task1 not approved: $T1_SHOW" >&2; exit 1; }
[ "$(printf '%s' "$T1_SHOW" | task_field not_actionable_reason)" = "approved" ] || { echo "task1 reason not cleared to approved: $T1_SHOW" >&2; exit 1; }

T2_SHOW="$("${CTL[@]}" tasks show --token "$CODER_TOKEN" --task-id "$T2")"
T2_STATUS="$(printf '%s' "$T2_SHOW" | task_field status)"
case "$T2_STATUS" in
  queued|in_progress) ;;
  *) echo "dependent task did not promote: $T2_SHOW" >&2; exit 1 ;;
esac

echo "PASS vote auto-approved $T1 and promoted dependent $T2 to $T2_STATUS"
