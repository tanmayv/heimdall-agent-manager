-- Owner legacy source fences, copied verbatim from the Mundus hub database
-- (sqlite_master of hub.sqlite.pre-v0.5.92-20261126T125101Z): the two state
-- tables and every owner_legacy_* trigger on the task tables the SCHED-0
-- migrations and boot mapping touch. They come from the bridge-owned legacy
-- chain export, which origin/main does not carry. Test fixture only.
CREATE TABLE owner_legacy_source_generations (
  chain_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK(typeof(generation)='integer' AND generation >= 0),
  UNIQUE(chain_id,account_id)
);
CREATE TABLE "owner_legacy_migrations" (
  migration_id TEXT PRIMARY KEY,
  chain_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  owner_bridge_id TEXT NOT NULL,
  owner_key_id TEXT NOT NULL,
  selection_digest TEXT NOT NULL CHECK(length(selection_digest)=64),
  state TEXT NOT NULL CHECK(state IN ('draining','frozen','imported')),
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision > 0),
  frozen_generation INTEGER NOT NULL DEFAULT 0 CHECK(frozen_generation >= 0),
  quiescence_digest TEXT NOT NULL DEFAULT '',
  manifest_digest TEXT NOT NULL DEFAULT '',
  receipt_digest TEXT NOT NULL DEFAULT '', neutralized_json TEXT NOT NULL DEFAULT '[]', forced_held_json TEXT NOT NULL DEFAULT '[]',
  UNIQUE(chain_id),
  FOREIGN KEY(chain_id,account_id) REFERENCES owner_legacy_source_generations(chain_id,account_id),
  CHECK((state='draining' AND quiescence_digest='' AND frozen_generation=0) OR
        (state IN ('frozen','imported') AND length(quiescence_digest)=64)),
  CHECK((state!='imported' AND manifest_digest='' AND receipt_digest='') OR
        (state='imported' AND length(manifest_digest)=64 AND length(receipt_digest)=64))
);
CREATE TRIGGER owner_legacy_generation_task_chain_fleets_delete AFTER DELETE ON task_chain_fleets
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.task_chain_id; END;
CREATE TRIGGER owner_legacy_generation_task_chain_fleets_insert AFTER INSERT ON task_chain_fleets
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.task_chain_id; END;
CREATE TRIGGER owner_legacy_generation_task_chain_fleets_update AFTER UPDATE ON task_chain_fleets
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.task_chain_id OR chain_id=NEW.task_chain_id; END;
CREATE TRIGGER owner_legacy_generation_task_chains_delete AFTER DELETE ON task_chains
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_generation_task_chains_insert AFTER INSERT ON task_chains
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_generation_task_chains_update AFTER UPDATE ON task_chains
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_generation_task_events_delete AFTER DELETE ON task_events
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id); END;
CREATE TRIGGER owner_legacy_generation_task_events_insert AFTER INSERT ON task_events
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_generation_task_events_update AFTER UPDATE ON task_events
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_generation_task_leases_delete AFTER DELETE ON task_leases
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id); END;
CREATE TRIGGER owner_legacy_generation_task_leases_insert AFTER INSERT ON task_leases
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_generation_task_leases_update AFTER UPDATE ON task_leases
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_generation_task_reviews_delete AFTER DELETE ON task_reviews
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id); END;
CREATE TRIGGER owner_legacy_generation_task_reviews_insert AFTER INSERT ON task_reviews
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_generation_task_reviews_update AFTER UPDATE ON task_reviews
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_generation_tasks_delete AFTER DELETE ON tasks
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_generation_tasks_insert AFTER INSERT ON tasks
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_generation_tasks_update AFTER UPDATE ON tasks
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chain_fleets_delete BEFORE DELETE ON task_chain_fleets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.task_chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_fleets_insert BEFORE INSERT ON task_chain_fleets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.task_chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_fleets_update BEFORE UPDATE ON task_chain_fleets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.task_chain_id OR m.chain_id=NEW.task_chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chains_delete BEFORE DELETE ON task_chains
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chains_insert BEFORE INSERT ON task_chains
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chains_update BEFORE UPDATE ON task_chains
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_events_delete BEFORE DELETE ON task_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_events_insert BEFORE INSERT ON task_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_events_update BEFORE UPDATE ON task_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_leases_delete BEFORE DELETE ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_leases_insert BEFORE INSERT ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_leases_update BEFORE UPDATE ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_reviews_delete BEFORE DELETE ON task_reviews
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_reviews_insert BEFORE INSERT ON task_reviews
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_reviews_update BEFORE UPDATE ON task_reviews
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_tasks_delete BEFORE DELETE ON tasks
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_tasks_insert BEFORE INSERT ON tasks
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_tasks_update BEFORE UPDATE ON tasks
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_no_new_lease BEFORE INSERT ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.chain_id=NEW.chain_id
  OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id))
BEGIN SELECT RAISE(ABORT,'legacy source grants are draining'); END;
CREATE TRIGGER owner_legacy_no_replaced_lease BEFORE UPDATE ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.chain_id=OLD.chain_id
  OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id))
 AND (NEW.lease_id!=OLD.lease_id OR NEW.task_id!=OLD.task_id OR NEW.chain_id!=OLD.chain_id
   OR NEW.owner_user_id!=OLD.owner_user_id OR NEW.holder_instance_id!=OLD.holder_instance_id
   OR NEW.attempt_no!=OLD.attempt_no OR NEW.kind!=OLD.kind OR NEW.review_role!=OLD.review_role
   OR NEW.granted_at!=OLD.granted_at)
BEGIN SELECT RAISE(ABORT,'legacy source grants are draining'); END;
