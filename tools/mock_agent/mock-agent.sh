#!/bin/sh
# Heimdall mock agent — drop-in replacement for a real agent (pi) process.
#
# The wrapper supervisor (RTE2E-5) launches the agent via `sh -c <agent_command>`
# with a sanitized env that includes:
#   HEIMDALL_BRIDGE_ENDPOINT  local Bridge JSONL endpoint (unix:|tcp:)
#   HEIMDALL_AGENT_TOKEN      local hlat_ token for agent-role methods
#   HEIMDALL_AGENT_INSTANCE_ID agent instance id
#
# This mock:
#   1. Executes a replay script (line-based action list) with configurable delays.
#   2. Logs every command + its stdout to a log file (the test artifact).
#   3. Logs all stdin (tmux send-keys input) to the same log file.
#   4. Logs all local-endpoint responses (Bridge notifications) to the log file.
#
# Config (env vars):
#   HEIMDALL_MOCK_LOG      log file path (default: $PWD/mock-agent.log)
#   HEIMDALL_MOCK_REPLAY   replay script path (default: $PWD/replay.txt)
#   HAM_CTL                ham-ctl binary path (default: ham-ctl from PATH)
#
# This is intentionally POSIX sh so it runs on any platform the wrapper targets.

set -u

LOG="${HEIMDALL_MOCK_LOG:-$PWD/mock-agent.log}"
REPLAY="${HEIMDALL_MOCK_REPLAY:-$PWD/replay.txt}"
HAM_CTL_BIN="${HAM_CTL:-ham-ctl}"

ENDPOINT="${HEIMDALL_BRIDGE_ENDPOINT:-}"
TOKEN="${HEIMDALL_AGENT_TOKEN:-}"
INSTANCE="${HEIMDALL_AGENT_INSTANCE_ID:-}"
START_TS="$(date +%s)"
STDIN_PID=""

# ── signal handling ──────────────────────────────────────────────────────────
# The wrapper/bridge sends TERM (stop) or HUP; tmux pane death may deliver INT.
# Log the signal and exit cleanly so the log artifact records the real cause.
mock_shutdown() {
    _sig="$1"
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    log_event "signal" "received $_sig; shutting down"
    [ -n "$STDIN_PID" ] && kill "$STDIN_PID" 2>/dev/null || true
    wait "$STDIN_PID" 2>/dev/null || true
    log_section "Heimdall mock agent exited $(ts) via signal $_sig (uptime $(($(date +%s) - START_TS))s)"
    exit 0
}
trap 'mock_shutdown TERM' TERM
trap 'mock_shutdown INT'  INT
trap 'mock_shutdown HUP'  HUP

# ── logging helpers ──────────────────────────────────────────────────────────

log_line() {
    printf '%s\n' "$*" >>"$LOG"
}

log_section() {
    log_line ""
    log_line "================================================================================"
    log_line "$*"
    log_line "================================================================================"
}

ts() {
    printf '%s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# Log a structured event as a single JSON-ish line for deterministic parsing.
log_event() {
    # $1=kind, rest=detail
    _kind="$1"; shift
    _detail="$*"
    log_line "{\"ts\":\"$(ts)\",\"kind\":\"$_kind\",\"detail\":\"$_detail\"}"
}

# ── local endpoint call wrapper (logs the response) ──────────────────────────
# Usage: endpoint_call <method-name> <ham-ctl-subcommand-args...>
endpoint_call() {
    _method="$1"; shift
    if [ -z "$ENDPOINT" ] || [ -z "$TOKEN" ]; then
        log_event "endpoint_skipped" "no endpoint/token configured; method=$_method"
        return 1
    fi
    _resp=$("$HAM_CTL_BIN" agent --bridge-endpoint "$ENDPOINT" --agent-token "$TOKEN" "$@" 2>&1) || true
    _rc=$?
    log_event "endpoint_call" "method=$_method args=$* rc=$_rc"
    log_line "  response: $_resp"
    [ -n "$_resp" ] && printf '%s\n' "$_resp" >>"$LOG"
    printf '%s' "$_resp"
}

# ── stdin capture (tmux send-keys input) ─────────────────────────────────────
# The agent runs in a tmux pane; operator/wrapper keystrokes arrive on stdin.
# Capture them in the background and log each line.
capture_stdin() {
    # Reads from fd 0; the caller redirects fd 0 from the saved real stdin (fd 3).
    while IFS= read -r _line 2>/dev/null; do
        log_event "stdin" "$_line"
    done
}

# ── startup banner ───────────────────────────────────────────────────────────

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: >"$LOG" 2>/dev/null || {
    echo "mock-agent: cannot write log file: $LOG" >&2
    exit 1
}

log_section "Heimdall mock agent started $(ts)"
log_event "config" "log=$LOG replay=$REPLAY ham_ctl=$HAM_CTL_BIN"
log_event "env" "endpoint=$ENDPOINT instance=$INSTANCE token_set=$([ -n "$TOKEN" ] && echo yes || echo no)"
log_line "  replay file: $REPLAY"
if [ ! -f "$REPLAY" ]; then
    log_event "replay_missing" "no replay script at $REPLAY; running default minimal loop"
fi

# Save real stdin to fd 3. Non-interactive shells (no job control) redirect
# async-command stdin from /dev/null, so an explicit fd-0 redirection is
# required for the background reader to actually receive the wrapper's
# tmux-send-keys input. Closing fd 3 in the parent lets the reader detect EOF.
exec 3<&0
capture_stdin <&3 &
STDIN_PID=$!
exec 3<&-
log_event "stdin_capture_started" "pid=$STDIN_PID"

# ── replay engine ────────────────────────────────────────────────────────────

LINENO_MOCK=0
run_replay() {
    if [ ! -f "$REPLAY" ]; then
        # Default behavior: announce readiness, then idle until killed.
        log_event "replay_default" "start-success then idle"
        endpoint_call "agent.start_success" "start-success" >/dev/null
        log_event "idle" "waiting for signals/stdin; will exit on TERM"
        while :; do
            sleep 1
        done
        return
    fi

    while IFS= read -r _raw || [ -n "$_raw" ]; do
        LINENO_MOCK=$((LINENO_MOCK + 1))
        _line="$(printf '%s' "$_raw" | sed 's/[[:space:]]*$//')"
        # Skip blank lines and comments.
        case "$_line" in
            ''|'#'*) continue ;;
        esac
        _action="${_line%% *}"
        _rest=""
        if [ "$_action" != "$_line" ]; then
            _rest="${_line#* }"
        fi
        log_event "replay_step" "line=$LINENO_MOCK action=$_action"

        case "$_action" in
            sleep)
                _secs="${_rest:-1}"
                log_line "  sleeping ${_secs}s"
                # Poll the endpoint during sleep to surface Bridge state.
                sleep "$_secs" 2>/dev/null || sleep 1
                ;;
            context)
                endpoint_call "agent.context.get" "context" >/dev/null
                ;;
            say)
                endpoint_call "agent.chat.send_to_user" chat send --body "$_rest" >/dev/null
                ;;
            task-comment)
                _tid="${_rest%% *}"
                _body="${_rest#* }"
                [ "$_tid" = "$_rest" ] && _body=""
                endpoint_call "agent.tasks.comment" tasks comment --task-id "$_tid" --body "$_body" >/dev/null
                ;;
            task-status)
                _tid="${_rest%% *}"
                _status="${_rest#* }"
                [ "$_tid" = "$_rest" ] && _status=""
                endpoint_call "agent.tasks.status" tasks status --task-id "$_tid" --status "$_status" >/dev/null
                ;;
            task-vote)
                _tid="${_rest%% *}"
                _result="${_rest#* }"
                [ "$_tid" = "$_rest" ] && _result=""
                endpoint_call "agent.tasks.vote" tasks vote --task-id "$_tid" --result "$_result" >/dev/null
                ;;
            start-success)
                endpoint_call "agent.start_success" "start-success" >/dev/null
                ;;
            run)
                _out=$(eval "$_rest" 2>&1) || true
                log_event "run_stdout" "$_rest"
                [ -n "$_out" ] && printf '%s\n' "$_out" >>"$LOG"
                ;;
            echo)
                log_line "  echo: $_rest"
                ;;
            done)
                log_event "replay_done" "clean exit"
                return 0
                ;;
            *)
                log_event "replay_unknown" "unknown action '$_action' on line $LINENO_MOCK"
                ;;
        esac
    done <"$REPLAY"
    log_event "replay_eof" "reached end of replay script"
}

# Run the replay.
run_replay
_REPLAY_RC=$?

# ── shutdown ─────────────────────────────────────────────────────────────────

log_event "stopping" "replay_rc=$_REPLAY_RC"
kill "$STDIN_PID" 2>/dev/null || true
wait "$STDIN_PID" 2>/dev/null || true
log_section "Heimdall mock agent exited $(ts) (uptime $(($(date +%s) - START_TS))s)"
exit "$_REPLAY_RC"
