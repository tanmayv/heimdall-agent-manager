# Heimdall AI Manager Project Guide

This project is a prototype for a local daemon + tmux-backed agent wrapper + CLI control tool. The daemon tracks uniquely named agent instances, wrapper processes launch interactive agents in tmux, and WebSocket notifications are used only to signal that messages are available; actual message storage/fetching is intended to go through a message provider abstraction later.

## Identity Model

- `agent_class`: agent type/category, usually derived from the part before `@`.
  - Example: `coder-agent`
- `agent_instance_id`: unique user-facing agent instance identity.
  - Example: `coder-agent@project-1`
- `conversation_id`: message conversation associated with an `agent_instance_id`.
- `agent_token`: credential issued by daemon for agent RPC calls.
- WebSocket notifications should not contain actual message bodies; they should only notify that messages are available.

## Root Files

- `flake.nix`
  - Nix flake defining build packages and apps.
  - Packages:
    - `ham-daemon`
    - `ham-wrapper`
    - `ham-ctl`
  - Provides a dev shell with Odin, OLS, tmux, curl, and jq.
  - Uses `nixpkgs-unstable` and overrides Odin to use LLVM 21 on Darwin to avoid current compiler-rt issues.

- `flake.lock`
  - Locked flake input versions.

- `config.toml`
  - Example runtime config.
  - Contains daemon bind/port settings, wrapper daemon URL, tmux session/window config, command to launch, and ctl daemon URL.
  - Documents managed agent run directories and provider bootstrap profiles:
    - `wrapper.agent_run_dir` enables generated runtime cwd layout `<agent_run_dir>/<safe-project>/<safe-agent-instance>`.
    - `wrapper.project` and per-agent-cmd `project` select project context/anchors for bootstrap files.
    - Per-agent-cmd `run_dir` is an exact cwd override and bypasses managed layout.
    - Per-agent-cmd `bootstrap_enabled` turns on managed file generation.
    - Per-agent-cmd `bootstrap_profile` chooses provider defaults: `pi` and `codex` generate `AGENTS.md`; `claude` generates `CLAUDE.md`.
    - Per-agent-cmd `bootstrap_files` overrides destination filenames; `bootstrap_sections` can restrict generated sections to any of `identity`, `guidance`, `project`, and `memory`.
    - Managed files are overwritten only when they contain the Heimdall managed header, and removed only when previously listed in `.heimdall-bootstrap-manifest`.

- `AGENTS.md`
  - This guide.

## Source Layout

```text
src/
  contracts/
  daemon/
  wrapper/
  ctl/
  lib/
    config/
    http_client/
    tmux/
    ws/
```

## Package Summaries

### `src/contracts` package: `contracts`

Shared public protocol and API types. All binaries should import this package for shared contracts so breaking contract changes are caught at build time.

Files:

- `identity.odin`
  - Defines core identity/token types:
    - `Agent_Class`
    - `Agent_Instance_ID`
    - `Conversation_ID`
    - `Wrapper_Instance_ID`
    - `Reconnect_Token`
    - `Ws_Token`
    - `Agent_Token`
  - Defines client kind/access/capability enums.

- `protocol.odin`
  - Protocol version and route constants:
    - `/health`
    - `/register`
    - `/reconnect`
    - `/heartbeat`
    - `/ws`
    - `/clients`
    - `/agent-rpc`

- `lifecycle.odin`
  - Health/register/reconnect request and response structs.
  - Registration is based on `agent_class` + `agent_instance_id`.
  - Register response includes `conversation_id`, `ws_url`, `ws_token`, and `agent_token`.

- `registry.odin`
  - Client/agent listing contract.
  - Tracks agent instance metadata, connection status, and last-seen timestamp.

- `messages.odin`
  - WebSocket command/event contract.
  - `Messages_Available` is metadata-only and must not carry actual message content.

- `agent_rpc.odin`
  - Agent RPC request/response contract.
  - Includes actions like health, list clients, send stdin, send message, and capture.
  - Message send targets `target_agent_instance_id`.

### `src/daemon` package: `main`

Daemon binary package for `ham-daemon`.

Responsibilities:

- Runs local HTTP server.
- Handles `/health`, `/register`, `/heartbeat`, `/clients`, `/agent-rpc`, and `/ws/<agent_instance_id>`.
- Maintains in-memory registry of agent instances.
- Maintains active WebSocket connection per agent instance.
- Sends metadata-only `messages_available` WebSocket notifications.

Files:

- `main.odin`
  - Loads config via `src/lib/config`.
  - Starts daemon server.

- `server.odin`
  - Minimal HTTP server and WebSocket upgrade handling.
  - Performs request routing.
  - Handles agent RPC send-message notification path.
  - Implements WebSocket handshake and basic read loop.

- `registry.odin`
  - In-memory daemon registry.
  - Maps `agent_instance_id` to agent metadata, conversation ID, tokens, timestamps, and WebSocket socket.
  - Generates conversation IDs from agent instance IDs.

### `src/wrapper` package: `main`

Wrapper binary package for `ham-wrapper`.

Responsibilities:

- Can be run from any directory, inside or outside tmux.
- Launches/reuses a tmux session/window for the actual interactive agent command.
- Registers the agent instance with daemon.
- Opens a WebSocket connection to daemon.
- Sends heartbeat loop to daemon.
- Logs wrapper status to stdout.
- Supports `--detach` mode by starting a background wrapper process.

Files:

- `main.odin`
  - Parses `--config`, `--detach`, and agent instance argument.
  - Derives `agent_class` from `agent_instance_id`.
  - Launches tmux agent pane.
  - Registers with daemon.
  - Connects WebSocket.
  - Runs heartbeat/poll loop.

- `daemon_client.odin`
  - Early wrapper-side daemon client shape using function pointers.
  - Uses `agent_instance_id` and `conversation_id` for wrapper credentials and WebSocket session metadata.

### `src/ctl` package: `main`

CLI binary package for `ham-ctl`.

Responsibilities:

- Loads config.
- Talks to daemon via HTTP.
- Current commands:
  - `health`
  - `list`

Files:

- `main.odin`
  - Parses command from args.
  - Calls daemon `/health` or `/clients` using shared HTTP client.

### `src/lib/config` package: `config`

Shared config loading library.

Responsibilities:

- Finds config path from `--config <path>`.
- Loads/parses minimal TOML-like config.
- Provides default config values.

Files:

- `config.odin`
  - Defines `Config`, `Daemon_Config`, `Wrapper_Config`, and `Ctl_Config`.
  - Implements minimal parser for sections/strings/ints/string arrays.
  - Supports wrapper tmux settings.

### `src/lib/http_client` package: `http_client`

Minimal shared HTTP client used by wrapper and CLI.

Files:

- `http_client.odin`
  - Implements simple `GET` and `POST` over TCP.
  - Parses HTTP status 200 and response body.
  - Intended only for local POC HTTP calls.

### `src/lib/tmux` package: `tmux`

Tmux integration helper used by wrapper.

Files:

- `tmux.odin`
  - Ensures tmux session exists.
  - Creates/reuses agent window.
  - Builds shell command for launching configured command in cwd.
  - Returns tmux pane ID.

### `src/lib/ws` package: `ws`

Minimal WebSocket client helper used by wrapper.

Files:

- `ws.odin`
  - Performs WebSocket HTTP upgrade.
  - Keeps socket open in `Connection`.
  - Provides nonblocking `poll_text` for simple server text frames.
  - POC only; supports small unfragmented text frames.

## Current POC Flow

1. Start daemon:

```bash
ham-daemon --config ./config.toml
```

2. Start wrapper:

```bash
ham-wrapper --config ./config.toml coder-agent@project-1
```

3. Wrapper launches configured command in tmux, registers with daemon, opens WS, and starts heartbeat.

4. List agents:

```bash
ham-ctl --config ./config.toml list
```

5. Agent RPC send-message currently triggers only WS metadata notification:

```json
{"type":"messages_available","conversation_id":"conv_...","pending_count":1}
```

## Important Design Notes

- Do not send actual message bodies over WebSocket.
- WebSocket is notification-only.
- Actual messages should be stored/fetched through a future `MessageProvider` abstraction.
- `agent_instance_id` is the primary public identity.
- `agent_class` is a grouping/type derived from `agent_instance_id` when possible.
- Current storage is in-memory only.
- Current HTTP/WS implementations are intentionally minimal for POC and not production-hardened.

## Current Control / Launch Model

Default config path:

```text
~/.config/heimdall/config.toml
```

Pass `--config <path>` to override.

### Agent command profiles

`config.toml` supports multiple wrapper agent command profiles:

```toml
[wrapper]
default_agent = "pi"

[wrapper.agent-cmd.pi]
command = ["pi"]
yolo_flags = []
prompt_flags = []
starter_prompt = "You are {instance}. Use token {token}."

[wrapper.agent-cmd.claude]
command = ["claude"]
yolo_flags = ["--dangerously-skip-permissions"]
prompt_flags = []
starter_prompt = "You are {instance}. Use token {token}."
```

`ham-ctl agents start ... --agent <name>` selects one of these profiles. If omitted, `[wrapper].default_agent` is used.

### Startup detection

Wrappers can classify provider startup without persisting raw terminal transcripts. Add a nested startup detection section under an agent command profile:

```toml
[wrapper.agent-cmd.claude.startup_detection]
enabled = true
startup_probe_seconds = 20
capture_interval_ms = 500
ready_patterns = ["> ", "How can I help"]
blocked_patterns = ["Do you trust the files in this folder", "Claude needs your permission"]
probe_prompt = ""
probe_expect_echo = false
startup_unknown_is_blocked = false
sanitized_reason_mapping = ["trust=Claude directory trust prompt", "permission=Claude permission prompt"]
```

The wrapper captures bounded pane text in memory only during the probe window. It reports only metadata and safe diagnostics to the daemon: `starting`, `ready`, `startup_blocked`, `startup_failed`, or `startup_unknown`, plus provider/run-dir/tmux metadata and a sanitized reason. Do not put secrets or raw terminal snippets in `sanitized_reason_mapping`; use short operator-safe descriptions such as “approve Claude directory trust in the agent terminal”.

### Ctl commands

`ham-ctl` is the preferred user/agent interface. Attention gating is enforced by the daemon: `tasks next` first recomputes eligible dependency/slot promotions, and if a reviewer/verifier is configured the assignee should not pick another task until the current task is validated. Attempts to create or move a task to `ready` while dependencies or assignee slots are blocked return structured errors such as `error: "dependency"` or `error: "assignee_active_task"` with `blocking_task_ids`; resolve or wait on those tasks, or explicitly move work to a blocked/planned state.

```bash
ham-ctl health
ham-ctl list
ham-ctl agents list
ham-ctl agents start <agent_instance_id> [--agent pi|claude] [--detached|--remote [host:port]]
ham-ctl send --token <token> --to <agent_instance_id> --body <text>
ham-ctl send --token <token> --to <agent_instance_id> --stdin
ham-ctl inbox --token <token> [--limit N] [--include-read] [--json]
```

### Local vs remote start

Foreground local start:

```bash
ham-ctl agents start pi-agent@a --agent pi
```

Local detached start:

```bash
ham-ctl agents start pi-agent@a --agent pi --detached
```

Remote daemon start:

```bash
ham-ctl agents start pi-agent@a --agent pi --remote host:49322
```

Remote semantics:

```text
ctl may be remote
remote daemon launches local wrapper on daemon machine
wrapper connects back to its local daemon via config
```

Daemon endpoint:

```text
POST /agents/start
```

The daemon package includes `ham-wrapper` in its Nix output so it can launch a local wrapper.

## Token Model

Agent tokens are now non-deterministic random bearer tokens returned by registration/start responses.

Do not assume token format like:

```text
agent_<agent_instance_id>
```

That old deterministic form should be rejected. Agents must use the exact token printed by wrapper/ctl/daemon response.

Examples:

```json
{"agent_token":"agt_<random-hex>"}
```

For daemon-launched remote wrappers, daemon generates the random token, returns it to ctl, and passes it to wrapper via `--agent-token` so wrapper registers with the same token.

## UI Debug IDs

Every interactive element in the Electron UI must have a `data-debug-id` attribute. The Electron debug API (exposed at `http://127.0.0.1:<debug-port>/elements`, `/click`, `/type`, etc.) uses these IDs to locate and interact with elements programmatically.

### Naming convention

- Format: `kebab-case` strings, all lowercase.
- Pattern: `<page-or-context>-<element-role>[-<qualifier>]`
- For list items that repeat, append the item's stable ID: `agent-item-${agent.id}`, `chain-card-${chainId}`.
- For indexed rows (e.g. anchor arrays), append the index: `create-anchor-type-0`, `detail-anchor-remove-btn-2`.
- For tier/tab variants, append the variant value: `start-agent-model-tier-smart`, `agents-tab-templates`.

### Required elements

All of the following element types must have `data-debug-id`:
- `button` — every button, including icon-only buttons and items that act as buttons
- `input` — every text/radio/checkbox input
- `select` — every dropdown
- `textarea` — every multi-line input
- `label` wrapping a radio input — use on the `<label>` itself for radio groups styled as clickable tiles

### Per-component registry

| Component | Key IDs |
|-----------|---------|
| `AgentSidebar` | `nav-chat`, `nav-tasks`, `nav-memory`, `nav-projects`, `nav-agents`, `nav-settings`, `new-agent-btn`, `refresh-agents-btn`, `project-group-toggle-${projectId}` |
| `AgentListItem` | `agent-item-${agent.id}`, `agent-item-dismiss-warning-${agent.id}` |
| `Composer` | `message-input`, `send-message-btn` |
| `ChatPane` | `chat-scroll-to-bottom-btn` |
| `SessionConfig` | `session-config-reconnect-btn`, `session-config-daemon-url`, `session-config-user-id` |
| `SettingsPage` | `settings-back-btn` |
| `StartAgentPage` | `start-agent-back-btn`, `start-agent-project-select`, `start-agent-template-select`, `start-agent-provider-select`, `start-agent-model-tier-${tier}`, `start-agent-display-name`, `start-agent-cancel-btn`, `start-agent-submit-btn` |
| `AgentsPage` | `agents-page-start-agent-btn`, `agents-tab-${t}`, `agent-stop-btn-${id}`, `agent-start-btn-${id}`, `agent-edit-toggle-btn-${id}`, `agent-archive-btn-${id}`, `agent-edit-display-name`, `agent-edit-template-select`, `agent-edit-provider`, `agent-edit-model-tier-${tier}`, `agent-edit-cancel-btn`, `agent-edit-save-btn`, `template-form-id`, `template-form-display-name`, `template-form-role-hint`, `template-form-provider`, `template-form-persona`, `template-form-cancel-btn`, `template-form-submit`, `template-new-btn`, `template-edit-btn-${id}`, `template-archive-btn-${id}`, `test-provider-select`, `test-tier-btn-${tier}`, `test-run-btn` |
| `MemoryBoard` | `memory-back-btn`, `memory-refresh-btn`, `memory-new-proposal-btn`, `memory-filter-agent`, `memory-filter-type`, `memory-filter-status`, `memory-record-${id}`, `proposal-action-select`, `proposal-memory-id`, `proposal-expected-version`, `proposal-subject-agent-select`, `proposal-type-select`, `proposal-scope`, `proposal-title`, `proposal-source-task-id`, `proposal-body`, `proposal-reason`, `proposal-evidence`, `proposal-cancel-btn`, `proposal-submit-btn`, `memory-propose-edit-btn`, `memory-propose-archive-btn`, `memory-propose-rollback-btn`, `memory-decision-reason`, `memory-reject-btn`, `memory-approve-btn` |
| `ProjectsPage` | `projects-back-btn`, `projects-refresh-btn`, `projects-new-btn`, `create-project-name`, `create-project-description`, `create-project-add-anchor-btn`, `create-anchor-type-${i}`, `create-anchor-value-${i}`, `create-anchor-note-${i}`, `create-anchor-browse-btn-${i}`, `create-anchor-remove-btn-${i}`, `create-project-cancel-btn`, `create-project-submit-btn`, `project-list-item-${id}`, `detail-project-name`, `detail-project-description`, `detail-project-add-anchor-btn`, `detail-anchor-type-${i}`, `detail-anchor-value-${i}`, `detail-anchor-note-${i}`, `detail-anchor-browse-btn-${i}`, `detail-anchor-remove-btn-${i}`, `detail-project-save-btn`, `project-agents-refresh-btn`, `project-agent-remove-btn`, `add-existing-agent-select`, `add-existing-agent-submit-btn`, `new-agent-template-select`, `new-agent-provider-select`, `new-agent-display-name`, `start-project-agent-btn` |
| `TaskBoard` | `task-back-btn`, `task-add-to-chain-btn`, `task-new-chain-btn`, `task-new-root-btn`, `task-refresh-btn`, `chain-card-${id}`, `task-card-${id}`, `chain-edit-title`, `chain-edit-description`, `chain-edit-coordinator-select`, `chain-edit-reviewer-select`, `chain-edit-final-summary`, `chain-save-metadata-btn`, `chain-status-input`, `chain-status-summary`, `chain-set-status-btn`, `chain-add-task-btn-${columnId}`, `create-chain-title`, `create-chain-id`, `create-chain-description`, `create-chain-coordinator-select`, `create-chain-reviewer-select`, `create-chain-cancel-btn`, `create-chain-submit-btn`, `create-task-mode-select`, `create-task-priority`, `create-task-status`, `create-task-title`, `create-task-description`, `create-task-assignee-select`, `create-task-reviewer-select`, `create-task-coordinator-select`, `create-task-cancel-btn`, `create-task-submit-btn`, `task-nudge-btn`, `task-comment-input`, `task-comment-submit-btn`, `task-status-input`, `task-status-note-input`, `task-status-update-btn`, `task-assign-agent-select`, `task-assign-submit-btn`, `task-participant-agent-select`, `task-participant-role-select`, `task-participant-submit-btn` |

### Shared component: AgentSelect

`AgentSelect` accepts an optional `debugId` prop that maps directly to `data-debug-id` on the underlying `<select>`. Always pass `debugId` when using `AgentSelect`:

```tsx
<AgentSelect debugId="create-task-assignee-select" ... />
```

### Adding new elements

When adding any new interactive element to the UI:

1. Choose an ID following the naming convention above.
2. Add `data-debug-id="your-id"` to the element.
3. Add the ID to the relevant row in the per-component registry table above.

## Wrapper Lifecycle Notes

- Wrapper checks for an exact existing tmux window before registration.
- If the window exists, wrapper prints the tmux location and asks whether to close it.
- Tmux window matching uses exact `list-windows` matching, not fuzzy tmux target matching.
- Wrapper exits if the agent tmux pane disappears.
- Wrapper attempts re-registration and WS reconnect after repeated heartbeat failures, allowing it to survive daemon restarts.
- When creating a new tmux session, wrapper creates the agent window directly and avoids an extra default shell window.

## Task Chain Best Practices

When coordinating a task chain, the designated Coordinator Agent must adhere to the following workflow upon task completion:

1. **Verify All Tasks:** Review the outputs of all individual tasks in the chain to ensure they are fully complete, correct, and work together.
2. **Submit Verifiable Evidence:** When moving the task chain to `completed` (using the `ham-ctl task-chains status --status completed --final-summary "..."` command), the coordinator must provide a comprehensive, high-fidelity final summary. This summary MUST include:
   - **Verifiable Results/Evidence:** Specific outputs, behavior descriptions, or test logs proving correctness.
   - **Git Commits:** The hashes of all commits created or reviewed as part of the task chain.
   - **File Paths:** Precise relative or absolute paths of the files modified or created.
   - **Result Summary:** A concise overview of the accomplishments.
3. **Propose Quality Rating:** Propose a quality rating status of `good` or `bad` for the task chain.
4. **Reasoning:** Provide clear, objective engineering rationale explaining why the chain succeeded (`good`) or if there were critical defects or difficulties encountered (`bad`).
