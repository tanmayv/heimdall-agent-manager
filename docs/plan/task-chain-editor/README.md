# Task Chain Editor — Design & Backend Plan

A dedicated, full-manual-control editor page for a single task chain.

- **Mockup:** [`mockup.html`](./mockup.html) (open in a browser)
- **Status:** design phase. This doc captures the UI intent and the backend
  gap analysis / required changes.

## Goals

Give an operator complete, direct control over one chain from a single page:

1. **Visualize** the task dependency graph (pan/drag canvas, draggable nodes).
2. **Select a task** node → edit it in a focused editor below the graph.
3. **Edit task fields:** title, description, acceptance criteria, status,
   assignee, reviewer.
4. **Set / unset dependencies** between tasks (graph edges + chip list).
5. **Add / delete tasks.**
6. **Manage the agent roster** defined in the chain: change provider/tier,
   start and stop agents manually.
7. **Chain-level controls:** title, coordinator, default reviewer, pause /
   complete.

Consistent with the recent provider/tier simplification: **provider and model
tier are runtime-only launch inputs.** Changing them in the roster affects the
*next* start; they are not durable per-agent identity fields.

## UX model

- The **graph is the navigator.** There is no long task list; the selected node
  drives a single "Selected task" editor card.
- **Canvas interactions:**
  - drag a node body (left click) to reposition,
  - **shift+left-drag or middle-drag to pan the canvas,**
  - drag from a node's out-port onto another node to add a dependency,
  - click an edge to remove a dependency.
- **Save model:** per-action optimistic writes for status/assignee/reviewer/
  runtime (matches today's task drawer), with a light "unsaved" affordance for
  free-text fields (title/description/acceptance) that flush on blur / explicit
  save.
- **Vim editing:** every long-form field (chain description, task description,
  task acceptance criteria) pairs its textarea with a `VimEditButton`, exactly
  like `agent-memory-editor-body`, `new-chain-goal`, and
  `settings-project-description` do today. The page renders within the existing
  app-level `VimSidebarProvider` so `openVim` is available. `lang="markdown"`;
  `onApply` writes back into the field's local state, then the normal
  save/flush path persists it.
- **Layout persistence:** node x/y positions are editor-only presentation state,
  not chain truth. See open question below on where to persist them.

---

## Backend gap analysis

Legend: ✅ exists and reusable · 🟡 exists but needs extension · ❌ missing.

All task/chain mutations already flow through `/user-rpc` (durable, event-shaped
in `task_store.odin`, projected in `task_projection.odin`). Runtime control flows
through `/agents/start` and `/agents/stop`. Reads exist via REST (`/task-chains`,
`/task-chains/{id}/tasks`, `/tasks/{id}`) and `/teams/{team_id}`.

### Tasks

| Capability | RPC / route | State |
|---|---|---|
| Create task | `task_create` → `task_service_create_task` | ✅ (supports `title`, `description`, `acceptance_criteria`, `status`, `assignee_agent_instance_id`, `depends_on`) |
| Edit title/description | `task_update` → `task_service_update_task` | 🟡 only `title` + `description` today |
| Edit acceptance criteria | — | ❌ not in `Task_Update_Command` / `Task_Metadata_Updated` projection |
| Set/unset dependencies | — | ❌ no update path; `depends_on` is only settable at create |
| Change status | `task_status` → `task_service_status_command` | ✅ (requires non-empty `body`, enforces gating; supports `force`) |
| Assign assignee | `task_assign` → `task_service_assign` | ✅ |
| Set reviewer | `task_participant` / `task_participant_remove` with role `lgtm_required` | ✅ (reviewer = participant; UI already does add+remove) |
| Delete task | — | ❌ no delete event/path. Only `cancelled` status exists |
| Comments / votes / nudge | `task_comment*`, `task_review_vote`, `task_nudge` | ✅ |

### Chain

| Capability | RPC | State |
|---|---|---|
| Update title/coordinator/default reviewer/description | `task_chain_update` → `task_service_update_chain` | ✅ |
| Set chain status (pause/complete) | `task_chain_status` | ✅ |
| Read chain + tasks | `GET /task-chains/{id}`, `.../tasks` | ✅ |

### Roster / runtime

| Capability | RPC / route | State |
|---|---|---|
| Read team roster | `GET /teams/{team_id}` (`fetchTeam`) | ✅ |
| Start agent (with provider/tier override) | `POST /agents/start` (`startAgent`) | ✅ (provider/tier are per-launch overrides after the simplification) |
| Stop agent | `POST /agents/stop` (`stopAgent`) | ✅ |
| Change default provider/tier persistently | `updateAgent` / preferences | 🟡 works but is now largely moot for launch; roster change should just pass override into next `startAgent` |
| Add agent to chain team | `handle_team_add_member` (`/teams/...`) | 🟡 exists; confirm wiring for editor "add agent to chain" |

---

## Required backend changes

Ordered by necessity for the editor MVP.

### 1. Extend task metadata update (acceptance criteria + dependencies) — 🟡→✅

Extend the existing update path rather than adding new event kinds.

- `Task_Update_Command` (`task_commands.odin`): add
  - `acceptance_criteria: string`, `acceptance_criteria_present: bool`
  - `depends_on: string`, `depends_on_present: bool`
- `task_service_update_task` (`task_service.odin`):
  - when `acceptance_criteria_present`, write new value into the
    `Task_Metadata_Updated` event.
  - when `depends_on_present`, **validate** via the existing
    `task_validate_dependency_ids(depends_on, chain_id, self_task_id)` (already
    used at create) — this rejects unknown ids and self-references. Add a
    **cycle check** across the chain's current dependency graph before persist.
- `Task_Event` (`task_store.odin`): `Task_Metadata_Updated` must carry
  `acceptance_criteria` and `depends_on` (fields already exist on the event
  struct; ensure they are serialized/deserialized and applied).
- `task_projection.odin` `case .Task_Metadata_Updated`: apply
  `acceptance_criteria` and `depends_on` (guard with "present"/non-sentinel so a
  metadata-only edit doesn't wipe deps). Recommend an explicit presence signal
  rather than empty-string overwrite, mirroring `description_present`.
- `user_rpc.odin handle_user_rpc_task_update`: parse the new fields using
  `json_has_key` for presence.

**Cycle prevention** is new logic: add
`task_dependencies_would_cycle(chain_id, task_id, depends_on) -> bool` in
`task_service.odin` (DFS over `task_states` filtered by chain). Reject with a
`dependency_cycle` error kind, reusing `task_dependency_validation_error`.

### 2. Task delete — ❌→✅

Add a first-class delete (distinct from `cancelled`, which keeps the row).

- New event kind `Task_Deleted` in `Task_Event_Kind`.
- `task_service_delete_task(task_id, chain_id, author)` in `task_service.odin`:
  - reject if other tasks depend on it **unless** caller also clears those deps
    (return `blocking_dependents` with the ids so the UI can offer "detach &
    delete"). MVP: reject with the dependent ids.
  - append `Task_Deleted`; projection removes it from `task_states`,
    participants, votes, comments, and the SQLite rows
    (`task_db_service.odin`).
- Wire `task_delete` in `user_rpc.odin` + `daemonApi.deleteTask`.

_Alternative if we want an audit-preserving delete:_ soft-delete flag on
`Task_State` + filter in projections/queries. Decision needed (see open
questions).

### 3. Dependency edge convenience RPCs (optional) — sugar over #1

The editor can implement add/remove-edge purely by re-sending the full
`depends_on` via `task_update`. Only add dedicated
`task_add_dependency` / `task_remove_dependency` RPCs if we want smaller,
race-safe patches. **Recommend: skip for MVP**, use full `depends_on` replace
with an `expected_depends_on` optimistic-concurrency guard if races matter.

### 4. Roster "add agent to chain" wiring — 🟡

Confirm `handle_team_add_member` supports adding a generated agent to an
existing chain team from the editor, returning enough for the roster row
(agent_instance_id, role, provider default). Add a `daemonApi.addTeamMember`
helper if missing. No new durable model expected.

### 5. Node layout persistence — decision, possibly ❌

Graph node positions need somewhere to live if we want them to persist:

- **Option A (recommended MVP):** don't persist server-side; store per-chain
  layout in UI local state / localStorage keyed by `chainId`. Zero backend work.
- **Option B:** add a `layout_json` blob to `Task_Chain_State` (new
  `Chain_Metadata_Updated` field) or a small `chain_layout` preference. Only if
  layouts must sync across machines.

---

## No-change / reuse list

- Status changes, assignment, reviewer (participant lgtm_required), comments,
  votes, nudges: **reuse existing RPCs.**
- Chain title/**description**/coordinator/default-reviewer/status: **reuse
  `task_chain_update` / `task_chain_status`** (`task_service_update_chain`
  already accepts `description`). No backend change for chain-description edit.
- Vim editing: **pure UI, no backend change.** Reuse `VimEditButton` /
  `VimSidebarProvider` for chain description, task description, and task
  acceptance criteria.
- Start/stop with provider+tier override: **reuse `/agents/start`,
  `/agents/stop`**; provider/tier are runtime-only per the recent simplification.
- Reads: **reuse REST + `fetchTeam`.**

## Open questions

1. **Delete semantics:** hard delete (`Task_Deleted` removes rows) vs. soft
   delete (flag + filter)? Affects audit/history.
2. **Dependency edits on live tasks:** should adding a dependency to an
   `in_progress`/`approved` task be blocked or allowed with a warning?
3. **Concurrency:** do we need optimistic-concurrency guards
   (`expected_depends_on`, task `version`) for multi-editor safety, or is
   last-write-wins acceptable for a single-operator tool?
4. **Layout persistence:** localStorage (A) vs. durable chain layout (B)?
5. **Status body requirement:** `task_status` requires a non-empty `body`. The
   editor should auto-fill a reason (e.g. "status set via chain editor") or
   prompt — pick one for UX consistency.

## Suggested build order

1. Backend #1 (metadata: acceptance + deps + cycle check) — unblocks most of the
   editor.
2. Backend #2 (task delete).
3. UI `ChainEditor.tsx` + `chainEditorSlice.ts`, route + entry button on
   `ChainView`, debug-id registry row (per `AGENTS.md`). Wire `VimEditButton`
   for chain description (`chain-editor-description-vim-edit-btn`), task
   description (`chain-editor-task-description-vim-edit-btn`), and task
   acceptance criteria (`chain-editor-task-acceptance-vim-edit-btn`).
4. Roster panel wiring (#4) + runtime WS status.
5. Decide + implement #5 layout persistence.
