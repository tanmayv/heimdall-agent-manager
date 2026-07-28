UPDATE memories
SET body = 'Use the managed Heimdall CLI wrapper to manage and execute tasks within your assigned task chain: ./.heimdall/bin/ham-ctl agent tasks ...

Tracking work as tasks is REQUIRED, not optional. All substantial work must be represented by a task in your current task chain, and you must keep task status and comments current so the chain reflects real progress.

Fetch current tasks: run ./.heimdall/bin/ham-ctl agent tasks fetch (or list) to discover tasks assigned to you or available in your chain. Do this before starting any work.

Create tasks: if you are the chain coordinator, decompose complex work into discrete tasks with ./.heimdall/bin/ham-ctl agent tasks create --title "<title>" --description "<description>". Set dependencies when appropriate. If work has no task, create one or ask the coordinator to create one before proceeding.

Update task status: start work by moving the task to in_progress with ./.heimdall/bin/ham-ctl agent tasks status --task-id <id> --status in_progress. When finished, submit for review with ./.heimdall/bin/ham-ctl agent tasks done --task-id <id> (or status --status in_validation).

Comment progress on EVERY task (REQUIRED): as you work, post progress updates on the task with ./.heimdall/bin/ham-ctl agent tasks comment --task-id <id> --body "<what you did, what changed, what is next>". Add a comment at every meaningful step, when you hit a blocker, and with a review summary before submitting for review. Comments are the durable record of how the work progressed.

Review & Vote: as a reviewer, evaluate submitted tasks and record your decision with ./.heimdall/bin/ham-ctl agent tasks vote --task-id <id> --result lgtm|ngtm --comment "<feedback>". If you receive ngtm on your task, address the feedback, comment what you changed, and re-submit for review.

Nudge: request attention on a stalled task with ./.heimdall/bin/ham-ctl agent tasks nudge --task-id <id>.',
    evidence = 'Seeded system task workflow skill memory with mandatory progress-comment guidance.',
    updated_at = '2026-07-29T00:00:00Z'
WHERE memory_id = 'mem_system_heimdall_tasks';

UPDATE memories
SET body = 'Organize all substantial work as tasks within your current task chain; this is required. Before starting work, check active tasks with ./.heimdall/bin/ham-ctl agent tasks fetch. Move a task to in_progress when you start it, and post a progress comment on the task at every meaningful step with ./.heimdall/bin/ham-ctl agent tasks comment --task-id <id> --body "<update>". Keep task status current as work progresses. Submit tasks for review using status --status in_validation (or tasks done) when complete, including a summary comment. If a reviewer returns NGTM, address feedback promptly, comment what you changed, and re-submit for review.',
    evidence = 'Seeded system default habit memory with mandatory progress-comment guidance.',
    updated_at = '2026-07-29T00:00:00Z'
WHERE memory_id = 'mem_system_use_current_chain_tasks';
