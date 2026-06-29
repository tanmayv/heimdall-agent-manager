#!/usr/bin/env bash
# Regression check for task and task-chain description editing.
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
AGENT="desc-coder@$RUN_ID"

json_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

task_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)["task"].get(sys.argv[1], ""))' "$1"
}

chain_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)["chain"].get(sys.argv[1], ""))' "$1"
}

register_agent_token() {
  local id="$1" cls="${1%@*}"
  python3 - <<PY
import json, urllib.request
req=urllib.request.Request('$DAEMON_URL/register', data=json.dumps({'agent_class':'$cls','agent_instance_id':'$id','display_name':'$id'}).encode(), headers={'Content-Type':'application/json'}, method='POST')
print(json.loads(urllib.request.urlopen(req).read())['agent_token'])
PY
}

TOKEN="$(register_agent_token "$AGENT")"
CHAIN_DESC="chain description before $RUN_ID"
CHAIN_DESC2="chain description after $RUN_ID"
TASK_DESC="task description before $RUN_ID"
TASK_DESC2="task description after $RUN_ID"

CHAIN_RES="$("${CTL[@]}" task-chains create --token "$TOKEN" --title "description edit regression $RUN_ID" --description "$CHAIN_DESC" --coordinator "$AGENT")"
[ "$(printf '%s' "$CHAIN_RES" | json_field ok)" = "True" ] || { echo "chain create failed: $CHAIN_RES" >&2; exit 1; }
CHAIN_ID="$(printf '%s' "$CHAIN_RES" | json_field chain_id)"

TASK_RES="$("${CTL[@]}" tasks create --token "$TOKEN" --chain-id "$CHAIN_ID" --title "description task $RUN_ID" --description "$TASK_DESC" --assignee "$AGENT")"
[ "$(printf '%s' "$TASK_RES" | json_field ok)" = "True" ] || { echo "task create failed: $TASK_RES" >&2; exit 1; }
TASK_ID="$(printf '%s' "$TASK_RES" | json_field task_id)"

UPDATE_TASK_RES="$("${CTL[@]}" tasks update --token "$TOKEN" --task-id "$TASK_ID" --description "$TASK_DESC2")"
[ "$(printf '%s' "$UPDATE_TASK_RES" | json_field ok)" = "True" ] || { echo "task update failed: $UPDATE_TASK_RES" >&2; exit 1; }
TASK_SHOW="$("${CTL[@]}" tasks show --token "$TOKEN" --task-id "$TASK_ID")"
[ "$(printf '%s' "$TASK_SHOW" | task_field description)" = "$TASK_DESC2" ] || { echo "task description not updated: $TASK_SHOW" >&2; exit 1; }
TASK_TITLE2="description task renamed $RUN_ID"
TITLE_ONLY_RES="$("${CTL[@]}" tasks update --token "$TOKEN" --task-id "$TASK_ID" --title "$TASK_TITLE2")"
[ "$(printf '%s' "$TITLE_ONLY_RES" | json_field ok)" = "True" ] || { echo "task title-only update failed: $TITLE_ONLY_RES" >&2; exit 1; }
TASK_SHOW="$("${CTL[@]}" tasks show --token "$TOKEN" --task-id "$TASK_ID")"
[ "$(printf '%s' "$TASK_SHOW" | task_field title)" = "$TASK_TITLE2" ] || { echo "task title not updated: $TASK_SHOW" >&2; exit 1; }
[ "$(printf '%s' "$TASK_SHOW" | task_field description)" = "$TASK_DESC2" ] || { echo "title-only update clobbered task description: $TASK_SHOW" >&2; exit 1; }
TASK_LOG="$("${CTL[@]}" tasks log --token "$TOKEN" --task-id "$TASK_ID")"
printf '%s' "$TASK_LOG" | grep -q 'Task_Metadata_Updated' || { echo "task update event missing: $TASK_LOG" >&2; exit 1; }

UPDATE_CHAIN_RES="$("${CTL[@]}" task-chains update --token "$TOKEN" --chain-id "$CHAIN_ID" --description "$CHAIN_DESC2")"
[ "$(printf '%s' "$UPDATE_CHAIN_RES" | json_field ok)" = "True" ] || { echo "chain update failed: $UPDATE_CHAIN_RES" >&2; exit 1; }
CHAIN_SHOW="$("${CTL[@]}" task-chains show --token "$TOKEN" --chain-id "$CHAIN_ID")"
[ "$(printf '%s' "$CHAIN_SHOW" | chain_field description)" = "$CHAIN_DESC2" ] || { echo "chain description not updated: $CHAIN_SHOW" >&2; exit 1; }
printf '%s' "$CHAIN_SHOW" | grep -q 'Chain_Metadata_Updated' || { echo "chain update event missing: $CHAIN_SHOW" >&2; exit 1; }

echo "PASS edited task $TASK_ID and chain $CHAIN_ID descriptions"
