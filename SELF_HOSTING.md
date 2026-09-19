# Heimdall Self-Hosting Guide

Heimdall is a hub-and-bridge system. The hub (daemon + web UI) runs on one central
device and stores all durable state. A bridge runs on each device where AI agent
processes (Claude Code, Codex, etc.) actually execute. The two sides communicate over
HTTPS, so they can live on different machines, networks, and operating systems.

---

## Part 1 — Hub and UI (one device, internet/VPN-accessible)

The hub is the central control plane. It exposes a REST/WebSocket API that bridges,
the web UI, and `ham-ctl` all connect to. It only needs to run on one machine.

### 1.1 What the hub needs

| Component | Purpose |
|-----------|---------|
| `ham-hub` | Odin binary — HTTP/WS server, task/memory/agent state, SQLite persistence |
| `ham-ctl` | CLI for humans and agents |
| Web UI / Electron app | React + Vite dashboard (optional for server-only setups) |
| A TLS terminator | nginx, Caddy, or Tailscale — exposes hub to internet or VPN |

### 1.2 Build dependencies

**Nix (recommended — all dependencies are pinned)**

```bash
# Install Nix with flakes support
curl -L https://nixos.org/nix/install | sh
# Enable flakes (add to ~/.config/nix/nix.conf or /etc/nix/nix.conf)
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

**Manual build dependencies (if not using Nix)**

| Dependency | Version | Purpose |
|------------|---------|---------|
| Odin compiler | ≥ 2024-11 (LLVM 18/21) | Compiles hub, bridge, ctl |
| SQLite 3 | ≥ 3.40 | Hub database (linked at build time) |
| Node.js | ≥ 20 | Builds the web UI |
| npm | ≥ 10 | UI dependency management |
| Electron | from npm | Desktop app wrapper |

### 1.3 Building

**With Nix (recommended)**

```bash
git clone https://github.com/tanmayv/heimdall-agent-manager
cd heimdall-agent-manager

# Build hub binary
nix build .#ham-hub

# Build CLI
nix build .#ham-ctl

# Build web UI (for browser access)
nix build .#heimdall

# Run the hub directly (wraps ham-hub with correct --migrations-dir)
nix run .#hub -- --db /var/lib/heimdall/hub.db --port 8081
```

**Manual build**

```bash
# Clone the repo
git clone https://github.com/tanmayv/heimdall-agent-manager
cd heimdall-agent-manager

# Build hub
odin build src/hub -collection:odin_test=src -out:./bin/ham-hub

# Build CLI
odin build src/ctl -collection:odin_test=src -out:./bin/ham-ctl

# Build UI (outputs to dist/)
npm install --legacy-peer-deps
npm run build
```

### 1.4 Running the hub

```bash
# Create data directory
mkdir -p /var/lib/heimdall

# Start the hub (replace /path/to/ with your actual paths)
ham-hub \
  --db /var/lib/heimdall/hub.db \
  --migrations-dir /path/to/share/ham-hub/migrations \
  --port 8081 \
  --host 127.0.0.1
```

The hub binds to `127.0.0.1` by default. Put nginx/Caddy in front to expose it over
HTTPS. The web UI is served as a static bundle and can be served by the same reverse proxy.

### 1.5 Systemd service (Linux hub)

Create `/etc/systemd/system/heimdall-hub.service`:

```ini
[Unit]
Description=Heimdall Hub
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=heimdall
Group=heimdall
ExecStart=/usr/local/bin/ham-hub \
    --db /var/lib/heimdall/hub.db \
    --migrations-dir /usr/local/share/ham-hub/migrations \
    --port 8081 \
    --host 127.0.0.1
Restart=on-failure
RestartSec=5s
StateDirectory=heimdall
WorkingDirectory=/var/lib/heimdall

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now heimdall-hub
```

### 1.6 NixOS module (hub + nginx)

In `nix-homelab-config` or any NixOS flake:

```nix
{
  inputs.heimdall.url = "github:tanmayv/heimdall-agent-manager";

  nixosConfigurations.myhub = nixpkgs.lib.nixosSystem {
    modules = [
      {
        environment.systemPackages = [
          inputs.heimdall.packages.x86_64-linux.ham-hub
          inputs.heimdall.packages.x86_64-linux.ham-ctl
        ];

        systemd.services.heimdall-hub = {
          description = "Heimdall Hub";
          after = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = ''
              ${inputs.heimdall.packages.x86_64-linux.ham-hub}/bin/ham-hub \
                --db /var/lib/heimdall/hub.db \
                --migrations-dir ${inputs.heimdall.packages.x86_64-linux.ham-hub}/share/ham-hub/migrations \
                --port 8081 --host 127.0.0.1
            '';
            Restart = "on-failure";
            StateDirectory = "heimdall";
            DynamicUser = true;
          };
        };

        # Serve hub API + web UI via nginx
        services.nginx.virtualHosts."hub.example.com" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://127.0.0.1:8081";
            proxyWebsockets = true;
          };
        };
      }
    ];
  };
}
```

### 1.7 Single-user / VPN setup with dev-proxy (no TLS cert required)

> **When to use this:** You are the only user, the hub is reachable only through a
> private VPN (Tailscale, WireGuard, etc.) or a local network, and you do not want to
> manage TLS certificates. If the hub is publicly accessible on the internet, **do not
> use this approach** — use a real TLS terminator (nginx + ACME, Caddy, or Tailscale
> HTTPS) so that credentials and agent traffic are encrypted in transit.

For a personal, VPN-only deployment you can skip the reverse proxy entirely and use
a simple dev-proxy (e.g. `caddy reverse-proxy` in plain HTTP mode, or a one-liner
`socat`/`nginx` forward) that just routes plain HTTP to the hub. The hub itself
already handles all authentication; the only risk you are accepting is that traffic
on the VPN is unencrypted — acceptable when the VPN itself provides the transport
security.

**Option A — Caddy as a plain HTTP proxy (no certificates)**

```bash
# Install Caddy, then create /etc/caddy/Caddyfile:
:80 {
    reverse_proxy 127.0.0.1:8081
}
```

```bash
sudo systemctl enable --now caddy
```

Bridges and the web UI connect to `http://<vpn-ip>` (port 80). No certificate
management needed.

**Option B — socat one-liner (quick test / no daemon)**

```bash
# Forward public VPN port 8080 → hub on 127.0.0.1:8081
socat TCP-LISTEN:8080,fork,reuseaddr TCP:127.0.0.1:8081
```

Bridges connect to `http://<vpn-ip>:8080`. This is a foreground process; wrap it in
a systemd unit or `tmux` session if you want it to persist.

**Option C — nginx plain HTTP proxy**

```nginx
# /etc/nginx/sites-available/heimdall
server {
    listen 80;
    server_name _;   # or your VPN hostname

    location / {
        proxy_pass         http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host $host;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/heimdall /etc/nginx/sites-enabled/
sudo systemctl reload nginx
```

**Configuring bridges to use a plain HTTP hub**

When the hub is served over plain HTTP, pass the `http://` URL to `ham-bridge enroll`
and to the bridge service:

```bash
ham-bridge enroll \
  --hub http://<vpn-ip> \
  --enrollment-token hbe_... \
  --bridge-token-file ~/.config/heimdall/bridge-token
```

The `--hub` flag in the systemd/launchd service should match (e.g.
`http://100.x.x.x` for a Tailscale IP).

---

## Part 2 — Bridge (one per agent-running device)

The bridge runs on every machine where AI agent processes execute — your laptop,
workstation, desktop, any server that spawns Claude Code / Codex sessions. It
connects outbound to the hub and never needs to be publicly reachable itself.

### 2.1 What the bridge needs

| Component | Purpose |
|-----------|---------|
| `ham-bridge` | Odin binary — agent supervisor, shell job executor, fs explorer |
| `ham-pty-host` | Rust binary — spawns agent CLIs in real PTYs (replaces tmux wrapper) |
| `ham-ctl` | CLI used by agents to read/send messages, update tasks, etc. |
| `socat` | TLS transport for bridge → hub connection (default backend) |
| `openssl` | Fallback TLS transport and socat's OpenSSL engine |
| The agent CLI | `claude`, `codex`, or any other supported CLI |

### 2.2 Build dependencies

**Nix (recommended)**

Same Nix setup as the hub. The bridge and pty-host are built from the same flake.

**Manual build dependencies**

| Dependency | Version | Purpose |
|------------|---------|---------|
| Odin compiler | ≥ 2024-11 (LLVM 18/21) | Compiles bridge, ctl |
| Rust toolchain | stable (≥ 1.77) | Compiles ham-pty-host |
| cargo | (with Rust) | Rust build tool |
| socat | ≥ 1.7 | Bridge → hub TLS tunnel |
| openssl / libssl | ≥ 1.1 | TLS; socat OpenSSL engine |

### 2.3 Building

**With Nix**

```bash
# Build bridge binary (bundles socat + openssl on PATH via wrapProgram)
nix build .#ham-bridge

# Build pty-host (Rust — hermetic crane build)
nix build .#ham-pty-host

# Build CLI
nix build .#ham-ctl

# Or run the bridge directly (sets all required env vars automatically)
nix run .#bridge -- --hub https://hub.example.com --bridge-token-file ~/.config/heimdall/bridge-token
```

**Manual build**

```bash
# Bridge (Odin)
odin build src/bridge -collection:odin_test=src -out:./bin/ham-bridge

# CLI (Odin)
odin build src/ctl -collection:odin_test=src -out:./bin/ham-ctl

# pty-host (Rust — must be in tools/pty_host/)
cd tools/pty_host && cargo build --release
cp target/release/ham-pty-host ~/bin/ham-pty-host
```

### 2.4 First-time enrollment

The hub uses a one-time enrollment token to issue a durable bridge token (`hbr_…`).
**Enrollment must be completed before the bridge can connect** — the bridge will refuse
to start (or will immediately exit) if it has no valid token file. Once enrollment is
done, you simply start (or restart) the bridge normally using the same token file; no
re-enrollment is ever needed unless the token is lost or explicitly revoked.

> **Order matters:** run `ham-bridge enroll` first, then start `ham-bridge`. You cannot
> enroll through a running bridge instance — enrollment is a one-shot CLI command that
> writes the token file and then exits.

**Step 1 — Generate an enrollment token on the hub**

```bash
# On the hub machine (or via ham-ctl pointing at hub):
ham-ctl bridge enroll-token --new
# → prints a one-time token like: hbe_...  (copy it — it is shown only once)
```

**Step 2 — Enroll the bridge on the device**

```bash
# On the device that will run the bridge:
mkdir -p ~/.config/heimdall

ham-bridge enroll \
  --hub https://hub.example.com \
  --enrollment-token hbe_... \
  --bridge-token-file ~/.config/heimdall/bridge-token
# → Contacts the hub, exchanges the enrollment token for a durable hbr_ token,
#   and writes it to ~/.config/heimdall/bridge-token (mode 0600).
#   The command exits when enrollment is complete.
```

**Step 3 — Start (or restart) the bridge normally**

After enrollment the bridge is started exactly the same way every time — just point it
at the token file. No enrollment flags are needed again.

```bash
ham-bridge \
  --hub https://hub.example.com \
  --bridge-token-file ~/.config/heimdall/bridge-token \
  --port 49323

# Or, if you set up the systemd/launchd service (sections 2.7–2.8):
systemctl --user restart heimdall-bridge   # Linux
launchctl kickstart -k gui/$(id -u)/works.earendil.heimdall-bridge  # macOS
```

The bridge reads the token file on every start and reconnects to the hub automatically.
You never need to touch the hub again for this device unless you deliberately revoke
the token.

### 2.5 Bridge token file

The token file is a plain text file containing a single `hbr_…` token:

```
hbr_18abc...
```

- Keep it at mode `0600` (`chmod 600 ~/.config/heimdall/bridge-token`).
- The path is passed to `ham-bridge` via `--bridge-token-file`.
- Losing it requires re-enrollment (Step 1–2 above).
- To revoke a bridge, delete the token record on the hub:
  `ham-ctl bridge revoke --bridge-id <id>`.

### 2.6 Required environment variables

The bridge needs these env vars set (or passed via `nix run .#bridge` which sets them
automatically):

```bash
# Path to ham-pty-host binary
export HEIMDALL_HAM_PTY_HOST_BIN=/usr/local/bin/ham-pty-host

# Enable pty-host agent runtime (recommended; set false to fall back to tmux)
export HEIMDALL_BRIDGE_PTY_HOST=true

# Path to ham-ctl binary (agents call this to communicate with hub)
export HEIMDALL_HAM_CTL_BIN=/usr/local/bin/ham-ctl
```

### 2.7 Systemd user service (Linux bridge)

Create `~/.config/systemd/user/heimdall-bridge.service`:

```ini
[Unit]
Description=Heimdall Bridge
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ham-bridge \
    --hub https://hub.example.com \
    --bridge-token-file %h/.config/heimdall/bridge-token \
    --port 49323 \
    --local-endpoint-port 49324 \
    --local-run-dir /tmp/heimdall-bridge-local
Environment=HEIMDALL_HAM_PTY_HOST_BIN=/usr/local/bin/ham-pty-host
Environment=HEIMDALL_BRIDGE_PTY_HOST=true
Environment=HEIMDALL_HAM_CTL_BIN=/usr/local/bin/ham-ctl
Restart=on-failure
RestartSec=5s
KillMode=process

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now heimdall-bridge
# Check status
systemctl --user status heimdall-bridge
journalctl --user -u heimdall-bridge -f
```

### 2.8 launchd agent (macOS bridge)

Create `~/Library/LaunchAgents/works.earendil.heimdall-bridge.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>works.earendil.heimdall-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/ham-bridge</string>
    <string>--hub</string>
    <string>https://hub.example.com</string>
    <string>--bridge-token-file</string>
    <string>/Users/you/.config/heimdall/bridge-token</string>
    <string>--port</string>
    <string>49323</string>
    <string>--local-endpoint-port</string>
    <string>49324</string>
    <string>--local-run-dir</string>
    <string>/tmp/heimdall-bridge-local</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HEIMDALL_HAM_PTY_HOST_BIN</key>
    <string>/usr/local/bin/ham-pty-host</string>
    <key>HEIMDALL_BRIDGE_PTY_HOST</key>
    <string>true</string>
    <key>HEIMDALL_HAM_CTL_BIN</key>
    <string>/usr/local/bin/ham-ctl</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>Crashed</key>
    <true/>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/heimdall-logs/heimdall-bridge.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/heimdall-logs/heimdall-bridge.err.log</string>
</dict>
</plist>
```

```bash
mkdir -p /tmp/heimdall-logs
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/works.earendil.heimdall-bridge.plist
launchctl kickstart -k gui/$(id -u)/works.earendil.heimdall-bridge
# Check status
launchctl print gui/$(id -u)/works.earendil.heimdall-bridge
tail -f /tmp/heimdall-logs/heimdall-bridge.err.log
```

### 2.9 Home Manager module (NixOS / nix-darwin bridge)

The flake ships a Home Manager module for declarative bridge setup:

```nix
{
  inputs.heimdall.url = "github:tanmayv/heimdall-agent-manager";

  homeConfigurations.you = home-manager.lib.homeManagerConfiguration {
    modules = [
      inputs.heimdall.homeModules.default
      {
        programs.heimdall = {
          enable = true;
          packageNames = [ "bridge" "ctl" "pty-host" ];

          bridge = {
            enable = true;
            hubUrl = "https://hub.example.com";
            # Path to the enrolled hbr_ token written by `ham-bridge enroll`
            tokenFile = "/home/you/.config/heimdall/bridge-token";
            port = 49323;
          };

          ctl.daemonUrl = "http://127.0.0.1:49323";
        };
      }
    ];
  };
}
```

After `home-manager switch`, a systemd user service (Linux) or launchd agent (macOS)
named `heimdall-bridge` is created and started automatically.

---

## Quick-start checklist

### Hub (once)
- [ ] Build or install `ham-hub`, `ham-ctl`
- [ ] Create a data directory and run `ham-hub --db … --migrations-dir …`
- [ ] Put a TLS-terminating reverse proxy in front (nginx/Caddy/Tailscale)
- [ ] Confirm the API is reachable: `curl https://hub.example.com/api/v1/health`

### Each bridge device (once per device)
- [ ] Build or install `ham-bridge`, `ham-pty-host`, `ham-ctl`
- [ ] Install runtime dependencies: `socat`, `openssl`
- [ ] Generate an enrollment token on the hub: `ham-ctl bridge enroll-token --new`
- [ ] Enroll: `ham-bridge enroll --hub … --enrollment-token … --bridge-token-file ~/.config/heimdall/bridge-token`
- [ ] Set `HEIMDALL_HAM_PTY_HOST_BIN`, `HEIMDALL_BRIDGE_PTY_HOST=true`, `HEIMDALL_HAM_CTL_BIN`
- [ ] Start the bridge service (systemd user service or launchd agent)
- [ ] Confirm the bridge appears in the hub UI or via `ham-ctl bridge list`

### Subsequent runs
The bridge reads `--bridge-token-file` on startup and reconnects automatically.
Re-enrollment is only needed if the token file is lost or the bridge is revoked.
