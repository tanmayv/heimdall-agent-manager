-- A batch is a pipeline delivery; members keep their existing run rows.
CREATE INDEX action_runs_delivery ON action_runs(delivery_id) WHERE state = 'routed';
CREATE INDEX action_runs_parked ON action_runs(target_instance_id) WHERE state = 'deferred' AND target_instance_id <> '';
