ALTER TABLE task_chains ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0;
ALTER TABLE task_chains ADD COLUMN pinned_at TEXT NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS idx_task_chains_owner_pinned ON task_chains(owner_user_id, is_pinned, pinned_at);
