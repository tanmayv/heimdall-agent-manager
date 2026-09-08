# Heimdall Agent Manager - Cloudtop Zero-Dependency Standalone Deployment

This guide explains how to deploy and operate Heimdall Agent Manager on a Google Cloudtop workstation without requiring Nix, Node.js, npm, or build dependencies.

---

## Deployment Options

You can deploy Heimdall using either **Google MPM** (recommended for Googlers) or a **standalone zero-dependency tarball**.

---

### Option 1: Google MPM (Recommended)

Google MPM packages pre-built, de-Nixified ELF binaries and pre-compiled static UI assets.

#### 1. Install via MPM
```bash
mpm install heimdall/cloudtop live ~/.local/share/heimdall
```

#### 2. Start Heimdall
```bash
~/.local/share/heimdall/bin/start.sh
```

#### 3. Enable Systemd User Service (Background Daemon)
```bash
~/.local/share/heimdall/scripts/install-systemd-service.sh
systemctl --user enable --now heimdall.service
```

#### 4. Publishing MPM Packages (For Maintainers)
```bash
# Build standalone bundle and publish to MPM
./scripts/publish-mpm.sh dev   # Publish to dev branch
./scripts/publish-mpm.sh live  # Publish to live branch
```

---

### Option 2: Standalone Tarball

If you do not want to use MPM, you can build and distribute the standalone tarball.

#### 1. Build the Bundle (on build host with Nix & Node.js)
```bash
./scripts/package-cloudtop-bundle.sh
```
This produces:
- `dist/heimdall-cloudtop/` (Self-contained directory structure)
- `dist/heimdall-cloudtop-bundle.tar.gz` (Portable release archive)

#### 2. Install on Target Cloudtop
Copy `heimdall-cloudtop-bundle.tar.gz` to target workstation and extract:
```bash
mkdir -p ~/.local/share/heimdall
tar -xzf heimdall-cloudtop-bundle.tar.gz -C ~/.local/share/heimdall --strip-components=1
~/.local/share/heimdall/install.sh
```
Or simply run directly from any extracted directory:
```bash
tar -xzf heimdall-cloudtop-bundle.tar.gz
cd heimdall-cloudtop
./start.sh
```

---

## Access Points & Architecture

Once started, Heimdall runs single-node on your Cloudtop:

| Endpoint | URL | Description |
| :--- | :--- | :--- |
| **Cloudtop Gateway** | `http://127.0.0.1:8989` (or `http://<ldap>.c.googlers.com:8989`) | Unified gateway serving Web UI & proxying `/api/v1` to Hub |
| **Hub API** | `http://127.0.0.1:49322` | Core orchestration daemon & SQLite repository |
| **Bridge Status** | `http://127.0.0.1:49323` (or 49325) | Local execution bridge running agents |

### Zero-Dependency Architecture Details
1. **Pre-Built Static UI**:
   - The React/Vite web application is pre-compiled into static assets (`ui/index.html` + `ui/assets/`).
   - `ham-dev-proxy` serves static assets directly via `--static-dir ui` with HTTP caching, correct MIME types, and SPA fallback for client routes.
   - **No Node.js, npm, or running Vite dev server is required on the target machine.**
2. **De-Nixified ELF Binaries**:
   - All ELF binaries (`ham-hub`, `ham-bridge`, `ham-dev-proxy`, `ham-ctl`, `ham-pty-host`) have their ELF interpreter set to the standard Linux dynamic linker `/lib64/ld-linux-x86-64.so.2`.
   - RPATH is set to `$ORIGIN/../lib:$ORIGIN`.
   - Dynamic dependencies like `libsqlite3.so.0` are bundled in `lib/`.
   - **Zero `/nix/store` references remain.**
3. **Automated Pairing**:
   - The local bridge auto-pairs with the local Hub on startup with secure token authentication (`bridge_token_cloudtop`).
4. **Collision Avoidance**:
   - The startup script automatically detects if port 49323 is occupied (e.g. by a remote supervisor bridge) and safely falls back to port 49325 without conflicting.
5. **Systemd & Linger**:
   - Integrates with systemd user session linger (`loginctl enable-linger`) so Heimdall survives SSH disconnections.

---

## Maintenance & Commands

### Control CLI
`ham-ctl` is symlinked to `~/.local/bin/ham-ctl`:
```bash
ham-ctl agents list
ham-ctl task-chain list
ham-ctl bridge list
```

### Stop Service
```bash
~/.local/share/heimdall/bin/stop.sh
# Or via systemd:
systemctl --user stop heimdall.service
```

### Snapshots & Backups
```bash
~/.local/share/heimdall/scripts/snapshot-hub.sh export
```
