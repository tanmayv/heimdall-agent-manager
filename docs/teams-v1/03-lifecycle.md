# 03 · Lifecycle (lazy teams, agents, chains, workspaces)

This is the highest-risk delta in the refactor. Read it carefully.

Reviewer checklist: lifecycle work is reviewed against [`10-review-invariants.md`](./10-review-invariants.md), especially `LC-*` invariants.

## Guiding principle

> Teams are records, not processes. Agents are processes that boot when work needs them and shut down when idle.

## State machines

### 3.1 Task chain

Chain state does not gain new values. `completed` is terminal.

```
planning → active → paused → active → …
                        ↘
                         completed  (terminal)
                        ↗
                     abandoned      (terminal)
```

Behavior on entering `completed`:

- If chain has a VCS workspace → emit a `Merge_Decision_Pending` approval item. Team **not** archived yet.
- If chain has no VCS workspace → archive team immediately.

Merge decision is not a chain state; it's an approval on `Needs attention`. See [`04-vcs.md`](./04-vcs.md).

### 3.2 Team instance

```
latent → warming → live → idle → live → idle → …
                                       ↘
                                    archived  (terminal)
```

- **latent** — row exists, no agents booted, no wrappers.
- **warming** — daemon is provisioning at least one agent (e.g. coordinator on chain view focus).
- **live** — at least one agent wrapper is running (heartbeating).
- **idle** — no live wrappers; the team is quiescent but still bootable.
- **archived** — the chain is done (and if VCS, merge decision made). No further boots. Row kept for history.

Transitions:

| From | Event | To |
|---|---|---|
| latent | first agent boot request | warming |
| warming | first wrapper heartbeats | live |
| live | last live wrapper shuts down (idle grace elapsed) | idle |
| idle | any boot trigger fires | warming |
| any | chain reaches `completed` (no VCS) OR merge decision recorded (VCS) | archived |
| any | chain reaches `abandoned` | archived |

### 3.3 Agent (wrapper) within a team

```
missing → booting → live · idle-in-role → shutting-down → missing
                       ↕
                  live · working-on-task
```

- **missing** — no wrapper for this team-member row.
- **booting** — wrapper started via `agents_start_launch`; not yet heartbeating.
- **live · idle-in-role** — wrapper up, no `current_task_id`.
- **live · working-on-task** — wrapper claimed a task via `tasks next` or has been assigned to one.
- **shutting-down** — idle grace elapsed; wrapper being stopped.

## Boot triggers (what starts an agent)

Handled centrally in the nudge scheduler (see 3.6). The scheduler polls; each of these conditions requests a boot:

1. **Task becomes `ready` with a specific assignee agent_instance_id** → boot that agent.
2. **Task becomes `ready` with `assignee_role = <role>`** and no live agent of that role → boot one member with that `role_key`.
3. **Task becomes `review_ready`** → boot the assigned reviewer (or the role-mapped reviewer).
4. **Nudge fires on a stale task** → boot the target of the nudge.
5. **User sends chat message in a chain** (chain view composer or `ham-ctl chat send-to-coordinator`) → boot the coordinator.
6. **User opens the chain view in UI** (warm-on-focus) → boot the coordinator with a low-priority marker.
7. **Agent A sends chat message to agent B on the same team** → boot B.
8. **Task comment mentions an agent** → boot that agent.

Boot request is idempotent: if the agent is already `booting` or `live`, the request is a no-op that touches a `last_needed_at_unix_ms` field to defer shutdown.

## Idle shutdown

- Default grace = **30 minutes** (kind-overridable via `Team_Kind_Def.idle_shutdown_ms`).
- An agent is a shutdown candidate when:
  - `current_task_id IS NULL` and
  - no unread mentions in comments, chats, or nudges targeting it, and
  - `now - last_needed_at_unix_ms > grace`.
- Heartbeats prove liveness only; they do **not** defer idle shutdown by themselves, otherwise a healthy idle wrapper would never age out.
- For wrappers that have not yet received any explicit `last_needed_at_unix_ms` bump, the implementation may use the wrapper startup timestamp as a one-time fallback anchor until the first explicit need signal is recorded.
- Shutdown path: nudge scheduler emits `agent_stop_request` → `agents_stop.handle_agents_stop` runs. Wrapper cleans up its tmux window on exit.
- Persistent state (memory rows, task state, VCS worktree) is untouched.

## Boot budget

- **Cap: 1 concurrent boot per team_instance.** Additional boot requests queue with a 30s stagger between kicks.
- Rationale: model startup + tmux + wrapper + provider auth can spike load; simultaneous boots pile up on the machine.
- Scheduler state: `team_boot_lease[team_instance_id]` with `holder_agent_instance_id` and `acquired_at_unix_ms`; auto-expires after 90s if the boot never becomes `live`.

## Warm-on-focus

- UI sends `POST /chains/{id}/focus` when the user opens a chain view.
- Handler: if `team.status ∈ {latent, idle}`, requests coordinator boot with `priority = low`; otherwise no-op.
- Low priority means: coordinator boot yields to any pending high-priority boot (e.g. a `review_ready` reviewer).
- No response payload; fire-and-forget.

## Chain completion → team archive

The two paths:

### 3.4 Non-VCS chain

```
coordinator writes final summary
  → chain status = completed
  → daemon requests shutdown of all team agents
  → team_instance status = archived (immediate)
  → chain remains queryable; team roster shown as historical
```

### 3.5 VCS-backed chain

```
coordinator writes final summary
  → chain status = completed
  → daemon emits Merge_Decision_Pending approval to operator@local
    (surfaced in Needs attention tab and chain view banner)
  → team remains bootable so operator can ask questions or request rework
  → operator picks one of:
       merge    → daemon surfaces merge command recipe; on operator's
                  confirmation of successful merge, team archives, worktree removed
       keep     → team archives, worktree kept on disk with `heimdall.keep=true` marker
       abandon  → team archives, worktree removed, no merge
```

The **merge itself is not run automatically**. The daemon prints exact `git` / `jj` commands or, at operator's option, offers to run them (still gated by an explicit `Run` click). See [`04-vcs.md`](./04-vcs.md).

## Chain reopen / rework after completion

- Operator can reopen a `completed` chain (moves to `paused` or `active`). This is rare but allowed.
- On reopen, team returns to `idle` (from `archived`) and can be booted lazily again. VCS workspace, if archived, is *not* auto-restored; if kept, resumes as-is.
- Rework triggered by "changes requested" on a task within a completed chain reopens the chain and the task.

## Interaction with existing nudge scheduler

The scheduler in `src/daemon/task_nudge_scheduler.odin` already has a periodic tick over task state. This is the natural place to add boot decisions:

```
tick:
  for chain in active_chains:
    for task in chain.tasks:
      if task.status == "ready":
        ensure_agent(team, task.assignee_role_or_agent, priority = normal)
      if task.status == "review_ready":
        ensure_agent(team, task.reviewer_role_or_agent, priority = high)
      if is_stale(task):
        emit_nudge(target); ensure_agent(team, target)
  for team in warming|live teams:
    for member in team.members:
      if candidate_for_shutdown(member):
        request_shutdown(member)
  process_boot_queue()   # respects boot lease and 30s stagger
```

`ensure_agent`:

1. Look up the durable team-member row by `team_member_id` or by the scoped tuple `(team_id, role_key, role_index)`; direct `agent_instance_id` assignment is accepted only after validating it belongs to the chain's `team_id`.
2. Use the row's persisted `agent_instance_id` for runtime routing. Generated team-member agent IDs are globally unique and stable for the slot: `<role-key>-<role-index+1>@<team-id>` (for example `coder-2@team-abc123`).
3. Route by durable slot identity, not by parsing display/agent strings or by global role lookup; `role_key` is a pool hint, while `team_member_id`/`team_id` identify the durable slot.
4. If agent is `live`, update `last_needed_at_unix_ms` and return.
5. If team_instance is `archived`, refuse.
6. If a boot lease is held, queue this request with the priority.
7. Else acquire lease and call `agents_start_launch` with the resolved provider/tier from `Team_Kind_Def`.

## `current_task_id` bookkeeping

New columns on `agent_instance_records`:

```
current_task_id        TEXT     NULL
current_task_since     INTEGER  DEFAULT 0
last_needed_at_unix_ms INTEGER  DEFAULT 0
```

Hooks:

- On `tasks next` claim → set `current_task_id`, `current_task_since = now`.
- On `tasks done | blocked | later | vote (reviewer)` → clear `current_task_id`.
- On `ensure_agent` call → set `last_needed_at_unix_ms = now`.

Used by:

- Idle shutdown decision (3.5).
- UI live-status column ("what is this agent doing now?").
- WS `agent_update` events (extended payload).

## Failure modes

### Boot failure

- Wrapper reports `startup_blocked` or `startup_failed` in its heartbeat.
- Scheduler detects `startup_status != "ready"` for > `startup_stale_after_seconds` (existing daemon config).
- Scheduler emits a chat notification to the coordinator with the failure metadata (no raw terminal output — see AGENTS.md startup-detection rules).
- Coordinator surfaces to operator via smart-reply card: "coder failed to start — trust prompt in terminal, please approve or reset."

### Repeated boot loop

- If the same `(team, role)` boots and fails 3× within 10 min, the scheduler disables further boot attempts for that role for 15 min and emits an operator alert.

### Idle shutdown race with new work

- If a task becomes `ready` while the wrapper is `shutting-down`, the boot request is queued behind the shutdown. Scheduler must wait for `missing` before re-booting.

## Order of operations at chain create

Default chain creation is team-type-first and active-ready by default:

```
POST /task-chains {project_id, kind, title?, description?/goal?, wants_vcs?}
  1. Validate kind against Team_Kind_Def registry.
  2. Insert team_instance(row, status=latent).
  3. Insert team_member rows (one per role slot × count), agent_record_id=NULL.
     For solo: user_proxy member with is_user_proxy=true.
  4. If project.vcs_kind != "none" and wants_vcs: provision VCS workspace (04-vcs.md).
  5. Insert task_chain row with team_id, project_id, vcs_workspace_id?, status=in_progress (active).
     If title is omitted, use a placeholder such as `New coding chain` / `Untitled coding chain`.
  6. Create exactly one initial coordinator discovery task in `ready` state.
  7. Return chain_id + team_id + workspace_path (if any) + discovery task id.
```

The initial discovery task is assigned to the chain coordinator and asks them to contact the user in chain chat, clarify the goal, explain the selected team kind/roles, update chain title/description once clear, and create downstream tasks or apply a task-bundle template.

At this point the scheduler has a concrete `ready` coordinator task, so coordinator boot is deterministic and does not rely on a separate `Start team` action. Legacy create-time `scaffold` fields may be accepted as compatibility shims, but default creation does not generate a full task graph.
