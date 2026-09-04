# Self-healing task-chain reconciliation

Status: **DESIGN — confirm before implementing**

## Model invariants (DECIDED — Option A)

The self-heal reconciler and the single-focus current_task model rest on two
hard invariants. They make cross-chain pointer contention impossible by
construction.

1. **One instance ↔ one chain (for its lifetime).**
   - `Agent_Instance.chain_id` is a single, immutable field. An instance belongs
     to exactly one task chain; to work in another chain, launch ANOTHER instance
     of the same durable agent. The durable `agent_id` is the reusable, multi-chain
     entity; the *instance* is the per-chain run.
   - `current_task_id`/`current_task_role` stay single scalars — an instance has
     at most one focus, resolved by exactly one chain's reconcile. No contention.
   - **Enforcement**: `add_chain_member` must reject an instance whose
     `instance.chain_id` != this chain (today it only checks owner). Membership and
     `instance.chain_id` can never diverge.

2. **One coordinator instance ↔ one chain.**
   - An agent instance may be `coordinator` of AT MOST ONE chain. (It is already
     bound to one chain by invariant 1; this additionally forbids the same
     instance holding the coordinator role via membership in a different chain.)
   - **Enforcement**: `add_chain_member` with `role == "coordinator"` must reject
     an instance that is already a coordinator member of any other chain (and, by
     invariant 1, whose `chain_id` differs). Coordinator identity stays 1:1 with
     the chain.
   - A durable *agent* can still coordinate many chains over time — via a
     separate instance per chain — but a single running instance coordinates one.

Both are enforced at the write boundary (`add_chain_member` / instance create),
so the reconciler can assume them and never reason about an instance spanning
chains.

## Goal

Replace the scattered, ad-hoc pointer fixes with ONE idempotent self-healing
pass — `reconcile_chain(chain)` — that, given a task chain, corrects:

- every task's **status** drift, and
- every instance's **current_task_id / current_task_role**

to match the true actionable state. It is safe to run any number of times
(idempotent: a no-op when already consistent) and is called from every
task-relevant update, plus read-time and instance-restart triggers.

## Why (what's broken today)

The selection engine `recompute_chain_promotions`
(`src/hub/service/taskchain/promotion.odin`) is correct about the RULES
(review>work, priority P0>P1>P2, promote chosen work → In_Progress, demote other
work → Queued), but it is:

1. **Restart clears focus with no cheap recovery.**
   `agent_service.apply_bridge_status_report` clears the pointer on
   stop/unreachable. On restart we deliberately do NOT auto-reconcile (coordinator
   owns kickoff), so focus is re-established on the next task-status-change
   reconcile or a manual `reconcile`. To keep reads correct in the meantime, the
   read-only serializer guard re-derives/validates focus at `context` time (no
   write), and a returning agent can always be re-pointed by the coordinator's
   `reconcile`. (The old behavior left a stale/blank pointer with nothing to fix
   it; the guard + manual reconcile close that.)

2. **Incomplete healing.** `apply_instance_focus` only writes pointers for
   instances referenced by SOME current task. An instance whose task was
   cancelled/reassigned/completed is not in that set, so its stale
   `current_task_id` is left as-is. Today this is patched by ad-hoc
   `clear_instance_current_task` calls sprinkled into `update_task` (the
   reassign-away case) — exactly the fragility we want to remove.

3. **No read-time correctness.** `context` and the instance record emit the
   persisted pointer without re-checking it still resolves to an actionable role
   for that instance, so a drifted pointer surfaces a task the agent should not
   act on.

## The self-healing algorithm: `reconcile_chain(service, chain)`

One simple, idempotent pass over durable state. Selection honors **priorities**
(P0>P1>P2) and **dependencies** (a task is only actionable when its deps are
satisfied) via the existing helpers — unchanged rules, just made total and
correctly triggered/notified.

```
reconcile_chain(chain) -> Reconcile_Result:
  if chain not Active+Published: return {}          # inactive chains don't drive focus
  tasks = list_tasks(chain); deps = list_deps(chain)
  result = {}                                       # accumulates changes for the coordinator summary

  # 1. Candidate instances = EVERYONE who could hold a pointer here:
  #    assignees ∪ designated reviewers ∪ chain members ∪ holders-of-chain-tasks.
  #    The union lets us CLEAR stale pointers for instances dropped from all tasks,
  #    not just re-point still-referenced ones.
  instances = union(task_assignees, task_reviewers, chain_members, holders_of_chain_tasks)

  # 2. Per instance, pick the single focus (deps + priority aware):
  #    review-pool  = tasks In_Validation this instance reviews
  #    work-pool    = actionable (Assigned/Queued/In_Progress/Validated_Not_Good),
  #                   deps-satisfied tasks assigned to this instance
  #    review wins over work; within a pool: priority P0>P1>P2, then created_at,
  #    then task_id. (Existing best_review/best_work logic.)
  for inst in instances:
     old_ptr        = inst.current_task_id/role
     focus[inst]    = best_focus(inst, tasks, deps, chain)   # {task_id, role} or none

  # 3. Heal task statuses (same rules, total):
  #    - chosen work task: Assigned/Queued/Validated_Not_Good -> In_Progress
  #    - instance's OTHER actionable work tasks -> Queued (leave Validated_Not_Good)
  #    - any In_Progress task with unsatisfied deps -> Queued
  #    Record every status flip in result.status_changes. No destructive actions
  #    (never auto-cancel/reassign; a gone-assignee task keeps its status).

  # 4. Heal pointers TOTALLY (write only on change):
  #    - focus present -> set current_task_id/role
  #    - no focus       -> CLEAR current_task_id/role   (replaces the ad-hoc clear_* calls)
  #    Record every pointer change in result.focus_changes {inst, old, new}.

  # 5. Notify — the three behaviors you asked for:
  #    (a) CURRENT-TASK CHANGED: for each inst whose pointer changed to a NEW task,
  #        call notify_current_task_changed (already exists: wakes the bridge,
  #        states WORK vs REVIEW). Pointer→none (cleared) sends no nudge.
  #    (b) NUDGE IDLE + ACTIONABLE: for each inst whose focus is unchanged but the
  #        instance is IDLE (runtime running/idle AND activity_status == "idle")
  #        while holding an actionable current task, send a gentle re-nudge so a
  #        stalled-but-present agent resumes. Debounced (should_debounce_nudge_
  #        dispatch, 1.5s) so repeated reconciles don't spam.
  #    (c) COORDINATOR SUMMARY: if result has ANY status_changes or focus_changes,
  #        send ONE compact summary to the chain coordinator instance
  #        (coordinator_primary_instance) describing what self-heal did
  #        (e.g. "Self-heal: promoted T3 (P0) to in_progress for A; re-pointed B to
  #        review T7; queued T5 (blocked by T4)."). Skip if the coordinator IS the
  #        only affected instance, and never notify on a pure no-op.

  return result
```

Notes:
- **Simple + deterministic**: one scan, existing priority/dep helpers, no
  scheduler. Idempotent — all writes are change-gated, so a repeat run with no
  real drift makes no writes and sends no notifications.
- **Idle detection** uses the instance's `runtime_status` (must be live:
  running/idle/busy) + `activity_status == "idle"`; a busy agent is never nudged.
- `recompute_chain_promotions` becomes a thin wrapper over `reconcile_chain`
  (or is renamed to it); all existing call sites keep working, and the ad-hoc
  `clear_instance_current_task` patches in `update_task`/etc. are deleted.

### Reuses existing primitives (little new code)
- **Notify current-task change (5a)**: `notify_current_task_changed` already
  exists and does exactly this (bridge wake + WORK/REVIEW label). We just call it
  from the reconcile loop for every pointer that changed to a new task, instead of
  only from manual `set_current`.
- **Idle nudge (5b)**: reuse the same `notify_task_nudge` runtime command
  (origin="self_heal_idle") + `should_debounce_nudge_dispatch`.
- **Coordinator summary (5c)**: `coordinator_primary_instance` resolves the
  coordinator; send one `notify_task_nudge` (origin="self_heal_summary") to it
  with the compact change list. `Reconcile_Result { status_changes[],
  focus_changes[], idle_nudged[] }` is built during the pass so the summary is a
  pure formatting step (and unit-testable without I/O).

## Trigger model (DECIDED — explicit, coordinator-driven setup)

The coordinator builds the chain WITHOUT anything firing, then explicitly kicks
it off. After that, only a small, well-defined set of events re-reconcile. A
reconcile NEVER triggers another reconcile.

### Setup phase — NO auto-trigger
The coordinator reads task descriptions, then creates all tasks, wires
dependencies, and sets assignees/reviewers. During this phase **nothing
reconciles** — no promotions, no current_task changes, no nudges. So these
mutations MUST NOT auto-reconcile anymore:
- `create_task` — remove its `recompute_*` call.
- `update_task` (assignee/reviewer/priority edits, dependency edits) — remove its
  `recompute_*` call.
- `add_task_dependency` / `remove_task_dependency` — remove their `recompute_*`
  calls. **Dependency changes never auto-reconcile** (your explicit ask): the
  coordinator can restructure deps freely without status churn, then reconcile
  manually.
This lets the coordinator stage an entire plan atomically-in-spirit and review it
before any agent is nudged.

### Kickoff — explicit command
New verb: **`reconcile task-chain <chain-id>`** (coordinator/user only) →
`POST /api/v1/task-chains/{id}/reconcile` → `reconcile_chain(chain)`. This is the
FIRST reconcile; it promotes the entry tasks, sets everyone's current_task, and
nudges. Same command is the manual "heal now" / "I changed dependencies, re-plan"
button.
- CLI: `ham-ctl task-chain reconcile [<chain-id>]` (agent-mode: coordinator only).
- Wire: `agent.task_chain.reconcile`.

### Ongoing AUTO-trigger (single)
After kickoff, the ONLY event that re-reconciles automatically is:
1. **Task status change** (`change_task_status`, and quorum resolution in
   `evaluate_task_quorum`) — a task moving (e.g. → In_Validation, →
   Validated_Not_Good, → Completed) changes who should act; reconcile the chain.

Everything else waits for the coordinator's manual `reconcile` command:
- create task, assignee/reviewer edits, **priority change**, dependency
  add/remove, chain edits — NO auto-reconcile. The coordinator re-runs
  `reconcile` when they want the new plan/priority to take effect.
- **Instance becomes live again** — NO auto-reconcile. A restarted/reconnected
  agent regains focus on the next status-change reconcile or a manual
  `reconcile`; the read-only serializer guard (below) keeps `context` honest in
  the meantime.

### Serializer guard (defense in depth, read-only)
`write_agent_current_task_json` and the bootstrap current-task writer re-validate
the pointer and emit `null` if it no longer resolves to an actionable role — so a
stale pointer never surfaces a wrong task even between reconciles. This is
read-only; it is NOT a reconcile and performs no writes.

### Re-entrancy guard (REQUIRED)
`reconcile_chain` must never cause a nested reconcile:
- The status/priority changes it makes internally (promote → In_Progress, demote →
  Queued) are written via the low-level repo save, which does NOT auto-reconcile
  (only the high-level `change_task_status`/`update_task` service procs do). So the
  internal heal is already reconcile-free.
- Add an explicit guard anyway: a per-chain "reconciling" flag (or a `reconciling`
  bool threaded through) so any status/priority write performed *by* the reconciler
  is recognized as internal and cannot re-enter. Notifications are fired after the
  single pass completes.

Net trigger set after kickoff: **task status change** is the ONLY auto-reconcile;
**everything else** (create, assignee/reviewer, priority, dependencies, chain
edits, instance restart) is manual via the coordinator's `reconcile` command.

## Repo addition

- `list_members_by_chain` already exists (canonical chain instance set).
- Need a cheap way to find "instances whose current_task points into this chain":
  either filter `list_instances_by_owner` by `chain_id` in the service, or add a
  small `list_instances_by_chain(chain_id, owner)` repo query. The members-table
  union usually already covers these, so filtering owner-instances by `chain_id`
  in-service is likely enough (no new repo proc). Confirm preference.

## Decisions (LOCKED)

1. **Write-on-read — NO.** `context` does NOT reconcile. Read-only serializer
   guard only: re-validate the pointer, emit `null` if stale.
2. **Instance set source — no new repo proc.** Union of `list_members_by_chain` +
   task assignee/reviewer refs + in-service filter of owner-instances by
   `chain_id` (to catch stale pointer holders).
3. **Gone-assignee tasks — leave status, clear pointer only.** Never
   auto-cancel/reassign. Pure status/pointer heal, no destructive actions.
4. **Idle nudge — 10 min minimum with exponential backoff.** An idle+actionable
   agent (both `work` and `review` roles, per #7) is nudged at most once per task
   per 10 min; the interval backs off exponentially on each successive idle nudge
   for the same task (10m → 20m → 40m …), reset when the task's focus/status
   changes. (The short 1.5s dispatch debounce still applies within a single
   reconcile burst.)
5. **Existing-data migration — NONE.** Guards apply to new writes only; no
   backfill or audit pass.
6. **Coordinator summary — DROPPED for now.** No self-heal summary to the
   coordinator. Reconcile still (a) notifies agents whose current_task changed and
   (b) nudges idle+actionable agents; it does NOT message the coordinator.
7. **Idle-nudge role scope — both.** Nudge idle agents in `work` AND `review`
   roles.
8. **Who can call `reconcile` — coordinator instance + user/owner only.** Workers
   and reviewers are rejected.

## Enforcement work (invariants, Option A)

Alongside the reconciler, land the two guards so the model can't drift:
- `add_chain_member`: reject when `instance.chain_id != chain_id`
  (Conflict, "an instance belongs to a single chain; launch a new instance to
  join another chain").
- `add_chain_member` with `role == "coordinator"`: reject when the instance is
  already a coordinator member of another chain (Conflict, "an instance can
  coordinate only one chain").
- Tests: cross-chain member add rejected; second-chain coordinator add rejected;
  same-chain re-add is idempotent.

## Recommendation

Implement `reconcile_chain` as the single healer (rename/wrap
`recompute_chain_promotions`): make the instance set + pointer-clearing total,
honor priorities + dependencies (existing helpers), delete the ad-hoc
`clear_instance_current_task` patches. Triggers: explicit `reconcile` command
(kickoff + manual re-plan) and task-status-change only; NO auto-reconcile on
create/assignee/reviewer/priority/dependency/chain edits or instance restart. On
each run it (a) notifies agents whose current_task changed and (b) nudges
idle+actionable agents (10 min min, exponential backoff, work+review). No
coordinator summary. Land the Option-A invariant guards in `add_chain_member`.
Keep selection rules and the no-destructive-actions boundary unchanged.
