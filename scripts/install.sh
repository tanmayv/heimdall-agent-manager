#!/usr/bin/env bash
# One-click installer and launcher for Heimdall Agent Manager on Google Cloudtop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
if [ -f "$SCRIPT_DIR/../package.json" ]; then
  ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [ -f "$SCRIPT_DIR/package.json" ]; then
  ROOT_DIR="$SCRIPT_DIR"
fi

echo "========================================================"
echo "    Heimdall Cloudtop Single-Node Installer & Launcher"
echo "========================================================"

# 1. Determine Bundle Directory
BUNDLE_DIR=""
if [ -d "$SCRIPT_DIR/bin" ] && [ -f "$SCRIPT_DIR/start.sh" ]; then
  BUNDLE_DIR="$SCRIPT_DIR"
elif [ -d "$ROOT_DIR/dist/heimdall-cloudtop/bin" ] && [ -f "$ROOT_DIR/dist/heimdall-cloudtop/start.sh" ]; then
  BUNDLE_DIR="$ROOT_DIR/dist/heimdall-cloudtop"
elif [ -f "$ROOT_DIR/scripts/package-cloudtop-bundle.sh" ]; then
  echo "[install] Building standalone bundle..."
  "$ROOT_DIR/scripts/package-cloudtop-bundle.sh"
  BUNDLE_DIR="$ROOT_DIR/dist/heimdall-cloudtop"
fi

if [ -z "$BUNDLE_DIR" ] || [ ! -d "$BUNDLE_DIR" ]; then
  echo "[-] Could not locate or build Heimdall Cloudtop bundle."
  exit 1
fi

DATA_DIR="${HEIMDALL_DATA_DIR:-$HOME/.local/share/heimdall}"
BIN_DIR="$DATA_DIR/bin"
LIB_DIR="$DATA_DIR/lib"
SHARE_DIR="$DATA_DIR/share/migrations"
RUN_DIR="$DATA_DIR/run"
LOG_DIR="$DATA_DIR/logs"
LOCAL_BIN="$HOME/.local/bin"

echo "[install] Installing to $DATA_DIR..."
mkdir -p "$DATA_DIR" "$BIN_DIR" "$LIB_DIR" "$SHARE_DIR" "$RUN_DIR" "$LOG_DIR" "$LOCAL_BIN"
chmod 0700 "$DATA_DIR"

# 2. Copy binaries and runtime libraries
echo "[install] Copying binaries..."
cp -a --remove-destination "$BUNDLE_DIR/bin/"* "$BIN_DIR/"
chmod u+w "$BIN_DIR/"* 2>/dev/null || true
chmod +x "$BIN_DIR/"*

if [ -d "$BUNDLE_DIR/lib" ]; then
  echo "[install] Copying runtime libraries..."
  cp -a --remove-destination "$BUNDLE_DIR/lib/"* "$LIB_DIR/" 2>/dev/null || true
  chmod -R u+w "$LIB_DIR/" 2>/dev/null || true
fi

# 3. Copy migrations
if [ -d "$BUNDLE_DIR/share/migrations" ]; then
  echo "[install] Copying database migrations..."
  cp -a "$BUNDLE_DIR/share/migrations/"* "$SHARE_DIR/"
fi

# 4. Copy management scripts
cp "$BUNDLE_DIR/start.sh" "$BIN_DIR/start.sh"
cp "$BUNDLE_DIR/stop.sh" "$BIN_DIR/stop.sh"
cp "$BUNDLE_DIR/start.sh" "$DATA_DIR/start.sh"
cp "$BUNDLE_DIR/stop.sh" "$DATA_DIR/stop.sh"
chmod +x "$BIN_DIR/start.sh" "$BIN_DIR/stop.sh" "$DATA_DIR/start.sh" "$DATA_DIR/stop.sh"

# 5. Symlink CLI to ~/.local/bin
echo "[install] Symlinking ham-ctl into $LOCAL_BIN/ham-ctl..."
ln -sf "$BIN_DIR/ham-ctl" "$LOCAL_BIN/ham-ctl"

# 6. Install systemd user unit
if [ -f "$BUNDLE_DIR/scripts/install-systemd-service.sh" ]; then
  echo "[install] Configuring systemd --user service..."
  bash "$BUNDLE_DIR/scripts/install-systemd-service.sh" || true
elif [ -f "$ROOT_DIR/scripts/install-systemd-service.sh" ]; then
  echo "[install] Configuring systemd --user service..."
  bash "$ROOT_DIR/scripts/install-systemd-service.sh" || true
fi

# 7. Start the stack
echo "[install] Launching Heimdall Single-Node Stack (Hub, Bridge, Dev-Proxy, UI)..."
if command -v systemctl >/dev/null 2>&1 && [ -f "$HOME/.config/systemd/user/heimdall.service" ]; then
  echo "[install] Starting via systemd user service..."
  systemctl --user daemon-reload || true
  systemctl --user restart heimdall.service || systemctl --user start heimdall.service || "$BIN_DIR/start.sh"
else
  "$BIN_DIR/start.sh"
fi

echo ""
echo "========================================================"
echo "    Heimdall Cloudtop Stack Successfully Installed!"
echo "========================================================"
