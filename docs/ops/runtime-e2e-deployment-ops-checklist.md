# Runtime E2E deployment / ops checklist

Runnable ops checklist for the smallest Hub → Bridge → wrapper → real agent
slice. Satisfies **RTE2E-2**. Fill in the placeholders during the final E2E
smoke task (task 8R / `task-19f8f183ca8`) and record the values there.

> All commands are illustrative. Replace `<…>` with real values for your
> environment. Nothing here requires Hub credentials on the Bridge host's
> wrapper or agent-mode `ham-ctl`; only the Bridge process holds Hub creds
> (RTE2E-9 preservation).

## 1. VPS Hub

### 1.1 Build / ship the Hub binary

```bash
nix build .#ham-hub -o /tmp/ham-hub
# copy /tmp/ham-hub/bin/ham-hub to the VPS, e.g. /opt/heimdall/bin/ham-hub
```

### 1.2 TLS termination

The Hub itself serves plain HTTP on its bind port (config: `--listen`, `--port`).
Terminate TLS in front of it with a reverse proxy (nginx/Caddy/traefik).

- **Recommended:** Caddy with automatic TLS, fronting `hub.<your-domain>`.
- Cert for `hub.<your-domain>` → proxy to `127.0.0.1:<hub-port>`.
- If you front with nginx, terminate TLS and reverse-proxy `http://127.0.0.1:<hub-port>`.

> Record in 8R: TLS terminator used (Caddy/nginx/…), cert source (Let's
> Encrypt / manual), hostname `hub.<your-domain>`.

### 1.3 Trusted proxy / trusted-header CIDR

The Hub derives the client IP from `req.remote_addr` directly. When behind a
reverse proxy, configure the proxy CIDR so the Hub trusts forwarded headers only
from the proxy:

```bash
ham-hub --listen 127.0.0.1:<hub-port> \
        --db /var/lib/heimdall/hub.db \
        --trusted-proxy-cidr 127.0.0.1/32 \
        --migrations-dir <path-to-migrations>
```

- Use the **loopback** CIDR (`127.0.0.1/32`) when the proxy is on the same host.
- Use the proxy host's real CIDR (e.g. `10.0.0.5/32`) when the proxy is remote.
- Do **not** set a broad CIDR (e.g. `0.0.0.0/0`) — that would allow header spoofing.

> Record in 8R: trusted-proxy mode (`--trusted-proxy-cidr <value>`) and whether
> the proxy is loopback or remote.

### 1.4 SQLite volume / WAL / backup / restore

The Hub uses a single SQLite file (`--db <path>`). Foreign keys are enabled
(`PRAGMA foreign_keys = ON`). For the E2E slice:

- Put the DB on a **persistent volume** (e.g. `/var/lib/heimdall/hub.db`), not
  `/tmp` or a container ephemeral layer.
- The connection enables `foreign_keys`; for heavy concurrency you may also set
  WAL mode per-deployment. Since the runtime code does not force WAL, set it as
  an operational hardening step:

  ```bash
  sqlite3 /var/lib/heimdall/hub.db "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"
  ```

- **Backup (online, safe under WAL):**

  ```bash
  sqlite3 /var/lib/heimdall/hub.db ".backup '/var/lib/heimdall/backup/hub-$(date +%F).db'"
  ```

- **Restore:** stop the Hub, replace the DB file with the backup, restart. WAL
  files (`hub.db-wal`, `hub.db-shm`) are recreated automatically.

> Record in 8R: DB path, WAL enabled (y/n), backup command used, restore test
> result.

## 2. Operator user API token (RTE2E-1)

Issue a user token **locally on the Hub host** (no HTTP issuance API by design —
arch §6.3.1). The plaintext is shown once; only the hash is stored.

```bash
ham-hub tokens issue --user <user_id> [--label "ops laptop"] [--expires-in 90d]
# prints the plaintext token once:  hut_<...>
ham-hub tokens list   --user <user_id>      # metadata only, never plaintext
ham-hub tokens revoke --token-id <token_id>
```

Keep `hut_<…>` only where you drive `ham-ctl hub …` (operator/user side). It is
the `Authorization: Bearer hut_<…>` credential for user mode (RTE2E-6); it is
**never** placed in query/body/URL.

> Record in 8R: token label, expiry, token-id (not the plaintext).

## 3. Local Bridge connectivity to the Hub

A Bridge only initiates outbound HTTP/WebSocket to its `hub_url`. Two supported
connectivity modes (runtime protocol §3.3):

### 3.1 Direct (Bridge host can reach the Hub)

```bash
ham-bridge enroll --hub https://hub.<your-domain> --enrollment-token <hbe_once>
```

### 3.2 SSH-tunneled (Bridge host cannot reach the Hub directly)

Bridge → Hub (forward from the Bridge/internal host to the VPS):

```bash
# on the internal/Bridge host
ssh -N -L 127.0.0.1:18080:127.0.0.1:<hub-port> user@vps.example.com
ham-bridge enroll --hub http://127.0.0.1:18080 --enrollment-token <hbe_once>
```

Laptop → internal host reverse forward (when the internal host can't dial out):

```bash
# on the laptop
ssh -N -R 127.0.0.1:18080:hub.<your-domain>:443 user@internal-machine
# on the internal/Bridge host
ham-bridge enroll --hub http://127.0.0.1:18080 --enrollment-token <hbe_once>
```

Notes (§3.3):
- WebSocket upgrades work transparently over the SSH TCP tunnel.
- Do not special-case tunnels in Hub auth — Bridge bearer tokens + assigned-instance
  checks still apply.
- If HTTPS-through-localhost, hostname validation may fail; either use HTTP
  inside the tunnel or preserve the Hub hostname via local DNS/hosts mapping and
  tunnel the matching port.

> Record in 8R: connectivity mode (`direct` | `ssh-forward` | `ssh-reverse`),
> the exact `hub_url` the Bridge enrolled with, tunnel command.

### 3.3 Bridge run command (post-enroll)

```bash
ham-bridge --hub https://hub.<your-domain> \
           --bridge-token <hbt_...> \
           --bind-host 127.0.0.1 --port 49323 \
           --local-endpoint-port 49324 --local-run-dir /var/lib/heimdall/bridge \
           [--agent-command "<provider launch command>"]
```

The local endpoint (RTE2E-3) binds a Unix-domain socket 0600 primary
(`/var/lib/heimdall/bridge/bridge.sock`) plus a loopback TCP fallback on
`--local-endpoint-port`. The wrapper and agent-mode `ham-ctl` connect to this
endpoint via `HEIMDALL_BRIDGE_ENDPOINT`.

## 4. Provider / profile prerequisites (on the Bridge host)

The Bridge's `launch_agent` launches `ham-bridge wrapper-supervisor`, which runs
the configured `--agent-command`. Prerequisites on the Bridge host:

- At least one known-good provider CLI installed and authenticated, e.g.:
  - `pi` (this coding agent) with a working profile, **or**
  - whichever provider the launched agent template targets.
- The provider's credentials live **only on the Bridge host's environment**;
  they are never passed into the wrapper/agent child env beyond the sanitized
  allowlist (PATH, HOME, USER, … + `HEIMDALL_BRIDGE_ENDPOINT`,
  `HEIMDALL_AGENT_TOKEN`, `HEIMDALL_AGENT_INSTANCE_ID`).
- Confirm the agent command works standalone before wiring it as
  `--agent-command`, e.g. `pi --version` and a one-shot prompt.

> Record in 8R: selected provider/profile/tier, the `--agent-command` used, and
> confirmation the provider CLI is authenticated on the Bridge host.

## 5. Smoke order (filled during task 8R)

1. Hub up + reachable (TLS, trusted-proxy CIDR set).
2. `ham-hub tokens issue --user <user_id>` → `hut_<…>`.
3. User-mode check: `ham-ctl hub --hub-url https://hub.<your-domain> --user-token hut_<…> me`.
4. Bridge enrolled + running (direct or SSH tunnel); local endpoint up.
5. `ham-ctl hub launch --agent-id <agent> --bridge-id <bridge>` → instance.
6. Agent boots, wrapper reports startup; Hub runtime status flips to `running`.
7. `ham-ctl hub chats create …` + `chats send …`; agent replies via
   `ham-ctl agent chat send --body …` through the local endpoint.
8. Agent creates/comments/completes one task via `ham-ctl agent tasks …`.
9. `ham-ctl hub task-chains show …` reflects the completed task.
10. Stop/restart the instance; Hub runtime status reflects real state.

## RTE2E-9 preservation note

This checklist is documentation only. It does not modify any code, and old
current-daemon `src/wrapper` / `src/ctl` behavior is untouched. The Bridge and
agent-mode `ham-ctl` paths described here are the new rewrite code only.
