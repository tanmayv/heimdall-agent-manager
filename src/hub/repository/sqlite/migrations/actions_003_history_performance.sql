-- Replaces narrower lookup indexes; see scripts/benchmark-action-queries.py.
DROP INDEX action_runs_action;
CREATE INDEX action_runs_action ON action_runs(action_id,created_at,run_id);
DROP INDEX pipeline_deliveries_open;
CREATE INDEX pipeline_deliveries_open ON pipeline_deliveries(bridge_id,created_at,delivery_id) WHERE state IN ('routed','forwarded');
CREATE INDEX action_runs_closed_age ON action_runs(created_at,run_id) WHERE state NOT IN ('queued','deferred','routed');
