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
  message_type TEXT NOT NULL DEFAULT 'text',
  message_status TEXT NOT NULL DEFAULT 'complete',
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  delivered_at TEXT NOT NULL DEFAULT '',
  read_at TEXT NOT NULL DEFAULT ''
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

MIGRATION_012_TASK_CHAINS_V2 :: `ALTER TABLE task_chains ADD COLUMN description TEXT NOT NULL DEFAULT '';
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
`

MIGRATION_013_TASK_WORKFLOW_SKILL_MEMORY :: `INSERT INTO memories (memory_id, owner_user_id, agent_id, type, status, title, body, evidence, created_at, updated_at)
VALUES (
  'mem_system_heimdall_tasks',
  'system',
  '',
  'skill',
  'active',
  'Heimdall Task Workflow Skill',
  'Use the managed Heimdall CLI wrapper to manage and execute tasks within your assigned task chain: ./.heimdall/bin/ham-ctl agent tasks ...\n\nFetch current tasks: run ./.heimdall/bin/ham-ctl agent tasks list (or fetch) to discover tasks assigned to you or available in your chain.\n\nCreate tasks: if you are the chain coordinator, decompose complex work into discrete tasks with ./.heimdall/bin/ham-ctl agent tasks create --title "<title>" --description "<description>". Set dependencies when appropriate.\n\nUpdate task status: start work by moving task to in_progress. When finished, submit for review with ./.heimdall/bin/ham-ctl agent tasks done --task-id <id> (or status --status in_validation).\n\nReview & Vote: as a reviewer, evaluate submitted tasks and record your decision with ./.heimdall/bin/ham-ctl agent tasks vote --task-id <id> --result lgtm|ngtm --comment "<feedback>".\n\nTask Comments: post progress updates or clarify requirements with ./.heimdall/bin/ham-ctl agent tasks comment --task-id <id> --body "<comment>".\n\nNudge: request attention on a stalled task with ./.heimdall/bin/ham-ctl agent tasks nudge --task-id <id>.',
  'Seeded system task workflow skill memory.',
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

INSERT INTO memories (memory_id, owner_user_id, agent_id, type, status, title, body, evidence, created_at, updated_at)
VALUES (
  'mem_system_use_current_chain_tasks',
  'system',
  '',
  'habit',
  'active',
  'Use Current Task Chain to Organize Work',
  'Organize all substantial work as tasks within your current task chain. Before starting work, check active tasks with ./.heimdall/bin/ham-ctl agent tasks fetch. Keep task status current as work progresses. Submit tasks for review using status --status in_validation when complete. If a reviewer returns NGTM, address feedback promptly and re-submit for review.',
  'Seeded system default habit memory.',
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

MIGRATION_014_TASK_WORKFLOW_SKILL_COMMENTS :: `UPDATE memories
SET body = 'Use the managed Heimdall CLI wrapper to manage and execute tasks within your assigned task chain: ./.heimdall/bin/ham-ctl agent tasks ...

Tracking work as tasks is REQUIRED, not optional. All substantial work must be represented by a task in your current task chain, and you must keep task status and comments current so the chain reflects real progress.

Fetch current tasks: run ./.heimdall/bin/ham-ctl agent tasks fetch (or list) to discover tasks assigned to you or available in your chain. Do this before starting any work.

Create tasks: if you are the chain coordinator, decompose complex work into discrete tasks with ./.heimdall/bin/ham-ctl agent tasks create --title "<title>" --description "<description>". Set dependencies when appropriate. If work has no task, create one or ask the coordinator to create one before proceeding.

Update task status: start work by moving the task to in_progress with ./.heimdall/bin/ham-ctl agent tasks status --task-id <id> --status in_progress. When finished, submit for review with ./.heimdall/bin/ham-ctl agent tasks done --task-id <id> (or status --status in_validation).

Comment progress on EVERY task (REQUIRED): as you work, post progress updates on the task with ./.heimdall/bin/ham-ctl agent tasks comment --task-id <id> --body "<what you did, what changed, what is next>". Add a comment at every meaningful step, when you hit a blocker, and with a review summary before submitting for review. Comments are the durable record of how the work progressed.

Review & Vote: as a reviewer, evaluate submitted tasks and record your decision with ./.heimdall/bin/ham-ctl agent tasks vote --task-id <id> --result lgtm|ngtm --comment "<feedback>". If you receive ngtm on your task, address the feedback, comment what you changed, and re-submit for review.

Nudge: request attention on a stalled task with ./.heimdall/bin/ham-ctl agent tasks nudge --task-id <id>.',
    evidence = 'Seeded system task workflow skill memory with mandatory progress-comment guidance.',
    updated_at = '2026-07-29T00:00:00Z'
WHERE memory_id = 'mem_system_heimdall_tasks';

UPDATE memories
SET body = 'Organize all substantial work as tasks within your current task chain; this is required. Before starting work, check active tasks with ./.heimdall/bin/ham-ctl agent tasks fetch. Move a task to in_progress when you start it, and post a progress comment on the task at every meaningful step with ./.heimdall/bin/ham-ctl agent tasks comment --task-id <id> --body "<update>". Keep task status current as work progresses. Submit tasks for review using status --status in_validation (or tasks done) when complete, including a summary comment. If a reviewer returns NGTM, address feedback promptly, comment what you changed, and re-submit for review.',
    evidence = 'Seeded system default habit memory with mandatory progress-comment guidance.',
    updated_at = '2026-07-29T00:00:00Z'
WHERE memory_id = 'mem_system_use_current_chain_tasks';
`

MIGRATION_015_MEMORY_TARGET_SCOPE :: `ALTER TABLE memories ADD COLUMN project_id TEXT NOT NULL DEFAULT '';
ALTER TABLE memories ADD COLUMN template_id TEXT NOT NULL DEFAULT '';
ALTER TABLE memories ADD COLUMN bridge_id TEXT NOT NULL DEFAULT '';
`

MIGRATION_018_COORDINATOR_MEMBER_BACKFILL :: `INSERT OR IGNORE INTO task_chain_members (chain_id, agent_instance_id, agent_id, owner_user_id, role, created_at)
SELECT c.chain_id, c.coordinator_agent_instance_id, '', c.owner_user_id, 'coordinator', c.created_at
FROM task_chains c
WHERE c.coordinator_agent_instance_id IS NOT NULL AND c.coordinator_agent_instance_id <> ''
  AND NOT EXISTS (SELECT 1 FROM task_chain_members m WHERE m.chain_id = c.chain_id AND m.role = 'coordinator');`

MIGRATION_017_CHAT_MESSAGE_TYPES :: `ALTER TABLE chat_messages ADD COLUMN message_type TEXT NOT NULL DEFAULT 'text';
ALTER TABLE chat_messages ADD COLUMN message_status TEXT NOT NULL DEFAULT 'complete';
ALTER TABLE chat_messages ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}';
`

MIGRATION_016_MEMORY_WORKFLOW_SKILL_MEMORY :: `INSERT INTO memories (memory_id, owner_user_id, agent_id, project_id, template_id, bridge_id, type, status, title, body, evidence, created_at, updated_at)
VALUES (
  'mem_system_heimdall_memory',
  'system',
  '',
  '',
  '',
  '',
  'skill',
  'active',
  'Heimdall Memory Management & Workflow Skill',
  '---
name: memory-management-workflow
description: Core guidance for Heimdall memory management, scope selection, proposal review, and ham-ctl CLI commands.
---

# Heimdall Memory Management & Workflow Skill

Use Heimdall memory management for managing long-term agent knowledge, project scopes, habits, facts, and expertise.

## Scope Selection Rules
- **Agent Scope** (agent_id): Knowledge specific to an agent definition across instances.
- **Project Scope** (project_id): Knowledge scoped to a specific project repository.
- **Bridge Scope** (bridge_id): Host environment or infrastructure knowledge.
- **Template Scope** (template_id): Guidance for agents initialized from a specific template.
- **Global Scope**: Leave scope fields empty for system-wide knowledge.
- **Ephemeral Instances**: Ephemeral instance memories bind durably to the instance''s underlying agent_id (and project/bridge where applicable).

## Memory Types
- fact: Static declarative truth or project configuration.
- habit: Behavioral pattern or operational preference.
- episode: Record of specific past event or task run outcome.
- expertise: Special knowledge, architectural insight, or deep domain rule.
- skill: Machine-actionable procedure or SKILL.md instruction set.
Template targeting is available through template_id scope; template is not a memory type.

## Propose-Review-Approve Workflow
- Agents propose new memories in pending status using ham-ctl or agent actions.
- Humans review pending proposals in Settings -> Memory UI or CLI.
- Proposals can be edited before approval, approved directly (flipping status to active), or rejected.
- System memories (owner_user_id = ''system'') are read-only.

## CLI Usage Examples (ham-ctl)
- Propose a memory: ./.heimdall/bin/ham-ctl agent memory propose --title "Build Rule" --type "fact" --body "Always run tests before committing."
- Approve proposal: ./.heimdall/bin/ham-ctl memory approve mem_123
- List memories: ./.heimdall/bin/ham-ctl memory list --status active',
  'Seeded system default memory for memory workflow skill.',
  '2026-07-29T00:00:00Z',
  '2026-07-29T00:00:00Z'
)
ON CONFLICT(memory_id) DO UPDATE SET
  agent_id=excluded.agent_id,
  project_id=excluded.project_id,
  template_id=excluded.template_id,
  bridge_id=excluded.bridge_id,
  type=excluded.type,
  status=excluded.status,
  title=excluded.title,
  body=excluded.body,
  evidence=excluded.evidence,
  updated_at=excluded.updated_at;
`

MIGRATION_019_CURRENT_TASK_AND_PRIORITY :: `ALTER TABLE agent_instances ADD COLUMN current_task_id TEXT NOT NULL DEFAULT '';
ALTER TABLE agent_instances ADD COLUMN current_task_role TEXT NOT NULL DEFAULT 'none';
ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'p2';
`

// MIGRATION_020_TITLE_TRACKING adds per-run auto-title tracking fields to
// conversations and task chains, plus a per-agent monotonic counter table used
// to mint default titles of the form "<agent-name> #<n>". The embedded fallback
// mirrors src/hub/repository/sqlite/migrations/020_title_tracking.sql.
MIGRATION_020_TITLE_TRACKING :: `ALTER TABLE chat_conversations ADD COLUMN last_activity_at TEXT NOT NULL DEFAULT '';
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
`

// MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME adds human-readable display_name
// support to agent_instances, defaulting to "<agent-name> #<n>".
MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME :: `ALTER TABLE agent_instances ADD COLUMN display_name TEXT NOT NULL DEFAULT '';
`

// MIGRATION_022_SCHEDULED_PROMPTS adds the scheduled_prompts table for
// delayed and recurring prompt injection into agent instances.
MIGRATION_022_SCHEDULED_PROMPTS :: `CREATE TABLE IF NOT EXISTS scheduled_prompts (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  target_instance_id TEXT NOT NULL,
  prompt_text TEXT NOT NULL,
  target_run_at TEXT NOT NULL,
  interval TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active',
  in_flight INTEGER NOT NULL DEFAULT 0,
  leased_at TEXT NOT NULL DEFAULT '',
  deleted_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_scheduled_prompts_target ON scheduled_prompts(target_instance_id);
`

migration_order :: [22]string{"001_foundation.sql", "002_owner_scoped_core.sql", "003_device_tokens.sql", "004_default_skill_memory.sql", "005_agent_to_agent_cross_chain_memory.sql", "006_live_agents_skill_memory.sql", "007_hide_agent_to_agent_from_user_chat.sql", "008_read_inbound_messages_skill_memory.sql", "009_artifact_metadata.sql", "010_artifact_usage_skill_memory.sql", "011_artifact_download_skill_memory.sql", "012_task_chains_v2.sql", "013_task_workflow_skill_memory.sql", "014_task_workflow_skill_comments.sql", "015_memory_target_scope.sql", "016_memory_workflow_skill_memory.sql", "017_chat_message_types.sql", "018_coordinator_member_backfill.sql", "019_current_task_and_priority.sql", "020_title_tracking.sql", "021_agent_instance_display_name.sql", "022_scheduled_prompts.sql"}

run_migrations :: proc(conn: ^Conn, migrations_dir := "src/hub/repository/sqlite/migrations") -> (bool, domain.Domain_Error) {
	if conn == nil || conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "database connection is not open")
	}
	for name in migration_order {
		if name == "016_memory_workflow_skill_memory.sql" {
			if !upgrade_memory_target_scope_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory target scope schema upgrade failed")
		}
		if migration_applied(conn, name) do continue
		if name == "003_device_tokens.sql" && table_column_exists(conn, "user_api_tokens", "created_from") && table_column_exists(conn, "user_api_tokens", "device_label") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "017_chat_message_types.sql" && table_column_exists(conn, "chat_messages", "message_type") && table_column_exists(conn, "chat_messages", "message_status") && table_column_exists(conn, "chat_messages", "metadata_json") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "019_current_task_and_priority.sql" && table_column_exists(conn, "agent_instances", "current_task_id") && table_column_exists(conn, "agent_instances", "current_task_role") && table_column_exists(conn, "tasks", "priority") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "020_title_tracking.sql" && table_column_exists(conn, "chat_conversations", "title_source") && table_column_exists(conn, "task_chains", "title_source") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "021_agent_instance_display_name.sql" && table_column_exists(conn, "agent_instances", "display_name") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "022_scheduled_prompts.sql" && table_column_exists(conn, "scheduled_prompts", "id") {
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
	if !upgrade_task_chains_v2_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_chains_v2 schema upgrade failed")
	if !upgrade_memory_target_scope_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory target scope schema upgrade failed")
	if !upgrade_chat_message_types_schema(conn) do return false, domain.domain_error(.Internal_Error, "chat message type schema upgrade failed")
	if !upgrade_current_task_and_priority_schema(conn) do return false, domain.domain_error(.Internal_Error, "current task + priority schema upgrade failed")
	if !upgrade_title_tracking_schema(conn) do return false, domain.domain_error(.Internal_Error, "title tracking schema upgrade failed")
	if !upgrade_agent_instance_display_name_schema(conn) do return false, domain.domain_error(.Internal_Error, "agent instance display_name schema upgrade failed")
	if !upgrade_scheduled_prompts_schema(conn) do return false, domain.domain_error(.Internal_Error, "scheduled prompts schema upgrade failed")
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
	if name == "012_task_chains_v2.sql" do return strings.clone(MIGRATION_012_TASK_CHAINS_V2)
	if name == "013_task_workflow_skill_memory.sql" do return strings.clone(MIGRATION_013_TASK_WORKFLOW_SKILL_MEMORY)
	if name == "014_task_workflow_skill_comments.sql" do return strings.clone(MIGRATION_014_TASK_WORKFLOW_SKILL_COMMENTS)
	if name == "015_memory_target_scope.sql" do return strings.clone(MIGRATION_015_MEMORY_TARGET_SCOPE)
	if name == "016_memory_workflow_skill_memory.sql" do return strings.clone(MIGRATION_016_MEMORY_WORKFLOW_SKILL_MEMORY)
	if name == "017_chat_message_types.sql" do return strings.clone(MIGRATION_017_CHAT_MESSAGE_TYPES)
	if name == "018_coordinator_member_backfill.sql" do return strings.clone(MIGRATION_018_COORDINATOR_MEMBER_BACKFILL)
	if name == "019_current_task_and_priority.sql" do return strings.clone(MIGRATION_019_CURRENT_TASK_AND_PRIORITY)
	if name == "020_title_tracking.sql" do return strings.clone(MIGRATION_020_TITLE_TRACKING)
	if name == "021_agent_instance_display_name.sql" do return strings.clone(MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME)
	if name == "022_scheduled_prompts.sql" do return strings.clone(MIGRATION_022_SCHEDULED_PROMPTS)
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

upgrade_task_chains_v2_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "task_chains", "description") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN description TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "tasks", "description") && !exec(conn, "ALTER TABLE tasks ADD COLUMN description TEXT NOT NULL DEFAULT '';") do return false
	return true
}

upgrade_memory_target_scope_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "memories", "project_id") && !exec(conn, "ALTER TABLE memories ADD COLUMN project_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "memories", "template_id") && !exec(conn, "ALTER TABLE memories ADD COLUMN template_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "memories", "bridge_id") && !exec(conn, "ALTER TABLE memories ADD COLUMN bridge_id TEXT NOT NULL DEFAULT '';") do return false
	return true
}

upgrade_chat_message_types_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "chat_messages", "message_type") && !exec(conn, "ALTER TABLE chat_messages ADD COLUMN message_type TEXT NOT NULL DEFAULT 'text';") do return false
	if !table_column_exists(conn, "chat_messages", "message_status") && !exec(conn, "ALTER TABLE chat_messages ADD COLUMN message_status TEXT NOT NULL DEFAULT 'complete';") do return false
	if !table_column_exists(conn, "chat_messages", "metadata_json") && !exec(conn, "ALTER TABLE chat_messages ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}';") do return false
	return true
}

upgrade_current_task_and_priority_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "agent_instances", "current_task_id") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN current_task_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "agent_instances", "current_task_role") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN current_task_role TEXT NOT NULL DEFAULT 'none';") do return false
	if !table_column_exists(conn, "tasks", "priority") && !exec(conn, "ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'p2';") do return false
	return true
}

upgrade_title_tracking_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "chat_conversations", "last_activity_at") && !exec(conn, "ALTER TABLE chat_conversations ADD COLUMN last_activity_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "chat_conversations", "last_title_nudge_at") && !exec(conn, "ALTER TABLE chat_conversations ADD COLUMN last_title_nudge_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "chat_conversations", "title_source") && !exec(conn, "ALTER TABLE chat_conversations ADD COLUMN title_source TEXT NOT NULL DEFAULT 'default';") do return false
	if !table_column_exists(conn, "task_chains", "last_activity_at") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN last_activity_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "task_chains", "last_title_nudge_at") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN last_title_nudge_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "task_chains", "title_source") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN title_source TEXT NOT NULL DEFAULT 'default';") do return false
	if !exec(conn, "CREATE TABLE IF NOT EXISTS agent_title_counters (agent_id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, counter INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT '');") do return false
	return true
}

upgrade_agent_instance_display_name_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "agent_instances", "display_name") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN display_name TEXT NOT NULL DEFAULT '';") do return false
	return true
}

upgrade_scheduled_prompts_schema :: proc(conn: ^Conn) -> bool {
	return exec(conn, `CREATE TABLE IF NOT EXISTS scheduled_prompts (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  target_instance_id TEXT NOT NULL,
  prompt_text TEXT NOT NULL,
  target_run_at TEXT NOT NULL,
  interval TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active',
  in_flight INTEGER NOT NULL DEFAULT 0,
  leased_at TEXT NOT NULL DEFAULT '',
  deleted_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_scheduled_prompts_target ON scheduled_prompts(target_instance_id);`)
}

