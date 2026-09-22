CREATE TABLE IF NOT EXISTS task_chain_directories (
  directory_id TEXT PRIMARY KEY,
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  path TEXT NOT NULL,
  bridge_id TEXT NOT NULL DEFAULT '',
  vcs_kind TEXT NOT NULL DEFAULT '',
  vcs_info_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (chain_id) REFERENCES task_chains(chain_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_task_chain_directories_chain_owner ON task_chain_directories(chain_id, owner_user_id);
CREATE TRIGGER IF NOT EXISTS task_chain_directories_owner_immutable BEFORE UPDATE OF owner_user_id ON task_chain_directories BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
