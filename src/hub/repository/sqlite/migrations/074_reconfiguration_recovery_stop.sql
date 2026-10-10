-- A correlated successful Force stop releases recovery and fences late runtime
-- reports. The old operation and configuration-change history remain intact.
CREATE TRIGGER IF NOT EXISTS instance_reconfiguration_recovery_stopped
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
