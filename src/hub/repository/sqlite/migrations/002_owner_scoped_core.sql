CREATE TABLE IF NOT EXISTS bridges (
  bridge_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT '',
  label_is_user_customized INTEGER NOT NULL DEFAULT 0,
  machine_hostname TEXT NOT NULL DEFAULT '',
  machine_os TEXT NOT NULL DEFAULT '',
  machine_arch TEXT NOT NULL DEFAULT '',
  capabilities_json TEXT NOT NULL DEFAULT '',
  hub_url TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'offline',
  bridge_token_hash TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL DEFAULT '',
  revoked_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS bridge_enrollments (
  enrollment_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT '',
  token_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'pending',
  expires_at TEXT NOT NULL DEFAULT '',
  consumed_at TEXT NOT NULL DEFAULT '',
  consumed_by_bridge_id TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS agents (
  agent_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  slug TEXT NOT NULL,
  template_id TEXT NOT NULL DEFAULT '',
  default_provider TEXT NOT NULL DEFAULT '',
  default_tier TEXT NOT NULL DEFAULT '',
  instructions TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(owner_user_id, slug)
);

CREATE TABLE IF NOT EXISTS agent_bridge_support (
  agent_id TEXT NOT NULL,
  bridge_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  provider TEXT NOT NULL DEFAULT '',
  tier TEXT NOT NULL DEFAULT '',
  priority INTEGER NOT NULL DEFAULT 0,
  max_instances INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (agent_id, bridge_id)
);

CREATE TABLE IF NOT EXISTS agent_instances (
  agent_instance_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  agent_id TEXT NOT NULL,
  bridge_id TEXT NOT NULL,
  provider TEXT NOT NULL DEFAULT '',
  tier TEXT NOT NULL DEFAULT '',
  project_id TEXT NOT NULL DEFAULT '',
  project_path TEXT NOT NULL DEFAULT '',
  chain_id TEXT NOT NULL DEFAULT '',
  conversation_id TEXT NOT NULL DEFAULT '',
  runtime_status TEXT NOT NULL,
  startup_status TEXT NOT NULL DEFAULT '',
  activity_status TEXT NOT NULL DEFAULT '',
  status_message TEXT NOT NULL DEFAULT '',
  last_applied_seq INTEGER NOT NULL DEFAULT 0,
  run_count INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT NOT NULL DEFAULT '',
  stopped_at TEXT NOT NULL DEFAULT '',
  last_seen_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS projects (
  project_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  slug TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  repo_url TEXT NOT NULL DEFAULT '',
  vcs_kind TEXT NOT NULL DEFAULT '',
  default_path TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(owner_user_id, slug)
);

CREATE TABLE IF NOT EXISTS project_bridge_paths (
  project_id TEXT NOT NULL,
  bridge_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  path TEXT NOT NULL,
  is_validated INTEGER NOT NULL DEFAULT 0,
  last_validated_at TEXT NOT NULL DEFAULT '',
  validation_error TEXT NOT NULL DEFAULT '',
  validation_details_json TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project_id, bridge_id)
);

CREATE TABLE IF NOT EXISTS task_chains (
  chain_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  title TEXT NOT NULL,
  publish_state TEXT NOT NULL DEFAULT 'draft',
  status TEXT NOT NULL DEFAULT 'active',
  kind TEXT NOT NULL DEFAULT 'team_work',
  coordinator_agent_instance_id TEXT NOT NULL DEFAULT '',
  default_reviewer_refs_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  published_at TEXT NOT NULL DEFAULT '',
  completed_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS tasks (
  task_id TEXT PRIMARY KEY,
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  title TEXT NOT NULL,
  publish_state TEXT NOT NULL DEFAULT 'draft',
  status TEXT NOT NULL DEFAULT 'assigned',
  assignee_ref_json TEXT NOT NULL DEFAULT '{}',
  reviewer_refs_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  published_at TEXT NOT NULL DEFAULT '',
  started_at TEXT NOT NULL DEFAULT '',
  completed_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS task_comments (
  comment_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  author_agent_instance_id TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memories (
  memory_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  agent_id TEXT NOT NULL DEFAULT '',
  type TEXT NOT NULL DEFAULT 'fact',
  status TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL,
  evidence TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_conversations (
  conversation_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  agent_id TEXT NOT NULL DEFAULT '',
  agent_instance_id TEXT NOT NULL DEFAULT '',
  project_id TEXT NOT NULL DEFAULT '',
  chain_id TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL DEFAULT '',
  unread_count INTEGER NOT NULL DEFAULT 0,
  last_message_preview TEXT NOT NULL DEFAULT '',
  last_message_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_messages (
  message_id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  direction TEXT NOT NULL DEFAULT 'user_to_agent',
  sender_agent_id TEXT NOT NULL DEFAULT '',
  sender_agent_instance_id TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL,
  artifact_ids_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  delivered_at TEXT NOT NULL DEFAULT '',
  read_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS artifacts (
  artifact_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'file',
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  content_type TEXT NOT NULL DEFAULT '',
  size_bytes INTEGER NOT NULL DEFAULT 0,
  blob_ref TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  agent_id TEXT NOT NULL DEFAULT '',
  agent_instance_id TEXT NOT NULL DEFAULT '',
  chain_id TEXT NOT NULL DEFAULT '',
  task_id TEXT NOT NULL DEFAULT '',
  project_id TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS templates (
  template_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL DEFAULT '',
  is_system INTEGER NOT NULL DEFAULT 0,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  persona TEXT NOT NULL DEFAULT '',
  instructions TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS user_api_tokens (
  token_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT '',
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL DEFAULT '',
  expires_at TEXT NOT NULL DEFAULT '',
  revoked_at TEXT NOT NULL DEFAULT ''
);

CREATE TRIGGER IF NOT EXISTS bridges_owner_immutable BEFORE UPDATE OF owner_user_id ON bridges BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS bridge_enrollments_owner_immutable BEFORE UPDATE OF owner_user_id ON bridge_enrollments BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS agents_owner_immutable BEFORE UPDATE OF owner_user_id ON agents BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS agent_bridge_support_owner_immutable BEFORE UPDATE OF owner_user_id ON agent_bridge_support BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS agent_instances_owner_immutable BEFORE UPDATE OF owner_user_id ON agent_instances BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS projects_owner_immutable BEFORE UPDATE OF owner_user_id ON projects BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS project_bridge_paths_owner_immutable BEFORE UPDATE OF owner_user_id ON project_bridge_paths BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS task_chains_owner_immutable BEFORE UPDATE OF owner_user_id ON task_chains BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS tasks_owner_immutable BEFORE UPDATE OF owner_user_id ON tasks BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS task_comments_owner_immutable BEFORE UPDATE OF owner_user_id ON task_comments BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS memories_owner_immutable BEFORE UPDATE OF owner_user_id ON memories BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS chat_conversations_owner_immutable BEFORE UPDATE OF owner_user_id ON chat_conversations BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS chat_messages_owner_immutable BEFORE UPDATE OF owner_user_id ON chat_messages BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS artifacts_owner_immutable BEFORE UPDATE OF owner_user_id ON artifacts BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS templates_owner_immutable BEFORE UPDATE OF owner_user_id ON templates BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;
CREATE TRIGGER IF NOT EXISTS user_api_tokens_owner_immutable BEFORE UPDATE OF owner_user_id ON user_api_tokens BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_api_tokens_token_hash ON user_api_tokens(token_hash);

CREATE INDEX IF NOT EXISTS idx_search_agents_owner_lower_name ON agents(owner_user_id, lower(name));
CREATE INDEX IF NOT EXISTS idx_search_agents_owner_lower_slug ON agents(owner_user_id, lower(slug));
CREATE INDEX IF NOT EXISTS idx_search_agent_instances_owner_lower_agent ON agent_instances(owner_user_id, lower(agent_id));
CREATE INDEX IF NOT EXISTS idx_search_chat_conversations_owner_lower_title ON chat_conversations(owner_user_id, lower(title));
CREATE INDEX IF NOT EXISTS idx_search_task_chains_owner_lower_title ON task_chains(owner_user_id, lower(title));
CREATE INDEX IF NOT EXISTS idx_search_tasks_owner_lower_title ON tasks(owner_user_id, lower(title));
CREATE INDEX IF NOT EXISTS idx_search_projects_owner_lower_name ON projects(owner_user_id, lower(name));
CREATE INDEX IF NOT EXISTS idx_search_projects_owner_lower_slug ON projects(owner_user_id, lower(slug));
CREATE INDEX IF NOT EXISTS idx_search_artifacts_owner_lower_name ON artifacts(owner_user_id, lower(name));
CREATE INDEX IF NOT EXISTS idx_search_memories_owner_lower_title ON memories(owner_user_id, lower(title));
