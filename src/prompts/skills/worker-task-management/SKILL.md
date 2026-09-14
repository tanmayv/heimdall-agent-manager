---
name: worker-task-management
description: How a WORKER agent uses ham-ctl to execute assigned tasks, report progress, and hand off for review in a task chain. Load whenever you are a non-coordinator member of a chain.
---

# Worker task management (execute your assigned tasks)

You are a worker on this chain. Do the tasks ASSIGNED to you and report progress. Do not coordinate the whole chain or take on unassigned work — route that to the coordinator.

All commands use the managed wrapper: `./.heimdall/bin/ham-ctl`.

## 1. Find your work
- `./.heimdall/bin/ham-ctl task list [--chain <id>]` — list tasks; focus on those assigned to you and currently actionable.
- Read the task description and the chain description for the REQ-IDs your task must satisfy.

## 2. Do the work with visible progress
- Start: `./.heimdall/bin/ham-ctl task status <task-id> --status in_progress`.
- Comment at every meaningful step, on blockers, and before handoff: `./.heimdall/bin/ham-ctl task comment <task-id> --body "<what you did, what changed, what is next>"`.
- Do not do substantial work that has no task. If one is missing, ask the coordinator to create it (do not silently expand scope).

## 3. Hand off for review
- When done: `./.heimdall/bin/ham-ctl task status <task-id> --status in_validation`. Include a summary comment of what to review and the evidence (tests, commits, files).
- If you receive an `ngtm` vote, address the feedback, comment what you changed, and re-submit.

## 4. Reviewing (when you are a reviewer)
- Vote with `./.heimdall/bin/ham-ctl task vote <task-id> --result lgtm|ngtm [--comment "<feedback>"]`.

## 5. Communication
- Route questions, blockers, and user-facing messages through the coordinator (`chat send --to <coordinator-agent-instance-id>`).
- See the `heimdall-ctl-communication` skill for complete guidance on messaging syntax, chat conventions, and separating technical logs (task comments) from user communication (`chat send --to user`).
- Use `./.heimdall/bin/ham-ctl task nudge <task-id> [--message "<text>"]` to request attention on a stalled task you own or review.

Keep your task status and comments current at all times so the chain reflects real progress.