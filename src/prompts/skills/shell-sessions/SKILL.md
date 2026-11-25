---
name: shell-sessions
description: Run, background, serve, read logs of and stop commands on the Bridge host with `ham-ctl shell`. Load before running any command that could take more than a moment, before `--bg`, `serve`, `log`, `kill` or `set-port`, or when a run misbehaves.
---

# Shell sessions (`ham-ctl shell`)

Use `ham-ctl shell` for any command that could take more than a moment, or when in doubt. Direct shell execution (Bash tool, os.execute, subprocess) is reserved ONLY for trivially fast read-only one-liners (a single grep, `wc -l`).

## The three kinds
The verb decides which you get; the hub enforces it. The retired spellings `interactive`, `command` and `agent` are REJECTED, not aliased. `shell run` is the only way an agent runs a command.

- **`run`**: one-shot command, output captured. **AGENT ONLY**, and the kind you want almost every time. **FOREGROUND by default: it BLOCKS until the command exits and prints the output inline.** No notification is sent (you already hold the result). **A run is NEVER moved to the background on its own, however long it takes.** Capped at 30 minutes.
- **`server`**: long-running process with captured output and an OPTIONAL port. Started by an agent or a user. Returns as soon as it is up. NOT subject to the 30-minute cap: use `serve` for anything expected to outlive that.
- **`shell`**: interactive terminal. **USER ONLY**; not available to you; no output capture.

## Commands
```bash
# Run a command and WAIT for it. Output is printed inline when it finishes.
ham-ctl shell run --cmd 'odin build src/bridge' --cwd ~/heimdall-agent-manager [--label <lbl>]

# Background it explicitly: returns a session id AT ONCE; you are notified on completion.
ham-ctl shell run --cmd 'long-running-thing' --bg

# Start a long-running process. --port is OPTIONAL; with one it becomes reachable.
ham-ctl shell serve --cmd 'npm run dev' --port 5173 [--cwd <dir>] [--label <lbl>]

# Read output (paged, filtered). Never poll this in a loop.
ham-ctl shell log <session_id> [--offset N] [--limit N] [--grep <pattern>]

# Stop a session; convert a live foreground run to background (one-way).
ham-ctl shell kill <session_id>
ham-ctl shell background <session_id>
```

## Rules
- A foreground `run` blocks and does NOT notify; a `--bg` run returns immediately and DOES notify on completion (only backgrounded runs notify). Nothing in between happens automatically.
- Ctrl-C does not stop a run. It keeps going; reach it with `shell log <id>` and `shell kill <id>`.
- `shell background <id>` releases whoever is waiting on the run and notifies on completion from then on. It is one-way.
- Two live sessions cannot hold the same port on one bridge; the second is refused and names the holder. A portless server is valid and simply exposes nothing.
- `shell log` returns `{lines, truncated, total_lines}`. `--offset` skips lines from the HEAD of the log and `--limit` caps how many come back; there is no tail mode, so "the end of the log" is an explicit offset. Read output with `log` rather than polling.
- Bridge, agent, conversation and project come from your own context; the conversation cannot be overridden.
- **`--cwd`**: if omitted, the command inherits the bridge service's working directory (typically `$HOME`), **NOT** the project directory. For build and test commands pass `--cwd <project-dir>` or prefix `cd <project-dir> &&`. `--cwd` may start with `~`. A `--cwd` that does not exist or is not a directory is REJECTED before the command runs and the error names the path; it is never silently replaced.

## Other verbs
- `shell start --bridge <id> [--kind run|shell|server] [--cmd <cmd>] [--cwd <dir>] [--label <lbl>] [--port <n>] [--project <id>] [--chain <id>]`: launch a session explicitly; returns `{session_id, status, pid}`. Scope is per kind: `server` needs `--chain`, `run` needs `--agent`, `shell` needs neither. `--port` declares the port the process binds and is what makes a session reachable over HTTP, whatever its kind.
- `shell list [--bridge <id>] [--project <id>] [--chain <id>] [--agent <id>] [--status <s>] [--limit N] [--cursor <c>]`: no flag is required. With none it lists every session you own across every bridge, paginated; filters are AND-ed. `--agent <agent_instance_id>` is how you list `run` sessions (a run is agent scoped, so bridge- and chain-narrowed listings omit it). `--status` takes a concrete status or the groups `live` | `finished`. Prints `preview_url` when a port is declared (`src/ctl/shell_cmds.odin` `ctl_shell_list`, `print_help_shell`). `shell show <session_id>` shows one session and its Preview URL.
- `shell capture <session_id>`: snapshot of the current terminal screen.
- `shell signal <session_id> --signal <int>`: send a POSIX signal (2 = SIGINT).
- `shell restart <session_id>`: stop then start; returns `{session_id, pid, status}`.
- `shell set-port <session_id> --port <n> | --clear`: declare (or clear) the port of a session that is ALREADY running (for example you opened an interactive terminal, then started a server in it). Effective immediately on both access paths (the preview and the Bridge-local proxy), with no restart. `--port 0` and `--clear` are the same. Refused with 409 on a session that has exited, 404 on one you do not own. Returns the updated session.

## What the user sees
A session shows two surfaces, both live: **stdout** (any session, no port needed; the user sees it in the session pane, you read the same stream with `shell log`) and, for a session with a declared port, a **preview** in the browser, tunnelled so no inbound port is opened. To hand the user a web UI, follow `heimdall-preview-setup`.

## Calling a server session from this host
A `server` session with a declared port is reachable through the Bridge's local endpoint, with no inbound port, no user token and no browser session:
```
http://127.0.0.1:<local_endpoint_port>/proxy/<session_id>/<path>
```
The Bridge relays over its Hub WebSocket to the Bridge that owns the session, which dials `127.0.0.1:<declared port>`; method, path, query string and body are forwarded. Find the local endpoint port (TCP fallback, default `49324`) with `bridge list --scope configured` → `{"local_endpoint_port": 49324}`; the unix socket path is in `$HEIMDALL_BRIDGE_ENDPOINT` (`unix:/path/to/bridge.sock`).

```bash
ham-ctl shell start --bridge brg_abc --kind server --port 8000 \
  --cwd /srv/site --cmd 'python3 -m http.server 8000 --bind 127.0.0.1'   # -> {"session_id":"sh_123",...}
curl http://127.0.0.1:49324/proxy/sh_123/index.html                      # over TCP
ham-ctl shell set-port sh_456 --port 3000 && curl http://127.0.0.1:49324/proxy/sh_456/   # port declared later
curl --unix-socket "${HEIMDALL_BRIDGE_ENDPOINT#unix:}" http://localhost/proxy/sh_123/index.html   # unix socket
```
The target must be `status=running`, have a declared port and be owned by you; any session kind qualifies. Request bodies up to **64 MiB** (67,108,864 bytes) are streamed with bounded memory and must carry `Content-Length`; responses have no size limit. Throughput is far below a direct connection (tens of MB take tens of seconds), so compress large payloads. Refusals are JSON `{"error":"<reason>"}`:

| status | reason | meaning |
| --- | --- | --- |
| 404 | `session_not_found` | no such session, or it is not yours |
| 409 | `session_not_running` | session has exited |
| 409 | `no_server_port` | no port declared: use `shell set-port` |
| 403 | `cross_owner` | belongs to another user |
| 503 | `unavailable` | Bridge cannot reach the Hub |
| 413 | `request_body_too_large` | `Content-Length` over 64 MiB (refused at once, before anything reaches the Hub) |
| 411 | `request_body_chunked` | chunked request body (also refused before anything reaches the Hub); send `Content-Length` instead |
| 504 | `upload_stalled` | the Bridge lost its Hub connection mid-upload (nothing drained for 30 s) |

Any process on this host that can reach the local endpoint can use this path and acts with the Bridge owner's authority; it is disabled by `--no-local-proxy` or `[bridge] local_proxy_enabled=false`.
