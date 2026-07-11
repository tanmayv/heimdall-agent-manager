# 08 · HTTP surface and `ham-ctl` after the refactor

Reviewer checklist: API and config work is reviewed against [`10-review-invariants.md`](./10-review-invariants.md), especially `API-*` and `CFG-*` invariants.

## HTTP additions

Existing routes stay; these are new or extended.

### Teams (observability only — no start/stop)

```
GET  /teams                        list teams (optional ?project_id, ?status)
GET  /teams/{team_id}              show team + members
GET  /teams/{team_id}/members      roster with live/idle status
```

There is intentionally no `POST /teams/start` on the main path; team allocation happens during `POST /task-chains`.

### Task chains (extended)

```
POST /task-chains                  {project_id, kind, title?, description?/goal?, wants_vcs?}
                                   → returns chain_id + team_id + workspace_path? + discovery_task_id?
POST /task-chains/{id}/focus       warm-on-focus signal (boots coordinator low-priority)
POST /task-chains/{id}/task-bundles/apply
                                   {template_key, variables?}
                                   → appends a coordinator-selected task bundle to an existing chain
```

Default `POST /task-chains` is active/ready by default: it creates the team, optional workspace, active chain row, and exactly one ready coordinator discovery task. Legacy `scaffold` / `no_scaffold` fields may remain accepted temporarily for compatibility, but clients should not require or send a scaffold in the main creation flow.

Existing `GET /task-chains`, `POST /task-chains/status`, `POST /task-chains/update`, etc. remain available; coordinators use update to rename/refine title/description after discovery.

### VCS workspace

```
GET  /chains/{id}/workspace                    handle + status
GET  /chains/{id}/workspace/diff?file=...      text diff
POST /chains/{id}/workspace/refresh
POST /chains/{id}/workspace/pull-base
GET  /chains/{id}/workspace/merge-preview
POST /chains/{id}/workspace/merge              executes merge (operator-only)
POST /chains/{id}/workspace/archive            {keep: bool}
```

### Chat (chain-scoped)

Messages carry `chain_id`. Handler routes `to=coordinator(chain)` when the origin is `operator@local`.

```
POST /chat send-to-coordinator     {chain_id, body, ...}
GET  /chat inbox                   filters by chain_id when provided
```

### Agent lifecycle (existing, extended payloads)

Heartbeat and register responses gain:

- `team_member_id` (durable team slot identity)
- `team_id`
- `role_key`
- `role_index`
- `agent_instance_id` (runtime route for the team slot; generated as `<role-key>-<role-index+1>@<team-id>` for daemon-created members)
- `chain_id` (current active chain the agent is booted for)
- `workspace_path` (if any)

Team/member routing uses `team_member_id`/`team_id` and the persisted `agent_instance_id`; clients must not infer routing by parsing display names or role strings.

WS `agent_update` event gains `current_task_id`, `state ∈ {live, warming, idle, blocked, shutting_down}`.

### Attention (aggregate)

```
GET  /attention                    aggregated list for operator token
  → { approvals: [...], blocked: [...], merge_decisions: [...] }
```

Powers the UI badge count and the `Needs attention` tab in one call.

## `ham-ctl` command surface

### Additions

```
ham-ctl chains list [--project <id>]
ham-ctl chains show --chain <id>
ham-ctl chains create --project <id> --kind coding [--title "..."] [--description "..."] [--no-vcs]
ham-ctl chains focus --chain <id>              # warm-on-focus signal
ham-ctl chains task-bundle apply --chain <id> --template feature

ham-ctl teams list [--project <id>]            # read-only
ham-ctl teams show --team <id>

ham-ctl workspace show --chain <id>
ham-ctl workspace pull --chain <id>
ham-ctl workspace diff --chain <id> [--file <path>]
ham-ctl workspace merge --chain <id> [--execute]
ham-ctl workspace forget --chain <id> [--keep]

ham-ctl attention list                         # operator convenience
ham-ctl attention approve --item <id> [--body "..."]
ham-ctl attention reject  --item <id> --body "..."
```

### Removals

The following commands are deleted or hidden behind Settings/debug:

```
ham-ctl agents start          — replaced by chains create (team type first)
ham-ctl teams start           — removed; allocation is automatic
```

Wrapper CLI removals:

```
--project-id
```

### `ham-ctl help work-guide`

Prints the long-form task/chain workflow guide. This is what today's `bootstrap_profile_guidance.md` contained; we ship it once as a CLI command instead of duplicating in every bootstrap.

## Config surface (`config.toml`)

### Kept

```toml
[daemon]
bind_host, advertise_host, port, data_dir, wrapper_bin
nudge_* (existing knobs)
startup_stale_after_seconds
team_idle_shutdown_seconds = 1800          # NEW; default 30 min

[wrapper]
daemon_url, credentials_path, agent_name, requested_access_mode
tmux_session, tmux_window_prefix
agent_run_dir                              # still used for non-VCS chains

[wrapper.agent-cmd.<name>]
command, yolo_flags, prompt_flags, starter_prompt
prompt_delivery, prompt_tmux_delay_ms, prompt_tmux_enter
startup_detection.*
models.*

[wrapper.agent-cmd.<name>.bootstrap.AGENTS_MD]
name

[wrapper.agent-cmd.<name>.bootstrap.MEMORY_MD]
name

[wrapper.agent-cmd.<name>.bootstrap.SKILLS]
relative_dir, filename
```

### Removed

```toml
wrapper.project
wrapper.memory_templates
wrapper.default_agent                       # kind decides; default set from Team_Kind_Def
wrapper.agent-cmd.<name>.project
wrapper.agent-cmd.<name>.memory_templates
wrapper.agent-cmd.<name>.bootstrap.<FEATURE>.content
```

Deprecation policy (Task 17):

- Read the deprecated keys during one release cycle.
- Log a `WARN` line once per boot if present.
- Ignore the value.
- Next release: hard error.

## Invariants

- **API-1** `POST /teams/start` does not exist. Team creation only via `POST /task-chains`.
- **API-2** All VCS write endpoints require the operator token; agent tokens can only call read endpoints.
- **API-3** Chat messages from `operator@local` are always routed to the chain's coordinator; the daemon rejects `to = <other agent>` from operator on the main path (settings/debug endpoint exempt).
- **API-4** Normal free-form user contact is coordinator-owned: non-coordinator agents route user-facing communication through the coordinator, while durable structured `Needs attention` prompts remain allowed for approvals/actions.
- **CFG-1** No new `config.toml` key requires per-agent tuning; team-kind defaults cover the common path.
