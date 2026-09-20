CREATE INDEX IF NOT EXISTS idx_artifacts_owner_project_created ON artifacts(owner_user_id, project_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_instance_created ON artifacts(owner_user_id, agent_instance_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_chain_created ON artifacts(owner_user_id, chain_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_task_created ON artifacts(owner_user_id, task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_created ON artifacts(owner_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_updated ON artifacts(owner_user_id, updated_at DESC);
