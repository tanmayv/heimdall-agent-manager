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
if [ -f "result-hub/bin/.ham-hub-wrapped" ]; then
  cp "$(readlink -f result-hub/bin/.ham-hub-wrapped)" "$BUNDLE_DIR/bin/ham-hub"
else
  cp "$(readlink -f result-hub/bin/ham-hub)" "$BUNDLE_DIR/bin/ham-hub"
fi

if [ -f "result-bridge/bin/.ham-bridge-wrapped" ]; then
  cp "$(readlink -f result-bridge/bin/.ham-bridge-wrapped)" "$BUNDLE_DIR/bin/ham-bridge"
else
  cp "$(readlink -f result-bridge/bin/ham-bridge)" "$BUNDLE_DIR/bin/ham-bridge"
fi

cp "$(readlink -f result-devproxy/bin/ham-dev-proxy)" "$BUNDLE_DIR/bin/ham-dev-proxy"
cp "$(readlink -f result-ctl/bin/ham-ctl)" "$BUNDLE_DIR/bin/ham-ctl"
cp "$(readlink -f result-ptyhost/bin/ham-pty-host)" "$BUNDLE_DIR/bin/ham-pty-host"
chmod u+w "$BUNDLE_DIR/bin/"*
chmod +x "$BUNDLE_DIR/bin/"*

echo "[bundle] 3. Copying migrations & configs..."
cp -r src/hub/repository/sqlite/migrations/* "$BUNDLE_DIR/share/migrations/"
cp systemd/heimdall.service "$BUNDLE_DIR/systemd/heimdall.service"
cp scripts/install-systemd-service.sh "$BUNDLE_DIR/scripts/install-systemd-service.sh"
cp scripts/snapshot-hub.sh "$BUNDLE_DIR/scripts/snapshot-hub.sh"
cp scripts/install.sh "$BUNDLE_DIR/install.sh"
chmod +x "$BUNDLE_DIR/install.sh"
if [ -f "scripts/publish-mpm.sh" ]; then
  cp scripts/publish-mpm.sh "$BUNDLE_DIR/scripts/publish-mpm.sh"
  chmod +x "$BUNDLE_DIR/scripts/publish-mpm.sh"
fi
if [ -d "packaging" ]; then
  cp -r packaging "$BUNDLE_DIR/"
fi

echo "[bundle] 3.5. Building production UI assets via vite..."
mkdir -p "$BUNDLE_DIR/ui"
npm run typecheck
npx vite build --outDir "$BUNDLE_DIR/ui"

echo "[bundle] 4. Writing start.sh and stop.sh..."
cat << 'STARTEOF' > "$BUNDLE_DIR/start.sh"
#!/usr/bin/env bash
# One-click startup script for Heimdall Cloudtop Single-Node
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${HEIMDALL_DATA_DIR:-$HOME/.local/share/heimdall}"
RUN_DIR="$DATA_DIR/run"
LOG_DIR="$DATA_DIR/logs"

if [ -d "$BUNDLE_DIR/bin" ]; then
  BIN_DIR="$BUNDLE_DIR/bin"
elif [ -f "$BUNDLE_DIR/ham-hub" ]; then
  BIN_DIR="$BUNDLE_DIR"
else
  BIN_DIR="$DATA_DIR/bin"
fi

if [ -d "$BUNDLE_DIR/share/migrations" ]; then
  MIGRATIONS_DIR="$BUNDLE_DIR/share/migrations"
elif [ -d "$DATA_DIR/share/migrations" ]; then
  MIGRATIONS_DIR="$DATA_DIR/share/migrations"
elif [ -d "$BUNDLE_DIR/../share/migrations" ]; then
  MIGRATIONS_DIR="$BUNDLE_DIR/../share/migrations"
else
  MIGRATIONS_DIR="$DATA_DIR/share/migrations"
fi

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
HUB_SECRET_FLAG=""
if [ -f "$DATA_DIR/proxy_secret" ]; then
  HUB_SECRET_FLAG="--proxy-secret-file $DATA_DIR/proxy_secret"
fi

if [ -f "$HUB_PID_FILE" ] && kill -0 "$(cat "$HUB_PID_FILE")" 2>/dev/null; then
  echo "[hub] Already running (PID $(cat "$HUB_PID_FILE"))"
else
  echo "[hub] Starting ham-hub on 127.0.0.1:49322..."
  nohup "$BIN_DIR/ham-hub" --listen 127.0.0.1:49322 --db "$DATA_DIR/hub.db" --migrations-dir "$MIGRATIONS_DIR" $HUB_SECRET_FLAG > "$HUB_LOG" 2>&1 &
  PID=$!
  echo $PID > "$HUB_PID_FILE"
  disown $PID 2>/dev/null || true
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
BRIDGE_PORT="${HEIMDALL_BRIDGE_PORT:-49323}"
BRIDGE_ENDPOINT_PORT="${HEIMDALL_BRIDGE_ENDPOINT_PORT:-49324}"
BRIDGE_RUN_DIR="${HEIMDALL_BRIDGE_RUN_DIR:-/tmp/heimdall-bridge-local}"
BRIDGE_TOKEN_FILE="$DATA_DIR/bridge_token_cloudtop"

# Detect if default port 49323 is already in use (e.g. multi-agent supervisor connected to remote hub)
if python3 -c "import socket; s=socket.socket(); s.settimeout(0.1); exit(0 if s.connect_ex(('127.0.0.1', int('$BRIDGE_PORT'))) == 0 else 1)" 2>/dev/null; then
  if [ "$BRIDGE_PORT" = "49323" ]; then
    echo "[bridge] Port 49323 is occupied; using port 49325 for standalone bridge"
    BRIDGE_PORT=49325
    BRIDGE_ENDPOINT_PORT=49326
    BRIDGE_RUN_DIR="/tmp/heimdall-bridge-standalone"
  fi
fi

if [ -f "$BRIDGE_PID_FILE" ] && kill -0 "$(cat "$BRIDGE_PID_FILE")" 2>/dev/null; then
  echo "[bridge] Already running (PID $(cat "$BRIDGE_PID_FILE"))"
else
  # Auto-pair if token not yet present
  if [ ! -s "$BRIDGE_TOKEN_FILE" ]; then
    echo "[bridge] Auto-pairing bridge with local Hub..."
    "$BIN_DIR/ham-bridge" enroll --hub http://127.0.0.1:49322 --name "$(hostname -s)" --user "${USER:-$(whoami)}" --bridge-token-file "$BRIDGE_TOKEN_FILE" || true
  fi

  echo "[bridge] Starting ham-bridge on 127.0.0.1:$BRIDGE_PORT..."
  export HEIMDALL_HAM_PTY_HOST_BIN="$BIN_DIR/ham-pty-host"
  export HEIMDALL_HAM_CTL_BIN="$BIN_DIR/ham-ctl"
  nohup "$BIN_DIR/ham-bridge" --bind-host 127.0.0.1 --port "$BRIDGE_PORT" --local-endpoint-port "$BRIDGE_ENDPOINT_PORT" --hub http://127.0.0.1:49322 --local-run-dir "$BRIDGE_RUN_DIR" --bridge-token-file "$BRIDGE_TOKEN_FILE" > "$BRIDGE_LOG" 2>&1 &
  PID=$!
  echo $PID > "$BRIDGE_PID_FILE"
  disown $PID 2>/dev/null || true
fi

# 4. Start Dev-Proxy (Port 8989 Cloudtop Gateway)
PROXY_LOG="$LOG_DIR/dev-proxy.log"
PROXY_PID_FILE="$RUN_DIR/dev-proxy.pid"
PROXY_SECRET_FLAG=""
if [ -f "$DATA_DIR/proxy_secret" ]; then
  PROXY_SECRET_FLAG="--proxy-secret-file $DATA_DIR/proxy_secret"
fi

STATIC_UI_DIR=""
if [ -d "$BUNDLE_DIR/ui" ] && [ -f "$BUNDLE_DIR/ui/index.html" ]; then
  STATIC_UI_DIR="$BUNDLE_DIR/ui"
elif [ -d "$DATA_DIR/ui" ] && [ -f "$DATA_DIR/ui/index.html" ]; then
  STATIC_UI_DIR="$DATA_DIR/ui"
elif [ -d "$BIN_DIR/../ui" ] && [ -f "$BIN_DIR/../ui/index.html" ]; then
  STATIC_UI_DIR="$BIN_DIR/../ui"
fi

STATIC_UI_FLAG=""
if [ -n "$STATIC_UI_DIR" ]; then
  STATIC_UI_FLAG="--static-dir $STATIC_UI_DIR"
  echo "[ui] Found pre-built static UI at $STATIC_UI_DIR (no Node.js/Vite needed)"
fi

if [ -f "$PROXY_PID_FILE" ] && kill -0 "$(cat "$PROXY_PID_FILE")" 2>/dev/null; then
  echo "[proxy] Already running (PID $(cat "$PROXY_PID_FILE"))"
else
  echo "[proxy] Starting ham-dev-proxy on 0.0.0.0:8989..."
  nohup "$BIN_DIR/ham-dev-proxy" --listen 0.0.0.0:8989 --hub-url http://127.0.0.1:49322 --vite-url http://127.0.0.1:5173 $PROXY_SECRET_FLAG $STATIC_UI_FLAG > "$PROXY_LOG" 2>&1 &
  PID=$!
  echo $PID > "$PROXY_PID_FILE"
  disown $PID 2>/dev/null || true
fi

# 5. Start Vite Dev Server (Frontend UI) - only if no static UI is available
if [ -n "$STATIC_UI_DIR" ]; then
  echo "[ui] Static UI served directly by dev-proxy; skipping Vite dev server."
else
  VITE_LOG="$LOG_DIR/vite.log"
  VITE_PID_FILE="$RUN_DIR/vite.pid"
  if [ -f "$VITE_PID_FILE" ] && kill -0 "$(cat "$VITE_PID_FILE")" 2>/dev/null; then
    echo "[ui] Vite server already running (PID $(cat "$VITE_PID_FILE"))"
  elif ss -tlpn 2>/dev/null | grep -q ":5173\b"; then
    echo "[ui] Vite server already running on port 5173"
  else
    UI_DIR="$BUNDLE_DIR/ui"
    if [ ! -d "$UI_DIR" ]; then
      if [ -f "$BUNDLE_DIR/../../package.json" ]; then
        UI_DIR="$(cd "$BUNDLE_DIR/../.." && pwd)"
      elif [ -f "$HOME/heimdall-cloudtop/package.json" ]; then
        UI_DIR="$HOME/heimdall-cloudtop"
      elif [ -f "$HOME/heimdall-agent-manager/package.json" ]; then
        UI_DIR="$HOME/heimdall-agent-manager"
      fi
    fi
    if [ -d "$UI_DIR" ] && [ -f "$UI_DIR/package.json" ]; then
      echo "[ui] Starting Vite dev server in $UI_DIR on 127.0.0.1:5173..."
      nohup bash -c "cd '$UI_DIR' && HEIMDALL_DEV_PROXY_URL='http://127.0.0.1:8989' exec npx vite --host 127.0.0.1 --port 5173" > "$VITE_LOG" 2>&1 &
      PID=$!
      echo $PID > "$VITE_PID_FILE"
      disown $PID 2>/dev/null || true
    fi
  fi
fi

# Wait for Dev-Proxy and Vite ports
deadline=$((SECONDS + 10))
while ! curl -s "http://127.0.0.1:8989/api/v1/health" >/dev/null 2>&1; do
  if [ $SECONDS -ge $deadline ]; then
    echo "[proxy] Warning: Dev proxy gateway not yet responding on port 8989. Check $PROXY_LOG"
    break
  fi
  sleep 0.2
done

if [ -z "$STATIC_UI_DIR" ]; then
  deadline=$((SECONDS + 10))
  while ! curl -s "http://127.0.0.1:5173" >/dev/null 2>&1; do
    if [ $SECONDS -ge $deadline ]; then
      echo "[ui] Notice: Vite server is bundling in background. Check $VITE_LOG"
      break
    fi
    sleep 0.2
  done
fi

HOST_FQDN="$(hostname | sed 's/\.c\.googlers\.com$//').c.googlers.com"
echo "=== Heimdall Single-Node Stack is UP ==="
echo "Access points:"
echo "  Cloudtop Gateway: http://127.0.0.1:8989 (or http://${HOST_FQDN}:8989)"
echo "  Hub API:        http://127.0.0.1:49322"
echo "  Bridge Status:  http://127.0.0.1:$BRIDGE_PORT"
if [ -z "$STATIC_UI_DIR" ]; then
  echo "  Vite UI Server: http://127.0.0.1:5173"
else
  echo "  Web UI:         Served directly via Cloudtop Gateway (Zero Node.js dependency)"
fi

if [ "${1:-}" = "--foreground" ] || [ "${1:-}" = "-f" ]; then
  trap 'echo "[supervisor] Shutting down Heimdall services..."; "$BIN_DIR/stop.sh" || true; exit 0' SIGTERM SIGINT SIGHUP
  echo "[supervisor] Running in foreground under systemd. Monitoring daemons..."
  while true; do
    sleep 2
    for pidf in "$HUB_PID_FILE" "$BRIDGE_PID_FILE" "$PROXY_PID_FILE"; do
      if [ -f "$pidf" ] && ! kill -0 "$(cat "$pidf")" 2>/dev/null; then
        echo "[-] Process $(basename "$pidf" .pid) died unexpectedly!"
        exit 1
      fi
    done
  done
fi
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
stop_proc "vite"
stop_proc "dev-proxy"
stop_proc "bridge"
stop_proc "hub"
pkill -f "ham-pty-host.*heimdall-bridge-standalone" 2>/dev/null || true
echo "=== Heimdall Single-Node Stack Stopped ==="
STOPEOF
chmod +x "$BUNDLE_DIR/stop.sh"
chmod +x "$BUNDLE_DIR/stop.sh"

cat << 'READMEEOF' > "$BUNDLE_DIR/README.md"
# Heimdall Agent Manager - Cloudtop Standalone Bundle

This bundle contains self-contained ELF binaries and pre-built static UI assets adapted to run on a Google Cloudtop workstation without requiring Nix, Node.js, or compilation.

## Zero-Dependency Quick Start
1. Run `./start.sh` to launch the stack on Cloudtop:
   - Cloudtop Gateway: `http://127.0.0.1:8989` (or `http://<ldap>.c.googlers.com:8989`)
   - Hub API: `http://127.0.0.1:49322`
   - Static Web UI is served directly via `ham-dev-proxy` (no Node.js or Vite required).
2. Run `./stop.sh` to shut down the stack.

## Systemd User Service with Linger
To run automatically on login / boot with systemd:
```bash
./scripts/install-systemd-service.sh
systemctl --user enable --now heimdall.service
```

## MPM Package Deployment
Alternatively, deploy or update via Google MPM:
```bash
mpm install heimdall/cloudtop live ~/.local/share/heimdall
~/.local/share/heimdall/bin/start.sh
```

## Backups & Snapshots
```bash
./scripts/snapshot-hub.sh export
```
READMEEOF

echo "[bundle] 5. De-Nixifying ELF binaries via patchelf..."
chmod u+w "$BUNDLE_DIR/bin/"*
nix-shell -p patchelf --run "
for bin in '$BUNDLE_DIR'/bin/*; do
  [ -f \"\$bin\" ] || continue
  # Extract any non-standard store dependencies
  for lib in \$(ldd \"\$bin\" 2>/dev/null | grep '/nix/store' | awk '{print \$3}'); do
    if [ -f \"\$lib\" ]; then
      case \"\$lib\" in
        *libc.so*|*libm.so*|*libpthread.so*|*libdl.so*|*ld-linux*)
          ;;
        *)
          cp -n \"\$lib\" '$BUNDLE_DIR/lib/' || true
          ;;
      esac
    fi
  done
  patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 \"\$bin\"
  patchelf --set-rpath '\$ORIGIN/../lib:\$ORIGIN' \"\$bin\"
done
chmod -R u+w '$BUNDLE_DIR/lib/' 2>/dev/null || true
for f in '$BUNDLE_DIR'/lib/libsqlite3.so.*; do
  if [ -f \"\$f\" ] && [ ! -f '$BUNDLE_DIR'/lib/libsqlite3.so ]; then
    ln -s \"\$(basename \"\$f\")\" '$BUNDLE_DIR'/lib/libsqlite3.so
  fi
done
for libfile in '$BUNDLE_DIR'/lib/*.so*; do
  if [ -f \"\$libfile\" ] && [ ! -L \"\$libfile\" ]; then
    patchelf --set-rpath '\$ORIGIN' \"\$libfile\" 2>/dev/null || true
  fi
done
"

echo "[bundle] 5.5. Verifying zero /nix/store references in binaries..."
NIX_REFS=$(ldd "$BUNDLE_DIR/bin/"* 2>/dev/null | grep '/nix/store' || true)
if [ -n "$NIX_REFS" ]; then
  echo "[-] ERROR: Detected lingering /nix/store references in bundled binaries:"
  echo "$NIX_REFS"
  exit 1
fi
echo "[bundle] Zero /nix/store references verified!"

echo "[bundle] 6. Creating archive dist/heimdall-cloudtop-bundle.tar.gz..."
tar -czf "$DIST_DIR/heimdall-cloudtop-bundle.tar.gz" -C "$DIST_DIR" heimdall-cloudtop

echo "[bundle] SUCCESS: Created $DIST_DIR/heimdall-cloudtop-bundle.tar.gz"
ls -lh "$DIST_DIR/heimdall-cloudtop-bundle.tar.gz"
