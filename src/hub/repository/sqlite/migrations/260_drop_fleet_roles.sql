-- SCHED-0b (spec art_18eb828949cd9431, sections 6.4 and 11.2): fleet roles,
-- per-role pause and lease review roles are gone. The role data the one-shot
-- SCHED-0a boot mapping still needs was snapshotted into sched0_fleet_roles by
-- migration 259, so dropping the columns here cannot lose it.
--
-- task_reviews.role stays (it is in the primary key); an agent verdict is now
-- written as 'review'. Rows written under the SCHED-0a interim name 'named' are
-- renamed; a row that would collide with an existing 'review' row is left as it
-- is (the gate matches agent verdicts by reviewer agent, not by role).
UPDATE OR IGNORE task_reviews SET role = 'review' WHERE reviewer_kind = 'agent' AND role = 'named';

-- task_chain_fleets.paused was kept equal to paused_roles_json by the 0a
-- repository; settle it once more before the source column goes.
UPDATE task_chain_fleets SET paused = 1 WHERE trim(paused_roles_json) NOT IN ('', '[]');

ALTER TABLE task_chain_fleets DROP COLUMN roles_json;
ALTER TABLE task_chain_fleets DROP COLUMN paused_roles_json;
ALTER TABLE task_leases DROP COLUMN review_role;
