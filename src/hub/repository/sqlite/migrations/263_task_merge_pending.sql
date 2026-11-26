-- Scale B: a durable merge_pending projection on tasks, so hub boot
-- (rebuild_timers) and bridge hello (requeue_pending_merges) read only the
-- Done tasks whose merge-back never settled instead of every Done task's event
-- log.
--
-- merge_pending mirrors taskv2.merge_pending(events) exactly: 1 while the
-- task's latest completion (approved | submitted) has no merged or
-- merge_conflict after it. merge_failed does not clear it (a failed merge is
-- retried on bridge hello). task_event_append_sqlite keeps it in sync in the
-- same transaction as the event; this migration backfills it once.
--
-- The backfill leaves out owner legacy frozen/imported chains (the TEMP view
-- owner_legacy_frozen_chains run_migrations provides; empty without the
-- fences): their rows are read-only under the owner_legacy_guard_* triggers
-- and cannot have a live merge.
-- One transaction: a failed backfill leaves no half-applied column behind.
BEGIN;
ALTER TABLE tasks ADD COLUMN merge_pending INTEGER NOT NULL DEFAULT 0;

UPDATE tasks SET merge_pending = 1
WHERE tasks.chain_id NOT IN (SELECT chain_id FROM owner_legacy_frozen_chains)
AND (
  SELECT e.kind FROM task_events e
  WHERE e.task_id = tasks.task_id
    AND e.kind IN ('approved', 'submitted', 'merged', 'merge_conflict')
  ORDER BY e.event_id DESC LIMIT 1
) IN ('approved', 'submitted');

CREATE INDEX IF NOT EXISTS idx_tasks_merge_pending ON tasks(state, created_at) WHERE merge_pending = 1;
COMMIT;
