# Task Chains (Hub Rewrite) — Plan

## Goal

Make task chains a first-class, agent-usable workflow in the Hub rewrite:

1. Every agent instance belongs to a task chain (its own private chain by
   default), and its `AGENTS.md` states the chain id + how to work with it.
2. Create an agent into an existing task chain, or auto-create a new chain if
   none is given.
3. A right-sidebar **Task Chain Overview** in the UI: chain title/description,
   task list with status/assignee/reviewers, expandable per-task comments, and
   quick actions (nudge, LGTM, NGTM, change status, cancel).
4. `ham-ctl` (user + agent modes) can drive the full lifecycle: create chains,
   add/remove agents, create tasks + dependencies, mark done → review, reviewer
   voting, comment, cancel.
5. A new **task workflow skill memory** + a **default habit memory** so agents
   naturally use their current chain's tasks to organize work.

## Current State (what already exists)

### Backend (Hub) — SUBSTANTIAL

- Domain (`src/hub/domain/taskchain.odin`):
  - `Task_Chain` (title, publish_state, status, kind,
    `coordinator_agent_instance_id`, `default_reviewer_refs_json`).
  - `Task` (title, publish_state, status, `assignee_ref_json`,
    `reviewer_refs_json`, timestamps).
  - `Task_Comment` (task/chain/owner/author_agent_instance_id/body).
  - `Task_Status`: Assigned, In_Progress, In_Validation, Validated_Good,
    Validated_Not_Good, Paused, Completed, Cancelled.
  - `Task_Chain_Status`: Active, Completed, Cancelled.
  - `task_status_unblocks_dependents()` helper already exists (anticipates deps)
    but there is **no dependency field/table yet**.
- Service (`src/hub/service/taskchain/taskchain_service.odin`):
  - `create_chain`, `publish_chain`, `change_chain_status` (Active→Completed/
    Cancelled), `list_chains`, `get_chain`.
  - `create_task`, `publish_task`, `change_task_status` (with a transition
    matrix), `list_tasks`.
  - `create_comment` / `list_comments`, `manual_nudge` (in-memory only),
    `validate_actor_refs` (assignee/reviewer ref validation).
  - Ref helpers: `agent_instance_ref_json`, `user_ref_json`.
- REST routes (`src/hub/app/wiring.odin`):
  - `GET/POST /api/v1/task-chains`, `GET /api/v1/task-chains/{id}`,
    `POST .../publish`, `POST .../complete`.
  - `GET/POST /api/v1/task-chains/{id}/tasks`,
    `POST .../tasks/{tid}/publish|status|nudge`.
  - Agent-facing: `POST /api/v1/agent-actions/tasks/{comment|status|vote|nudge}`.
    `vote` maps `lgtm→Validated_Good`, `ngtm→Validated_Not_Good`.
- Instance→chain binding (`agent_service.odin`):
  - `resolve_instance_chain`: if `chain_id` given, validate + bind; else
    **auto-create** a `private_conversation` chain (published/active).
  - `update_private_chain_coordinator`: first instance becomes coordinator.
  - `bootstrap_json_for_bridge` already emits `chain`, `task_context`, and a
    `default_reviewer_refs`/`publish_state`/`status` block.

### Bridge / bootstrap — PARTIAL

- `bridge_bootstrap_fetch_and_materialize` writes `AGENTS.md` from the bootstrap
  `content` field + appends CLI guidance + writes the skill file + ham-ctl
  wrapper.
- The Hub-built `AGENTS_MD` `content` (in `agent_service.odin`) currently
  contains only agent name + instance + memory markdown. It does **NOT** include
  the chain id or task-workflow guidance.

### `ham-ctl` — PARTIAL

- Agent mode (`src/ctl/agent_mode.odin`): `agent tasks fetch|comment|status|
  vote|nudge` exist.
- Hub/user mode (`src/ctl/hub_mode.odin`): `hub task-chains list|create|show|
  publish|complete`, `hub tasks list|create|publish|status|nudge`.
- Missing: add/remove agents to a chain, dependencies, reviewer add/remove,
  cancel task, richer create (description, reviewers, assignee variants),
  comment via user mode, list comments.

### UI — MINIMAL

- `src/ui/api/endpoints/tasks.ts` exists (thin).
- No right-sidebar Task Chain Overview in the rewrite shell.
- `ContextInspector` (`workspace-inspector`) is a generic tabbed right panel we
  can host the overview in.

## Gaps To Close

- **Data model**: chain `description`; task `description`; task **dependencies**;
  persisted **per-reviewer votes** (today "vote" just flips task status, so N
  reviewers and quorum are not modeled); chain/task ordering fields.
- **AGENTS.md**: inject `chain_id`, chain title, and a short "how to use tasks"
  block.
- **Membership**: explicit chain membership (which agents belong), add/remove.
- **CLI**: full lifecycle verbs in user + agent modes.
- **UI**: right-sidebar overview with expandable comments + quick actions.
- **Memory**: task-workflow skill + default habit memory.

---

## Data Model Changes

### Chain

- Add `description TEXT` to `task_chains` (migration + domain + repo binds +
  handlers).

### Task

- Add `description TEXT`.
- Add **dependencies**: new table `task_dependencies`
  (`task_id`, `depends_on_task_id`, `chain_id`, `owner_user_id`,
  `created_at`), owner-scoped, unique `(task_id, depends_on_task_id)`. No cycles
  (validate on insert). A task is **blocked** (not startable) until all
  `depends_on` tasks are `Completed`/`Cancelled`
  (reuse `task_status_unblocks_dependents`).

### Reviewer votes (quorum)

- New table `task_votes` (`task_id`, `chain_id`, `owner_user_id`,
  `reviewer_agent_instance_id`, `vote` = `lgtm|ngtm`, `comment`, `created_at`,
  `updated_at`), unique `(task_id, reviewer_agent_instance_id)`.
- `In_Validation` → auto-promote to `Validated_Good` when **all required
  reviewers** (from `reviewer_refs_json`) have `lgtm`; any `ngtm` moves to
  `Validated_Not_Good`. Keep the existing single-shot vote endpoint working as a
  degenerate case (0/1 reviewer).

### Membership

- New table `task_chain_members` (`chain_id`, `agent_instance_id`,
  `agent_id`, `owner_user_id`, `role` = `coordinator|worker|reviewer`,
  `created_at`), unique `(chain_id, agent_instance_id)`. Populated when an
  instance is created into a chain (Task 2) and via CLI add/remove.

All new tables owner-scoped with `owner_user_id` immutable trigger, mirroring
`002_owner_scoped_core.sql`.

---

## API Contracts (new/changed)

Chains:
- `POST /api/v1/task-chains` — add `description`.
- `PATCH /api/v1/task-chains/{id}` — edit title/description/status (new).
- `GET /api/v1/task-chains/{id}` — return `description`, `members[]`, and (for
  the overview) an embedded `tasks[]` with assignee/reviewers/vote summary.

Tasks:
- `POST /api/v1/task-chains/{id}/tasks` — add `description`, `assignee_ref`,
  `reviewer_refs`, `depends_on` (array of task ids).
- `PATCH /api/v1/task-chains/{id}/tasks/{tid}` — edit title/description,
  assignee, reviewers, dependencies (new).
- `POST .../tasks/{tid}/status` — already exists; ensure `done` maps to
  `In_Validation` (submit-for-review), `cancel` → `Cancelled`, etc.
- `POST .../tasks/{tid}/cancel` — convenience (new) → `Cancelled`.
- `GET .../tasks/{tid}/comments` — list (new).
- `POST .../tasks/{tid}/comments` — user-mode comment (new; agent path already
  exists via agent-actions).
- `GET .../tasks/{tid}/votes` — list reviewer votes (new).

Membership:
- `GET /api/v1/task-chains/{id}/members` (new).
- `POST /api/v1/task-chains/{id}/members` `{ agent_instance_id, role }` (new).
- `DELETE /api/v1/task-chains/{id}/members/{agentInstanceId}` (new).

Agent-actions (already present, extend):
- `tasks/vote` — persist per-reviewer vote + quorum promotion (change behavior).
- add `tasks/create`, `tasks/depend` for agents that coordinate (optional,
  gated to coordinator instance).

---

## Tasks

### Task 1 — Backend: chain/task descriptions + PATCH + detail payload

- Migration: add `description` to `task_chains` and `tasks`.
- Domain + sqlite binds/reads + handler JSON writers include `description`.
- Add `update_chain` / `update_task` service procs and PATCH handlers.
- `task_chain_detail_handler` returns `description`, embedded `tasks[]` (with
  assignee/reviewer refs) so the UI can render the overview in one call.

Validation: `odin build src/hub`; curl create+patch+detail.

Files: `migrations.odin` (+ new `012_*.sql`), `domain/taskchain.odin`,
`taskchain_repo_sqlite.odin`, `taskchain_service.odin`,
`transport/http/taskchain_handlers.odin`, `wiring.odin`.

### Task 2 — Backend: chain membership + auto-membership on instance create

- New `task_chain_members` table + iface + sqlite.
- On `create_instance` (and the private-chain path), upsert a membership row
  (coordinator for the first/creator, worker otherwise).
- Service + routes: list/add/remove members (owner-scoped; validate the
  instance belongs to the owner and the chain).
- Removing the coordinator is disallowed unless another coordinator exists (or
  reassign).

Validation: `odin build src/hub`; create instance → member appears; add/remove.

Files: `domain/taskchain.odin`, `iface/taskchain_repo.odin`,
`taskchain_repo_sqlite.odin`, `migrations`, `taskchain_service.odin`,
`agent_service.odin` (hook), `taskchain_handlers.odin`, `wiring.odin`.

### Task 3 — Backend: task dependencies

- New `task_dependencies` table + iface + sqlite.
- `create_task`/`update_task` accept `depends_on[]`; validate same-chain, no
  self/cycle.
- Gate `change_task_status` to `In_Progress`: reject start if any dependency is
  not terminal (Completed/Cancelled) → `.Conflict "task is blocked by
  dependencies"`.
- Detail/task JSON includes `depends_on[]` and a computed `blocked` bool.

Validation: `odin build src/hub`; A→B dependency; B cannot start until A done.

Files: same set as Task 1/2.

### Task 4 — Backend: persisted reviewer votes + quorum

- New `task_votes` table + iface + sqlite.
- Change `agent_action_task_vote_handler` + a new user-mode vote route to
  **record** a per-reviewer vote (`lgtm|ngtm` + optional comment) instead of
  directly flipping status.
- Promotion logic on vote:
  - any `ngtm` → task `Validated_Not_Good`.
  - all required reviewers `lgtm` → task `Validated_Good`.
  - otherwise stay `In_Validation`.
- Only instances in `reviewer_refs_json` may vote; assignee cannot vote on own
  task.
- `GET .../votes` returns the tally.

Validation: `odin build src/hub`; 2-reviewer task needs both LGTM to advance.

Files: domain/iface/sqlite/migrations, `taskchain_service.odin`,
`agent_action_handlers.odin`, `taskchain_handlers.odin`, `wiring.odin`.

### Task 5 — Backend: AGENTS.md carries chain id + task workflow block

- In `bootstrap_json_for_bridge`, extend the `AGENTS_MD` `content` to include:
  - `Task chain: <title> (chain_id)`
  - `Coordinator: <instance or you>`
  - a short "Working with tasks" block pointing at
    `./.heimdall/bin/ham-ctl agent tasks ...` (fetch/comment/status/vote/nudge)
    and the rule: **organize your work as tasks in this chain; move a task to
    review with `status --status in_validation` (done); reviewers vote lgtm/
    ngtm**.
- Keep it concise; the deep how-to lives in the skill memory (Task 8).

Validation: `odin build src/hub`; launch instance; `AGENTS.md` shows chain id +
task block.

Files: `agent_service.odin`.

### Task 6 — CLI: user-mode task chain lifecycle (`ham-ctl hub ...`)

Extend `src/ctl/hub_mode.odin`:
- `task-chains create --title --description [--coordinator ...]`
- `task-chains update --chain-id [--title --description --status]`
- `task-chains show --chain-id` (already; include members/tasks)
- `task-chains members --chain-id` / `members-add --chain-id --agent-instance-id
  [--role]` / `members-remove --chain-id --agent-instance-id`
- `task-chains add-agent --chain-id --agent-id [--bridge-id --provider --tier
  --project-id]` → creates an instance bound to the chain (wraps
  `POST /api/v1/agent-instances` with `chain_id`).
- `tasks create --chain-id --title [--description --assignee --reviewer ...
  --depends-on task_a,task_b]`
- `tasks update --chain-id --task-id [...]`
- `tasks status --status done|in_progress|cancel|...` (map friendly aliases)
- `tasks done|cancel` convenience
- `tasks comment --task-id --body` / `tasks comments --task-id`
- `tasks vote --task-id --result lgtm|ngtm [--comment]`
- `tasks depend --task-id --on task_id` / `tasks undepend ...`

Validation: `odin build src/ctl`; run against local hub for each verb.

Files: `src/ctl/hub_mode.odin` (+ help text).

### Task 7 — CLI: agent-mode task verbs (`ham-ctl agent tasks ...`)

Extend `src/ctl/agent_mode.odin` for the running agent:
- `agent tasks list|fetch` (current chain's tasks + statuses)
- `agent tasks create --title [...]` (coordinator only; gated server-side)
- `agent tasks status --task-id --status done|in_progress|...`
- `agent tasks done --task-id` (alias → in_validation)
- `agent tasks comment --task-id --body`
- `agent tasks vote --task-id --result lgtm|ngtm [--comment]`
- `agent tasks nudge --task-id [--message]`
- `agent tasks depend --task-id --on <task_id>` (coordinator)
Wire to `/api/v1/agent-actions/tasks/*` via the bridge local endpoint allowlist
(`bridge_local_is_agent_method_allowed`) and hub route map in
`wrapper_endpoint.odin`.

Validation: `odin build src/ctl` + `odin build src/bridge`; exercise from a live
agent.

Files: `src/ctl/agent_mode.odin`, `src/bridge/wrapper_endpoint.odin`
(allowlist + route map), `src/hub/transport/http/agent_action_handlers.odin`
(any new create/depend actions).

### Task 8 — Memory: task-workflow skill + default habit

- New migration seeding two **system** memories (owner `system`, status
  `active`), mirroring the existing `mem_system_heimdall_ctl_communication`
  pattern:
  - `type=skill` `mem_system_heimdall_tasks`: a SKILL.md-style body on using
    `ham-ctl agent tasks` (fetch, create, comment, status→done, vote, nudge,
    dependencies), when to split work into tasks, and the review flow.
  - `type=habit` `mem_system_use_current_chain_tasks`: short habit like
    "Organize your work as tasks in your current task chain; before starting,
    run `ham-ctl agent tasks fetch`; keep task status current; submit for review
    with `status --status done`; respond to reviewer NGTM by fixing and
    re-submitting."
- Both apply to all agents (empty `agent_id`), so they flow through
  `bootstrap_memory_applies` into `AGENTS.md`/skills automatically.
- If the bootstrap only materializes one skill file today
  (`write_bootstrap_default_skill_fields` returns first skill), extend it to
  emit multiple skill files (array), or fold task guidance into the existing
  skill. Prefer emitting multiple skill files.

Validation: `odin build src/hub`; launch instance; confirm task skill + habit
appear in bootstrap.

Files: `migrations.odin` + `013_task_workflow_skill_memory.sql`,
`agent_service.odin` (multi-skill materialization if needed),
`bridge/bootstrap_service.odin` (write N skill files).

### Task 9 — UI API: task-chain endpoints

Reimplement/extend `src/ui/api/endpoints/tasks.ts` (cookie-auth `/api/v1`):
- `useListTaskChainsQuery`, `useFetchTaskChainQuery` (detail w/ tasks+members).
- `useCreateTaskChainMutation`, `useUpdateTaskChainMutation`.
- `useCreateTaskMutation`, `useUpdateTaskMutation`,
  `useChangeTaskStatusMutation`, `useCancelTaskMutation`.
- `useListTaskCommentsQuery`, `useAddTaskCommentMutation`.
- `useListTaskVotesQuery`, `useVoteTaskMutation` (lgtm/ngtm).
- `useNudgeTaskMutation`.
- `useAddChainMemberMutation` / `useRemoveChainMemberMutation` /
  `useAddAgentToChainMutation`.
Tag with `TaskChains`/`TaskChain`/`Task` and invalidate on mutations; also
invalidate on relevant user-WS events if present.

Validation: `npm run typecheck`.

Files: `src/ui/api/endpoints/tasks.ts`, `heimdallApi.ts` (tag types).

### Task 10 — UI: right-sidebar Task Chain Overview

Host in the existing right panel (`ContextInspector` / `global-right-sidebar`),
add a **Task Chain** tab shown when the active context has a `chain_id`
(conversation/agent/chain routes).

Layout (see ASCII mock):
- Header: chain title + status chip; expandable description.
- Progress summary: counts (todo / in-progress / in-review / done / blocked).
- Task list: each row shows title, status chip, assignee, reviewers, blocked
  indicator; row expands to show description + comments (paged) + a comment
  composer.
- Per-task quick actions: Nudge, LGTM, NGTM, Change status (menu:
  start/done/pause/cancel), Cancel.
- Members strip (avatars/names + role) with add/remove for the owner.

Debug IDs (register in `AGENTS.md`, new `TaskChainOverview` row):
- `taskchain-overview`, `taskchain-overview-title`,
  `taskchain-overview-status`, `taskchain-overview-description-toggle-btn`,
  `taskchain-overview-progress`, `taskchain-overview-progress-${bucket}`,
  `taskchain-overview-members`, `taskchain-overview-member-${agentId}`,
  `taskchain-overview-add-member-btn`,
  `taskchain-overview-member-remove-btn-${agentInstanceId}`,
  `taskchain-task-row-${taskId}`, `taskchain-task-expand-btn-${taskId}`,
  `taskchain-task-title-${taskId}`, `taskchain-task-status-${taskId}`,
  `taskchain-task-assignee-${taskId}`, `taskchain-task-reviewers-${taskId}`,
  `taskchain-task-blocked-${taskId}`,
  `taskchain-task-comments-${taskId}`,
  `taskchain-task-comment-${taskId}-${index}`,
  `taskchain-task-comment-load-older-btn-${taskId}`,
  `taskchain-task-comment-input-${taskId}`,
  `taskchain-task-comment-submit-btn-${taskId}`,
  `taskchain-task-nudge-btn-${taskId}`,
  `taskchain-task-lgtm-btn-${taskId}`,
  `taskchain-task-ngtm-btn-${taskId}`,
  `taskchain-task-status-menu-btn-${taskId}`,
  `taskchain-task-status-${statusKey}-btn-${taskId}`,
  `taskchain-task-cancel-btn-${taskId}`,
  `taskchain-new-task-btn`, `taskchain-new-task-title-input`,
  `taskchain-new-task-submit-btn`.

Validation: `npm run typecheck`; Electron debug-API click-through for expand +
each quick action.

Files: `src/ui/components/workspace/ContextInspector.tsx` (tab),
`src/ui/components/taskchain/TaskChainOverview.tsx` (new),
`src/ui/components/shell/AppShell.tsx` (mount where chain context exists),
`AGENTS.md`.

### Task 11 — UI: create agent into a chain (existing/new)

- In the chain overview + the agent/instance launch flows, allow "Add agent to
  this chain" → calls `add-agent`/`POST /api/v1/agent-instances` with `chain_id`.
- In the New Conversation / launch composer, allow choosing an existing chain or
  "new chain" (default). Surfacing chain selection is optional but preferred.

Validation: `npm run typecheck`; add an agent to a chain and see it in members.

Files: `TaskChainOverview.tsx`, `ConversationLaunchComposer.tsx` /
`AgentDetailPanel.tsx`, `tasks.ts`, `AGENTS.md`.

### Task 12 — E2E verification + docs

- E2E on `hub.mundus.in` + local bridge:
  1. Create chain (CLI + UI); add two agents (assignee + reviewer).
  2. Create tasks with a dependency; confirm blocked task can't start.
  3. Agent marks task done → `In_Validation`; reviewer LGTM/NGTM; quorum flips
     status; NGTM returns to In_Progress path.
  4. Comment on a task from agent + UI; verify visible in overview.
  5. Nudge from UI; cancel a task.
  6. Confirm `AGENTS.md` shows chain id + task block, and task skill/habit are
     present.
- Update this doc's status.

Validation: `npm run typecheck`, `odin build src/hub`, `odin build src/ctl`,
`odin build src/bridge`, live run.

---

## UI Mock (ASCII) — Right-sidebar Task Chain Overview

```
+---------------------------- Task Chain --------------------------------+  taskchain-overview
| Payments refactor                                  [ active ]         |  -title / -status
| ▾ description: migrate to new gateway, keep old API stable            |  -description-toggle-btn
|                                                                       |
| Progress:  todo 2 · doing 1 · review 1 · done 3 · blocked 1           |  -progress
|                                                                       |
| Members:  ● coordinator: backend-dev   ● reviewer: reviewer   [ + ]   |  -members / -add-member-btn
|                                                                       |
| Tasks                                              [ + New task ]     |  taskchain-new-task-btn
| +-------------------------------------------------------------------+ |
| | ▸ Implement gateway client        [in_progress]                  | |  taskchain-task-row-${id}
| |   assignee: backend-dev   reviewers: reviewer                    | |
| |   [Nudge] [LGTM] [NGTM] [Status v] [Cancel]                      | |  quick actions
| +-------------------------------------------------------------------+ |
| | ▾ Migrate settlement job          [in_validation]  ⛔blocked-off | |  expanded
| |   assignee: backend-dev   reviewers: reviewer, qa                | |
| |   desc: move cron to new queue                                  | |
| |   comments:                                                     | |  taskchain-task-comments-${id}
| |     backend-dev: submitted for review (2m)                      | |
| |     reviewer: NGTM — handle retry (1m)                          | |
| |     [ load older ]                                              | |
| |   [ write a comment____________________ ]  [ Send ]             | |  -comment-input / -submit-btn
| |   [Nudge] [LGTM] [NGTM] [Status v] [Cancel]                     | |
| +-------------------------------------------------------------------+ |
| | ▸ Backfill ledger                 [assigned]  ⛔ blocked by #1   | |  blocked indicator
| +-------------------------------------------------------------------+ |
+-----------------------------------------------------------------------+
```

Status menu (`Status v`) options: Start (→in_progress), Done (→in_validation),
Pause, Cancel. LGTM/NGTM only enabled for reviewer instances; disabled with a
tooltip otherwise.

---

## Status → action mapping (UI quick actions)

```
button      calls                                    effect
----------  ---------------------------------------  ---------------------------------
Start       status --status in_progress              Assigned/Paused → In_Progress (dep-gated)
Done        status --status in_validation            In_Progress → In_Validation (submit review)
LGTM        vote --result lgtm                       record vote; quorum → Validated_Good
NGTM        vote --result ngtm                       record vote → Validated_Not_Good
Pause       status --status paused                   → Paused
Cancel      status --status cancelled (or /cancel)   → Cancelled (terminal)
Nudge       tasks nudge --message                    ping owner/assignee/reviewer per status
Comment     tasks comment --body                     append Task_Comment
```

("Complete" = coordinator moves Validated_Good → Completed; expose as a Status
menu item on validated tasks.)

---

## Sequencing

1. Task 1 (descriptions + PATCH + detail payload) — foundation for UI + CLI.
2. Task 2 (membership) and Task 3 (dependencies) — backend, parallelizable.
3. Task 4 (reviewer votes/quorum) — backend.
4. Task 5 (AGENTS.md chain block) + Task 8 (skill/habit memory) — bootstrap.
5. Task 6 (user CLI) + Task 7 (agent CLI).
6. Task 9 (UI API) → Task 10 (overview) → Task 11 (add agent to chain).
7. Task 12 (E2E + docs).

## Risks / Notes

- Keep the **private auto-chain** behavior: agents with no explicit chain still
  get one; the overview + AGENTS.md must handle `kind=private_conversation`
  gracefully (a chain of one).
- Votes change existing behavior: today `vote` flips status directly. Preserve a
  0/1-reviewer fast path so simple chains keep working.
- Dependency gating must not deadlock the private chain (no deps there).
- All new tables owner-scoped; never trust client `owner_user_id`.
- REST-first under `/api/v1`; do not add `/user-rpc` task actions.
- Every new interactive element needs a `data-debug-id` + `AGENTS.md` entry.
- Reuse existing status enums/transition matrix; do not invent parallel status
  strings — map friendly CLI/UI words (done/start/cancel) to the enum.
