-- A batch is a pipeline delivery; members keep their existing run rows.
CREATE INDEX IF NOT EXISTS action_runs_delivery_members ON action_runs(delivery_id) WHERE delivery_id <> '';
CREATE INDEX IF NOT EXISTS action_runs_target_parked ON action_runs(owner_user_id,target_instance_id,not_before) WHERE state='deferred' AND target_instance_id <> '';
