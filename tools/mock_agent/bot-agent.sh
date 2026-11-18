#!/bin/sh
# Deterministic provider for bot delivery integration tests (no model/network API).
set -eu

HAM_CTL=${HAM_CTL:-./bin/ham-ctl}
case ${BOT_AGENT_MODE:-reply} in
    reply|silent|ctl) ;;
    *) printf '%s\n' 'bot-agent: unknown BOT_AGENT_MODE' >&2; exit 2 ;;
esac
pending_kind=
pending_args=
trap 'exit 0' TERM
"$HAM_CTL" agent start-success
while IFS= read -r line; do
    case $line in
        *'New message from'*) "$HAM_CTL" chat read ;;
        *'New chat message for you'*)
            messages=$("$HAM_CTL" channel read)
            [ "${BOT_AGENT_MODE:-reply}" = silent ] && continue
            # Split fields onto lines so the first entry wins in a compact envelope.
            body=$(printf '%s\n' "$messages" | sed 's/"body"[[:space:]]*:/\
&/g' | sed -n 's/^"body"[[:space:]]*:[[:space:]]*"\(\([^"\\]*\\.\)*[^"\\]*\)".*/\1/p' | sed -n '1p' | sed 's/\\"/"/g; s/\\\//\//g; s/\\\\/\\/g')
            if [ "${BOT_AGENT_MODE:-reply}" = ctl ]; then
                if [ -n "$pending_kind" ]; then
                    answer=$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')
                    kind=$pending_kind
                    args=$pending_args
                    pending_kind=
                    pending_args=
                    if [ "$answer" != yes ]; then
                        "$HAM_CTL" channel send --text 'Cancelled.'
                        continue
                    fi
                    # Test-only eval: argument text is supplied by the E2E fixture.
                    eval "set -- $args"
                    if [ "$kind" = chain ]; then
                        output=$("$HAM_CTL" task-chain create "$@" 2>&1) || :
                        coordinator=$(printf '%s' "$output" | python3 -c 'import json,sys
def find(v):
    if isinstance(v,dict):
        if v.get("coordinator_agent_instance_id"): return v["coordinator_agent_instance_id"]
        for child in v.values():
            found=find(child)
            if found: return found
    return ""
print(find(json.load(sys.stdin)))')
                        if [ -n "$coordinator" ]; then
                            "$HAM_CTL" chat send --to "$coordinator" --body "From the user via chat: confirm chain $args"
                        fi
                    else
                        output=$("$HAM_CTL" shell run "$@" 2>&1) || :
                    fi
                    "$HAM_CTL" channel send --text "$(printf '%s' "$output" | head -c 3000)"
                    continue
                fi
                case $body in
                    'confirm chain '*)
                        pending_kind=chain
                        pending_args=$(printf '%s' "$body" | cut -c 15-)
                        "$HAM_CTL" channel send --text "Confirm chain $pending_args. Reply yes to confirm."
                        ;;
                    'confirm command '*)
                        pending_kind=command
                        pending_args=$(printf '%s' "$body" | cut -c 17-)
                        "$HAM_CTL" channel send --text "Confirm command $pending_args. Reply yes to confirm."
                        ;;
                    'ctl '*)
                        # Test-only eval: all command text is supplied by our E2E fixture.
                        eval "set -- ${body#ctl }"
                        output=$("$HAM_CTL" "$@" 2>&1) || :
                        "$HAM_CTL" channel send --text "$(printf '%s' "$output" | head -c 3000)"
                        ;;
                    *) "$HAM_CTL" channel send --text "echo: $body" ;;
                esac
                continue
            fi
            case $body in
                'status?')
                    chains=$("$HAM_CTL" task-chain list)
                    title=$(printf '%s\n' "$chains" | sed 's/"title"[[:space:]]*:/\
&/g' | sed -n 's/^"title"[[:space:]]*:[[:space:]]*"\(\([^"\\]*\\.\)*[^"\\]*\)".*/\1/p' | sed -n '1p' | sed 's/\\"/"/g; s/\\\//\//g; s/\\\\/\\/g')
                    "$HAM_CTL" channel send --text "chains: $title"
                    ;;
                *) "$HAM_CTL" channel send --text "echo: $body" ;;
            esac
            ;;
    esac
done
