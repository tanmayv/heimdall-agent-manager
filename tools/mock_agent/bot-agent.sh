#!/bin/sh
# Deterministic provider for bot delivery integration tests (no model/network API).
set -eu

HAM_CTL=${HAM_CTL:-./bin/ham-ctl}
case ${BOT_AGENT_MODE:-reply} in
    reply|silent) ;;
    *) printf '%s\n' 'bot-agent: unknown BOT_AGENT_MODE' >&2; exit 2 ;;
esac
trap 'exit 0' TERM
"$HAM_CTL" agent start-success
while IFS= read -r line; do
    case $line in
        *'New Telegram message for you'*)
            messages=$("$HAM_CTL" channel read)
            [ "${BOT_AGENT_MODE:-reply}" = silent ] && continue
            # Split fields onto lines so the first entry wins in a compact envelope.
            body=$(printf '%s\n' "$messages" | sed 's/"body"[[:space:]]*:/\
&/g' | sed -n 's/^"body"[[:space:]]*:[[:space:]]*"\(\([^"\\]*\\.\)*[^"\\]*\)".*/\1/p' | sed -n '1p' | sed 's/\\"/"/g; s/\\\//\//g; s/\\\\/\\/g')
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
