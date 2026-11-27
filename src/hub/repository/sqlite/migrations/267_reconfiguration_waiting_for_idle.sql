-- Deferred apply (agent settings panel, T4): a reconfiguration may be queued
-- until the current turn ends. Adds phase 'waiting_for_idle', which does NOT
-- block input (blocks_input=0) but still holds the instance's single
-- active-operation slot, so the exclusive index now covers both.
-- SQLite cannot alter a CHECK, so the table is rebuilt. Every trigger on it is
-- dropped with the old table and recreated unchanged (commit = 265's body;
-- requested = 072; recovery_stopped = 074). instance_reconfiguration_hold_messages
-- (on chat_messages) is dropped first so the RENAME sees no dangling reference.
-- The outcome trigger now words a cancelled or superseded queued change as
-- 'Configuration change cancelled' instead of 'failed'.
-- run_migrations skips this file when the table SQL already admits
-- waiting_for_idle and the LAST statement's trigger exists.
BEGIN;
DROP TRIGGER IF EXISTS instance_reconfiguration_hold_messages;
CREATE TABLE instance_reconfigurations_v266 (
  operation_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  agent_instance_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision >= 1),
  phase TEXT NOT NULL CHECK (phase IN ('prepared','stopping','source_stopped','launching','ready','failed','recovery_required','waiting_for_idle')),
  blocks_input INTEGER NOT NULL CHECK (blocks_input IN (0,1)),
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (owner_user_id, agent_instance_id, idempotency_key)
);
INSERT INTO instance_reconfigurations_v266 (operation_id, owner_user_id, agent_instance_id, idempotency_key, revision, phase, blocks_input, payload_json, created_at, updated_at)
  SELECT operation_id, owner_user_id, agent_instance_id, idempotency_key, revision, phase, blocks_input, payload_json, created_at, updated_at FROM instance_reconfigurations;
DROP TABLE instance_reconfigurations;
ALTER TABLE instance_reconfigurations_v266 RENAME TO instance_reconfigurations;
-- One active operation per instance: blocking, or queued after the turn.
CREATE UNIQUE INDEX instance_reconfigurations_exclusive
  ON instance_reconfigurations(agent_instance_id) WHERE blocks_input = 1 OR phase = 'waiting_for_idle';
CREATE INDEX instance_reconfigurations_owner_instance
  ON instance_reconfigurations(owner_user_id, agent_instance_id, created_at DESC);

-- Same body as 263.
CREATE TRIGGER instance_reconfiguration_commit
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
      AND provider_profile = COALESCE(NULLIF(json_extract(NEW.payload_json, '$.source.provider_profile'),''),json_extract(NEW.payload_json, '$.source.provider'))
      AND model = json_extract(NEW.payload_json, '$.source.model')
  ) THEN RAISE(ABORT, 'configuration changed before move commit') END;
  UPDATE agent_instances SET
    bridge_id = json_extract(NEW.payload_json, '$.destination.bridge_id'),
    project_id = json_extract(NEW.payload_json, '$.destination.project_id'),
    project_path = json_extract(NEW.payload_json, '$.destination.project_path'),
    provider = json_extract(NEW.payload_json, '$.destination.provider'),
    provider_profile = COALESCE(NULLIF(json_extract(NEW.payload_json, '$.destination.provider_profile'),''),json_extract(NEW.payload_json, '$.destination.provider')),
    model = json_extract(NEW.payload_json, '$.destination.model'),
    runtime_transport = COALESCE(NULLIF(json_extract(NEW.payload_json, '$.destination.runtime_transport'),''),'pty'),
    runtime_transport_override = COALESCE(json_extract(NEW.payload_json, '$.destination.runtime_transport_override'), runtime_transport_override),
    permission_mode = COALESCE(json_extract(NEW.payload_json, '$.destination.permission_mode'), permission_mode),
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

-- Same body as 072.
CREATE TRIGGER instance_reconfiguration_requested
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

-- 072 plus cancelled/superseded wording for a queued change that never fired.
CREATE TRIGGER instance_reconfiguration_outcome
AFTER UPDATE OF phase ON instance_reconfigurations
WHEN NEW.phase IN ('ready', 'failed', 'recovery_required') AND NEW.phase != OLD.phase
BEGIN
  INSERT OR IGNORE INTO chat_messages (message_id, conversation_id, owner_user_id, direction,
    sender_agent_instance_id, body, artifact_ids_json, message_type, message_status,
    metadata_json, created_at)
  SELECT NEW.operation_id || '_' || NEW.phase, conversation_id, NEW.owner_user_id,
    'agent_to_user', NEW.agent_instance_id,
    CASE WHEN NEW.phase = 'ready' THEN 'Configuration changed'
      WHEN NEW.phase = 'failed' AND OLD.phase = 'waiting_for_idle'
        AND json_extract(NEW.payload_json, '$.failure_code') IN ('cancelled', 'superseded') THEN 'Configuration change cancelled'
      WHEN NEW.phase = 'failed' THEN 'Configuration change failed'
      ELSE 'Configuration change needs recovery' END,
    '[]', 'configuration_change', CASE NEW.phase WHEN 'ready' THEN 'complete' ELSE 'failed' END,
    json_set(NEW.payload_json, '$.phase', NEW.phase), NEW.updated_at
  FROM chat_conversations WHERE conversation_id = json_extract(NEW.payload_json, '$.conversation_id')
    AND owner_user_id = NEW.owner_user_id AND agent_instance_id = NEW.agent_instance_id;
END;

-- Same body as 074.
CREATE TRIGGER instance_reconfiguration_recovery_stopped
BEFORE UPDATE OF phase ON instance_reconfigurations
WHEN NEW.phase = 'failed' AND OLD.phase = 'recovery_required'
  AND json_extract(NEW.payload_json, '$.failure_code') = 'recovery_stopped'
  AND json_extract(OLD.payload_json, '$.failure_code') = 'force_stopping'
BEGIN
  UPDATE agent_instances SET runtime_status = 'stopped', startup_status = 'stopped',
    activity_status = 'unknown', stopped_at = NEW.updated_at, updated_at = NEW.updated_at,
    launch_epoch = 'stopped_' || NEW.operation_id,
    configuration_revision = configuration_revision + 1
  WHERE agent_instance_id = NEW.agent_instance_id AND owner_user_id = NEW.owner_user_id;
END;

-- Same body as 072 (waiting_for_idle rows have blocks_input = 0, so they never hold messages).
CREATE TRIGGER instance_reconfiguration_hold_messages
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
COMMIT;
