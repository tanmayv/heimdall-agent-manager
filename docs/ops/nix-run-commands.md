# Runbook: `nix run .#<app>` commands

Every Heimdall binary is runnable via `nix run .#<app>` from the **local flake**
(`.` = the repo root of `heimdall-hub-rewrite`). This runbook lists each runnable
app, its exact command, key flags, default ports/paths, and caveats.

> **Conventions**
> - `.#` means "the local flake in the current directory" — run these from the
>   repo root, e.g. `cd ~/heimdall-hub-rewrite && nix run .#hub`.
> - To run from **any other directory**, substitute the absolute path to the
>   flake: `nix run ~/heimdall-hub-rewrite#hub`.
> - Pass extra args after `--`, e.g. `nix run .#hub -- --port 9000 --db /tmp/hub.db`.
> - The flake prints `warning: Git tree has uncommitted changes` when the working
>   tree is dirty; this is harmless and the build still proceeds.

---

## Apps at a glance

| App | Binary | Default port / path | CWD-independent? |
|-----|--------|---------------------|------------------|
| `.#hub` | `ham-hub` | `127.0.0.1:8081`, `./hub.db`, bundled migrations | ✅ (wrapper injects `--migrations-dir`) |
| `.#bridge` | `ham-bridge` | `127.0.0.1:49323`, daemon `http://127.0.0.1:49322` | ✅ |
| `.#daemon` (default) | `ham-daemon` | `127.0.0.1:49322` (from `config.toml`) | ✅ (config-driven) |
| `.#dev-proxy` | `ham-dev-proxy` | `127.0.0.1:8080` → hub `http://127.0.0.1:8081` | ✅ |
| `.#wrapper` | `ham-wrapper` | launched by daemon, not normally run directly | n/a |
| `.#ctl` | `ham-ctl` | connects to daemon `http://127.0.0.1:49322` | ✅ |
| `.#test-agent` | `ham-test-agent` | connects to daemon `http://127.0.0.1:49322` | ✅ |
| `.#daemon-with-wrapper` | wrapper script | daemon `127.0.0.1:49322` + same-build wrapper/ctl | ✅ |
| `.#daemon-with-bridge` | wrapper script | daemon `49322` + bridge `49323` | ✅ |

---

## `.#hub` — HTTP hub server

```sh
nix run .#hub                                    # defaults
nix run .#hub -- --port 8090 --db /tmp/hub.db    # custom port + db
```

**What it does:** runs `ham-hub`, the HTTP API + SQLite-backed hub server.

**Flags** (forwarded to `ham-hub`):
- `--listen <host:port>` — bind address (e.g. `0.0.0.0:8081`).
- `--port <n>` — port only (host stays default).
- `--db <path>` — SQLite database path.
- `--migrations-dir <path>` — migrations source dir. **Injected automatically**
  by the `.#hub` wrapper (see caveat below); you normally do not pass this.
- `--trusted-proxy-cidr <cidr>` — trusted-proxy CIDR (repeatable; replaces set).
- `--logout-url <url>` — logout/SSO end-session URL.

**Defaults** (`src/hub/app/config_bind.odin`): `bind_host=127.0.0.1`,
`port=8081`, `database_path=./hub.db`,
`migrations_dir=src/hub/repository/sqlite/migrations` (relative).

> **Caveat — CWD / migrations (now resolved by the wrapper).**
> Historically `ham-hub` defaulted to a *relative* `migrations_dir`, so a bare
> `nix run .#hub` only worked from the repo root. The `.#hub` app is now a
> wrapper that bundles the migrations into the `ham-hub` store output
> (`share/ham-hub/migrations`) and injects the absolute store path via
> `--migrations-dir`. As a result `nix run .#hub` works from **any CWD**, and the
> bundled migrations are applied to the chosen `--db`. If you invoke the
> underlying `ham-hub` binary directly (e.g. from a dev shell) **without**
> `--migrations-dir`, it falls back to embedded SQL, so migrations still run but
> from the *embedded* copy rather than your on-disk SQL — prefer the wrapper.
>
> Also note: the default `--db` is `./hub.db` written to your **current CWD**
> unless overridden, so override `--db` when running outside the repo to avoid
> littering.

---

## `.#bridge` — user-owned bridge

```sh
nix run .#bridge -- --daemon-url http://127.0.0.1:49322 --bridge-token <TOKEN>
```

**What it does:** runs `ham-bridge`, the user-owned Bridge that connects a
daemon/hub to local agents.

**Flags** (`src/bridge/main.odin`): `--config <path>`, `--bind-host 127.0.0.1`,
`--port 49323`, `--daemon-url URL | --hub URL`, `--daemon-id ID`,
`--bridge-token TOKEN`, `--peer-ws ws://host:port/bridge-ws`,
`--peer-auth-token TOKEN`, `--chunk-bytes N`, `--local-endpoint-port PORT`,
`--local-run-dir DIR`, `--agent-command CMD`.

**Defaults:** `bind_host=127.0.0.1`, `port=49323`,
`daemon_url=http://127.0.0.1:49322`.

**Caveats:** a bridge needs a hub/daemon to talk to (start `.#hub` or `.#daemon`
first) and a valid bridge token. See `ham-bridge --help` / usage for enrollment.

---

## `.#daemon` (default app) — agent manager daemon

```sh
nix run .#                                       # default app is the daemon
nix run .#daemon -- --config ./config.toml
nix run .#daemon -- --version
```

**What it does:** runs `ham-daemon`, the daemon that manages agents, wrappers,
task chains, chat, and federation. This is the flake `default` package/app.

**Flags:** `--config <path>` (TOML config), `--version`, `--help`. The daemon is
**config-file driven** (no inline port/db flags); bind host/port, data dir,
wrapper/ctl paths, federation peers, and default agents all come from the TOML.

**Defaults** (from `config.toml`): `bind_host=127.0.0.1`, `port=49322`,
`data_dir=~/.local/share/heimdall`, `wrapper_bin=./result-wrapper/bin/ham-wrapper`.

**Caveats:** expects a config file (`config.toml` in the repo is the sample).
The default `wrapper_bin` points at `./result-wrapper/...`, so for wrapper
support prefer `.#daemon-with-wrapper` (below) which injects a same-build
wrapper path that works from any CWD.

---

## `.#dev-proxy` — trusted-header dev proxy

```sh
nix run .#dev-proxy
nix run .#dev-proxy -- --listen 127.0.0.1:8090 --hub-url http://127.0.0.1:8081
nix run .#dev-proxy -- --print-config
```

**What it does:** runs `ham-dev-proxy`, a local reverse proxy that injects
trusted auth headers (the `X-authentik-*` set) for local hub development without
a real IdP, cycling between preset dev users.

**Flags:** `--listen <host:port>`, `--hub-url <url>`, `--default-user <name>`,
`--print-config`.

**Defaults** (`src/dev_proxy/users.odin`): `listen=127.0.0.1:8080`,
`hub_url=http://127.0.0.1:8081`, `default_user=tanmay`.

**Caveats:** start `.#hub` first; the proxy forwards to `hub_url`. Dev users are
fixed (`tanmay`, `reviewer`).

---

## `.#wrapper` — agent process wrapper

```sh
nix run .#wrapper -- <args>      # rarely invoked directly
```

**What it does:** runs `ham-wrapper`, which launches/manages agent processes
(tmux windows, VCS workspaces). It is normally spawned by the daemon, not by hand.

**Caveats:** carries `tmux`, `git`, and `jujutsu` on PATH (the daemon launches
it with a constrained PATH). Prefer `.#daemon-with-wrapper` to exercise it as
part of a daemon run.

---

## `.#ctl` — ham-ctl CLI

```sh
nix run .#ctl -- inbox
nix run .#ctl -- tasks list
nix run .#ctl -- --daemon-url http://127.0.0.1:49322 agents run <id>
```

**What it does:** runs `ham-ctl`, the operator CLI for the daemon (tasks,
inbox/messages, agents, config).

**Flags:** `--config <path>`, `--daemon-url <url>`. Then a subcommand:
`inbox`, `tasks <...>`, `agents <...>`, etc.

**Defaults:** connects to `http://127.0.0.1:49322` (from config or `--daemon-url`).

**Caveats:** needs a running daemon. `--daemon-url` overrides the config-derived
URL for ad-hoc runs.

---

## `.#test-agent` — test agent

```sh
nix run .#test-agent -- \
  --agent-instance-id <id> --agent-token <token> \
  [--daemon-url http://127.0.0.1:49322] [--targets <id:ms,...>] [--duration-sec N]
```

**What it does:** runs `ham-test-agent`, a throwaway agent that connects to the
daemon and exchanges traffic with target agents (for E2E/race testing).

**Flags** (`src/test_agent/main.odin`): `--agent-instance-id <id>` (required),
`--agent-token <token>` (required), `--daemon-url <url>`, `--targets <id:ms,...>`,
`--duration-sec N`, `--version`, `--help`.

**Defaults:** `daemon_url=http://127.0.0.1:49322`.

**Caveats:** needs a running daemon and a provisioned agent instance + token.

---

## `.#daemon-with-wrapper` — daemon wired to a same-build wrapper + ctl

```sh
nix run .#daemon-with-wrapper -- --config ./config.toml
nix run .#daemon-with-wrapper -- --config ./config.toml --port 9000
```

**What it does:** builds the current `ham-wrapper` and `ham-ctl` alongside the
`ham-daemon`, then launches the daemon with a generated config whose
`[daemon].wrapper_bin` and `[wrapper].ham_ctl_bin` point at those exact
same-build store paths. Stronger than relying on repo `result-wrapper` symlinks
because it works from any CWD and cannot use a stale wrapper/ctl.

**Flags:** `--config <path>` (base config; optional — defaults to
`$XDG_CONFIG_HOME/heimdall/config.toml` or `~/.config/heimdall/config.toml`),
plus any extra daemon args forwarded after.

**Behavior:** if `--config` is given (or found at the default XDG path), the
script rewrites `wrapper_bin`/`ham_ctl_bin` into a temp config and runs the
daemon with it; otherwise it runs the daemon with forwarded args only. The
script also refreshes `./result-wrapper` and `./result-ctl` symlinks for
tools/tests that read them directly.

**Caveats:** intended for local full-stack runs. Extra args after `--` are
forwarded to `ham-daemon`.

---

## `.#daemon-with-bridge` — daemon + local bridge, wired together

```sh
nix run .#daemon-with-bridge -- --config ./config.toml
HAM_BRIDGE_PORT=5050 HAM_BRIDGE_TOKEN=<tok> nix run .#daemon-with-bridge -- --config ./config.toml
nix run .#daemon-with-bridge -- --config ./config.toml --bridge-port 5050 --bridge-token <tok>
```

**What it does:** launches `ham-daemon` together with a local `ham-bridge` on
`127.0.0.1:$BRIDGE_PORT`, generating a config that points the daemon at the
bridge (and vice-versa).

**Flags / env:** `--config <path>`, `--bridge-port <n>`,
`--bridge-token <token>`. Env overrides: `HAM_BRIDGE_PORT` (default `49323`),
`HAM_BRIDGE_TOKEN` (default `br_loopback_dev_token`).

**Defaults:** daemon `49322`, bridge `127.0.0.1:49323`,
`BRIDGE_URL=http://127.0.0.1:$BRIDGE_PORT`.

**Caveats:** like `daemon-with-wrapper`, it rewrites a base config into a temp
file (replacing the bridge-related fields) and runs both processes. Intended for
local full-stack runs with bridge support.

---

## UI apps (out of scope here, documented for completeness)

The flake also exposes UI/Electron apps not covered by this runbook (which is
scoped to the Odin backend binaries): `.#heimdall`, `.#heimdall-browser`, and
`.#ham-ui-server`. These build/run the web/Electron frontend and have their own
dev-workflow docs under `docs/ops/ui-dev-run-order.md`.

---

## Verifying the build

```sh
nix build .#ham-hub                                      # build the hub package
find $(nix build .#ham-hub --no-link --print-out-paths) -path '*migrations*'
# -> .../share/ham-hub/migrations/{001_foundation.sql,002_owner_scoped_core.sql}
```

The bundled-migrations check above is the regression guard for the
CWD-independent `.#hub` wrapper.
