---
name: worker-task-management
description: How a WORKER agent uses ham-ctl to execute assigned tasks, report progress, and hand off for review in a task chain. Load whenever you are a non-coordinator member of a chain.
---

# Worker task management (execute your assigned tasks)

You are a worker on this chain. Do the tasks ASSIGNED to you and report progress. Do not coordinate the whole chain or take on unassigned work — route that to the coordinator.

All commands use the managed wrapper: `./.heimdall/bin/ham-ctl`.

## 1. Find your work
- `./.heimdall/bin/ham-ctl agent tasks fetch` — list tasks; focus on those assigned to you and currently actionable.
- Read the task description and the chain description for the REQ-IDs your task must satisfy.

## 2. Do the work with visible progress
- Start: `./.heimdall/bin/ham-ctl agent tasks status --task-id <id> --status in_progress`.
- Comment at every meaningful step, on blockers, and before handoff: `./.heimdall/bin/ham-ctl agent tasks comment --task-id <id> --body \"<what you did, what changed, what is next>\"`.
- Do not do substantial work that has no task. If one is missing, ask the coordinator to create it (do not silently expand scope).

## 3. Hand off for review
- When done: `./.heimdall/bin/ham-ctl agent tasks done --task-id <id>` (moves it to `review_ready`). Include a summary comment of what to review and the evidence (tests, commits, files).
- If you receive an `ngtm` vote, address the feedback, comment what you changed, and re-submit.

## 4. Reviewing (when you are a reviewer)
- Vote with `./.heimdall/bin/ham-ctl agent tasks vote --task-id <id> --result lgtm|ngtm --comment \"<feedback>\"`.

## 5. Communication
- Route questions, blockers, and user-facing messages to the coordinator. Chat sent with chain context is redirected to them automatically.
- Use `./.heimdall/bin/ham-ctl agent tasks nudge --task-id <id>` to request attention on a stalled task you own.

Keep your task status and comments current at all times so the chain reflects real progress.