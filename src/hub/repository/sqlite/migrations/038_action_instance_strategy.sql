-- Opt-in "fresh instance per run" strategy for scheduled actions (REQ-SCHED-2).
-- instance_strategy: 'reuse' (default, legacy behavior) reuses/wakes an existing
-- instance of the durable agent-id; 'fresh_per_run' mints a new instance on every
-- fire and reaps the previous one. last_spawned_instance_id tracks the instance
-- created by the previous fresh_per_run fire so the next fire can reap it. Both
-- default to backward-compatible values so existing rows behave exactly as before.
ALTER TABLE actions ADD COLUMN instance_strategy TEXT NOT NULL DEFAULT 'reuse';
ALTER TABLE actions ADD COLUMN last_spawned_instance_id TEXT NOT NULL DEFAULT '';
