-- 210_agent_writes.sql: who changed what, for writes made by agent instances
-- through the routes relaxed in the bot capabilities slice. Append-only.
CREATE TABLE IF NOT EXISTS agent_writes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  write_id TEXT NOT NULL UNIQUE,
  owner_user_id TEXT NOT NULL,
  actor_agent_instance_id TEXT NOT NULL,
  actor_agent_id TEXT NOT NULL DEFAULT '',
  resource_kind TEXT NOT NULL CHECK (resource_kind IN ('project', 'memory', 'agent')),
  resource_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('create', 'update', 'archive', 'unarchive')),
  fields_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS agent_writes_owner_seq ON agent_writes(owner_user_id, seq DESC);
CREATE INDEX IF NOT EXISTS agent_writes_owner_resource ON agent_writes(owner_user_id, resource_kind, resource_id, seq DESC);
