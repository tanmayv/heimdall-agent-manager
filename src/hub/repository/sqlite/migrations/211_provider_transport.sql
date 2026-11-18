BEGIN IMMEDIATE;
-- Provider-wide runtime choice; existing launches and catalog defaults remain PTY.
ALTER TABLE provider_catalog ADD COLUMN transports TEXT NOT NULL DEFAULT '["pty"]'
  CHECK (json_valid(transports) AND json_type(transports) = 'array'
         AND json_array_length(transports) BETWEEN 1 AND 2);
ALTER TABLE provider_catalog ADD COLUMN default_transport TEXT NOT NULL DEFAULT 'pty'
  CHECK (default_transport IN ('pty','acp'));
ALTER TABLE provider_catalog ADD COLUMN acp_recipe TEXT DEFAULT NULL
  CHECK (acp_recipe IS NULL OR
         (json_valid(acp_recipe) AND json_type(acp_recipe) = 'object'));
ALTER TABLE bridge_provider_settings ADD COLUMN transport TEXT DEFAULT NULL
  CHECK (transport IS NULL OR
         (transport IN ('pty','acp') AND profile_id = provider));
ALTER TABLE bridge_provider_status ADD COLUMN acp_adapter TEXT DEFAULT NULL
  CHECK (acp_adapter IS NULL OR
         (json_valid(acp_adapter) AND json_type(acp_adapter) = 'object'));
ALTER TABLE agent_instances ADD COLUMN runtime_transport TEXT NOT NULL DEFAULT 'pty'
  CHECK (runtime_transport IN ('pty','acp'));

CREATE TRIGGER provider_transport_insert BEFORE INSERT ON provider_catalog
BEGIN
  SELECT CASE WHEN
    EXISTS (SELECT 1 FROM json_each(NEW.transports)
            WHERE type <> 'text' OR value NOT IN ('pty','acp'))
    OR (SELECT count(*) FROM json_each(NEW.transports)) <>
       (SELECT count(DISTINCT value) FROM json_each(NEW.transports))
    OR NOT EXISTS (SELECT 1 FROM json_each(NEW.transports)
                   WHERE value = NEW.default_transport)
    OR (EXISTS (SELECT 1 FROM json_each(NEW.transports) WHERE value='acp')
        AND NEW.acp_recipe IS NULL)
  THEN RAISE(ABORT, 'invalid provider transport contract') END;
END;
CREATE TRIGGER provider_transport_update
BEFORE UPDATE OF transports, default_transport, acp_recipe ON provider_catalog
BEGIN
  SELECT CASE WHEN
    EXISTS (SELECT 1 FROM json_each(NEW.transports)
            WHERE type <> 'text' OR value NOT IN ('pty','acp'))
    OR (SELECT count(*) FROM json_each(NEW.transports)) <>
       (SELECT count(DISTINCT value) FROM json_each(NEW.transports))
    OR NOT EXISTS (SELECT 1 FROM json_each(NEW.transports)
                   WHERE value = NEW.default_transport)
    OR (EXISTS (SELECT 1 FROM json_each(NEW.transports) WHERE value='acp')
        AND NEW.acp_recipe IS NULL)
  THEN RAISE(ABORT, 'invalid provider transport contract') END;
END;

UPDATE provider_catalog SET
  transports='["pty","acp"]', default_transport='pty',
  acp_recipe='{"command":"claude-agent-acp","args":[],"env":{"CLAUDE_AGENT_ACP_PROTOCOL":"v1"},"protocol_version":1,"adapter_package":"@agentclientprotocol/claude-agent-acp","adapter_version":"0.108.0"}'
WHERE provider='claude';

CREATE TABLE acp_assistant_turns (
  agent_instance_id TEXT NOT NULL REFERENCES agent_instances(agent_instance_id) ON DELETE CASCADE,
  launch_epoch TEXT NOT NULL,
  turn_id TEXT NOT NULL,
  message_id TEXT NOT NULL UNIQUE REFERENCES chat_messages(message_id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK (revision >= 1),
  payload_hash TEXT NOT NULL,
  PRIMARY KEY (agent_instance_id, launch_epoch, turn_id)
);

-- Reconfiguration commits the frozen destination snapshot with the launch epoch.
DROP TRIGGER instance_reconfiguration_commit;
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

-- Canonical catalog body hash, including all runtime transport fields.
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta(catalog_etag) VALUES ('sha256:d570576e77256f085d8b2eb03343d0d7d72072770b8455fae8702873910c400b');

COMMIT;
