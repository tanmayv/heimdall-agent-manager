#!/usr/bin/env bash
# Regression check for task create/done response correctness.
# Requires a running ham-daemon. Uses HAM_CTL_BIN if set, otherwise the configured ham_ctl_bin.
set -euo pipefail

if [ -n "${HEIMDALL_HOME:-}" ]; then
  HEIMDALL_CONFIG_PATH="$HEIMDALL_HOME/config.toml"
else
  HEIMDALL_CONFIG_PATH="$HOME/.config/heimdall/config.toml"
fi

HAM_CTL_BIN="${HAM_CTL_BIN:-$(grep 'ham_ctl_bin' "$HEIMDALL_CONFIG_PATH" 2>/dev/null | sed 's/.*= "\(.*\)"/\1/' | head -1)}"
HAM_CTL_BIN="${HAM_CTL_BIN:-ham-ctl}"
CTL=("$HAM_CTL_BIN" --config "$HEIMDALL_CONFIG_PATH")
TOKEN="${HAM_AGENT_TOKEN:?set HAM_AGENT_TOKEN to an agent token}"
ASSIGNEE="${HAM_ASSIGNEE:-coder-Heimdall-System@heimdall-system}"
RUN_ID="$(date +%s)-$$"

json_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

CREATE_RES="$("${CTL[@]}" tasks create --token "$TOKEN" --title "create done response regression $RUN_ID" --description "temporary standalone regression task" --assignee "$ASSIGNEE" --standalone)"
[ "$(printf '%s' "$CREATE_RES" | json_field ok)" = "True" ] || { echo "create did not return ok:true: $CREATE_RES" >&2; exit 1; }
TASK_ID="$(printf '%s' "$CREATE_RES" | json_field task_id)"
[ -n "$TASK_ID" ] || { echo "create response missing task_id: $CREATE_RES" >&2; exit 1; }

DONE_RES="$("${CTL[@]}" tasks done --token "$TOKEN" --task-id "$TASK_ID" --comment "done response regression evidence")"
[ "$(printf '%s' "$DONE_RES" | json_field ok)" = "True" ] || { echo "done did not return ok:true: $DONE_RES" >&2; exit 1; }
[ "$(printf '%s' "$DONE_RES" | json_field status)" = "review_ready" ] || { echo "done response missing status=review_ready: $DONE_RES" >&2; exit 1; }

SHOW_RES="$("${CTL[@]}" tasks show --token "$TOKEN" --task-id "$TASK_ID")"
printf '%s' "$SHOW_RES" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["task"]["status"] == "review_ready", d'

echo "PASS task create/done responses are ok:true and done reports review_ready ($TASK_ID)"
