#!/usr/bin/env bash
# scripts/apply-bridge-update.sh
# Detached out-of-process supervisor for atomic Heimdall Bridge binary replacement
# and health-monitored automated rollback (REQ-BUPD-4, REQ-BUPD-5).

set -euo pipefail

# --- Configuration & Defaults ------------------------------------------------
DATA_DIR="${DATA_DIR:-$HOME/.local/share/heimdall}"
STAGE_DIR="${STAGE_DIR:-}"
BRIDGE_PORT="${BRIDGE_PORT:-49323}"
HUB_URL="${HUB_URL:-http://127.0.0.1:8989}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}"
SERVICE_NAME="${SERVICE_NAME:-heimdall.service}"
RESTART_CMD="${RESTART_CMD:-}"
STOP_CMD="${STOP_CMD:-}"
HEALTH_URL="${HEALTH_URL:-}"

# Parse command line flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --stage-dir)
      STAGE_DIR="$2"
      shift 2
      ;;
    --bridge-port)
      BRIDGE_PORT="$2"
      shift 2
      ;;
    --hub-url)
      HUB_URL="$2"
      shift 2
      ;;
    --health-timeout)
      HEALTH_TIMEOUT="$2"
      shift 2
      ;;
    --service-name)
      SERVICE_NAME="$2"
      shift 2
      ;;
    --restart-cmd)
      RESTART_CMD="$2"
      shift 2
      ;;
    --stop-cmd)
      STOP_CMD="$2"
      shift 2
      ;;
    --health-url)
      HEALTH_URL="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo "  --data-dir DIR        Root data directory (default: ~/.local/share/heimdall)"
      echo "  --stage-dir DIR       Staging directory containing extracted binaries"
      echo "  --bridge-port PORT    Port bridge listens on for health check (default: 49323)"
      echo "  --hub-url URL         Central Hub URL"
      echo "  --health-timeout SEC  Healthcheck probe timeout in seconds (default: 30)"
      echo "  --service-name NAME   Systemd service unit name (default: heimdall.service)"
      echo "  --restart-cmd CMD     Command to restart bridge (optional)"
      echo "  --stop-cmd CMD        Command to stop bridge (optional)"
      echo "  --health-url URL      Explicit health URL override (optional)"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2
      shift
      ;;
  esac
done

# Expand leading ~ in DATA_DIR if present
DATA_DIR="${DATA_DIR/#\~/$HOME}"
if [ -z "$STAGE_DIR" ]; then
  STAGE_DIR="$DATA_DIR/updates/stage"
fi
STAGE_DIR="${STAGE_DIR/#\~/$HOME}"

if [ -z "$HEALTH_URL" ]; then
  HEALTH_URL="http://127.0.0.1:$BRIDGE_PORT/api/v1/health"
fi

log() {
  printf '[apply-bridge-update] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

log_err() {
  printf '[apply-bridge-update] [%s] ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

log "Starting supervisor execution"
log "  DATA_DIR:       $DATA_DIR"
log "  STAGE_DIR:      $STAGE_DIR"
log "  BRIDGE_PORT:    $BRIDGE_PORT"
log "  HEALTH_URL:     $HEALTH_URL"
log "  HEALTH_TIMEOUT: ${HEALTH_TIMEOUT}s"

# Locate staged binaries
STAGE_BIN=""
if [ -d "$STAGE_DIR/bin" ]; then
  STAGE_BIN="$STAGE_DIR/bin"
elif [ -d "$STAGE_DIR/extract/bin" ]; then
  STAGE_BIN="$STAGE_DIR/extract/bin"
elif [ -d "$STAGE_DIR/heimdall-cloudtop/bin" ]; then
  STAGE_BIN="$STAGE_DIR/heimdall-cloudtop/bin"
elif [ -f "$STAGE_DIR/ham-bridge" ]; then
  STAGE_BIN="$STAGE_DIR"
else
  log_err "Staged binaries not found in $STAGE_DIR"
  exit 1
fi

log "Located staged binaries at: $STAGE_BIN"

# Helper to stop service
stop_service() {
  log "Stopping active bridge service..."
  if [ -n "$STOP_CMD" ]; then
    eval "$STOP_CMD" || true
  elif command -v systemctl >/dev/null 2>&1 && [ -f "$HOME/.config/systemd/user/$SERVICE_NAME" ]; then
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
  else
    pkill -f "ham-bridge" 2>/dev/null || true
  fi
}

# Helper to start service
start_service() {
  log "Starting bridge service..."
  if [ -n "$RESTART_CMD" ]; then
    eval "$RESTART_CMD"
  elif command -v systemctl >/dev/null 2>&1 && [ -f "$HOME/.config/systemd/user/$SERVICE_NAME" ]; then
    systemctl --user daemon-reload || true
    systemctl --user restart "$SERVICE_NAME" || systemctl --user start "$SERVICE_NAME"
  elif [ -f "$DATA_DIR/start.sh" ]; then
    "$DATA_DIR/start.sh" --standalone &
  elif [ -f "$DATA_DIR/bin/start.sh" ]; then
    "$DATA_DIR/bin/start.sh" --standalone &
  elif [ -f "$DATA_DIR/bin/ham-bridge" ]; then
    "$DATA_DIR/bin/ham-bridge" &
  else
    log_err "No start mechanism found for bridge"
    return 1
  fi
}

# 1. Stop current service cleanly
stop_service

# 2. Backup existing binaries
log "Backing up current bin to $DATA_DIR/bin.bak"
rm -rf "$DATA_DIR/bin.bak"
if [ -d "$DATA_DIR/bin" ]; then
  cp -R -p "$DATA_DIR/bin" "$DATA_DIR/bin.bak"
fi

# 3. Atomically replace binaries
log "Staging new binaries into $DATA_DIR/bin.new"
rm -rf "$DATA_DIR/bin.new"
mkdir -p "$DATA_DIR/bin.new"
cp -R -p "$STAGE_BIN/"* "$DATA_DIR/bin.new/"
chmod +x "$DATA_DIR/bin.new/"* 2>/dev/null || true

# Copy migrations or assets if staged
if [ -d "$STAGE_DIR/share/migrations" ]; then
  mkdir -p "$DATA_DIR/share/migrations"
  cp -R -p "$STAGE_DIR/share/migrations/"* "$DATA_DIR/share/migrations/"
fi

log "Performing atomic directory swap into $DATA_DIR/bin"
rm -rf "$DATA_DIR/bin.old"
if [ -d "$DATA_DIR/bin" ]; then
  mv "$DATA_DIR/bin" "$DATA_DIR/bin.old"
fi
mv "$DATA_DIR/bin.new" "$DATA_DIR/bin"
rm -rf "$DATA_DIR/bin.old"

# 4. Restart service
if ! start_service; then
  log_err "Failed to restart bridge service"
fi

# 5. Verification Gate: Poll health endpoint for up to HEALTH_TIMEOUT seconds
log "Beginning health check polling for up to ${HEALTH_TIMEOUT} seconds..."
deadline=$((SECONDS + HEALTH_TIMEOUT))
healthy=false

while [ $SECONDS -lt $deadline ]; do
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "$HEALTH_URL" 2>/dev/null || true)
  if [ "$http_code" = "200" ] || [ "$http_code" = "401" ] || curl -s "$HEALTH_URL" 2>/dev/null | grep -q '"ok":true'; then
    healthy=true
    log "Health check succeeded (HTTP code: $http_code)"
    break
  fi
  sleep 1
done

# 6. Finalize or Rollback
if [ "$healthy" = true ]; then
  log "Update verification succeeded! Removing backup and staging directory."
  rm -rf "$DATA_DIR/bin.bak" "$STAGE_DIR"
  log "Bridge update completed successfully."
  exit 0
else
  log_err "Health check timed out or failed after ${HEALTH_TIMEOUT}s! Initiating automatic rollback..."
  stop_service

  if [ -d "$DATA_DIR/bin.bak" ]; then
    log "Restoring binaries from $DATA_DIR/bin.bak..."
    rm -rf "$DATA_DIR/bin.failed"
    if [ -d "$DATA_DIR/bin" ]; then
      mv "$DATA_DIR/bin" "$DATA_DIR/bin.failed"
    fi
    cp -R -p "$DATA_DIR/bin.bak" "$DATA_DIR/bin"
    rm -rf "$DATA_DIR/bin.failed"
  else
    log_err "No $DATA_DIR/bin.bak found to restore from!"
  fi

  log "Restarting rolled-back service..."
  start_service || true

  mkdir -p "$DATA_DIR/logs"
  rollback_log="$DATA_DIR/logs/update_rollback.log"
  echo "Update failed: Health check timed out or failed after ${HEALTH_TIMEOUT}s on $(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "$rollback_log"
  log_err "Rollback complete. Log written to $rollback_log"
  exit 1
fi
