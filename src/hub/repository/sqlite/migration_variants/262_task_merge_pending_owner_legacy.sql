-- 262_task_merge_pending.sql for a database that carries the owner legacy
-- source fences (bridge-owned legacy chain export; see the hub's
-- owner_legacy_migrations table). The owner_legacy_guard_* triggers RAISE
-- 'legacy canonical source is frozen' on any write to the tasks of a chain
-- whose owner_legacy_migrations.state is 'frozen' or 'imported', so the
-- backfill leaves those chains out: their rows are read-only and cannot have a
-- live merge. Otherwise identical to migrations/262_task_merge_pending.sql.
-- One transaction: a failed backfill leaves no half-applied column behind.
BEGIN;
ALTER TABLE tasks ADD COLUMN merge_pending INTEGER NOT NULL DEFAULT 0;

UPDATE tasks SET merge_pending = 1
WHERE tasks.chain_id NOT IN (
  SELECT m.chain_id FROM owner_legacy_migrations m WHERE m.state IN ('frozen', 'imported')
)
AND (
  SELECT e.kind FROM task_events e
  WHERE e.task_id = tasks.task_id
    AND e.kind IN ('approved', 'submitted', 'merged', 'merge_conflict')
  ORDER BY e.event_id DESC LIMIT 1
) IN ('approved', 'submitted');

CREATE INDEX IF NOT EXISTS idx_tasks_merge_pending ON tasks(state, created_at) WHERE merge_pending = 1;
COMMIT;
