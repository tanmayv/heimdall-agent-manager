#!/usr/bin/env bash
# Install Heimdall systemd --user service and enable linger on Google Cloudtop
set -euo pipefail

USER_NAME="${USER:-$(id -un)}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SERVICE_SRC="$ROOT_DIR/systemd/heimdall.service"
SERVICE_DEST="$SYSTEMD_USER_DIR/heimdall.service"

echo "[install-service] Installing systemd unit to $SERVICE_DEST..."
cp "$SERVICE_SRC" "$SERVICE_DEST"
chmod 0644 "$SERVICE_DEST"

echo "[install-service] Enabling systemd user linger for $USER_NAME..."
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "$USER_NAME" || echo "[install-service] Warning: loginctl enable-linger failed (may require privileges), continuing."
else
  echo "[install-service] Warning: loginctl not found; linger must be enabled manually if needed."
fi

if command -v systemctl >/dev/null 2>&1; then
  echo "[install-service] Reloading systemd user daemon..."
  systemctl --user daemon-reload || true
  echo "[install-service] Service installed successfully."
  echo "To enable and start now, run:"
  echo "  systemctl --user enable --now heimdall.service"
  echo "To check logs, run:"
  echo "  journalctl --user -u heimdall.service -f"
fi
