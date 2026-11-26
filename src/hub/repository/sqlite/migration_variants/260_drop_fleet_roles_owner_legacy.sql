-- 260_drop_fleet_roles.sql for a database that carries the owner legacy source
-- fences (owner_legacy_migrations and the owner_legacy_* triggers, created by
-- the bridge-owned legacy chain export on deployments that ran it, e.g. Mundus).
-- run_migrations executes this file under the 260 ledger name instead of
-- migrations/260_drop_fleet_roles.sql whenever owner_legacy_migrations exists.
-- It lives outside migrations/ because it is not in migration_order and has no
-- ledger row of its own. It differs from 260 in one statement only:
--
-- * task_leases.review_role is NOT dropped: owner_legacy_no_replaced_lease
--   reads NEW.review_role / OLD.review_role, so SQLite refuses the drop ("error
--   in trigger owner_legacy_no_replaced_lease after drop column"). The guard
--   triggers are kept exactly as they are. The column is NOT NULL DEFAULT ''
--   and nothing reads or writes it since SCHED-0b, so it stays inert.
--
-- As in 260, the data updates skip owner legacy frozen/imported chains
-- (owner_legacy_frozen_chains, the TEMP view run_migrations provides). Their
-- hub rows are read-only: the owner_legacy_guard_* triggers RAISE(ABORT,
-- 'legacy canonical source is frozen') on any write. Skipping is safe: such a
-- chain's canonical copy lives with its owner (imported) or is being exported
-- verbatim (frozen), so this hub never schedules, reviews or gates it again,
-- and its rows keep exactly what the export digested. A leftover 'named' agent
-- verdict would still be matched by reviewer agent, not by role, and no lease
-- can be granted on such a chain (owner_legacy_no_new_lease), so its fleet
-- pause flag is never consulted.
--
-- Dropping task_chain_fleets.roles_json / paused_roles_json rewrites rows of
-- frozen chains too, but ALTER TABLE DROP COLUMN fires no triggers and no fence
-- trigger names these columns.
--
-- One transaction, so a failure leaves 260 unapplied rather than half-dropped.
BEGIN IMMEDIATE;

UPDATE OR IGNORE task_reviews SET role = 'review' WHERE reviewer_kind = 'agent' AND role = 'named'
  AND chain_id NOT IN (SELECT chain_id FROM owner_legacy_frozen_chains)
  AND coalesce((SELECT t.chain_id FROM tasks t WHERE t.task_id = task_reviews.task_id), '') NOT IN (SELECT chain_id FROM owner_legacy_frozen_chains);

UPDATE task_chain_fleets SET paused = 1 WHERE trim(paused_roles_json) NOT IN ('', '[]')
  AND task_chain_id NOT IN (SELECT chain_id FROM owner_legacy_frozen_chains);

ALTER TABLE task_chain_fleets DROP COLUMN roles_json;
ALTER TABLE task_chain_fleets DROP COLUMN paused_roles_json;

COMMIT;
