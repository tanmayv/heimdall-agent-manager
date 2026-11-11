# Heimdall AI Manager: Contributor Guide

Start here. This file orients a new contributor (human or agent): what the system is, where the code
lives, how to build and test it, the invariants that must not be broken, and the traps that have
already bitten us. The deep dive is [docs/architecture.md](docs/architecture.md); the docs index is
[docs/README.md](docs/README.md).

## 1. What Heimdall is

Heimdall is a Hub-and-Bridge multi-agent orchestration system. The **Hub** (`ham-hub`, Odin) owns
durable state (SQLite), authorization, chat, memory, projects, artifacts, cards and the chain owner
registry, and serves the HTTP/WebSocket APIs. One **Bridge** (`ham-bridge`, Odin) runs per execution
device, holds an outbound WebSocket to the Hub, and launches and supervises local agents, shell
sessions and VCS worktrees. Task chains are **Bridge-owned**: each chain's tasks, leases, reviews,
fleet, workflows and summary live in its owner Bridge's local store (`src/lib/owner_local`); the Hub
only routes to the owner; the former Hub task engine (Task System v2) is removed. `ham-pty-host`
(Rust) is the Bridge's local daemon that runs each provider CLI (Claude Code, Codex, ...) under a PTY. `ham-ctl` (Odin) is the CLI that agents and
operators use. The **UI** is React/TypeScript/Redux, shipped as a web app and an Electron app.
The Hub coordinates work on Bridges; it never launches agent processes on the Hub host.

```text
 Browser / Electron UI  (src/ui)
        |  HTTPS REST /api/v1 (cookie or bearer)  +  WebSocket (user events, pane/shell PTY frames)
        v
   ham-hub  (src/hub: transport/http -> service/* -> repository/sqlite)   <-- external MCP clients (HTTP)
        ^
        |  ONE outbound WebSocket per bridge (bridge token): JSON commands down, heartbeats/results up,
        |  binary PTY frames, HTTP-over-WS relays (previews). No inbound port on the bridge host.
   ham-bridge  (src/bridge)  -- git/jj child processes, provider extension hooks (ham.ext.v1)
     |  AF_UNIX socket (framed protocol)         ^ loopback HTTP 127.0.0.1:<port> (or unix: endpoint)
     v                                           |
   ham-pty-host  (tools/pty_host, Rust)     ham-ctl (src/ctl; agent mode, per-agent shim + instance token)
     |  real PTY                                 ^ invoked by the agent
     v                                           |
   provider CLI (claude / codex / ...) -----------+      extensions/ = provider-native hooks -> bridge
```

The old `ham-daemon`, `ham-wrapper` and tmux-based agent launch are historical; the only launch
path is [src/bridge/pty_host_runtime.odin](src/bridge/pty_host_runtime.odin). Details and transports:
[docs/architecture.md](docs/architecture.md).

## 2. Repository map

```text
src/
  contracts/            wire and auth contracts shared by hub, bridge, ctl
  hub/
    app/                wiring (App_Graph), MCP binding, reaper, metrics listener, OIDC user CLI
    domain/             durable record types and errors (no I/O)
    repository/iface/   storage interfaces + unit of work
    repository/sqlite/  SQLite implementations, numbered migrations/
    service/            one package per domain area (no task engine: chains are Bridge-owned)
    transport/http/     router, middleware, handlers, WebSocket streams, mcp_tools.json
  bridge/               flat Odin package: hub client, bootstrap, pty-host runtime, shells, extensions
  ctl/                  ham-ctl: agent_mode.odin (to bridge), hub_mode.odin (to hub), *_cmds.odin
  lib/                  owner_local (Bridge-owned chain store), httpc, ws, vault, vcs, local_socket, ...
  prompts/              shipped bootstrap text, canonical skills/, workflows/*.json
  templates/            built-in agent role templates
  ui/                   React/Redux app (api/, store/, components/, hooks/) and electron/
  dev_proxy/ test_agent/ mcp_probe/   dev-only proxy, scripted provider stand-in, MCP probe
tools/                  pty_host (Rust), gen_static_skills, mock_agent, mock-oidc, vault_vectors, ...
extensions/             claude-code, codex, antigravity provider hooks
tests/                  package-level Odin suites, ui_*_test.ts, python/shell tests, e2e/
scripts/                dev-preview, install, release, check-http-boundary.sh, windows/, lib/
nix/                    libcurl.nix + libcurl-pin.json, home-manager.nix
docs/                   architecture, guides, designs, audits (indexed in docs/README.md)
.agents/skills/         repo-local skills for working on this codebase
```

| To change ... | Look in |
| --- | --- |
| A REST/WebSocket route or handler | `src/hub/transport/http/` (`router.odin`, `*_handlers.odin`) |
| Business rules for an area (agents, content, shells, billing, ...) | `src/hub/service/<area>/` |
| Task leases, reviews, gate, merge-back, workflows | `src/lib/owner_local/`, `src/bridge/owner_*.odin` |
| Legacy Hub chain import | `src/hub/repository/sqlite/owner_migration*.odin`, `src/lib/owner_local/migration_import.odin`, `src/bridge/owner_migration.odin` |
| A table, query or migration | `src/hub/repository/sqlite/` (+ `repository/iface/`, `domain/`) |
| An owner-local (Bridge chain store) table | `src/lib/owner_local/schema.sql` is the flat baseline (V38). Until a release users run owner chains on ships, edit it in place and bump `SCHEMA_VERSION` with `runtime_database.schema_version`; after that, add numbered `migration_NNN.sql` steps from the baseline in `migrations.odin`. Stores older than the baseline are refused |
| A hub-to-bridge command | `src/bridge/hub_runtime_client.odin` (`bridge_hub_handle_command`), `hub_command_dispatch.odin` |
| Agent bootstrap files | `src/bridge/bootstrap_*.odin`, `src/hub/service/agent/`, `src/prompts/` |
| Agent launch, PTY, terminal I/O | `src/bridge/pty_host_runtime.odin`, `tools/pty_host/src/` |
| `ham-ctl` commands | `src/ctl/` (agent mode vs `hub_mode.odin`) |
| Outbound HTTP, WebSocket, vault, VCS, sockets | `src/lib/httpc`, `ws`, `vault`, `vcs`, `local_socket` |
| Wire types / schemas | `src/contracts/` (and the TypeScript mirror in `src/ui/api/`) |
| Shipped skills and workflows | `src/prompts/skills/`, `src/prompts/workflows/` |
| UI screens, state, API client | `src/ui/components/`, `src/ui/store/`, `src/ui/api/` |
| Electron shell | `src/ui/electron/` |
| Provider-native hooks | `extensions/<provider>/`, `src/bridge/extension_ingest.odin` |
| Build, packaging, checks | `flake.nix`, `nix/`, `package.json`, `scripts/` |
| Tests | `*_test.odin` beside the code, `tests/` |

## 3. Build, run and test

Use `nix develop` for the toolchain (Odin, ols, the pinned libcurl, openssl, socat, tmux). Odin code
uses one import collection, `odin_test`, rooted at `src/`.

```bash
nix build .#ham-hub          # also .#ham-bridge .#ham-ctl .#ham-pty-host .#ham-dev-proxy .#ham-test-agent
nix run .#hub                # hub wrapper (injects migrations dir); also .#bridge .#pty-host .#ctl
nix run .#heimdall           # desktop UI;  .#heimdall-browser / .#ham-ui-server for the web client
nix flake check              # runs checks.http-boundary (scripts/check-http-boundary.sh)
```

Odin tests, one package at a time (there is no single workflow that runs every suite):

```bash
odin test src/hub/transport/http -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/http-$$
```

- Always pass `-collection:odin_test=src` and a **unique `-out:` under `$HOME`**, never `/tmp`
  (see [Gotchas](#7-gotchas)). A unique name also keeps parallel runs from clobbering each other.
- Run suites multithreaded (the default). Do **not** pass `-define:ODIN_TEST_THREADS=1`; a test
  that only passes serially is a bug. Odin runs every test as a thread of ONE process, so tests
  must be hermetic:
  - never `os.set_env`/`os.unset_env`: in `src/bridge` use `bridge_test_env_set`/`_unset`
    (per-thread overrides read by `bridge_env_get`/`bridge_env_lookup`, also seen by `lib/config`);
  - in `src/bridge` read/write the config through `bridge_cfg()` (a per-thread copy in test builds)
    and start worker threads with `bridge_thread_run*` / `bridge_thread_start_with_*`, which hand the
    spawning test's config and env overrides to the worker;
  - test hooks (`bridge_owner_*_effect(s)`, `bridge_codex_own_*_hook`, `bridge_provider_reprobe_hook`,
    `bridge_rollover_effects`) are `@(thread_local)`; set them with the matching `*_sync` flag so the
    effect runs on the test's thread;
  - state that worker threads must share (the shell session map, the pty-host test socket, local
    token records, the launch registry) is guarded by holding `bridge_test_config_mutex` for the test;
  - per-test temp dirs and sockets (unique name with pid + nanoseconds), port 0 for listeners;
  - a loaded multithreaded run is slow, so do not let real elapsed time decide a test that is not
    about timeouts (e.g. restart `Fence_Challenge.started` before `fence_accept`, as
    `execution_test_accept` does in `src/lib/owner_local`).
- Frontend: `npm run typecheck` (`tsc -b`), `npm test` (Node test runner; the file list is in
  `package.json`), `npm run build` (typecheck + Vite + Electron). `npm run dev` runs Vite + Electron;
  `npm run dev:preview` runs the live-data preview ([docs/dev-preview.md](docs/dev-preview.md)).
- Rust: `cd tools/pty_host && cargo test -- --test-threads=1`.
- Python/shell tests live in `tests/` (`python3 tests/test_<name>.py`, `tests/e2e_*.sh`);
  `npm run test:e2e:vault|profiles` and `npm run test:pane-transport` cover end-to-end paths.
- Run what you touched. Report commands and outcomes honestly; do not claim unrun tests passed.
- Run build/test commands through `ham-ctl shell run --cmd '...' --cwd <workdir>` when working as a
  Heimdall agent; use `--bg` for long ones and `shell serve --port` for servers.

## 4. Core concepts and invariants

| Identifier | Meaning |
| --- | --- |
| `agent_id` (`agt_...`) | Durable named agent (template + instructions). Fleet rows, assignees and reviewers use it. |
| `agent_instance_id` (`inst_...`) | One managed instance: agent + Bridge + provider/model + run dir + conversation. Survives process exit; not a PID. |
| `conversation_id` | Durable conversation binding used to read and route chat. |
| `bridge_id` | Enrolled execution device and its authenticated Hub connection. |
| `task_id` / `lease_id` | Durable work item / temporary authority to work on or review its current attempt. |

Records: [src/hub/domain](src/hub/domain), auth contracts: [src/contracts/auth.odin](src/contracts/auth.odin).

- **Durable state vs runtime projections.** The Hub persists agents, instances, the chain owner registry,
  chat, memory, projects, artifacts, authorization and audit state in SQLite; each Bridge persists the tasks, leases,
  reviews and workflows of the chains it owns in its owner-local store. Live Bridge
  connections, runtime maps, viewer queues, pending permission prompts and tool activity are
  transient projections and never substitute for durable records ([docs/runtime-registry.md](docs/runtime-registry.md)).
  A live process, an instance record and a task lease are three different things: a task can await
  review while its worker has stopped, and disconnection alone does not prove a process died.
- **Owner-local transactions.** Every chain mutation commits in one owner-store transaction on its
  Bridge; side effects (wakes, stops, merges, notices) are recorded as outbox intents and run only
  after commit ([src/lib/owner_local](src/lib/owner_local)). The Hub has no chain/task write path:
  its `/task-chains`, `/tasks`, `/workflows` and `/workflow-runs` routes and the MCP `chains.*`,
  `tasks.*`, `events.wait` tools answer `410 hub_chains_removed`.
- **Auth boundaries.** Humans use OIDC/browser sessions ([docs/auth-oidc.md](docs/auth-oidc.md),
  [docs/desktop-auth.md](docs/desktop-auth.md)); Bridges use enrolled Bridge credentials; agents use
  per-instance tokens through the local Bridge. Owner scoping is enforced by
  [service/ownership](src/hub/service/ownership/ownership.odin). Never widen access by substituting
  one identity for another, and never assume token values or derive credentials from identifiers; shells, artifacts, conversations and tasks each have their own ownership
  checks. Fleet roles are agent work/review roles, not human access grants.
- **Memory.** Types: `fact`, `habit`, `episode`, `expertise`, `skill`. Targeting lists agent, project,
  template and Bridge IDs (all non-empty dimensions must match); `template` is a dimension, not a
  type. Proposals need human approval before becoming bootstrap knowledge
  ([reference](docs/reference/heimdall_memory_system_and_bootstrap.md)).
- **Notifications carry no payload.** A terminal wake notice only tells the agent to run
  `ham-ctl chat read` or `lease next`; never infer message bodies, tool results or task
  completion from a notice or a terminal screen.
- **One outbound HTTP client.** `src/lib/httpc` (libcurl) is the ONLY outbound HTTP(S) client
  ([README](src/lib/httpc/README.md)). Requests are structured (parsed base URL, path segments,
  query, validated headers, typed bodies); never build URLs/headers/bodies by string interpolation.
  `scripts/check-http-boundary.sh` (also `nix flake check`) fails if another package touches libcurl.
  One libcurl is pinned by [nix/libcurl-pin.json](nix/libcurl-pin.json), built by
  [nix/libcurl.nix](nix/libcurl.nix) and linked statically in release builds; `httpc.init()` refuses
  any other version. Never link nixpkgs' `curl` into an Odin package.
- **UI debug IDs.** Every interactive UI element needs a `data-debug-id`; see section 6.
- **Electron has no debug-control server** (REQ-ELECTRON-NO-REMOTE-DEBUG-1); do not add one.

## 5. Key flows

Full walkthroughs with function names: [docs/architecture.md](docs/architecture.md) section 5.

**Agent launch and bootstrap.** UI/CLI/MCP or an owner Bridge's fleet requests an instance; the Hub validates
ownership and provider/model, then sends `launch_agent` to the owning Bridge
([agent_service.odin](src/hub/service/agent/agent_service.odin)). The Bridge issues an instance token,
clean-slates the run dir, fetches the content-addressed manifest and blobs
([bootstrap_prespawn.odin](src/bridge/bootstrap_prespawn.odin),
[bootstrap_service.odin](src/bridge/bootstrap_service.odin)) and writes instructions
(`AGENTS.md`/`CLAUDE.md`), memories, skills, `heimdall-bootstrap-manifest.json` and the `./bin/ham-ctl`
shim. It then spawns the provider through `ham-pty-host`. The agent signals readiness with
`ham-ctl agent start-success`. The run dir is cleared on every launch: keep project edits in the task
Workdir, never in the bootstrap directory.

**Task lifecycle.** Stored states: `backlog`, `ready`, `in_progress`, `in_review`, `done`,
`cancelled`, held in the owner Bridge's store ([src/lib/owner_local](src/lib/owner_local)); state is
driven by leases, reviews and dependencies, never set by hand. Chains are created in the Heimdall app
on a Bridge.
- Create tasks with a non-empty goal and acceptance items; publish drafts. Assign work to durable
  `agt_...` identities. Workers choose and report their own checks; briefs carry no verify command.
- A work lease makes a ready task `in_progress`; one instance holds at most one lease and a task has at
  most one work lease. `lease next` returns the current lease or claims eligible work.
- On wake read `TASK.md` and do all edits and commits in the Workdir it names (git chains use
  per-task worktrees). Post a plan and milestone comments; `lease heartbeat` at least every 15 min;
  `lease_lost` ends your authority.
- `lease submit` releases for review, `lease handoff` returns unfinished work, `lease block` records
  an external dependency. There is no manual status transition.
- Reviews: `review post --verdict approve|request_changes`. The gate
  ([review_roles.odin](src/lib/owner_local/review_roles.odin)) checks required reviewers, fleet review roles and user
  approval; authors never review their own work; a request for changes wins. `changes_requested`
  is a gate result, not a state (task returns to `ready`; three rounds park it with a human block).
- Merge-back is separate from review: the task branch is merged through the directory's Bridge
  ([owner_local_lifecycle.odin](src/bridge/owner_local_lifecycle.odin)); conflicts stay visible and block dependents.
- Dependencies need success (`task depend`). Workflow runs of a Bridge-owned chain are steered whole
  (`workflow retry|cancel`); do not edit stage identities. Finishing a batch does not complete a chain:
  read `work_revision` from `task-chain show`, then
  `task-chain complete <id> --expected-work-revision <n> --summary ...` once everything succeeded, no
  leases remain and proposals are decided. The summary must state results, checks and outcomes,
  commits, paths and limits, plus a `good`/`bad` quality rating with rationale.
- **Solo mode:** the coordinator is also a worker, pulls with `lease next`, defaults to user review,
  cannot approve its own work and stays running across submits; other lease holders are stopped on
  release and re-bootstrapped ([leases.odin](src/lib/owner_local/leases.odin)).
- **Legacy Hub chains** stay on the Hub read-only until imported (Settings → Bridges → Import all
  legacy chains, or `ham-ctl task-chain migrate` for one chain). Busy chains are neutralized during
  import (leases ended, in-progress tasks force-held, running workflows cancelled, pending merges
  closed) and the import records what it did.
- Keep required user gates; record a verdict on the user's behalf only after an explicit decision,
  never from silence or an answer selection.

**Chat and wake notifications.** Messages are durable; the Hub sends `notify_agent_message` and the
Bridge types a one-line notice into the PTY ([content_service.odin](src/hub/service/content/content_service.odin),
[pty_host_runtime.odin](src/bridge/pty_host_runtime.odin)). Task wakes come from the
owner Bridge ([owner_local.odin](src/bridge/owner_local.odin), [agent_wake.odin](src/bridge/agent_wake.odin)). Use chat
(`ham-ctl chat read|send --to user|<inst_id>`) for user-facing talk and task comments / submit
summaries for technical evidence, decisions and dead ends. Agents use the generated `./bin/ham-ctl`;
operator commands live under `ham-ctl hub` (check `ham-ctl help hub`).

**Provider catalog and extensions.** The Hub owns the catalog (executable/args, model selection,
prompt delivery, bootstrap paths) and pushes it to Bridges; Bridges report detection, profiles and
discovered models ([provider_service.odin](src/hub/service/provider/provider_service.odin)). Explicit
provider/model choices are validated, never silently substituted. Provider authentication is part of
the device's setup, not a universal API-key store. `extensions/` hooks emit `ham.ext.v1` events that
the Bridge ingests ([extension_ingest.odin](src/bridge/extension_ingest.odin)); capabilities differ per
provider, so preserve the native-prompt fallback when a permission hook cannot deliver a decision.

## 6. Conventions

- **Commit subjects** follow `git log`: `UI: ...`, `ham-ctl/Bridge: ...`, `Hub: ...`, `Billing: ...`,
  `docs: ...`, imperative and specific. Commit in the task Workdir; do not push (the hub merges).
- **Contracts first.** Change the wire/schema contract in `src/contracts/` (and its TypeScript/Hub
  mirrors) before the implementations; see `.agents/skills/contracts-first`.
- **`data-debug-id` rule.** Every interactive element carries a kebab-case
  `<page-or-context>-<element-role>[-<qualifier>]` ID, with the stable item ID appended for repeated
  rows; tests and browser automation select on it. Full convention and per-component registry:
  [docs/ui-debug-ids.md](docs/ui-debug-ids.md).
- **Testing discipline.** Add or update a test beside the code you change (`*_test.odin`,
  `tests/ui_*_test.ts`); run the packages you touched; bridge tests spawn real children, so clean up
  with the helpers; see `.agents/skills/testing-discipline`.
- **Edits stay in the task Workdir.** Never edit the shared checkout or the bootstrap directory.
- Docs: derive claims from source; `ham-daemon`/`ham-wrapper`/tmux launch are historical.

## 7. Gotchas

- **Socket lifetime across threads:** closing a socket on one thread while another blocks reading it has
  caused the same defect five times; read [docs/socket-lifetime.md](docs/socket-lifetime.md) before
  copying any stream-teardown pattern.
- **Terminal transport:** keep socket ownership and viewer backpressure rules intact when changing pane/shell
  transport ([docs/pane-transport.md](docs/pane-transport.md)).
- **Odin test binaries under `/tmp` get SIGKILLed** on managed hosts with endpoint security (first run of
  a never-seen binary dies with exit 137); build into `$HOME/.cache/heimdall-tests/` instead
  ([section 3](#3-build-run-and-test)).
- **libcurl pin bump:** edit [nix/libcurl-pin.json](nix/libcurl-pin.json) (version, URLs, SHA-256 checked
  against the release signature), build the `release-*` attrs and run the httpc suite
  ([README](src/lib/httpc/README.md)).
- **Stale `npmDepsHash`:** when `package-lock.json` changes, update `npmDepsHash` in [flake.nix](flake.nix);
  a stale hash still builds where the old deps are in the store and only fails on a fresh deploy, so a
  local `nix build` will not catch it.
- **Bridge tests spawning children:** they start real processes (`setsid sh -c`, `git`, `ps`); kill them
  with `bridge_shell_test_kill_pid` ([src/bridge/shell_common.odin](src/bridge/shell_common.odin)), which only group-kills a provably-own session leader, never the
  runner's group.

## 8. Further reading

- [docs/README.md](docs/README.md) (index), [docs/architecture.md](docs/architecture.md),
  [docs/dev-preview.md](docs/dev-preview.md) (live-data preview with instant HMR)
- [README.md](README.md), [SELF_HOSTING.md](SELF_HOSTING.md) (operator setup), [DESIGN.md](DESIGN.md),
  [REVIEW_GUIDELINES.md](REVIEW_GUIDELINES.md), [SECURITY.md](SECURITY.md)
- [.agents/skills](.agents/skills): repo-local skills (git hygiene, contracts-first, testing, review)
- Historical: [docs/fsm_task_chain_engine.md](docs/fsm_task_chain_engine.md) is an earlier proposal, not
  the current task engine reference.
