# Bridge File Structure Guideline

Status: Target structure for the rewritten Heimdall Bridge (`ham-bridge`)
Companion to: `hub-bridge-user-owned-architecture-and-api.md` and
`hub-file-structure-guideline.md`

---

## 1. Purpose

The Bridge is a **user-owned machine-local runner**. It connects outbound to the
Hub over a WebSocket, receives commands (launch/stop/validate), launches wrappers
in tmux, reports capabilities and runtime status, and validates local project
paths. It owns **no durable product state** — the Hub is the source of truth.

This document defines the Bridge's file/package layout and the allowed
interactions, using the same layered discipline as the Hub so the two codebases
feel consistent and stay untangled.

Key differences from the Hub:

- The Bridge has no product database and stores almost nothing durably.
- Its only persistence is small local config/credentials (bridge_id, hub_url,
  bridge token, wrapper profiles, provider config) and a small runtime index of
  processes it manages.
- Its "domain" is commands, capabilities, and local processes, not user
  resources.

---

## 2. Core structural rules

1. **Directory = package = layer boundary** (Odin: directory is a package).
2. **Dependency direction is one-way:**
   `main → app → transport(hub client) / control → service → adapter`.
   Adapters (tmux, fs, provider probes) never import services; services never
   import the Hub WS transport directly (they use an injected interface).
3. **The Hub is reached through one client package.** Nothing else speaks the
   Hub protocol or holds the bridge token. The client uses the persisted
   `hub_url` exactly as enrolled/configured, including localhost/loopback SSH
   tunnel URLs; do not normalize it back to a public Hub URL.
4. **External systems (tmux, filesystem, provider CLIs) are reached only through
   adapter packages behind interfaces.** This keeps the runner testable and lets
   OS-specific bits stay isolated.
5. **One composition root wires everything.** Only `main` + `app` construct
   concrete types and inject them.
6. **No package-level mutable globals.** The live process index and connection
   state live in structs owned by a service and passed by pointer.
7. **Command handling is centralized.** Every inbound Hub command flows through a
   single dispatcher into the owning service; command handling is not scattered
   across transport code.
8. **Wire types (Hub protocol) and internal types are separate.** The Hub
   protocol envelope is mapped into internal command/event types at the
   transport boundary.

---

## 3. Top-level package layout

```text
src/
  bridge/
    main.odin              # entrypoint: parse args, subcommands (enroll|run)
    app/                   # composition root (only wiring place)
    hubclient/             # the ONLY package speaking the Hub protocol
    control/               # inbound command dispatch + outbound event emit
    service/               # bridge business logic (runner, capabilities, paths)
    adapter/               # tmux, fs, provider, wrapper-launch adapters
    domain/                # pure internal types (commands, capabilities, status)
    store/                 # small local persistence (config + runtime index)
    platform/              # clock, ids, log, config primitives
  contracts/               # shared Hub<->Bridge wire types (shared with Hub)
  lib/                     # engine-neutral shared libs (tmux, vcs, ws, config)
```

Dependency direction:

```text
main -> app -> control -> service -> adapter
                 ^            |          |
                 |            v          v
              hubclient    domain      (tmux/fs/provider)
                 |
              contracts

app injects: hubclient + adapters + store into services; services into control.
```

`domain`, `contracts`, `platform` are leaf packages.

---

## 4. `bridge/domain` — internal types

Pure types describing what the Bridge works with. No I/O.

```text
bridge/domain/
  command.odin      # Launch, Stop, ValidatePath, RefreshCaps, SyncState (internal form)
  capability.odin   # Provider capability the bridge reports
  instance.odin     # Managed instance runtime state (status enum, pane/pid handle)
  validation.odin   # Path validation request/result (internal form)
  status.odin       # runtime_status / startup_status / activity_status enums
  errors.odin       # bridge-side error codes (map to protocol error codes)
```

- **Imports:** `core:*` only.
- Enums shared with the Hub protocol (runtime_status etc.) should match
  `contracts`; map at the boundary rather than importing `contracts` here.

---

## 5. `contracts` — shared wire types

Reuse the same `contracts` package the Hub uses for the Hub↔Bridge runtime
protocol (envelope, launch_agent, stop_agent, validate_project_path,
capability_report, agent_instance_status, command_result, bridge_hello). Sharing
one contracts package guarantees both sides agree on the wire.

- **Who imports it in the Bridge:** `hubclient` (encode/decode) and `app`.
- **What it imports:** `core:*`, optionally `domain` enums shared across sides.

---

## 6. `bridge/hubclient` — the Hub protocol boundary

The single package that connects to the Hub, authenticates with the bridge
token, and translates wire messages ↔ internal `domain` types.

```text
bridge/hubclient/
  connection.odin    # outbound WS connect, bearer auth, reconnect/backoff loop
  session.odin       # protocol_version negotiation stub, hello handshake
  encode.odin        # domain -> contracts wire encode
  decode.odin        # contracts wire -> domain decode
  sink.odin          # Hub_Event_Sink interface impl: send events/results to Hub
  heartbeat.odin     # heartbeat sender
```

Interaction rules:

- **Imports:** `contracts`, `domain`, `platform`, `lib/ws`.
- **Does NOT import:** `service`, `control`, `app`, adapters.
- Holds the bridge token (received from `store`), and is the only place it is
  used in an `Authorization: Bearer` header. Never in URL/query.
- On inbound message: decode to a `domain.Command` and hand it to `control` via
  an injected `Command_Handler` callback. `hubclient` does not execute commands
  itself.
- On outbound: exposes a `Hub_Event_Sink` (send status, command_result,
  capability_report) that services use through an interface — services never
  import `hubclient` directly.

---

## 7. `bridge/control` — command dispatch + event emission

The seam between "a message arrived from the Hub" and "the right service does the
work". Centralizes command routing so it is not scattered in the WS loop.

```text
bridge/control/
  dispatcher.odin    # domain.Command -> owning service method
  result.odin        # wrap service outcome -> command_result via Hub_Event_Sink
  subscriptions.odin # forward service-produced runtime events to the Hub sink
```

Interaction rules:

- **Imports:** `domain`, `service/*`, and the `Hub_Event_Sink` interface (from
  `domain` or a small `ports` file), injected by `app`.
- `dispatcher` maps each command kind to exactly one service call:
  `launch_agent → runner.launch`, `stop_agent → runner.stop`,
  `validate_project_path → pathcheck.validate`,
  `refresh_capabilities → capabilities.report`,
  `sync_runtime_state → runner.snapshot`.
- Applies command idempotency (dedupe by `command_id` via `store` runtime index)
  before dispatch.
- `control` is injected into `hubclient` as the `Command_Handler`; this is the
  one wiring edge that lets inbound messages reach services without `hubclient`
  importing `service`.

---

## 8. `bridge/service` — bridge business logic

The runner logic. One sub-package per concern. Services own the managed-process
state and drive adapters.

```text
bridge/service/
  runner/
    runner_service.odin   # launch/stop instances; owns managed-instance lifecycle + state_seq
    supervisor.odin       # watch panes/pids, detect exit, feed state changes to runner
    reporter.odin         # coalesce/debounce edge events; build heartbeat digest (7.4)
  capabilities/
    capability_service.odin # probe providers, build capability report
  pathcheck/
    path_service.odin     # validate project path (exists/dir/vcs/remote match)
  bootstrap/
    bootstrap_service.odin # fetch bootstrap from Hub, write managed files, manifest
  ports.odin              # interfaces the services depend on (sinks/adapters)
```

Interaction rules:

- **Imports:** `domain`, `platform`, adapter interfaces (from `ports.odin`), and
  the `Hub_Event_Sink` / bootstrap-fetch interface (injected).
- **Does NOT import:** `hubclient`, `control`, `app`, concrete adapters.
- `runner_service` is the single owner of managed-instance state (the in-memory
  index of what this bridge is running). All status transitions
  (launching→starting→running→stopping→stopped/failed) happen here. It owns the
  per-instance monotonic `state_seq`, bumping it on every observed change
  (protocol 7.4.1). No other package flips instance status or the seq.
- `reporter` implements the reporting discipline (protocol 7.4). It is the only
  thing that decides *when* to send to the Hub: it coalesces/debounces
  edge-triggered transitions into a single `agent_instance_status` per instance
  per window, drops level-triggered noise (activity flapping, load counters), and
  builds the full per-instance digest consumed by the heartbeat. This keeps the
  "don't bombard the Hub" policy in one place instead of scattered `send` calls.
- `supervisor` detects process/pane exit and calls back into `runner_service`,
  which updates state (and seq) and hands the change to `reporter`. Supervisor
  does not talk to the Hub sink directly, and never sends per-tick updates.
- `bootstrap_service` fetches bootstrap via an injected `Bootstrap_Fetcher`
  (implemented in `hubclient` or a small HTTP client), then uses the fs adapter
  to write managed files. It never embeds product data logic; content comes from
  the Hub.

---

## 9. `bridge/adapter` — external-system adapters

All OS/tool interaction lives behind interfaces so services stay testable and
platform-specific code is isolated.

```text
bridge/adapter/
  tmux/
    tmux_adapter.odin     # create/list/kill windows, capture pane (uses lib/tmux)
  fs/
    fs_adapter.odin       # write/read/remove managed files, path checks, run dirs
  provider/
    provider_probe.odin   # detect installed provider CLIs + tiers
  vcs/
    vcs_adapter.odin      # branch/remote inspection for path validation (uses lib/vcs)
  wrapper/
    wrapper_launcher.odin # assemble + spawn the agent command in tmux
    wrapper_endpoint.odin # local Bridge endpoint (unix socket/loopback) the
                          # wrapper + agent (ham-ctl) talk to; receives local
                          # signals (startup/activity/liveness/exit) and
                          # agent-facing actions, authenticates local agent
                          # tokens, and hands them to a service for relay
    agent_token_store.odin # issue/verify/rotate Bridge-managed local agent
                          # tokens (local-only; map token -> agent_instance_id)
```

Wrapper/agent boundary: neither the wrapper nor the agent process talks to the
Hub or holds a Hub URL/token. Both connect only to the local Bridge endpoint. The
agent (`ham-ctl`) authenticates with a **Bridge-managed local agent token** and
issues agent-facing actions (chat/task/artifact/memory) locally; the Bridge
relays them to the Hub with the instance token and **asserts the instance
identity** on the agent's behalf. The Bridge owns the single Hub connection + the
Hub credential, issues/verifies local agent tokens, and reports to the Hub only
on edge state-changes plus periodic snapshots (runtime protocol 7.4). This keeps
one outbound connection and all Hub credentials off both wrapper and agent.

Interaction rules:

- Each adapter implements an interface declared in `service/ports.odin` and is
  injected by `app`.
- **Imports:** `domain`, `platform`, and relevant `lib/*` (tmux, vcs).
- **Does NOT import:** `service`, `control`, `hubclient`, `app`.
- Adapters contain no business decisions — they execute mechanical operations and
  return results/errors. "Should we launch?" is a service question; "run this
  tmux command" is an adapter question.

---

## 10. `bridge/store` — small local persistence

The Bridge persists very little. Keep it in one package with a clear interface so
it is not confused with product state.

```text
bridge/store/
  config_store.odin     # bridge_id, hub_url, bridge token (secure file perms)
  profile_store.odin    # wrapper agent-command profiles + provider config
  runtime_index.odin    # in-memory index of managed instances + command_id dedupe
```

Rules:

- **Imports:** `domain`, `platform`.
- Credentials are stored with restrictive file permissions and never logged.
- `runtime_index` is ephemeral (rebuilt on restart / via `sync_runtime_state`);
  it is not a source of truth — the Hub is.
- If any local data ever needs a real DB, it goes behind a repository interface
  exactly like the Hub's `repository/iface` pattern. For v1, flat local config
  files are acceptable **for the Bridge only** because this is machine-local
  runner config, not durable product state (the no-JSONL rule targets Hub
  product data).

---

## 11. `bridge/platform` and `bridge/app`

```text
bridge/platform/
  clock.odin
  ids.odin
  log.odin
  config.odin      # bridge config load (reuses lib/config)

bridge/app/
  app.odin         # run(): build graph, connect, serve command loop
  wiring.odin      # construct adapters -> services -> control -> hubclient
  enroll.odin      # `ham-bridge enroll`: one-time enrollment flow -> config_store
```

Wiring order:

```text
1. load config + platform primitives
2. construct store (config/profile/runtime_index)
3. construct adapters (tmux, fs, provider, vcs, wrapper)
4. construct services, injecting adapters + store + event sink placeholder
5. construct hubclient (Hub_Event_Sink + Bootstrap_Fetcher), inject into services
6. construct control.dispatcher, injecting services; inject as hubclient handler
7. connect hubclient (WS) with reconnect loop; run command loop + heartbeat
```

- **`app` imports everything; nothing imports `app`.**
- `enroll` subcommand is a separate short-lived flow that writes credentials to
  `config_store` and exits; it does not start the runner.

---

## 12. Allowed-import matrix (quick reference)

| Package | May import |
|---|---|
| `domain` | `core:*` |
| `contracts` | `core:*`, `domain` |
| `platform` | `core:*` |
| `store` | `domain`, `platform` |
| `adapter/*` | `domain`, `platform`, `lib/*` |
| `service/*` | `domain`, `platform`, `service/ports`, `store` |
| `control` | `domain`, `service/*` |
| `hubclient` | `contracts`, `domain`, `platform`, `lib/ws` |
| `app` | everything |
| `main` | `app`, `platform/config` |

Any import outside this table is a design bug.

---

## 13. Command/event flow (end to end)

```text
Hub WS --launch_agent--> hubclient.decode
   -> control.dispatcher (idempotency check via store.runtime_index)
   -> service/runner.launch
        -> adapter/fs (resolve run dir, effective path already in command)
        -> service/bootstrap.fetch_and_write (Bootstrap_Fetcher -> Hub, adapter/fs)
        -> adapter/wrapper.launch (tmux)
        -> runner marks instance launching->starting; emits status
   -> service emits via injected Hub_Event_Sink
        -> hubclient.encode -> Hub WS (command_result + agent_instance_status)
```

- Every inbound command takes this single path.
- Every outbound status/result goes through the one `Hub_Event_Sink`.
- No adapter or supervisor talks to the Hub directly.

---

## 14. Anti-spaghetti checklist

- Only `hubclient` speaks the Hub protocol or holds the bridge token.
- Only `adapter/*` calls tmux/fs/provider CLIs.
- Only `service/runner` mutates managed-instance status.
- Inbound commands flow through `control.dispatcher` — never handled inline in
  the WS read loop.
- Services depend on adapter/sink **interfaces** (`service/ports.odin`), not
  concrete adapters or `hubclient`.
- No package-level global holds the connection, token, or process index.
- `app` is the only constructor of concrete types.
- The Bridge stores no durable product state; the Hub remains source of truth.
```

