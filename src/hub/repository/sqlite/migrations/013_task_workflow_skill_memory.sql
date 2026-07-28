INSERT INTO memories (memory_id, owner_user_id, agent_id, type, status, title, body, evidence, created_at, updated_at)
VALUES (
  'mem_system_heimdall_tasks',
  'system',
  '',
  'skill',
  'active',
  'Heimdall Task Workflow Skill',
  'Use the managed Heimdall CLI wrapper to manage and execute tasks within your assigned task chain: ./.heimdall/bin/ham-ctl agent tasks ...\n\nFetch current tasks: run ./.heimdall/bin/ham-ctl agent tasks list (or fetch) to discover tasks assigned to you or available in your chain.\n\nCreate tasks: if you are the chain coordinator, decompose complex work into discrete tasks with ./.heimdall/bin/ham-ctl agent tasks create --title "<title>" --description "<description>". Set dependencies when appropriate.\n\nUpdate task status: start work by moving task to in_progress. When finished, submit for review with ./.heimdall/bin/ham-ctl agent tasks done --task-id <id> (or status --status in_validation).\n\nReview & Vote: as a reviewer, evaluate submitted tasks and record your decision with ./.heimdall/bin/ham-ctl agent tasks vote --task-id <id> --result lgtm|ngtm --comment "<feedback>".\n\nTask Comments: post progress updates or clarify requirements with ./.heimdall/bin/ham-ctl agent tasks comment --task-id <id> --body "<comment>".\n\nNudge: request attention on a stalled task with ./.heimdall/bin/ham-ctl agent tasks nudge --task-id <id>.',
  'Seeded system task workflow skill memory.',
  '2026-07-28T00:00:00Z',
  '2026-07-28T00:00:00Z'
)
ON CONFLICT(memory_id) DO UPDATE SET
  agent_id=excluded.agent_id,
  type=excluded.type,
  status=excluded.status,
  title=excluded.title,
  body=excluded.body,
  evidence=excluded.evidence,
  updated_at=excluded.updated_at;

INSERT INTO memories (memory_id, owner_user_id, agent_id, type, status, title, body, evidence, created_at, updated_at)
VALUES (
  'mem_system_use_current_chain_tasks',
  'system',
  '',
  'habit',
  'active',
  'Use Current Task Chain to Organize Work',
  'Organize all substantial work as tasks within your current task chain. Before starting work, check active tasks with ./.heimdall/bin/ham-ctl agent tasks fetch. Keep task status current as work progresses. Submit tasks for review using status --status in_validation when complete. If a reviewer returns NGTM, address feedback promptly and re-submit for review.',
  'Seeded system default habit memory.',
  '2026-07-28T00:00:00Z',
  '2026-07-28T00:00:00Z'
)
ON CONFLICT(memory_id) DO UPDATE SET
  agent_id=excluded.agent_id,
  type=excluded.type,
  status=excluded.status,
  title=excluded.title,
  body=excluded.body,
  evidence=excluded.evidence,
  updated_at=excluded.updated_at;
