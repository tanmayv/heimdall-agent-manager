# Heimdall AI Manager Project Guide

Heimdall is a local multi-agent orchestration system built around four runtime pieces:

- `ham-daemon` — the durable control plane and HTTP/WS server
- `ham-wrapper` — the tmux-backed agent launcher/runtime shim
- `ham-ctl` — the CLI used by operators, agents, and tests
- Heimdall UI — the Electron/Vite/React/Redux desktop client

The daemon owns durable state, runtime routing, and notification fanout. Wrappers boot agents, register them, generate bootstrap files, and keep heartbeats/activity flowing back to the daemon. CLI and UI mostly fetch durable state over HTTP/REST/RPC. Agent-facing WebSockets are primarily event/summary channels: messages and chat do **not** stream full inbox bodies over WS, and agents/UI fetch the durable records after notification.

## Architecture Invariants

- The daemon is the source of truth for durable task, memory, project, team, VCS, artifact, auth, and agent-identity state.
- Runtime sockets, live wrapper status, and user WebSocket connections are in-memory projections rebuilt on restart.
- `agent_id` is the durable identity tier; `agent_instance_id` is the concrete running/project-bound instance.
- Wrapper bootstrap files (`AGENTS.md` / `CLAUDE.md`, optional skills files, manifest) are generated from daemon state, not handwritten per run.
- Agent inbox/chat WebSockets are metadata-only notification channels; task/lifecycle UI notifications may embed compact task/chain payloads, but durable state still lives behind REST/RPC/CLI fetches.

## Identity Model

- `agent_id`
  - Durable identity shared across projects and runs.
  - Stored in `src/daemon/agent_id_store.odin` as `Agent_Id_Record`.
- `agent_instance_id`
  - Concrete instance/session identity, often `agent_id@project-or-scope`.
  - Stored durably as `Agent_Instance_Record`, mirrored live in `Agent_Record`.
- `conversation_id`
  - Agent-to-agent inbox/message stream key.
- `client_instance_id`
  - Durable user-client/UI identity for `/user-client/register`, `/user-rpc`, and `/user-ws`.
- `agent_token`, `client_token`
  - Random bearer tokens persisted in `auth/tokens.db` and recovered after daemon restart.
- `ws_token`, `reconnect_token`
  - Wrapper/WebSocket session credentials returned by `/register` / `/reconnect`.

## Root Files

- `flake.nix`
  - Nix flake defining build packages/apps such as `ham-daemon`, `ham-wrapper`, `ham-ctl`, and UI packaging.
- `package.json`
  - Electron/Vite/React/TypeScript UI package scripts and dependencies.
- `config.toml`
  - Main runtime config for daemon, wrapper, providers, model tiers, startup/activity detection, guide agent, managed run dirs, and ctl defaults.
- `README.md`
  - High-level project overview.
- `docs/teams-v1/`
  - Current chain/team/VCS/bootstrap lifecycle design docs.
- `AGENTS.md`
  - This architecture/bootstrap guide.

## Source Layout

```text
src/
  contracts/          shared protocol/data contracts
  ctl/                ham-ctl CLI
  daemon/             ham-daemon server, stores, services, notifications
  lib/
    config/           config parser/defaults
    http_client/      local HTTP client helpers
    message_provider/ agent-to-agent message provider interface + impl
    router_envelope/  router envelope helpers
    tmux/             tmux launch/control helpers
    vcs/              git/jj workspace helpers
    ws/               WebSocket client helpers
  prompts/            bootstrap/profile/persona/task-chain guidance text
  test_agent/         smoke-test agent helpers
  ui/                 Electron/Vite/React/Redux app
  wrapper/            ham-wrapper runtime/bootstrap generator
```

## Package Summaries

### `src/contracts`

Shared contracts used across binaries.

- `identity.odin`
  - Core identity/token types such as `Agent_Instance_ID`, `Conversation_ID`, `Ws_Token`, and `Agent_Token`.
- `lifecycle.odin`
  - `/register` and `/reconnect` request/response types, including `conversation_id`, `ws_url`, `ws_token`, and `agent_token`.
- `protocol.odin`
  - Base protocol constants (`/health`, `/register`, `/heartbeat`, `/ws`, `/agent-rpc`, `/agents/start`).
- `messages.odin`
  - Agent WS/message event types such as `Messages_Available` and `Messages_Read`.
- `message_provider.odin`
  - Shared `Message`, status/read receipt, fetch, unread-count, and mark-read contracts.
- `memory_provider.odin`
  - Shared `Memory_Record`, `Memory_Event`, type/status enums, and replay/list/history contracts.
- `artifacts.odin`
  - Artifact metadata types, supported kinds, and artifact routes.

`src/contracts/agent_rpc.odin` still covers the minimal shared agent RPC surface. Modern task/chat/memory/project/team flows also go through daemon REST endpoints and `/user-rpc`; do not treat `agent_rpc.odin` as the whole product surface.

### `src/daemon`

The `ham-daemon` package. It is both the runtime hub and the persistence boundary.

Key responsibilities:

- HTTP server and route dispatch (`server.odin`, `rest_router.odin`, `*_http.odin`, `*_rest.odin`)
- Wrapper lifecycle: `/register`, `/heartbeat`, `/startup`, `/ws`, `/agents/start`, `/agents/stop`
- Agent runtime registry and lifecycle notifications (`registry.odin`, `agent_runtime_tracker.odin`, `agent_lifecycle_notifications.odin`)
- Task chains/tasks/comments/votes/participants, projections, review routing, nudge scheduling, and durable notification outbox (`task_*.odin`)
- User/agent chat plus approvals (`chat_*.odin`, `message_db_service.odin`, `user_rpc.odin`, `user_ws.odin`)
- Durable memory proposal/approval pipeline (`memory_*.odin`)
- Projects/teams/VCS/artifacts/auth/preferences/audit (`project_store.odin`, `team_*.odin`, `vcs_*.odin`, `artifact_*.odin`, `0_auth_db_service.odin`, `user_pref_db_service.odin`, `audit_db_service.odin`)
- Hub/router scaffolding and guide/test services (`hub_*`, `router_*`, `guide_*`, `test_run.odin`)

### `src/wrapper`

The `ham-wrapper` package. It turns a daemon-issued start request into a managed tmux session.

Key responsibilities:

- Resolve provider profile / model tier / run directory / project context
- Register with daemon and receive `conversation_id`, `agent_token`, and WS info
- Generate managed bootstrap files (`AGENTS.md` or `CLAUDE.md`, optional `MEMORY.md`, skills files, `.heimdall-bootstrap-manifest`)
- Launch the real agent command in tmux
- Run startup detection and activity detection without persisting raw terminal transcripts
- Maintain WebSocket connection, heartbeat loop, and startup/activity status reporting
- Recover from daemon restarts via re-registration / WS reconnect logic

### `src/ctl`

The `ham-ctl` CLI used by both humans and agents.

Current command families are much broader than the original POC:

- `health`
- `agents ...`
- `send`, `inbox`
- `tasks ...`, `task-chains ...`
- `projects ...`, `teams ...`, `workspace ...`, `chains ...`, `attention`
- `memory ...`
- `users ...`, `chat ...`
- `artifacts ...`
- `start-success`
- `help work-guide`

### `src/ui`

The Heimdall desktop UI.

- Electron shell in `src/ui/electron`
- HTTP API client in `src/ui/api/daemonApi.ts`
- Redux slices in `src/ui/store/*`
- React components in `src/ui/components/*`
- Exposes/consumes the debug-element surface used by the Electron debug API
- Uses `/user-client/register`, `/user-ws`, REST reads, and `/user-rpc` mutations for most interactive flows

### `src/lib`

Shared libraries used by daemon/wrapper/ctl.

- `config` — config structs/defaults/parser for daemon data dirs, wrapper launch/bootstrap settings, provider/model tiers, startup/activity detection, guide agent, and ctl defaults
- `http_client` — local daemon HTTP calls
- `message_provider` — agent-to-agent provider interface plus current in-memory implementation
- `router_envelope` — router envelope helpers
- `tmux` — tmux lifecycle helpers
- `vcs` — git/jj workspace helpers
- `ws` — wrapper-side WebSocket client

## Core Data Structures and Stores

### Identities and auth

- `Agent_Id_Record`
  - Durable identity: display name, template, role, default provider, default tier, state.
  - Append-only JSONL store in `src/daemon/agent_id_store.odin`.
- `Agent_Instance_Record`
  - Durable instance binding: `agent_instance_id`, `agent_id`, provider, project, run dir, tier, scope, role, current task timestamps.
  - Append-only JSONL store in `src/daemon/agent_store.odin`.
- `Agent_Record`
  - In-memory runtime/session projection: live socket, heartbeat, tmux pane, pid, startup/activity state, provider cache.
  - Lives in `src/daemon/registry.odin`.
- Auth tokens
  - `agent_token` and `client_token` are persisted in SQLite (`src/daemon/0_auth_db_service.odin`) and recovered across daemon restarts.

### Tasks, chains, comments, votes, and participants

Defined primarily in `src/daemon/task_store.odin`.

- `Task_Chain_State`
  - Durable chain projection: project/team/workspace ids, title/description, coordinator, default reviewer, final summary, archive/evaluation flags.
- `Task_State`
  - Durable task projection: title, description, acceptance criteria, assignee, dependencies, timestamps, status.
- `Task_Event`
  - Event log record for task/chain mutations, comments, votes, status changes, nudges, archive events, and final summary.
- `Task_Participant`
  - Extra role membership beyond the primary assignee/coordinator/default reviewer.
  - Roles include `assignee`, `coordinator`, `lgtm_required`, `lgtm_optional`, and `subscriber`.
- `Task_Comment_State`
  - Durable comments with `resolved` state.
- `Task_LGTM_Vote_State`
  - Durable reviewer vote state (`approved`, role, comment, timestamp).
- Task statuses
  - Core task states are `planning`, `queued`, `in_progress`, `review_ready`, `approved`, `blocked`, and `cancelled`.
  - `ready` is accepted as a CLI/HTTP alias for `queued`.
- Storage model
  - Tasks are event-shaped and projected into in-memory arrays plus SQLite tables (`task_db_service.odin`).
  - The daemon also keeps a durable task notification outbox for retryable per-agent notifications.

### Agent-to-agent inbox messages

- Shared wire/data types live in `src/contracts/message_provider.odin`:
  - `Message`, `Message_Status`, `Message_Direction`, `Send_Message_Request`, `Fetch_Messages_Request`, `Mark_Read_Request`, read receipts.
- The provider interface lives in `src/lib/message_provider/provider.odin`.
- The current default provider implementation is `src/lib/message_provider/memory.odin`.
  - This is a **real** provider, but it is process-memory only today.
  - That is separate from user/agent chat, which is durable.

### User/agent chat

Defined in `src/daemon/chat_store.odin` and `message_db_service.odin`.

- `Chat_Event`
  - Append/delivered/read/failure events for human↔agent chat.
- `Chat_Message`
  - Durable SQLite row keyed by `message_id`, `user_id`, `agent_instance_id`, direction, body, chain id, delivery/read timestamps, and failure info.
- Read state
  - Stored durably per conversation/direction in the chat DB and exposed through `/user-rpc`, `/chats/...`, and UI slices.

### Memory

Defined by `src/contracts/memory_provider.odin` and implemented by `src/daemon/memory_*.odin`.

- `Memory_Record`
  - Durable current record.
- `Memory_Event`
  - Durable proposal/approval/rejection/archive history.
- Types
  - `fact`, `habit`, `episode`, `expertise`, `skill`, `template`.
- Statuses
  - `pending`, `active`, `archived`, `rejected`.
- Targeting dimensions
  - `target_agent_id`, `target_team_kind`, `target_role`, `target_project_id`.
- Storage
  - SQLite in `memory/memory.db` with event history and applicable-memory queries.

### Projects, teams, VCS workspaces, and artifacts

- `Project_Record`
  - Durable project metadata plus loose anchors (`type`, `value`, `note`).
  - Append-only JSONL store in `src/daemon/project_store.odin`.
- `Team_Record` / `Team_Member_Record`
  - Durable chain team and roster records in `teams/teams.db`.
  - Team members can be generated agents or `user_proxy` slots with `route_to` metadata.
- `Vcs_Workspace_Record`
  - Durable workspace handle in `vcs/vcs.db`: project, chain, path, base ref, branch/change, status, keep-on-archive.
- `Artifact_Record`
  - Durable artifact metadata in `artifacts/artifacts.db`; blob bytes live under the artifact blob store.

### Bootstrap artifacts

Generated by `src/wrapper/main.odin`.

- Managed files can include `AGENTS.md`, `CLAUDE.md`, `MEMORY.md`, and per-skill `SKILL.md` files under directories such as `.agents/skills/` or `skills/`.
- The wrapper writes `.heimdall-bootstrap-manifest` so it can clean up only files it previously managed.
- Bootstrap content is assembled from live identity data, project/team/chain/workspace context, active approved memories/templates, and agent template persona/instructions.

## Persistence Model

Heimdall is **not** an in-memory-only system.

Current storage is mixed by subsystem:

- SQLite: auth tokens, tasks/projections/outbox, chat/messages, memory, teams, VCS workspaces, artifacts, preferences, audits
- JSONL append-only stores: durable agent identities/instances, projects, some legacy/migration paths
- In-memory runtime projections: live wrapper registry, active sockets, pending WS connections, provider-memory agent inbox implementation

A good rule of thumb: durable business state lives on disk; live transport/session state stays in memory.

## Runtime Data Flow

### 1. Agent start and bootstrap generation

1. `ham-ctl agents start ...` or UI start action sends `POST /agents/start`.
2. The daemon validates/provider-resolves the request, upserts durable agent identity state, and launches `ham-wrapper` detached.
3. The wrapper calls `/health`, then `/register`.
4. The daemon returns `agent_instance_id`, `conversation_id`, WS info, `agent_token`, template persona/instructions, and team-role context.
5. The wrapper optionally validates project context, fetches applicable memories/project/team/chain/workspace state, writes managed bootstrap files, and launches the real agent command in tmux.
6. The wrapper reports startup status, heartbeats, and activity snapshots; the agent later signals `start-success` through `ham-ctl ... start-success`.

### 2. Agent-to-agent inbox messaging

1. Agent CLI/RPC sends a message through `/agent-rpc`.
2. `message_service.odin` routes through the configured message provider and emits message-bus events.
3. The daemon sends a metadata-only `messages_available` WS event to the target agent, including `conversation_id`, sender, and `pending_count`.
4. The target agent fetches actual bodies through inbox/fetch RPC/CLI.
5. Read events produce `messages_read` notifications back to the sender.

### 3. User ↔ agent chat

1. The UI registers a `client_instance_id` and `client_token` via `/user-client/register`, heartbeats via `/user-client/heartbeat`, and opens `/user-ws/<client_instance_id>`.
2. Human sends use `/user-rpc action=send_to_agent`; agent sends use `chat send-to-user` / chat HTTP helpers.
3. Chat bodies are stored durably in the chat/message SQLite store.
4. WS `chat_event` fanout tells the UI/user client that a conversation changed and carries metadata such as `message_id`, direction, chain id, and unread count.
5. UI/CLI fetch full bodies through `/chats/...` or `/user-rpc fetch_chat`, and mark read via `/user-rpc mark_read`.

### 4. Task lifecycle and review routing

1. Task and chain mutations append `Task_Event` records.
2. Projections update `Task_State`, `Task_Chain_State`, comments, participants, and votes.
3. Automatic gating promotes tasks from `planning` to `queued`, then to `in_progress` when the assignee is free.
4. `tasks done` moves a task to `review_ready`; required `lgtm_required` votes auto-approve it.
5. Notification routing is status-aware:
   - `queued` / `in_progress` → assignee (+ subscribers)
   - `review_ready` → required reviewers with fallback routing
   - `approved` / `blocked` / `cancelled` → assignee + coordinator (+ subscribers)
   - review-ready comments are not themselves a reviewer broadcast; nudges and status ownership determine who gets pinged live
6. User-facing task WS events can include embedded task/chain snapshots, while agent-facing notifications stay lightweight summaries.
7. If live delivery fails, the daemon queues a durable notification outbox entry for replay.

### 5. Memory lifecycle

1. Agents or users propose memory changes (`new`, `edit`, `archive`, `rollback`).
2. Proposal records are stored as `pending`.
3. Approval promotes the proposed memory to `active` (or archives/replaces the target on edit/archive/rollback flows).
4. Wrapper bootstrap generation calls `/memory/applicable` to pull only active memories/templates relevant to the current agent/team/role/project scope.

### 6. Project / team / VCS / artifact lifecycle

- Projects are durable metadata records with loose anchors; they are hints, not mandatory cwd bindings.
- Creating chains can allocate a team, generated roster, optional VCS workspace setup tasks, and workspace records.
- VCS endpoints under `/chains/{id}/workspace...` expose status, diff, pull-base, merge-preview, merge, and archive flows.
- Completing a VCS-backed chain can leave a workspace `merge_pending` until the merge/keep/archive decision is resolved.
- Artifact metadata is stored durably; blobs are served separately via artifact content routes.

## Current Control / Launch Model

Default config path:

```text
~/.config/heimdall/config.toml
```

Pass `--config <path>` to override.

### Agent command profiles

`config.toml` supports multiple wrapper agent command profiles, each with command args, model-tier mapping, bootstrap feature settings, startup/activity detection, and prompt-delivery behavior.

Example knobs that exist today:

- `wrapper.default_agent`
- `wrapper.agent_run_dir`, `wrapper.use_random_dir`
- per-profile `command`, `prompt_flags`, `yolo_flags`, `starter_prompt`
- per-profile `models.{cheap,normal,smart}`
- per-profile bootstrap feature blocks such as `bootstrap.AGENTS_MD`, `bootstrap.MEMORY_MD`, and `bootstrap.SKILLS`
- per-profile `startup_detection` and `activity_detection`
- guide-agent defaults under `[guide_agent]`

### Startup detection

Wrappers can classify startup without persisting raw transcripts.

Per-profile startup detection can:

- probe a bounded tmux capture window in memory
- auto-press safe keys for known prompts
- classify `starting`, `ready`, `startup_blocked`, `startup_failed`, or `startup_unknown`
- report only sanitized diagnostics back to the daemon

### `ham-ctl` command families

Run `ham-ctl --help` for the current surface. Important families include:

```bash
ham-ctl agents list|start|create|update
ham-ctl send|inbox
ham-ctl tasks ...
ham-ctl task-chains ...
ham-ctl projects ...
ham-ctl teams ...
ham-ctl workspace ...
ham-ctl memory ...
ham-ctl users ...
ham-ctl chat ...
ham-ctl artifacts ...
ham-ctl help work-guide
```

### Daemon-managed agent start

All managed launches go through the daemon. `ham-ctl` or the UI does **not** spawn wrappers directly for normal operation; it requests `POST /agents/start`, and the daemon launches `ham-wrapper` on the daemon host.

## Token Model

Agent and user tokens are random bearer tokens persisted by the auth DB.

Do **not** assume deterministic formats such as `agent_<agent_instance_id>`.

Examples:

```json
{"agent_token":"agt_<random-hex>"}
{"client_token":"uct_<random-hex>"}
```

For daemon-launched wrappers, the daemon may pre-generate the agent token, return it to ctl/UI, and pass it to the wrapper so the wrapper registers using the same durable credential.

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
| `HomePage` | `home-new-chain-btn`, `home-new-project-btn`, `home-chain-row-${chainId}`, `home-chain-open-btn-${chainId}`, `home-project-new-chain-btn-${projectId}`, `home-running-agents-panel`, `home-running-agents-refresh-btn`, `home-running-agents-list`, `home-running-agent-${agentId}`, `home-running-agent-chat`, `home-running-agent-chat-title`, `home-running-agent-chat-status`, `home-running-agent-chat-scroll`, `home-running-agent-chat-composer-shell`, `home-running-agent-chat-input`, `home-running-agent-chat-send-error`, `home-running-agent-chat-upload-error`, `home-running-agent-chat-send-btn`, `home-running-agent-chat-artifact-upload-button`, `home-agent-picker`, `home-http-load-evidence`, `home-periodic-evidence`, `home-ws-evidence`, `home-local-action-evidence` |
| `AttentionPage` | `attention-approval-${itemId}-approve-btn`, `attention-approval-${itemId}-reject-btn`, `attention-blocked-${taskId}-message-btn`, `attention-blocked-${taskId}-open-btn`, `attention-merge-${chainId}-merge-btn`, `attention-merge-${chainId}-keep-btn`, `attention-merge-${chainId}-abandon-btn`, `attention-merge-${chainId}-show-diff-btn` |
| `Sidebar` | `nav-home-btn`, `nav-attention-btn`, `nav-memory-btn`, `nav-agents-btn`, `nav-task-chains-btn`, `nav-projects-btn`, `nav-settings-btn`, `conversation-sidebar-collapse-btn`, `conversation-sidebar-expand-btn`, `conversation-collapsed-nav`, `nav-${itemId}-collapsed-btn`, `conversation-focused-sidebar`, `conversation-active-chains`, `conversation-sidebar-chain-${chainId}`, `sidebar-durable-agents`, `sidebar-agent-group-${agentId}`, `sidebar-agent-group-open-btn-${agentId}`, `sidebar-agent-new-instance-btn-${agentId}`, `sidebar-agent-status-${agentId}`, `sidebar-agent-status-label-${agentId}`, `sidebar-conversations-paged-list`, `sidebar-conversations-show-more-btn`, `sidebar-conversations-loading`, `sidebar-agents-paged-list`, `sidebar-agents-show-more-btn`, `sidebar-agents-loading`, `sidebar-agent-instances-panel`, `sidebar-agent-instances-title-${agentId}`, `sidebar-agent-instances-close-btn`, `sidebar-agent-instances-empty`, `sidebar-agent-instance-row-${agentInstanceId}`, `sidebar-agent-instance-status-${agentInstanceId}`, `sidebar-agent-instance-status-label-${agentInstanceId}`, `sidebar-conversations`, `sidebar-new-conversation-btn`, `sidebar-new-conversation-collapsed-btn`, `conversation-thread-${agentId}`, `conversation-thread-open-btn-${agentId}`, `conversation-thread-status-${agentId}`, `conversation-thread-status-label-${agentId}`, `sidebar-agent-launch-btn`, `sidebar-agent-launch-name-input`, `sidebar-agent-launch-role-input`, `sidebar-agent-launch-provider-select`, `sidebar-agent-launch-project-select`, `sidebar-agent-launch-tier-select`, `sidebar-agent-launch-save-defaults-label`, `sidebar-agent-launch-save-defaults-checkbox`, `sidebar-agent-launch-submit-btn`, `sidebar-agent-launch-cancel-btn`, `sidebar-agent-launch-progress`, `sidebar-agent-launch-done-btn`, `sidebar-agent-launch-new-btn`, `sidebar-agent-picker-close-btn`, `sidebar-agent-${agentId}`, `sidebar-chain-list`, `sidebar-chain-${chainId}`, `sidebar-new-chain-btn` |
| `AgentsManagementSurface` | `agents-management-surface`, `agents-management-back-btn`, `agents-management-create-card`, `agents-management-list`, `agents-management-agent-${agentId}`, `agents-management-edit-btn-${agentId}`, `agents-management-new-instance-btn-${agentId}`, `agents-management-instance-btn-${agentInstanceId}` |
| `TaskChainsSurface` | `task-chains-surface`, `task-chains-back-btn`, `task-chains-new-btn`, `task-chains-active-list`, `task-chains-active-row-${chainId}`, `task-chains-completed-list`, `task-chains-completed-row-${chainId}` |
| `ProjectsSurface` | `projects-surface`, `projects-back-btn`, `projects-new-btn`, `projects-list`, `projects-row-${projectId}`, `projects-open-btn-${projectId}`, `projects-new-chain-btn-${projectId}` |
| `ChainView` | `chain-view`, `chain-back-btn`, `chain-workspace-btn`, `chain-open-editor-btn`, `chain-tasks-toggle-btn`, `chain-split-view`, `chain-coordinator-panel`, `chain-coordinator-live-status`, `chain-coordinator-composer-shell`, `chain-coordinator-composer-input`, `chain-coordinator-send-btn`, `chain-progress-panel`, `chain-progress-bar`, `chain-progress-complete-count`, `chain-progress-active-count`, `chain-progress-review-count`, `chain-progress-blocked-count`, `chain-task-surface`, `chain-task-count`, `chain-task-list-active`, `chain-task-list-completed`, `chain-task-row-${taskId}`, `chain-task-row-${taskId}-open-btn`, `chain-task-row-${taskId}-expand-btn`, `chain-task-row-${taskId}-title`, `chain-task-row-${taskId}-status`, `chain-task-row-${taskId}-agents`, `chain-task-assignee-${agentId}`, `chain-task-reviewer-${agentId}`, `task-detail-actions-${taskId}`, `task-detail-description-${taskId}`, `task-detail-votes-${taskId}`, `task-detail-comments-${taskId}`, `task-detail-comment-textarea-${taskId}`, `task-detail-comment-submit-btn-${taskId}`, `task-detail-assignee-picker-btn-${taskId}`, `task-detail-reviewer-picker-btn-${taskId}`, `task-agent-picker-close-btn`, `task-assignee-agent-picker`, `task-reviewer-agent-picker`, `task-detail-status-done-btn-${taskId}`, `task-detail-status-block-btn-${taskId}`, `task-detail-status-later-btn-${taskId}`, `task-detail-status-cancel-btn-${taskId}`, `task-detail-status-start-btn-${taskId}`, `task-detail-vote-lgtm-btn-${taskId}`, `task-detail-vote-ngtm-btn-${taskId}`, `task-detail-nudge-textarea-${taskId}`, `task-detail-nudge-btn-${taskId}`, `chain-workspace-row`, `chain-http-load-evidence`, `chain-ws-evidence`, `chain-local-action-evidence` |
| `GuideSidePanel` | `guide-side-panel`, `guide-side-panel-agent`, `guide-side-panel-status-dot`, `guide-side-panel-status`, `guide-side-panel-close-btn`, `guide-debug-toggle-btn`, `guide-current-page-send-btn`, `guide-debug-info`, `guide-chat-composer-shell`, `guide-chat-composer-input`, `guide-chat-send-btn`, `guide-chat-artifact-upload-btn`, `guide-chat-artifact-upload-input`, `guide-chat-upload-error` |
| `AgentDetailPage` | `agent-detail-page`, `agent-detail-back-btn`, `agent-detail-title`, `agent-detail-live-status`, `agent-detail-all-instances-btn`, `agent-detail-start-btn`, `agent-detail-stop-btn`, `agent-detail-edit-btn`, `agent-detail-delete-btn`, `agent-detail-action-error`, `agent-detail-stop-progress`, `agent-detail-stop-progress-bar`, `agent-detail-stop-step-${stepKey}`, `agent-detail-stop-progress-dismiss-btn`, `agent-detail-edit-close-btn`, `agent-detail-edit-name-input`, `agent-detail-edit-provider-select`, `agent-detail-edit-project-select`, `agent-detail-edit-tier-select`, `agent-detail-edit-cancel-btn`, `agent-detail-edit-save-btn`, `agent-detail-project`, `agent-detail-role`, `agent-detail-provider`, `agent-detail-runtime`, `agent-detail-chat`, `agent-detail-refresh-chat-btn`, `agent-detail-chat-composer-shell`, `agent-detail-chat-input`, `agent-detail-nudge-btn`, `agent-detail-chat-send-btn`, `agent-detail-tasks`, `agent-detail-task-${taskId}`, `agent-detail-task-open-btn-${taskId}`, `agent-detail-task-title-${taskId}`, `agent-detail-task-status-${taskId}`, `agent-detail-task-meta-${taskId}`, `agent-detail-task-description-${taskId}`, `agent-detail-task-open-chain-${taskId}`, `agent-detail-memory`, `agent-detail-memory-refresh-btn`, `agent-detail-memory-add-btn`, `agent-detail-memory-item-${memoryId}`, `agent-detail-memory-edit-btn-${memoryId}`, `agent-memory-editor`, `agent-memory-editor-body-vim-edit-btn`, `agent-memory-editor-close-btn`, `agent-memory-editor-type-select`, `agent-memory-editor-title-input`, `agent-memory-editor-body-textarea`, `agent-memory-editor-evidence-input`, `agent-memory-editor-cancel-btn`, `agent-memory-editor-save-btn` |
| `AgentIdentityPage` | `agent-identity-page`, `agent-identity-breadcrumb`, `agent-identity-back-btn`, `agent-identity-edit-btn`, `agent-identity-new-instance-btn`, `agent-identity-summary`, `agent-identity-title`, `agent-identity-instance-count`, `agent-identity-template`, `agent-identity-default-project`, `agent-identity-provider-tier`, `agent-identity-memory-summary`, `agent-instance-list`, `agent-instance-group-running`, `agent-instance-group-recent`, `agent-instance-group-stopped`, `agent-instance-row-${agentInstanceId}`, `agent-instance-status-${agentInstanceId}`, `agent-instance-id-${agentInstanceId}`, `agent-instance-context-${agentInstanceId}`, `agent-instance-open-btn-${agentInstanceId}`, `agent-instance-resume-btn-${agentInstanceId}` |
| `NewConversationPage` | `new-conversation-page`, `new-convo-breadcrumb`, `new-convo-back-btn`, `new-convo-project-select`, `new-convo-title`, `new-convo-subtitle`, `new-convo-suggestion-grid`, `new-convo-option-ask-btn`, `new-convo-option-open-chain-btn`, `new-convo-option-pick-agent-btn`, `new-convo-option-plan-work-btn`, `new-convo-composer-shell`, `new-convo-input`, `new-convo-error`, `new-convo-progress`, `new-convo-agent-select`, `new-convo-provider-select`, `new-convo-tier-select`, `new-convo-send-btn` |
| `ConversationThreadPage` | `conversation-thread-page`, `conversation-thread-back-btn`, `conversation-thread-breadcrumb`, `conversation-thread-title`, `conversation-thread-project-chip`, `conversation-thread-status-chip`, `conversation-thread-refresh-btn`, `conversation-thread-start-btn`, `conversation-thread-stop-btn`, `conversation-thread-action-error`, `conversation-thread-transcript`, `conversation-thread-worked-status`, `conversation-thread-message-${messageId}`, `conversation-thread-message-actions-${messageId}`, `conversation-thread-message-copy-btn-${messageId}`, `conversation-composer-shell`, `conversation-composer-input`, `conversation-composer-send-error`, `conversation-composer-upload-error`, `conversation-composer-starting-indicator`, `conversation-tier-select`, `conversation-composer-send-btn`, `conversation-attach-button`, `conversation-attach-input` |
| `ChainWorkspaceBox` | `workspace-refresh-btn`, `workspace-pull-base-btn`, `workspace-preview-merge-btn`, `workspace-file-${slug}`, `workspace-show-diff-btn`, `workspace-diff-file-select`, `workspace-copy-diff-btn`, `workspace-ask-coordinator-btn` |
| `NewChainModal` | `new-chain-project-select`, `new-chain-title-input`, `new-chain-goal-textarea`, `new-chain-kind-select`, `new-chain-scaffold-select`, `new-chain-vcs-checkbox`, `new-chain-coordinator-select`, `new-chain-cancel-btn`, `new-chain-submit-btn` |
| `NewProjectModal` | `new-project-name-input`, `new-project-description-textarea`, `new-project-repo-input`, `new-project-vcs-select`, `new-project-cancel-btn`, `new-project-submit-btn` |
| `SettingsPage` | `settings-modal`, `settings-rail`, `settings-body`, `settings-close-btn`, `settings-single-daemon-note`, `settings-nav-${key}`, `settings-nav-daemon`, `settings-nav-providers`, `settings-daemon-single-active-banner`, `settings-daemon-list`, `settings-daemon-row-${daemonKey}`, `settings-daemon-reconnect-btn-${daemonKey}`, `settings-daemon-remove-btn-${daemonKey}`, `settings-daemon-url-input`, `settings-daemon-label-input`, `settings-daemon-user-input`, `settings-daemon-add-btn`, `settings-debug-server-checkbox`, `settings-providers-single-daemon-banner`, `settings-providers-daemon-select`, `settings-providers-list`, `settings-provider-card-${providerName}`, `settings-provider-default-btn-${providerName}`, `settings-default-agent-provider-select`, `settings-default-agent-tier-select`, `settings-default-agent-save-btn`, `settings-back-btn`, `settings-create-agent-btn`, `settings-create-agent-modal`, `settings-create-agent-name-input`, `settings-create-agent-template-select`, `settings-create-agent-provider-select`, `settings-create-agent-tier-select`, `settings-create-agent-cancel-btn`, `settings-create-agent-cancel-secondary-btn`, `settings-create-agent-submit-btn`, `settings-create-agent-error`, `settings-direct-chat-agent-select`, `settings-direct-chat-feed`, `settings-direct-chat-composer-shell`, `settings-direct-chat-input`, `settings-direct-chat-send-btn` |
| `SessionConfig` | `session-config-reconnect-btn`, `session-config-daemon-url`, `session-config-user-id` |

### Shared component: AgentSelect

`AgentSelect` accepts an optional `debugId` prop that maps directly to `data-debug-id` on the underlying `<select>`. Always pass `debugId` when using `AgentSelect`:

```tsx
<AgentSelect debugId="create-task-assignee-select" ... />
```

### Shared component: AgentPicker

`AgentPicker` accepts a required `debugId` prop and derives child IDs from it: `${debugId}-search-input`, `${debugId}-agent-grid`, `${debugId}-agent-card-${agentId}`, `${debugId}-agent-run-${agentId}`, `${debugId}-run-id-input`, `${debugId}-run-submit-btn`, `${debugId}-create-id-input`, and `${debugId}-create-submit-btn`. Always pass a page-specific `debugId` such as `home-agent-picker`.

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
