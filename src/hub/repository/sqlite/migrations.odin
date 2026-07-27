package sqlite

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"

MIGRATION_001_FOUNDATION :: `CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS users (
  user_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  email TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
`
MIGRATION_002_OWNER_SCOPED_CORE :: `CREATE TABLE IF NOT EXISTS bridges (
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
  instance_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  agent_id TEXT NOT NULL,
  bridge_id TEXT NOT NULL,
  runtime_status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
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
  body TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_conversations (
  conversation_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_messages (
  message_id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS artifacts (
  artifact_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  blob_ref TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS templates (
  template_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  body TEXT NOT NULL,
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
`

// MIGRATION_003_DEVICE_TOKENS is the embedded fallback for the token-provenance
// migration (ELDA-4). The canonical source is
// src/hub/repository/sqlite/migrations/003_device_tokens.sql.
MIGRATION_003_DEVICE_TOKENS :: `ALTER TABLE user_api_tokens ADD COLUMN created_from TEXT NOT NULL DEFAULT 'operator';
ALTER TABLE user_api_tokens ADD COLUMN device_label TEXT NOT NULL DEFAULT '';
`

migration_order :: [3]string{"001_foundation.sql", "002_owner_scoped_core.sql", "003_device_tokens.sql"}

run_migrations :: proc(conn: ^Conn, migrations_dir := "src/hub/repository/sqlite/migrations") -> (bool, domain.Domain_Error) {
	if conn == nil || conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "database connection is not open")
	}
	for name in migration_order {
		if migration_applied(conn, name) do continue
		if name == "003_device_tokens.sql" && table_column_exists(conn, "user_api_tokens", "created_from") && table_column_exists(conn, "user_api_tokens", "device_label") {
			mark_migration_applied(conn, name)
			continue
		}
		sql := migration_sql(name, migrations_dir)
		if sql == "" {
			return false, domain.domain_error(.Internal_Error, fmt.tprintf("missing migration %s", name))
		}
		if !exec(conn, sql) {
			delete(sql)
			return false, domain.domain_error(.Internal_Error, fmt.tprintf("migration failed: %s", name))
		}
		mark_migration_applied(conn, name)
		delete(sql)
	}
	if !upgrade_user_api_tokens_schema(conn) do return false, domain.domain_error(.Internal_Error, "user_api_tokens schema upgrade failed")
	if !upgrade_task_comments_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_comments schema upgrade failed")
	return true, domain.Domain_Error{}
}

migration_sql :: proc(name, migrations_dir: string) -> string {
	path := strings.concatenate({migrations_dir, "/", name})
	data, err := os.read_entire_file(path, context.allocator)
	if err == nil {
		return strings.clone(string(data))
	}
	if name == "001_foundation.sql" do return strings.clone(MIGRATION_001_FOUNDATION)
	if name == "002_owner_scoped_core.sql" do return strings.clone(MIGRATION_002_OWNER_SCOPED_CORE)
	if name == "003_device_tokens.sql" do return strings.clone(MIGRATION_003_DEVICE_TOKENS)
	return ""
}

migration_applied :: proc(conn: ^Conn, version: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("SELECT 1 FROM schema_migrations WHERE version='%s' LIMIT 1;", escape_sql_literal(version))
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	return sqlite3_step(stmt) == SQLITE_ROW
}

mark_migration_applied :: proc(conn: ^Conn, version: string) {
	query := fmt.tprintf("INSERT OR IGNORE INTO schema_migrations (version) VALUES ('%s');", escape_sql_literal(version))
	exec(conn, query)
}

upgrade_user_api_tokens_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "user_api_tokens", "label") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN label TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "last_used_at") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN last_used_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "expires_at") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN expires_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "revoked_at") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN revoked_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "created_from") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN created_from TEXT NOT NULL DEFAULT 'operator';") do return false
	if !table_column_exists(conn, "user_api_tokens", "device_label") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN device_label TEXT NOT NULL DEFAULT '';") do return false
	if !exec(conn, "CREATE UNIQUE INDEX IF NOT EXISTS idx_user_api_tokens_token_hash ON user_api_tokens(token_hash);") do return false
	return true
}

upgrade_task_comments_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "task_comments", "author_agent_instance_id") && !exec(conn, "ALTER TABLE task_comments ADD COLUMN author_agent_instance_id TEXT NOT NULL DEFAULT '';") do return false
	return true
}

table_column_exists :: proc(conn: ^Conn, table_name, column_name: string) -> bool {
	if conn == nil || conn.db == nil do return false
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("PRAGMA table_info(%s);", table_name)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	for sqlite3_step(stmt) == SQLITE_ROW {
		if column_text(stmt, 1) == column_name do return true
	}
	return false
}

escape_sql_literal :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in value {
		if ch == '\'' {
			strings.write_string(&builder, "''")
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	return strings.to_string(builder)
}
