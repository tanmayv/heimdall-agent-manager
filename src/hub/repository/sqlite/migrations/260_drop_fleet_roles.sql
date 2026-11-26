-- SCHED-0b (spec art_18eb828949cd9431, sections 6.4 and 11.2): fleet roles,
-- per-role pause and lease review roles are gone. The role data the one-shot
-- SCHED-0a boot mapping still needs was snapshotted into sched0_fleet_roles by
-- migration 259, so dropping the columns here cannot lose it.
--
-- task_reviews.role stays (it is in the primary key); an agent verdict is now
-- written as 'review'. Rows written under the SCHED-0a interim name 'named' are
-- renamed; a row that would collide with an existing 'review' row is left as it
-- is (the gate matches agent verdicts by reviewer agent, not by role).
--
-- Rows of owner legacy frozen/imported chains are read-only (the fence triggers
-- abort any write) and are skipped: owner_legacy_frozen_chains is the TEMP view
-- run_migrations provides, empty on a database without the fences. A database
-- with the fences runs ../migration_variants/260_drop_fleet_roles_owner_legacy.sql
-- under this ledger name instead, because a fence trigger reads
-- task_leases.review_role. Keep the two in step.
--
-- One transaction, so a failure leaves 260 unapplied rather than half-dropped.
BEGIN IMMEDIATE;

UPDATE OR IGNORE task_reviews SET role = 'review' WHERE reviewer_kind = 'agent' AND role = 'named'
  AND chain_id NOT IN (SELECT chain_id FROM owner_legacy_frozen_chains)
  AND coalesce((SELECT t.chain_id FROM tasks t WHERE t.task_id = task_reviews.task_id), '') NOT IN (SELECT chain_id FROM owner_legacy_frozen_chains);

-- task_chain_fleets.paused was kept equal to paused_roles_json by the 0a
-- repository; settle it once more before the source column goes.
UPDATE task_chain_fleets SET paused = 1 WHERE trim(paused_roles_json) NOT IN ('', '[]')
  AND task_chain_id NOT IN (SELECT chain_id FROM owner_legacy_frozen_chains);

ALTER TABLE task_chain_fleets DROP COLUMN roles_json;
ALTER TABLE task_chain_fleets DROP COLUMN paused_roles_json;
ALTER TABLE task_leases DROP COLUMN review_role;

COMMIT;
