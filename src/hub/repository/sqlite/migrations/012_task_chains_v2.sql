ALTER TABLE task_chains ADD COLUMN description TEXT NOT NULL DEFAULT '';
ALTER TABLE tasks ADD COLUMN description TEXT NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS task_chain_members (
  chain_id TEXT NOT NULL,
  agent_instance_id TEXT NOT NULL,
  agent_id TEXT NOT NULL DEFAULT '',
  owner_user_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'worker',
  created_at TEXT NOT NULL,
  PRIMARY KEY (chain_id, agent_instance_id)
);

CREATE TABLE IF NOT EXISTS task_dependencies (
  task_id TEXT NOT NULL,
  depends_on_task_id TEXT NOT NULL,
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (task_id, depends_on_task_id)
);

CREATE TABLE IF NOT EXISTS task_votes (
  task_id TEXT NOT NULL,
  reviewer_agent_instance_id TEXT NOT NULL,
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  vote TEXT NOT NULL,
  comment TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (task_id, reviewer_agent_instance_id)
);

CREATE TRIGGER IF NOT EXISTS task_chain_members_owner_immutable BEFORE UPDATE OF owner_user_id ON task_chain_members BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS task_dependencies_owner_immutable BEFORE UPDATE OF owner_user_id ON task_dependencies BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS task_votes_owner_immutable BEFORE UPDATE OF owner_user_id ON task_votes BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
