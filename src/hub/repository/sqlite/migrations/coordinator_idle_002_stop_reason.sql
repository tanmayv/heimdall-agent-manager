-- Why the Hub last stopped this instance (stop_instance reason, e.g.
-- user_requested, bot_idle, coordinator_idle_completed, coordinator_idle), so
-- the UI and instance events can say why it is stopped. Written only by
-- agent_set_stop_reason; the instance upsert clears it when a new run starts
-- (run_count increases) and otherwise never touches it.
ALTER TABLE agent_instances ADD COLUMN stop_reason TEXT NOT NULL DEFAULT '';
