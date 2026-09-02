-- CT-1: persist an instance's current task focus (single source of truth for
-- which task an agent is actively working or reviewing).
ALTER TABLE agent_instances ADD COLUMN current_task_id TEXT NOT NULL DEFAULT '';
ALTER TABLE agent_instances ADD COLUMN current_task_role TEXT NOT NULL DEFAULT 'none';

-- CT-3: task priority for work-queue ordering. Defaults to the lowest urgency
-- (p2); the auto-promotion engine orders p0 > p1 > p2.
ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'p2';
