---
name: task-workflow
description: Use when starting, resuming, updating, or handing off Heimdall task work. It explains task authority, comments, unresolved items, and review handoff.
heimdall_managed: true
---

# Task workflow
- Start by reading the task chain, the current task, predecessor evidence, and unresolved comments.
- Treat task and participant state as the only source of current responsibility: assignee implements, coordinator routes user-facing decisions, reviewers vote LGTM/NGTM, subscribers observe.
- Keep progress and evidence in task comments; resolve informational comments before handoff.
- Before marking done, list unresolved comments, address or explicitly defer each one, and include changed files plus validation commands in the completion comment.
- Marking done means ready for review, not self-approval.
