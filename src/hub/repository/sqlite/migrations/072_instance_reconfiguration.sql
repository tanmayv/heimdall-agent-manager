CREATE TABLE IF NOT EXISTS instance_reconfigurations (
  operation_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  agent_instance_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision >= 1),
  phase TEXT NOT NULL CHECK (phase IN ('prepared','stopping','source_stopped','launching','ready','failed','recovery_required')),
  blocks_input INTEGER NOT NULL CHECK (blocks_input IN (0,1)),
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (owner_user_id, agent_instance_id, idempotency_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS instance_reconfigurations_exclusive
  ON instance_reconfigurations(agent_instance_id) WHERE blocks_input = 1;
CREATE INDEX IF NOT EXISTS instance_reconfigurations_owner_instance
  ON instance_reconfigurations(owner_user_id, agent_instance_id, created_at DESC);

ALTER TABLE agent_instances ADD COLUMN configuration_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE agent_instances ADD COLUMN launch_epoch TEXT NOT NULL DEFAULT '';

-- Atomic move commit: operation progress, instance routing and conversation scope
-- either all change together or none do. Only a confirmed source stop may commit.
CREATE TRIGGER IF NOT EXISTS instance_reconfiguration_commit
BEFORE UPDATE OF phase ON instance_reconfigurations
WHEN NEW.phase = 'launching' AND OLD.phase = 'source_stopped'
BEGIN
  SELECT CASE WHEN json_extract(NEW.payload_json, '$.source_stopped') != 1
    OR json_extract(NEW.payload_json, '$.destination_committed') != 1
    THEN RAISE(ABORT, 'source termination must be confirmed') END;
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM agent_instances WHERE agent_instance_id = NEW.agent_instance_id
      AND owner_user_id = NEW.owner_user_id
      AND configuration_revision = json_extract(NEW.payload_json, '$.expected_revision')
      AND bridge_id = json_extract(NEW.payload_json, '$.source.bridge_id')
      AND project_id = json_extract(NEW.payload_json, '$.source.project_id')
      AND provider = json_extract(NEW.payload_json, '$.source.provider')
      AND model = json_extract(NEW.payload_json, '$.source.model')
  ) THEN RAISE(ABORT, 'configuration changed before move commit') END;
  UPDATE agent_instances SET
    bridge_id = json_extract(NEW.payload_json, '$.destination.bridge_id'),
    project_id = json_extract(NEW.payload_json, '$.destination.project_id'),
    project_path = json_extract(NEW.payload_json, '$.destination.project_path'),
    provider = json_extract(NEW.payload_json, '$.destination.provider'),
    model = json_extract(NEW.payload_json, '$.destination.model'),
    configuration_revision = configuration_revision + 1,
    launch_epoch = json_extract(NEW.payload_json, '$.launch_epoch'),
    runtime_status = 'launching', startup_status = 'starting', activity_status = 'unknown',
    run_count = run_count + 1, last_applied_seq = 0,
    started_at = NEW.updated_at, stopped_at = '', updated_at = NEW.updated_at,
    last_seen_at = NEW.updated_at
  WHERE agent_instance_id = NEW.agent_instance_id AND owner_user_id = NEW.owner_user_id;
  UPDATE chat_conversations SET project_id = json_extract(NEW.payload_json, '$.destination.project_id'),
    updated_at = NEW.updated_at
  WHERE conversation_id = json_extract(NEW.payload_json, '$.conversation_id')
    AND agent_instance_id = NEW.agent_instance_id AND owner_user_id = NEW.owner_user_id;
END;

-- Durable, deduplicated system records. These are UI events, never user prompts.
CREATE TRIGGER IF NOT EXISTS instance_reconfiguration_requested
AFTER INSERT ON instance_reconfigurations
BEGIN
  INSERT INTO chat_messages (message_id, conversation_id, owner_user_id, direction,
    sender_agent_instance_id, body, artifact_ids_json, message_type, message_status,
    metadata_json, created_at)
  SELECT NEW.operation_id || '_requested', conversation_id, NEW.owner_user_id,
    'agent_to_user', NEW.agent_instance_id, 'Configuration change requested', '[]',
    'configuration_change', 'pending',
    json_set(NEW.payload_json, '$.phase', NEW.phase), NEW.created_at
  FROM chat_conversations WHERE conversation_id = json_extract(NEW.payload_json, '$.conversation_id')
    AND owner_user_id = NEW.owner_user_id AND agent_instance_id = NEW.agent_instance_id;
END;
CREATE TRIGGER IF NOT EXISTS instance_reconfiguration_outcome
AFTER UPDATE OF phase ON instance_reconfigurations
WHEN NEW.phase IN ('ready', 'failed', 'recovery_required') AND NEW.phase != OLD.phase
BEGIN
  INSERT OR IGNORE INTO chat_messages (message_id, conversation_id, owner_user_id, direction,
    sender_agent_instance_id, body, artifact_ids_json, message_type, message_status,
    metadata_json, created_at)
  SELECT NEW.operation_id || '_' || NEW.phase, conversation_id, NEW.owner_user_id,
    'agent_to_user', NEW.agent_instance_id,
    CASE NEW.phase WHEN 'ready' THEN 'Configuration changed' WHEN 'failed' THEN 'Configuration change failed' ELSE 'Configuration change needs recovery' END,
    '[]', 'configuration_change', CASE NEW.phase WHEN 'ready' THEN 'complete' ELSE 'failed' END,
    json_set(NEW.payload_json, '$.phase', NEW.phase), NEW.updated_at
  FROM chat_conversations WHERE conversation_id = json_extract(NEW.payload_json, '$.conversation_id')
    AND owner_user_id = NEW.owner_user_id AND agent_instance_id = NEW.agent_instance_id;
END;

-- Close the check/save race for all incoming message writers, including callers
-- outside the conversation UI. Operation-authored system events remain allowed.
CREATE TRIGGER IF NOT EXISTS instance_reconfiguration_hold_messages
BEFORE INSERT ON chat_messages
WHEN NEW.direction IN ('user_to_agent', 'agent_to_agent') AND EXISTS (
  SELECT 1 FROM instance_reconfigurations op JOIN chat_conversations conversation
    ON conversation.agent_instance_id = op.agent_instance_id
  WHERE conversation.conversation_id = NEW.conversation_id
    AND op.owner_user_id = NEW.owner_user_id AND op.blocks_input = 1
)
BEGIN
  SELECT RAISE(ABORT, 'conversation is read-only while configuration changes');
END;
