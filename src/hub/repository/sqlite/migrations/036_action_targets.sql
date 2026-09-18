ALTER TABLE actions ADD COLUMN target_agent_id TEXT NOT NULL DEFAULT '';
ALTER TABLE actions ADD COLUMN target_bridge_id TEXT NOT NULL DEFAULT '';
ALTER TABLE actions ADD COLUMN target_provider TEXT NOT NULL DEFAULT '';
ALTER TABLE actions ADD COLUMN target_tier TEXT NOT NULL DEFAULT '';
ALTER TABLE actions ADD COLUMN target_project_id TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_actions_target_agent ON actions(target_agent_id);
CREATE INDEX IF NOT EXISTS idx_actions_target_bridge ON actions(target_bridge_id);
