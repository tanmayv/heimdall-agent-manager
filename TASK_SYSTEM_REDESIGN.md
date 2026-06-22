# Task System Redesign Plan

## Overview

Full redesign of the task/chain system. No backward compatibility. Clean slate on statuses, roles, and review model.

## Status Enums (clean, replacing old set)

### Task statuses
| New | Replaces | Meaning |
|---|---|---|
| `planning` | `pending` | Created, deps unmet or chain in planning state |
| `ready` | `ready` | Deps met, chain active, waiting for auto-claim |
| `in_progress` | `claimed`, `working`, `in_progress`, `open` | Assignee actively working |
| `review_ready` | `review`, `needs_review` | Submitted for review |
| `approved` | `approved`, `done`, `validated` | All lgtm_required approved (auto-transition) |
| `blocked` | `blocked` | Manual block |
| `cancelled` | `cancelled`, `rejected`, `archived` | Terminal |

Remove: `claimed`, `working`, `open`, `review`, `needs_review`, `needs_improvements`, `rejected`, `done`, `validated`

### Chain statuses
| New | Replaces | Meaning |
|---|---|---|
| `planning` | (new) | Being defined; tasks cannot start |
| `in_progress` | `active` | Work underway |
| `blocked` | (new) | Manually blocked |
| `completed` | `completed`, `done` | All tasks approved |
| `archived` | `archived` | Historical |

## Participant Roles (clean)

| Role | Cardinality | Purpose |
|---|---|---|
| `assignee` | 1 per task | Does the work; one active task at a time |
| `lgtm_required` | 1+ per task | Must approve; gates auto-approve |
| `lgtm_optional` | 0+ per task | Can vote; informational only |
| `coordinator` | 1 per task/chain | Override authority; receives blocked/done notifs |
| `subscriber` | 0+ per task | Notified of all state changes; no action required |

Remove roles: `reviewer`, `verifier`

## Data Model Changes

### Task_State (remove fields)
- Remove: `reviewer_agent_instance_id` (use lgtm_required participant)
- Remove: `assigned_agent_instance_id` (duplicate of assignee)
- Remove: `last_comment` (use comment store)

### Task_Chain_State (add/remove)
- Add: `project_id: string`
- Remove: `default_reviewer_agent_instance_id`

### New Event Kinds
- `Task_Comment_Resolved` — marks comment resolved by comment_id
- `Task_Review_Vote` — per-reviewer LGTM/NGTM vote

### New Event Fields
- `comment_id: string` — on Task_Comment: assigned ID; on Task_Comment_Resolved: which to resolve
- `vote_approved: string` — `"true"` or `"false"` on Task_Review_Vote
- `project_id: string` — on Chain_Created

### New Projection Arrays
```odin
Task_Comment_State :: struct {
    comment_id, task_id, chain_id, body, author_agent_instance_id: string,
    resolved: bool,
    created_unix_ms: i64,
}
TASK_MAX_COMMENTS :: 8192

Task_LGTM_Vote_State :: struct {
    task_id, chain_id, reviewer_agent_instance_id: string,
    approved: bool,
    role: string,  // "lgtm_required" or "lgtm_optional"
    comment: string,
    created_unix_ms: i64,
}
TASK_MAX_VOTES :: 2048
```

## Automation Logic

### Auto-approve
After every `Task_Review_Vote`:
1. Collect all participants with role `lgtm_required` for the task
2. Check all have a vote with `approved = true` in lgtm_vote_states
3. If yes → emit `Task_Status_Changed` status=`approved` author=`system-auto-approve`
4. `task_recompute_promotions` fires → dependent tasks unblock → chain may complete

### Auto-claim
After every task transitions to `ready` and assignee is known:
1. If assignee has no other in_progress task → emit `Task_Status_Changed` status=`in_progress` author=`system-auto-claim`
2. Notify assignee

### Reviewer rotation
After `Task_Review_Vote` is appended by reviewer R:
1. Find next `review_ready` task where R is `lgtm_required` and hasn't voted yet
2. If R has no other task in `review_ready` state → send immediate nudge to R

### Chain auto-transitions
- Chain `planning` → `in_progress`: when chain activate command is called explicitly
- Chain `in_progress` → `completed`: when all tasks in chain are `approved` or `cancelled`
- Chain state is NOT auto-computed on every event; transitions are explicit + auto-complete check

### One active chain per project
- On chain create/activate: if another chain for same `project_id` is `in_progress`, return 409

## New API Surface

### New endpoints
- `POST /tasks/vote` — submit LGTM/NGTM vote (replaces `/tasks/review`)
- `POST /tasks/comment-resolve` — resolve a comment by comment_id
- `POST /tasks/comments` — list comments for a task (with `unresolved_only` filter)

### Updated endpoints
- `POST /task-chains/create` — now accepts `project_id`
- `POST /tasks/create` — `reviewer_agent_instance_id` removed; use participant add for lgtm_required
- `POST /task-chains/activate` — transitions chain from planning → in_progress

### Removed endpoints
- `POST /tasks/review` — replaced by `/tasks/vote`

## New CTL Commands
```
tasks vote   --token <t> --task-id <id> --result lgtm|ngtm --comment <text>
tasks comment-resolve --token <t> --task-id <id> --comment-id <id>
tasks comments --token <t> --task-id <id> [--unresolved]
task-chains activate --token <t> --chain-id <id>
```

## Implementation Tasks (in order)

1. **task_store.odin** — new status strings, new event kinds/fields, new structs, new arrays
2. **task_projection.odin** — handle new events, comment/vote projection, remove old handlers
3. **task_queries.odin** — new status predicates, reviewer slot blocker, unresolved comments query, lgtm check, chain-project query, JSON serialization updates
4. **task_service.odin** — new vote/resolve services, auto-approve, auto-claim, chain planning guard, one-active-per-project, remove old review service
5. **task_notifications.odin** — new status routing, subscriber fanout, reviewer rotation nudge
6. **task_nudge_scheduler.odin** — new status thresholds, unresolved comments in nudge body
7. **task_commands.odin** — new command structs, remove old review command
8. **task_http.odin** — new handlers, remove old review handler
9. **server.odin** — register new routes, remove old route
10. **ctl/main.odin** — new subcommands, updated help text

## End-to-End Autonomous Flow

```
User creates chain (project_id=P, status=planning)
User creates tasks T1→T2→T3 with assignees + lgtm_required participants
User calls: task-chains activate --chain-id C
  → chain: planning → in_progress
  → T1 has no deps → auto: planning → ready
  → T1 assignee has no active task → auto: ready → in_progress
  → assignee nudged: "T1 is in progress, work on it"

Assignee sets T1 status=review_ready
  → all lgtm_required for T1 nudged immediately

Reviewer A votes lgtm
Reviewer B votes lgtm (last required)
  → system auto-approves T1: review_ready → approved
  → T2 deps satisfied → auto: planning → ready → in_progress
  → T2 assignee nudged

...

Last task approved → chain auto-completes
```
