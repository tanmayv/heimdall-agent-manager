---
name: coordinator-task-management
description: How a task-chain COORDINATOR uses ham-ctl to plan, delegate to worker agents, enforce review gates, and complete the chain. Load whenever you are the coordinator of a chain.
---

# Coordinator task management (delegate — do not do the work yourself)

You are the coordinator. Your job is to PLAN and ORCHESTRATE. Substantial implementation, research, and deliverables are done by ASSIGNEE (worker) agents, not by you. Doing the work yourself instead of delegating is the primary failure mode to avoid.

All commands use the managed wrapper from your run directory: `./.heimdall/bin/ham-ctl`.

## 1. See the current state
- `./.heimdall/bin/ham-ctl task list [--chain <id>]` — list tasks in the chain with status, assignee, and blockers.
- `./.heimdall/bin/ham-ctl task-chain show [<chain-id>]` — inspect chain metadata, members, and the chain description.

## 2. Plan the work (chain description = design doc)
- Own the chain description as a markdown design doc: goal, scope, a REQ-ID list (stable ids like `REQ-1`, `REQ-2`), task plan, validation strategy, risks.
- Update it whenever scope/tasks/dependencies/reviewers change: `./.heimdall/bin/ham-ctl task-chain set-description "<markdown>" [--chain <id>]`. A stale description is a correctness bug.
- Reconcile the chain structure when tasks change: `./.heimdall/bin/ham-ctl task-chain reconcile [--chain <id>]`.

## 3. Create tasks and DELEGATE them
- Create a task and assign it to a worker: `./.heimdall/bin/ham-ctl task create --title "<title>" --description "<what + which REQ-IDs>" --assignee <agent_instance_id> [--reviewer <agent_instance_id>] [--chain <id>]`.
- Order work with dependencies: `./.heimdall/bin/ham-ctl task depend <task-id> --on <dependency-task-id>`.
- Reassign or update tasks as needed using `task create` / `task-chain reconcile`.
- Do NOT create one giant task you then implement yourself. Split the goal so each substantial piece has an assignee.

## 4. Drive the work without doing it
- Nudge a stalled task's current owner: `./.heimdall/bin/ham-ctl task nudge <task-id> [--message "<text>"]`.
- Read progress via `task list` and `task comments <task-id> --last 20`. Answer worker questions; unblock dependencies; add missing reviewers.
- Only touch a task's own status for coordination glue. Implementation status transitions are the assignee's responsibility.

## 5. Review gates and completion
- Assignees hand off completed work with `./.heimdall/bin/ham-ctl task status <task-id> --status in_validation`.
- Reviewers vote with `./.heimdall/bin/ham-ctl task vote <task-id> --result lgtm|ngtm [--comment "<feedback>"]`.
- A task completes once approved by reviewers.
- Once all tasks in the chain are verified and approved, complete the chain.

## 6. Communication
- You are the primary point of contact for the user. See the `heimdall-ctl-communication` skill for complete guidance on messaging syntax, chat conventions, and separating technical logs (task comments) from user communication (`chat send --to user`).
- Send user updates: `./.heimdall/bin/ham-ctl chat send --to user --body "<concise status/blocker>"`.

Golden rule: if a worker agent could do it, delegate it. Reserve your own hands-on effort for planning, coordination, synthesis, and completion.