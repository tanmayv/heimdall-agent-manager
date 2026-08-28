#!/usr/bin/env bash
# Local Heimdall dev stack: hub + dev-proxy + bridge + (optional) UI.
# Everything talks to the LOCAL hub (127.0.0.1:8081), never hub.mundus.in.
#
# Usage:
#   scripts/dev-stack.sh build      # build fresh nix binaries -> ./result-* symlinks
#   scripts/dev-stack.sh start      # repair bridge config, then start hub+proxy+bridge
#   scripts/dev-stack.sh enroll     # mint a fresh bridge token for this hub.db (fixes
#                                   # "bridge is offline" after a hub.db reset)
#   scripts/dev-stack.sh fix-config # rewrite bridge ham_ctl_bin/wrapper_bin to current
#                                   # build + strip [[peer]] blocks (start does this too)
#   scripts/dev-stack.sh stop       # stop local hub+proxy+bridge (NOT the mundus bridge)
#   scripts/dev-stack.sh status     # show what is running
#   scripts/dev-stack.sh ui         # run the Vite+Electron dev UI (foreground)
#
# Note: `start` always repairs the bridge config so it points at the CURRENT
# freshly-built ham-ctl/ham-wrapper. This avoids the classic trap where a pinned
# stale /nix/store ham-ctl lacks `agent start-success`, so launched agents run but
# get stuck at startup_failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_DIR="$ROOT/.run-logs"
mkdir -p "$RUN_DIR/bridge"

HUB_ADDR="127.0.0.1:8081"
PROXY_ADDR="127.0.0.1:8080"
BRIDGE_PORT="49323"
BRIDGE_LOCAL_ENDPOINT_PORT="49324"
HUB_DB="$ROOT/hub.db"
MIGRATIONS="$ROOT/src/hub/repository/sqlite/migrations"
BRIDGE_CONFIG="$RUN_DIR/bridge/bridge-config-full.toml"
BRIDGE_RUN_DIR="/tmp/heimdall-bridge-local"

build() {
  echo "[dev-stack] building fresh binaries via nix..."
  nix build "$ROOT#ham-hub" -o result-hub
  nix build "$ROOT#ham-dev-proxy" -o result-devproxy
  nix build "$ROOT#ham-bridge" -o result-bridge
  nix build "$ROOT#ham-ctl" -o result-ctl
  nix build "$ROOT#ham-wrapper" -o result-wrapper
  echo "[dev-stack] built:"
  for r in result-hub result-devproxy result-bridge result-ctl result-wrapper; do
    printf '  %-18s -> %s\n' "$r" "$(readlink "$r")"
  done
}

BRIDGE_TOKEN_FILE="$RUN_DIR/bridge/bridge-token"

# Rewrite the volatile fields in the bridge config so it always points at the
# CURRENT freshly-built binaries and this hub. This prevents the classic dev trap
# where the config pins stale /nix/store ham-ctl / ham-wrapper paths — an old
# ham-ctl lacks `agent start-success`, so every launched agent times out to
# startup_failed even though it is actually running.
_fix_bridge_config() {
  [ -f "$BRIDGE_CONFIG" ] || { echo "[dev-stack] WARN: $BRIDGE_CONFIG missing; skipping config fix"; return; }
  local ctl_bin wrap_bin
  ctl_bin="$ROOT/result-ctl/bin/ham-ctl"
  wrap_bin="$ROOT/result-wrapper/bin/ham-wrapper"
  BRIDGE_CONFIG="$BRIDGE_CONFIG" CTL_BIN="$ctl_bin" WRAP_BIN="$wrap_bin" \
  HUB_URL="http://$HUB_ADDR" python3 - <<'PY'
import os, re
cfg = os.environ["BRIDGE_CONFIG"]
ctl, wrap, hub = os.environ["CTL_BIN"], os.environ["WRAP_BIN"], os.environ["HUB_URL"]
t = open(cfg).read()

def set_key(text, key, value):
    # Replace `key = "..."` if present, else return unchanged (caller may append).
    pat = re.compile(rf'^({re.escape(key)} = ")[^"]*(")', re.M)
    if pat.search(text):
        return pat.sub(lambda m: f'{m.group(1)}{value}{m.group(2)}', text, count=1)
    return text

# Point tool binaries at the current build.
t = set_key(t, "ham_ctl_bin", ctl)
t = set_key(t, "wrapper_bin", wrap)
# Point the bridge/ctl at this local hub.
t = re.sub(r'(\[ctl\]\s*\n\s*\ndaemon_url = ")[^"]*(")', lambda m: f'{m.group(1)}{hub}{m.group(2)}', t, count=1)
t = set_key(t, "bridge_token", open(os.environ.get("HAM_BRIDGE_TOKEN_FILE","/dev/null")).read().strip()) if os.environ.get("HAM_BRIDGE_TOKEN_FILE") and os.path.exists(os.environ.get("HAM_BRIDGE_TOKEN_FILE","")) else t

# Strip any [[peer]] blocks (local single-hub dev needs no federation peers; a
# stale cloudtop peer just spams failed ws dials).
lines = t.split('\n'); out = []; skip = False
for l in lines:
    if l.strip() == '[[peer]]':
        skip = True; continue
    if skip and l.startswith('[') and l.strip() != '[[peer]]':
        skip = False
    if skip and l.strip() == '':
        skip = False; continue
    if not skip:
        out.append(l)
open(cfg, 'w').write('\n'.join(out))
print(f"[dev-stack] bridge config: ham_ctl_bin -> {ctl}")
print(f"[dev-stack] bridge config: wrapper_bin -> {wrap}")
print("[dev-stack] bridge config: stripped [[peer]] blocks")
PY
}

# Ensure the bridge config has a bridge_token that this hub.db actually knows.
# If the current token fails the hub-runtime handshake, re-enroll to mint a fresh
# matching token and write it into the config. Idempotent.
enroll() {
  [ -e result-bridge ] || { echo "[dev-stack] run 'build' first"; exit 1; }
  _running "$(_pidfile hub)" || { echo "[dev-stack] start the hub first (dev-stack start)"; exit 1; }
  mkdir -p "$RUN_DIR/bridge"
  echo "[dev-stack] creating a bridge enrollment via dev-proxy (user tanmay)"
  local resp token
  resp="$(curl -s -m5 -X POST "http://$PROXY_ADDR/api/v1/bridge-enrollments" -H 'Content-Type: application/json' -d '{"label":"dev-local"}')"
  token="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["enrollment_token"])' 2>/dev/null || true)"
  [ -n "$token" ] || { echo "[dev-stack] enrollment failed: $resp"; exit 1; }
  echo "[dev-stack] exchanging enrollment token for a durable bridge token"
  ./result-bridge/bin/ham-bridge enroll --hub "http://$HUB_ADDR" --enrollment-token "$token" --bridge-token-file "$BRIDGE_TOKEN_FILE" 2>&1 | sed 's/^/  /'
  [ -s "$BRIDGE_TOKEN_FILE" ] || { echo "[dev-stack] enroll did not write a token file"; exit 1; }
  # Fold the fresh token into the config.
  HAM_BRIDGE_TOKEN_FILE="$BRIDGE_TOKEN_FILE" _fix_bridge_config
  echo "[dev-stack] enrolled; token written to $BRIDGE_TOKEN_FILE and config updated."
}

_pidfile() { echo "$RUN_DIR/$1.pid"; }

_running() { # $1=pidfile
  local f="$1"
  [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null
}

_stop_pidfile() { # $1=name
  local f; f="$(_pidfile "$1")"
  if _running "$f"; then
    local pid; pid="$(cat "$f")"
    echo "[dev-stack] stopping $1 (pid $pid)"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$f"
}

_stop_by_match() { # $1=grep-pattern label
  # Stop LOCAL processes matching pattern, but never the mundus bridge.
  local pat="$1"
  local pids
  pids=$(ps ax -o pid= -o command= | grep -E "$pat" | grep -v grep | grep -v "hub.mundus.in" | awk '{print $1}' || true)
  for pid in $pids; do
    echo "[dev-stack] stopping stray '$pat' pid $pid"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  done
}

stop() {
  _stop_pidfile hub
  _stop_pidfile devproxy
  _stop_pidfile bridge
  # Clean up any stale copies bound to the local hub only.
  _stop_by_match "ham-hub .*--listen ${HUB_ADDR}"
  _stop_by_match "ham-dev-proxy .*${PROXY_ADDR}"
  _stop_by_match "ham-bridge .*hub http://127.0.0.1:8081"
  echo "[dev-stack] local stack stopped (mundus bridge left running)."
}

start() {
  [ -e result-hub ] || { echo "[dev-stack] run 'build' first"; exit 1; }
  stop
  sleep 1

  echo "[dev-stack] starting hub on $HUB_ADDR"
  nohup ./result-hub/bin/ham-hub \
    --listen "$HUB_ADDR" --db "$HUB_DB" \
    --migrations-dir "$MIGRATIONS" \
    --trusted-proxy-cidr 127.0.0.1/32 \
    >"$RUN_DIR/hub.log" 2>&1 &
  echo $! > "$(_pidfile hub)"
  sleep 2

  echo "[dev-stack] starting dev-proxy on $PROXY_ADDR -> hub"
  nohup ./result-devproxy/bin/ham-dev-proxy \
    --listen "$PROXY_ADDR" --hub-url "http://$HUB_ADDR" \
    --default-user tanmay \
    >"$RUN_DIR/dev-proxy.log" 2>&1 &
  echo $! > "$(_pidfile devproxy)"
  sleep 1

  # Always repair the bridge config against the CURRENT build + this hub before
  # launching. Fold in a previously-enrolled token file if present.
  [ -s "$BRIDGE_TOKEN_FILE" ] && export HAM_BRIDGE_TOKEN_FILE="$BRIDGE_TOKEN_FILE"
  _fix_bridge_config
  unset HAM_BRIDGE_TOKEN_FILE

  echo "[dev-stack] starting bridge on port $BRIDGE_PORT -> hub"
  local bridge_token_args=()
  [ -s "$BRIDGE_TOKEN_FILE" ] && bridge_token_args=(--bridge-token-file "$BRIDGE_TOKEN_FILE")
  HEIMDALL_HAM_WRAPPER_BIN="$ROOT/result-wrapper/bin/ham-wrapper" \
  HEIMDALL_HAM_CTL_BIN="$ROOT/result-ctl/bin/ham-ctl" \
  nohup ./result-bridge/bin/ham-bridge \
    --config "$BRIDGE_CONFIG" \
    --bind-host 127.0.0.1 --port "$BRIDGE_PORT" \
    --hub "http://$HUB_ADDR" \
    "${bridge_token_args[@]}" \
    --local-endpoint-port "$BRIDGE_LOCAL_ENDPOINT_PORT" \
    --local-run-dir "$BRIDGE_RUN_DIR" \
    >"$RUN_DIR/bridge.log" 2>&1 &
  echo $! > "$(_pidfile bridge)"
  sleep 3

  # Detect the stale-token trap: if the bridge never reaches "hub runtime ready",
  # the config token doesn't match this hub.db — tell the operator to enroll.
  if ! grep -q "bridge hub runtime ready" "$RUN_DIR/bridge.log"; then
    echo "[dev-stack] WARN: bridge has not reported 'hub runtime ready'."
    echo "[dev-stack]       If launches fail with 'bridge is offline', run:"
    echo "[dev-stack]         scripts/dev-stack.sh enroll && scripts/dev-stack.sh start"
  fi

  status
}

status() {
  echo "=== dev-stack status ==="
  for s in hub devproxy bridge; do
    f="$(_pidfile "$s")"
    if _running "$f"; then echo "  $s: RUNNING (pid $(cat "$f"))"; else echo "  $s: stopped"; fi
  done
  echo "--- listeners ---"
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E "8080|8081|$BRIDGE_PORT|$BRIDGE_LOCAL_ENDPOINT_PORT" | awk '{print "  "$1, $9}' || true
  echo "--- health ---"
  curl -s -m 3 "http://$HUB_ADDR/api/v1/health" >/dev/null 2>&1 && echo "  hub /api/v1/health: OK" || echo "  hub health: (check log)"
  echo "NOTE: mundus bridge (hub.mundus.in) is intentionally left untouched."
}

ui() {
  echo "[dev-stack] launching Vite + Electron dev UI (hub API -> local 8081, /api/v1 -> dev-proxy 8080)"
  HEIMDALL_HUB_API_URL="http://127.0.0.1:8081" \
  HEIMDALL_DEV_PROXY_URL="http://127.0.0.1:8080" \
    npm run dev
}

case "${1:-}" in
  build) build ;;
  start) start ;;
  stop) stop ;;
  status) status ;;
  enroll) enroll ;;
  fix-config) _fix_bridge_config ;;
  ui) ui ;;
  *) echo "usage: $0 {build|start|stop|status|enroll|fix-config|ui}"; exit 2 ;;
esac
