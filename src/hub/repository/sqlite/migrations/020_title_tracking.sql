ALTER TABLE chat_conversations ADD COLUMN last_activity_at TEXT NOT NULL DEFAULT '';
ALTER TABLE chat_conversations ADD COLUMN last_title_nudge_at TEXT NOT NULL DEFAULT '';
ALTER TABLE chat_conversations ADD COLUMN title_source TEXT NOT NULL DEFAULT 'default';
ALTER TABLE task_chains ADD COLUMN last_activity_at TEXT NOT NULL DEFAULT '';
ALTER TABLE task_chains ADD COLUMN last_title_nudge_at TEXT NOT NULL DEFAULT '';
ALTER TABLE task_chains ADD COLUMN title_source TEXT NOT NULL DEFAULT 'default';
CREATE TABLE IF NOT EXISTS agent_title_counters (
  agent_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  counter INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT ''
);
