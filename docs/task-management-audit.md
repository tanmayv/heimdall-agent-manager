# Task Management Audit and Proposed Redesign

## Goal

Diagnose why agents get stuck in task management, why nudges/auto-claim create deadlocks, and propose a simpler system where:

- task chain status controls whether work is in scope
- moving a chain back to `planning` stops active work
- agents always know whether a task is:
  - current focus
  - queued for later
  - blocked
  - ready for review
  - done
  - cancelled
- completion requires approval by another agent or a user
- cancellation does not require approval
- users can always unblock the system from the UI

---

## Current System Audit

## 1. Current task status model

Current task statuses in `src/daemon/task_store.odin`:

- `planning`
- `ready`
- `in_progress`
- `review_ready`
- `approved`
- `blocked`
- `cancelled`

Current chain statuses in practice:

- `planning`
- `in_progress`
- `blocked`
- `reviewing`
- `completed`
- `archived`

## 2. What the current system is trying to do

The current system combines several concepts into task status transitions:

- dependency gating
- assignee slot gating
- reviewer slot gating
- review workflow
- queue selection
- nudge routing
- chain completion

Main logic lives in:

- `src/daemon/task_service.odin`
- `src/daemon/task_queries.odin`
- `src/daemon/task_notifications.odin`
- `src/daemon/task_nudge_scheduler.odin`
- `src/daemon/task_http.odin`

## 3. Main problems found

### Problem A: `blocked` mixes very different meanings

`blocked` is used for:

- true work blockers set by an assignee
- system dependency blockers
- assignee-active-task gating
- reviewer-gating side effects

Examples:

- `system_block:assignee_active_task:...`
- manual blocked note from assignee
- reviewer gate halting active tasks via `task_service_halt_active_tasks_for_agent`

This makes UI and agents unable to tell:

- “I cannot work because dependency missing”
- “I should work later because another task is higher priority”
- “I was forcibly paused because I owe a review”
- “I am truly blocked by missing information”

These are not the same state.

### Problem B: reviewer gating mutates assignee work state

When a task moves to `review_ready`, the system may block active tasks for required reviewers:

- `task_service_halt_active_tasks_for_agent`

That function changes the reviewer’s active task to `blocked`.

This is dangerous because a review obligation is not the same as a blocker on the reviewer’s implementation task. It creates fake blockage and can deadlock chains where:

- A reviews B
- B reviews A
- each has an active task
- each task gets force-blocked

### Problem C: auto-promotion and auto-claim are mixed with queue policy

`task_recompute_promotions` both:

- checks dependencies
- checks active slots
- chooses the “best” task for an assignee
- turns other eligible tasks into `blocked`
- auto-claims `ready` tasks

This means queue ordering is represented by status churn rather than explicit queue state.

Result:

- agents see tasks flip between `planning`, `blocked`, `ready`, `in_progress`
- “later” work is not represented explicitly
- users cannot easily tell what is intentionally deferred vs accidentally blocked

### Problem D: chain status does not fully define execution scope

Today `planning` chains are skipped by promotion logic, but the system still stores task-level statuses that may imply actionable work.

Also, moving a chain to `planning` sets member tasks to `planning`, but there is no explicit “stop now, you are out of scope” workflow beyond status mutation.

This means:

- agents may keep working locally after chain scope changed
- nudges and local focus can become stale
- users cannot clearly pause a whole workstream

### Problem E: task completion semantics are unclear

Current terminal success is task `approved`; chain then moves to `reviewing`; coordinator later marks chain `completed`.

This creates two completion layers:

- task done when `approved`
- chain not done until coordinator summary

That is okay, but for agents it is ambiguous whether:

- they should keep working after `review_ready`
- they are “done” after review submit
- they are “done” only after approval

There is no explicit “submitted for approval; not your focus anymore unless bounced back” framing.

### Problem F: user UI has too much raw status mutation and too little operator intent

The UI exposes raw task status selection:

- `planning`
- `ready`
- `in_progress`
- `review_ready`
- `approved`
- `blocked`
- `cancelled`

This is operator-hostile because the user must understand internal workflow invariants. The user needs intent-level actions like:

- Start chain
- Pause chain
- Resume chain
- Mark task current
- Queue for later
- Submit for review
- Approve
- Reject with feedback
- Cancel
- Reassign
- Force unstick

### Problem G: deadlock cases are real

Observed or likely deadlocks:

1. **Mutual review deadlock**
   - agent A reviewing B while B reviewing A
   - reviewer gating blocks both active tasks

2. **Single reviewer bottleneck**
   - one reviewer assigned to many tasks
   - auto-notify only sends one review at a time
   - everything else stalls invisibly

3. **Active-slot pseudo-deadlock**
   - assignee has one `review_ready` task awaiting external approval
   - next task remains blocked by active-slot gating
   - if reviewer is unavailable, assignee cannot progress at all

4. **Planning-chain ghost work**
   - chain moved to `planning`
   - local agent still has old focus in terminal/tmux
   - no clear stop-work handshake

5. **Status ambiguity deadlock**
   - task shown as `blocked`
   - unclear whether user should resolve dependency, requeue, reassign, or ask reviewer to vote

---

## Root Cause Summary

The system currently uses one task status field to encode four different concepts:

1. **scope** — should this task be worked at all now?
2. **readiness** — are dependencies cleared?
3. **focus** — is this the assignee’s current task?
4. **outcome** — is it awaiting review, approved, cancelled?

That compression is the main reason agents get confused and users cannot reliably unblock them.

---

## Proposed Redesign

## Design principles

1. **Chain state defines scope**
   - if chain is not active, its tasks are out of execution scope
2. **Task state should describe work outcome, not queue policy**
3. **Current focus should be explicit**
4. **Queued-for-later should be explicit**
5. **Review obligations should not mutate implementation tasks into `blocked`**
6. **User controls should be intent-based, not raw-status-based**
7. **Every stuck condition must have a visible owner and an obvious recovery action**

---

## New model

## A. Chain lifecycle

Proposed chain statuses:

- `planning` — define scope; no task is actionable
- `active` — tasks in this chain may be claimed, nudged, reviewed
- `paused` — temporary stop; active work should halt
- `approval_pending` — all tasks resolved, waiting for coordinator/user finalization
- `completed` — chain closed successfully
- `cancelled` — chain abandoned

### Rules

- Only `active` chains are in scope for:
  - auto-claim
  - scheduled nudges
  - “next task” selection
- `planning` and `paused` chains are out of scope
- moving a chain to `planning` or `paused` should emit a stop-work event to any currently focused assignees
- `approval_pending` means no more implementation work should auto-start

## B. Task lifecycle

Proposed task states:

- `backlog` — defined but not executable yet because chain not active
- `queued` — executable eventually, but not current focus
- `active` — assignee’s current implementation focus
- `blocked` — true work blocker requiring intervention
- `review_pending` — assignee submitted work; waiting for reviewer/user approval
- `done` — approved
- `cancelled` — intentionally dropped

### Meaning

- `queued` replaces most current uses of `planning`/system `blocked`
- `active` is the only assignee work state that means “work this now”
- `blocked` means real blocker only
- `review_pending` means assignee should stop implementation unless review bounces it back
- `done` means approved by reviewer or user

## C. Separate focus from state when useful

For minimal change, `active` can remain a state.

For cleaner design, add explicit per-agent work selection:

- one `current_task_id` per assignee per active chain scope
- other assignee tasks remain `queued`

That makes queue behavior explicit and avoids overusing `blocked`.

## D. Approval model

A task can be finished successfully only by:

- approval from another agent, or
- approval from a user

### Rules

- assignee cannot self-approve
- reviewer cannot equal assignee
- `review_pending` requires at least one approver identity distinct from assignee
- user may approve directly from UI
- user may reject and send task back to `active`
- cancellation requires no approval
- a coding assignee with a task in `review_pending` is still considered busy and must not auto-claim another coding task until that task is validated (`done`) or cancelled
- a reviewer is considered busy only while they currently have an outstanding review they have not yet acted on; once they approve/reject, they are immediately eligible for the next review

---

## Operator-facing workflow

The user and agents should think in these actions:

### For assignee

- **Work now** → `active`
- **Queue for later** → `queued`
- **Blocked** → `blocked` with reason
- **Submit for approval** → `review_pending`
- **Cancel** → `cancelled`

### For reviewer/user

- **Approve** → `done`
- **Request changes** → back to `active`
- **Cancel** → `cancelled`

### For coordinator/user at chain level

- **Plan** → `planning`
- **Start work** → `active`
- **Pause all work** → `paused`
- **Finalize chain** → `approval_pending` then `completed`
- **Cancel chain** → `cancelled`

---

## Nudge policy redesign

## Nudge scope

Only nudge tasks in chains with status:

- `active`
- optionally `approval_pending` for coordinator-only nudges

Never nudge tasks in:

- `planning`
- `paused`
- `completed`
- `cancelled`

## Nudge routing

- `queued` → optional low-noise reminder to assignee only if it is top of queue and assignee has no current task
- `active` → assignee work-stale nudges
- `blocked` → coordinator/user escalation nudges, not assignee spam
- `review_pending` → reviewer or user approval nudges; if the designated reviewer is not currently reviewing anything else, this should be nudged immediately
- `approval_pending` chain → coordinator/user nudges only

## Important change

Do **not** block an assignee’s current task because they owe a review elsewhere.

Instead track review debt separately:

- `review_inbox_count`
- nudge reviewer
- optionally reduce eligibility for new auto-claims
- but do not rewrite unrelated active implementation task to `blocked`

---

## Auto-claim redesign

Auto-claim should operate only on:

- chain status = `active`
- task state = `queued`
- dependencies satisfied
- assignee has no current `active` task
- assignee has no overdue required review older than threshold if you want soft gating

### Soft vs hard review gating

Recommended:

- **soft gate by default**
- if reviewer owes reviews, keep nudging them but do not mutate their active task
- optionally prevent claiming a *new* task while review debt exists

This avoids deadlocking in-flight work.

---

## Chain status should control active work directly

When chain moves to `planning` or `paused`:

1. every `active` task becomes `queued` with system note like `chain_paused`
2. every `review_pending` task remains `review_pending`
3. every `blocked` task remains `blocked`
4. send stop-work event to currently focused assignees
5. suppress further nudges and auto-claims for that chain

This matches your requirement:

> Move things to planning should have agents auto stop working on them.

---

## UI redesign recommendation

Replace raw status editing with intent buttons.

## Task actions

For assignee/current user:

- `Start work`
- `Queue for later`
- `Mark blocked`
- `Submit for approval`
- `Cancel task`
- `Reassign`

For reviewer/user:

- `Approve`
- `Request changes`
- `Cancel`

For coordinator/user:

- `Force set active`
- `Force queue`
- `Force unblock`
- `Escalate reviewer`

## Chain actions

- `Keep in planning`
- `Start chain`
- `Pause chain`
- `Resume chain`
- `Mark ready for final approval`
- `Complete chain`
- `Cancel chain`

## Required visibility in UI

Every task should display:

- chain scope status
- task state
- blocker reason if blocked
- current assignee
- current approver(s)
- whether it is current focus or queued
- why it is not claimable

Suggested computed field:

- `not_actionable_reason`
  - `chain_planning`
  - `chain_paused`
  - `deps_unmet`
  - `awaiting_review`
  - `assignee_busy`
  - `reviewer_unavailable`
  - `manual_block`

This alone would make debugging much easier.

---

## Deadlock handling rules

## Case 1: mutual review

Rule:

- never convert active implementation tasks to blocked because of pending review
- if A owes review to B and B owes review to A, both tasks may stay `review_pending` or `active`, but UI must show mutual dependency
- user can approve one side or reassign review

## Case 2: absent reviewer

Rule:

- reviewer reassignment must be first-class in UI
- user can directly approve if reviewer unavailable
- stale `review_pending` tasks escalate to coordinator/user after threshold
- reviewer availability is review-slot based, not coding-slot based: they can take the next review as soon as they act on the current one

## Case 3: assignee waiting on approval

Rule:

- assignee may have at most one `active` task
- tasks in `review_pending` do not count as active implementation focus
- therefore agent may take next queued task if policy allows parallel review wait

Recommended policy:

- one `active` implementation task
- any number of `review_pending` submitted tasks

This dramatically reduces deadlock.

## Case 4: planning/pause transitions

Rule:

- explicit stop-work event to assignee
- active task demoted to `queued`
- no nudges until chain returns to `active`

## Case 5: blocked forever

Rule:

- blocked tasks require structured blocker reason
- blocked tasks nudge coordinator/user, not just assignee
- user can resolve by:
  - editing dependency
  - reassigning
  - queueing task
  - cancelling task
  - pausing chain

---

## Migration plan from current system

## Phase 1: semantic cleanup without full schema rewrite

Can be done with current structure first:

1. Stop using `blocked` for assignee-slot and reviewer-slot gating
2. Treat current system-generated `blocked` tasks as `queued` in behavior
3. Limit nudges and auto-claim to chains in `in_progress`
4. When chain moved to `planning`, emit stop-work event and suppress nudges
5. Remove `task_service_halt_active_tasks_for_agent` behavior
6. Allow assignee to take next task when previous is `review_ready`
7. Add computed `reason_not_actionable` fields to task JSON

This alone should remove most deadlocks.

## Phase 2: introduce explicit new statuses

Map old to new:

- `planning` task in planning chain -> `backlog`
- `ready` -> `queued`
- `in_progress` -> `active`
- `review_ready` -> `review_pending`
- `approved` -> `done`
- `cancelled` -> `cancelled`
- manual `blocked` -> `blocked`
- system blocked by active-slot -> `queued`

Chain mapping:

- `in_progress` -> `active`
- `reviewing` -> `approval_pending`
- add `paused`

## Phase 3: UI intent actions

- replace raw status dropdowns with action buttons
- show queue/focus/approval explicitly
- add one-click operator unblock actions

---

## Recommended final system behavior

## What an agent should know, exactly

For every task assigned to it, the agent should be able to answer:

- **Should I work on this now?**
  - yes only if task is `active` and chain is `active`
- **Is this for later?**
  - yes if task is `queued`
- **Am I waiting on someone else?**
  - yes if task is `blocked` or `review_pending`
- **Am I done with implementation?**
  - yes if task is `review_pending`, `done`, or `cancelled`
- **Should I stop because scope changed?**
  - yes if chain is `planning` or `paused`

This is much clearer than the current mixed model.

---

## Concrete recommended decisions

1. **Chain status is the source of truth for scope**
2. **Only active chains participate in nudges and auto-claim**
3. **Introduce `queued` as explicit “later” state**
4. **Reserve `blocked` for real blockers only**
5. **Do not rewrite active tasks to blocked because of reviewer obligations**
6. **A coding assignee may not start another coding task while their current task is awaiting validation**
7. **A reviewer should be nudged immediately for `review_pending` if they are not currently reviewing another task, and after they approve/reject they become eligible for the next review immediately**
8. **Reviewer identity must never equal assignee identity; task creation and participant edits must enforce this strictly**
9. **Completion requires non-assignee approval by agent or user**
10. **Cancellation requires no approval**
11. **Moving a chain to planning/paused sends stop-work and deactivates active tasks**
12. **UI should expose actions, not raw internal statuses**

---

## Highest-priority fixes

If implementing incrementally, do these first:

1. Remove reviewer-gate forced blocking of active tasks
2. Scope auto-claim/nudges strictly to active chains
3. Treat planning-chain tasks as non-actionable and send stop-work on chain pause/planning
4. Add explicit queued semantics
5. Add UI operator actions for reassign / queue / approve / request changes / pause chain

These should address the deadlock and unblockability issues fastest.
