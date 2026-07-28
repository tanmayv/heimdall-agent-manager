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

MIGRATION_004_DEFAULT_SKILL_MEMORY :: `INSERT INTO memories (memory_id, owner_user_id, agent_id, type, status, title, body, evidence, created_at, updated_at)
VALUES (
  'mem_system_heimdall_ctl_communication',
  'system',
  '',
  'skill',
  'active',
  'Heimdall CLI communication basics',
  'Use the managed Heimdall CLI wrapper from the agent run directory for all Heimdall communication: ./.heimdall/bin/ham-ctl. The wrapper injects HEIMDALL_AGENT_TOKEN, HEIMDALL_AGENT_INSTANCE_ID, and HEIMDALL_BRIDGE_ENDPOINT, so do not paste tokens into commands unless explicitly needed.\n\nStartup: after you are fully ready, report readiness with ./.heimdall/bin/ham-ctl agent start-success.\n\nList live agents: to discover other running instances you can message, run ./.heimdall/bin/ham-ctl agents live (equivalent: ./.heimdall/bin/ham-ctl agent agents live). Use returned agent_instance_id values for agent-to-agent messaging; do not rely on display names.\n\nReading inbound messages: when notified about a new message, run ./.heimdall/bin/ham-ctl agent chat read before responding. This fetches the agent-visible conversation transcript, including user_to_agent messages from the user and agent_to_agent messages from other agents. Treat chat messages from the user as authoritative task guidance.\n\nReplying to the user: use ./.heimdall/bin/ham-ctl agent chat send --body "<concise status or answer>". Keep replies concise, include concrete results, blockers, and next steps. Do not dump large logs or files inline; summarize and attach/create an artifact when appropriate.\n\nAgent-to-agent communication: use ./.heimdall/bin/ham-ctl agent chat send-to-agent --to-instance <agent_instance_id> --body "..." when you know the target instance id. This is allowed across task chains and across bridges for agents owned by the same user. Target exact agent_instance_id values.\n\nTask communication: prefer durable Heimdall task comments/status/chat commands over ad-hoc terminal notes. Reference stable IDs such as agent_instance_id, task_id, chain_id, artifact_id, and file paths.\n\nBest practices: acknowledge messages promptly, state what you changed or checked, include exact commands/tests run when reporting completion, mention blockers explicitly, and avoid exposing secrets or raw tokens in chat, comments, artifacts, or logs.',
  'Seeded system default memory. Applies to all agents because agent_id is empty and owner_user_id is system.',
  '2026-07-28T00:00:00Z',
  '2026-07-28T00:00:00Z'
)
ON CONFLICT(memory_id) DO UPDATE SET
  agent_id=excluded.agent_id,
  type=excluded.type,
  status=excluded.status,
  title=excluded.title,
  body=excluded.body,
  evidence=excluded.evidence,
  updated_at=excluded.updated_at;
`

MIGRATION_005_AGENT_TO_AGENT_CROSS_CHAIN_MEMORY :: `UPDATE memories
SET body = 'Use the managed Heimdall CLI wrapper from the agent run directory for all Heimdall communication: ./.heimdall/bin/ham-ctl. The wrapper injects HEIMDALL_AGENT_TOKEN, HEIMDALL_AGENT_INSTANCE_ID, and HEIMDALL_BRIDGE_ENDPOINT, so do not paste tokens into commands unless explicitly needed.\n\nStartup: after you are fully ready, report readiness with ./.heimdall/bin/ham-ctl agent start-success.\n\nList live agents: to discover other running instances you can message, run ./.heimdall/bin/ham-ctl agents live (equivalent: ./.heimdall/bin/ham-ctl agent agents live). Use returned agent_instance_id values for agent-to-agent messaging; do not rely on display names.\n\nReading inbound messages: when notified about a new message, run ./.heimdall/bin/ham-ctl agent chat read before responding. This fetches the agent-visible conversation transcript, including user_to_agent messages from the user and agent_to_agent messages from other agents. Treat chat messages from the user as authoritative task guidance.\n\nReplying to the user: use ./.heimdall/bin/ham-ctl agent chat send --body "<concise status or answer>". Keep replies concise, include concrete results, blockers, and next steps. Do not dump large logs or files inline; summarize and attach/create an artifact when appropriate.\n\nAgent-to-agent communication: use ./.heimdall/bin/ham-ctl agent chat send-to-agent --to-instance <agent_instance_id> --body "..." when you know the target instance id. This is allowed across task chains and across bridges for agents owned by the same user. Target exact agent_instance_id values.\n\nTask communication: prefer durable Heimdall task comments/status/chat commands over ad-hoc terminal notes. Reference stable IDs such as agent_instance_id, task_id, chain_id, artifact_id, and file paths.\n\nBest practices: acknowledge messages promptly, state what you changed or checked, include exact commands/tests run when reporting completion, mention blockers explicitly, and avoid exposing secrets or raw tokens in chat, comments, artifacts, or logs.',
    updated_at = '2026-07-28T00:10:00Z'
WHERE memory_id = 'mem_system_heimdall_ctl_communication';
`


MIGRATION_006_LIVE_AGENTS_SKILL_MEMORY :: `UPDATE memories
SET body = 'Use the managed Heimdall CLI wrapper from the agent run directory for all Heimdall communication: ./.heimdall/bin/ham-ctl. The wrapper injects HEIMDALL_AGENT_TOKEN, HEIMDALL_AGENT_INSTANCE_ID, and HEIMDALL_BRIDGE_ENDPOINT, so do not paste tokens into commands unless explicitly needed.\n\nStartup: after you are fully ready, report readiness with ./.heimdall/bin/ham-ctl agent start-success.\n\nList live agents: to discover other running instances you can message, run ./.heimdall/bin/ham-ctl agents live (equivalent: ./.heimdall/bin/ham-ctl agent agents live). Use returned agent_instance_id values for agent-to-agent messaging; do not rely on display names.\n\nReading inbound messages: when notified about a new message, run ./.heimdall/bin/ham-ctl agent chat read before responding. This fetches the agent-visible conversation transcript, including user_to_agent messages from the user and agent_to_agent messages from other agents. Treat chat messages from the user as authoritative task guidance.\n\nReplying to the user: use ./.heimdall/bin/ham-ctl agent chat send --body "<concise status or answer>". Keep replies concise, include concrete results, blockers, and next steps. Do not dump large logs or files inline; summarize and attach/create an artifact when appropriate.\n\nAgent-to-agent communication: use ./.heimdall/bin/ham-ctl agent chat send-to-agent --to-instance <agent_instance_id> --body "..." when you know the target instance id. This is allowed across task chains and across bridges for agents owned by the same user. Target exact agent_instance_id values.\n\nTask communication: prefer durable Heimdall task comments/status/chat commands over ad-hoc terminal notes. Reference stable IDs such as agent_instance_id, task_id, chain_id, artifact_id, and file paths.\n\nBest practices: acknowledge messages promptly, state what you changed or checked, include exact commands/tests run when reporting completion, mention blockers explicitly, and avoid exposing secrets or raw tokens in chat, comments, artifacts, or logs.',
    updated_at = '2026-07-28T00:20:00Z'
WHERE memory_id = 'mem_system_heimdall_ctl_communication';
`


MIGRATION_007_HIDE_AGENT_TO_AGENT_FROM_USER_CHAT :: `-- Agent-to-agent messages are delivered to the target instance inbox, but they
-- must not drive the human-facing conversation transcript/preview.
UPDATE chat_conversations
SET
  last_message_preview = COALESCE((
    SELECT m.body
    FROM chat_messages m
    WHERE m.conversation_id = chat_conversations.conversation_id
      AND m.owner_user_id = chat_conversations.owner_user_id
      AND m.direction != 'agent_to_agent'
    ORDER BY m.created_at DESC
    LIMIT 1
  ), ''),
  last_message_at = COALESCE((
    SELECT m.created_at
    FROM chat_messages m
    WHERE m.conversation_id = chat_conversations.conversation_id
      AND m.owner_user_id = chat_conversations.owner_user_id
      AND m.direction != 'agent_to_agent'
    ORDER BY m.created_at DESC
    LIMIT 1
  ), ''),
  updated_at = COALESCE((
    SELECT m.created_at
    FROM chat_messages m
    WHERE m.conversation_id = chat_conversations.conversation_id
      AND m.owner_user_id = chat_conversations.owner_user_id
      AND m.direction != 'agent_to_agent'
    ORDER BY m.created_at DESC
    LIMIT 1
  ), chat_conversations.updated_at)
WHERE EXISTS (
  SELECT 1 FROM chat_messages a
  WHERE a.conversation_id = chat_conversations.conversation_id
    AND a.owner_user_id = chat_conversations.owner_user_id
    AND a.direction = 'agent_to_agent'
)
AND NOT EXISTS (
  SELECT 1 FROM chat_messages newer_visible
  WHERE newer_visible.conversation_id = chat_conversations.conversation_id
    AND newer_visible.owner_user_id = chat_conversations.owner_user_id
    AND newer_visible.direction != 'agent_to_agent'
    AND newer_visible.created_at > (
      SELECT MAX(a2a.created_at)
      FROM chat_messages a2a
      WHERE a2a.conversation_id = chat_conversations.conversation_id
        AND a2a.owner_user_id = chat_conversations.owner_user_id
        AND a2a.direction = 'agent_to_agent'
    )
);
`


MIGRATION_008_READ_INBOUND_MESSAGES_SKILL_MEMORY :: `UPDATE memories
SET body = replace(
  replace(
    body,
    'Reading user messages: when notified about a new message, run ./.heimdall/bin/ham-ctl agent chat read before responding. Treat chat messages from the user as authoritative task guidance.',
    'Reading inbound messages: when notified about a new message, run ./.heimdall/bin/ham-ctl agent chat read before responding. This fetches the agent-visible conversation transcript, including user_to_agent messages from the user and agent_to_agent messages from other agents. Treat chat messages from the user as authoritative task guidance.'
  ),
  'Reading user messages: when notified about a new message, run ./.heimdall/bin/ham-ctl agent chat read before responding. Treat chat messages from the user as authoritative task guidance.',
  'Reading inbound messages: when notified about a new message, run ./.heimdall/bin/ham-ctl agent chat read before responding. This fetches the agent-visible conversation transcript, including user_to_agent messages from the user and agent_to_agent messages from other agents. Treat chat messages from the user as authoritative task guidance.'
),
updated_at = '2026-07-28T00:25:00Z'
WHERE memory_id = 'mem_system_heimdall_ctl_communication';
`

MIGRATION_009_ARTIFACT_METADATA :: `ALTER TABLE artifacts ADD COLUMN mime TEXT NOT NULL DEFAULT '';
ALTER TABLE artifacts ADD COLUMN ext TEXT NOT NULL DEFAULT '';
ALTER TABLE artifacts ADD COLUMN sha256 TEXT NOT NULL DEFAULT '';
ALTER TABLE artifacts ADD COLUMN origin_kind TEXT NOT NULL DEFAULT '';
ALTER TABLE artifacts ADD COLUMN origin_ref TEXT NOT NULL DEFAULT '';
ALTER TABLE artifacts ADD COLUMN deleted_at TEXT;
`

MIGRATION_010_ARTIFACT_USAGE_SKILL_MEMORY :: `UPDATE memories
SET body = body || '

Artifacts: use artifacts for large logs, screenshots, diffs, generated files, or any output too large/noisy for chat. Create artifacts from an agent run with ./.heimdall/bin/ham-ctl agent artifacts create --name "<name>" --kind markdown --content "...", --file <path>, or --stdin; use --content-type <mime> when useful. List available artifacts with ./.heimdall/bin/ham-ctl agent artifacts list. Inspect metadata with ./.heimdall/bin/ham-ctl agent artifacts show --artifact-id <artifact_id> or include content with --with-content. Read artifact bodies with ./.heimdall/bin/ham-ctl agent artifacts read --artifact-id <artifact_id> (aliases: content or get). When reporting work, summarize briefly in chat and include the artifact_id / artifact://<artifact_id> reference rather than pasting large content inline.',
    updated_at = '2026-07-28T00:30:00Z'
WHERE memory_id = 'mem_system_heimdall_ctl_communication'
  AND instr(body, 'Artifacts: use artifacts for large logs') = 0;
`

MIGRATION_011_ARTIFACT_DOWNLOAD_SKILL_MEMORY :: `UPDATE memories
SET body = replace(
  body,
  'Read artifact bodies with ./.heimdall/bin/ham-ctl agent artifacts read --artifact-id <artifact_id> (aliases: content or get).',
  'Read artifact bodies with ./.heimdall/bin/ham-ctl agent artifacts read --artifact-id <artifact_id> (aliases: content or get). To materialize an artifact as a local file, run ./.heimdall/bin/ham-ctl agent artifacts download --artifact-id <artifact_id> --dir <directory>; it writes a random filename with the inferred extension and returns the filename/path.'
),
updated_at = '2026-07-28T22:45:00Z'
WHERE memory_id = 'mem_system_heimdall_ctl_communication'
  AND instr(body, 'artifacts download --artifact-id') = 0;
`

migration_order :: [11]string{"001_foundation.sql", "002_owner_scoped_core.sql", "003_device_tokens.sql", "004_default_skill_memory.sql", "005_agent_to_agent_cross_chain_memory.sql", "006_live_agents_skill_memory.sql", "007_hide_agent_to_agent_from_user_chat.sql", "008_read_inbound_messages_skill_memory.sql", "009_artifact_metadata.sql", "010_artifact_usage_skill_memory.sql", "011_artifact_download_skill_memory.sql"}

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
	if name == "004_default_skill_memory.sql" do return strings.clone(MIGRATION_004_DEFAULT_SKILL_MEMORY)
	if name == "005_agent_to_agent_cross_chain_memory.sql" do return strings.clone(MIGRATION_005_AGENT_TO_AGENT_CROSS_CHAIN_MEMORY)
	if name == "006_live_agents_skill_memory.sql" do return strings.clone(MIGRATION_006_LIVE_AGENTS_SKILL_MEMORY)
	if name == "007_hide_agent_to_agent_from_user_chat.sql" do return strings.clone(MIGRATION_007_HIDE_AGENT_TO_AGENT_FROM_USER_CHAT)
	if name == "008_read_inbound_messages_skill_memory.sql" do return strings.clone(MIGRATION_008_READ_INBOUND_MESSAGES_SKILL_MEMORY)
	if name == "009_artifact_metadata.sql" do return strings.clone(MIGRATION_009_ARTIFACT_METADATA)
	if name == "010_artifact_usage_skill_memory.sql" do return strings.clone(MIGRATION_010_ARTIFACT_USAGE_SKILL_MEMORY)
	if name == "011_artifact_download_skill_memory.sql" do return strings.clone(MIGRATION_011_ARTIFACT_DOWNLOAD_SKILL_MEMORY)
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
