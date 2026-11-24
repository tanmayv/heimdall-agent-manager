CREATE INDEX pipeline_deliveries_instance_prompt_pending ON pipeline_deliveries(agent_instance_id) WHERE kind = 'prompt' AND state IN ('routed','forwarded','delivered');
CREATE INDEX action_runs_instance_routed ON action_runs(target_instance_id,started_at) WHERE state = 'routed';
