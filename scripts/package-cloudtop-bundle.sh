#!/usr/bin/env bash
# Package a self-contained, de-Nixified Cloudtop bundle for Heimdall single-node operation.
# Produces dist/heimdall-cloudtop/ and dist/heimdall-cloudtop-bundle.tar.gz
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DIST_DIR="$ROOT/dist"
BUNDLE_DIR="$DIST_DIR/heimdall-cloudtop"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/bin" "$BUNDLE_DIR/lib" "$BUNDLE_DIR/share/migrations" "$BUNDLE_DIR/systemd" "$BUNDLE_DIR/scripts"

echo "[bundle] 1. Building components via nix..."
nix build .#ham-hub -o result-hub
nix build .#ham-bridge -o result-bridge
nix build .#ham-dev-proxy -o result-devproxy
nix build .#ham-ctl -o result-ctl
nix build .#ham-pty-host -o result-ptyhost

echo "[bundle] 2. Copying binaries..."
cp "$(readlink -f result-hub/bin/ham-hub)" "$BUNDLE_DIR/bin/ham-hub"
cp "$(readlink -f result-bridge/bin/ham-bridge)" "$BUNDLE_DIR/bin/ham-bridge"
cp "$(readlink -f result-devproxy/bin/ham-dev-proxy)" "$BUNDLE_DIR/bin/ham-dev-proxy"
cp "$(readlink -f result-ctl/bin/ham-ctl)" "$BUNDLE_DIR/bin/ham-ctl"
cp "$(readlink -f result-ptyhost/bin/ham-pty-host)" "$BUNDLE_DIR/bin/ham-pty-host"
chmod +x "$BUNDLE_DIR/bin/"*

echo "[bundle] 3. Copying migrations & configs..."
cp -r src/hub/repository/sqlite/migrations/* "$BUNDLE_DIR/share/migrations/"
cp systemd/heimdall.service "$BUNDLE_DIR/systemd/heimdall.service"
cp scripts/install-systemd-service.sh "$BUNDLE_DIR/scripts/install-systemd-service.sh"
cp scripts/snapshot-hub.sh "$BUNDLE_DIR/scripts/snapshot-hub.sh"

echo "[bundle] 4. Writing start.sh and stop.sh..."
cat << 'STARTEOF' > "$BUNDLE_DIR/start.sh"
#!/usr/bin/env bash
# One-click startup script for Heimdall Cloudtop Single-Node
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${HEIMDALL_DATA_DIR:-$HOME/.local/share/heimdall}"
RUN_DIR="$DATA_DIR/run"
LOG_DIR="$DATA_DIR/logs"
BIN_DIR="$BUNDLE_DIR/bin"
MIGRATIONS_DIR="$BUNDLE_DIR/share/migrations"

mkdir -p "$DATA_DIR" "$RUN_DIR" "$LOG_DIR"
chmod 0700 "$DATA_DIR"

echo "=== Heimdall Agent Manager (Cloudtop Single-Node) ==="

# 1. Check LOAS / gcert
if command -v gcertstatus >/dev/null 2>&1; then
  echo "[gcert] Checking LOAS certificate status..."
  gcertstatus 2>&1 | head -n 2 || true
fi

# 2. Start Hub
HUB_LOG="$LOG_DIR/hub.log"
HUB_PID_FILE="$RUN_DIR/hub.pid"
if [ -f "$HUB_PID_FILE" ] && kill -0 "$(cat "$HUB_PID_FILE")" 2>/dev/null; then
  echo "[hub] Already running (PID $(cat "$HUB_PID_FILE"))"
else
  echo "[hub] Starting ham-hub on 127.0.0.1:49322..."
  "$BIN_DIR/ham-hub" --listen 127.0.0.1:49322 --db "$DATA_DIR/hub.db" --migrations-dir "$MIGRATIONS_DIR" > "$HUB_LOG" 2>&1 &
  echo $! > "$HUB_PID_FILE"
fi

# Wait for Hub port
deadline=$((SECONDS + 10))
while ! curl -s "http://127.0.0.1:49322/api/v1/health" >/dev/null 2>&1; do
  if [ $SECONDS -ge $deadline ]; then
    echo "[-] Hub failed to start. Check $HUB_LOG"
    exit 1
  fi
  sleep 0.2
done
echo "[hub] Ready at http://127.0.0.1:49322"

# 3. Start Bridge
BRIDGE_LOG="$LOG_DIR/bridge.log"
BRIDGE_PID_FILE="$RUN_DIR/bridge.pid"
if [ -f "$BRIDGE_PID_FILE" ] && kill -0 "$(cat "$BRIDGE_PID_FILE")" 2>/dev/null; then
  echo "[bridge] Already running (PID $(cat "$BRIDGE_PID_FILE"))"
else
  echo "[bridge] Starting ham-bridge on 127.0.0.1:49323..."
  export HEIMDALL_HAM_PTY_HOST_BIN="$BIN_DIR/ham-pty-host"
  export HEIMDALL_HAM_CTL_BIN="$BIN_DIR/ham-ctl"
  "$BIN_DIR/ham-bridge" --bind-host 127.0.0.1 --port 49323 --hub http://127.0.0.1:49322 --local-run-dir "/tmp/heimdall-bridge-local" > "$BRIDGE_LOG" 2>&1 &
  echo $! > "$BRIDGE_PID_FILE"
fi

# 4. Start Dev-Proxy
PROXY_LOG="$LOG_DIR/dev-proxy.log"
PROXY_PID_FILE="$RUN_DIR/dev-proxy.pid"
if [ -f "$PROXY_PID_FILE" ] && kill -0 "$(cat "$PROXY_PID_FILE")" 2>/dev/null; then
  echo "[proxy] Already running (PID $(cat "$PROXY_PID_FILE"))"
else
  echo "[proxy] Starting ham-dev-proxy on 127.0.0.1:8080..."
  "$BIN_DIR/ham-dev-proxy" --listen 127.0.0.1:8080 --hub-url http://127.0.0.1:49322 > "$PROXY_LOG" 2>&1 &
  echo $! > "$PROXY_PID_FILE"
fi

echo "=== Heimdall Single-Node Stack is UP ==="
echo "Access points:"
echo "  Dev Proxy / UI: http://127.0.0.1:8080"
echo "  Hub API:        http://127.0.0.1:49322"
echo "  Bridge Status:  http://127.0.0.1:49323"
STARTEOF
chmod +x "$BUNDLE_DIR/start.sh"

cat << 'STOPEOF' > "$BUNDLE_DIR/stop.sh"
#!/usr/bin/env bash
# One-click stop script for Heimdall Cloudtop Single-Node
set -euo pipefail

DATA_DIR="${HEIMDALL_DATA_DIR:-$HOME/.local/share/heimdall}"
RUN_DIR="$DATA_DIR/run"

stop_proc() {
  local name="$1"
  local pid_file="$RUN_DIR/$name.pid"
  if [ -f "$pid_file" ]; then
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "[$name] Stopping PID $pid..."
      kill -TERM "$pid" 2>/dev/null || true
      deadline=$((SECONDS + 5))
      while kill -0 "$pid" 2>/dev/null; do
        if [ $SECONDS -ge $deadline ]; then
          echo "[$name] Force killing PID $pid..."
          kill -KILL "$pid" 2>/dev/null || true
          break
        fi
        sleep 0.1
      done
    fi
    rm -f "$pid_file"
    echo "[$name] Stopped."
  fi
}

echo "=== Stopping Heimdall Single-Node Stack ==="
stop_proc "dev-proxy"
stop_proc "bridge"
stop_proc "hub"
echo "=== Heimdall Single-Node Stack Stopped ==="
STOPEOF
chmod +x "$BUNDLE_DIR/stop.sh"

cat << 'READMEEOF' > "$BUNDLE_DIR/README.md"
# Heimdall Agent Manager - Cloudtop Standalone Bundle

This bundle contains self-contained ELF binaries adapted to run on a Google Cloudtop workstation without requiring Nix or compilation.

## Quick Start
1. Run `./start.sh` to launch the stack on loopback:
   - Web UI / Dev Proxy: `http://127.0.0.1:8080`
   - Hub API: `http://127.0.0.1:49322`
2. Run `./stop.sh` to shut down the stack.

## Systemd User Service with Linger
To run automatically on login / boot with systemd:
```bash
./scripts/install-systemd-service.sh
systemctl --user enable --now heimdall.service
```

## Backups & Snapshots
```bash
./scripts/snapshot-hub.sh export
```
READMEEOF

echo "[bundle] 5. De-Nixifying ELF binaries via patchelf..."
nix-shell -p patchelf --run "
for bin in '$BUNDLE_DIR'/bin/*; do
  [ -f \"\$bin\" ] || continue
  # Extract any non-standard store dependencies
  for lib in \$(ldd \"\$bin\" 2>/dev/null | grep '/nix/store' | awk '{print \$3}'); do
    if [ -f \"\$lib\" ]; then
      cp -n \"\$lib\" '$BUNDLE_DIR/lib/' || true
    fi
  done
  patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 \"\$bin\" 2>/dev/null || true
  patchelf --set-rpath '\$ORIGIN/../lib:\$ORIGIN' \"\$bin\" 2>/dev/null || true
done
"

echo "[bundle] 6. Creating archive dist/heimdall-cloudtop-bundle.tar.gz..."
tar -czf "$DIST_DIR/heimdall-cloudtop-bundle.tar.gz" -C "$DIST_DIR" heimdall-cloudtop

echo "[bundle] SUCCESS: Created $DIST_DIR/heimdall-cloudtop-bundle.tar.gz"
ls -lh "$DIST_DIR/heimdall-cloudtop-bundle.tar.gz"
