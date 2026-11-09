BEGIN IMMEDIATE;
-- The Hub task-chain engine is removed: every chain is Bridge-owned
-- (owner-local). Existing legacy rows stay as read-only records that the
-- one-shot importer exports to an owner Bridge; nothing creates new ones.
-- No table or row is dropped.
CREATE TRIGGER hub_chains_removed_task_chains_insert BEFORE INSERT ON task_chains
BEGIN SELECT RAISE(ABORT,'hub_chains_removed'); END;
CREATE TRIGGER hub_chains_removed_tasks_insert BEFORE INSERT ON tasks
BEGIN SELECT RAISE(ABORT,'hub_chains_removed'); END;
-- The importer neutralizes busy legacy work itself (no engine is left to
-- drain it). What it did is recorded on the migration row: a JSON array of
-- {code,count,items} and the force-held task ids.
ALTER TABLE owner_legacy_migrations ADD COLUMN neutralized_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE owner_legacy_migrations ADD COLUMN forced_held_json TEXT NOT NULL DEFAULT '[]';
INSERT INTO schema_migrations(version) VALUES('213_hub_chains_removed.sql');
COMMIT;
