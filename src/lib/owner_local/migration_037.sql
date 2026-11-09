-- V37: review roles are removed. A task's review gate is its brief's
-- reviewers (durable agent ids) plus requires_user_approval, and the
-- configured independent reviewer (lifecycle.configure).
-- local_review_role_migrations records, once, how each brief that named
-- review_roles (or each task with a review.roles configuration) was mapped:
-- subject requirements (subject_id task, revision requirements revision),
-- workflow_definition (workflow id, version) or proposal (task spec id, defaults
-- accepted_seq); source task_role_pairs (the task's configured pair),
-- fleet_role (a chain fleet row holding the role), user_approval (no holder:
-- the brief now requires the user) or role_config_user_approval. The rewrite
-- itself runs in migration_037_review_roles (Odin); update triggers it needs
-- to lift are restored there. local_role_* tables stay as legacy evidence and
-- are no longer read. Re-runnable after a test downgrade of the version.
CREATE TABLE IF NOT EXISTS local_review_role_migrations (
 chain_id TEXT NOT NULL, subject TEXT NOT NULL CHECK(subject IN('requirements','workflow_definition','proposal')),
 subject_id TEXT NOT NULL, revision INTEGER NOT NULL, role TEXT NOT NULL, agent_id TEXT NOT NULL,
 source TEXT NOT NULL CHECK(source IN('task_role_pairs','fleet_role','user_approval','role_config_user_approval')),
 PRIMARY KEY(chain_id,subject,subject_id,revision,role,agent_id)
);
CREATE TRIGGER IF NOT EXISTS local_review_role_migrations_immutable BEFORE UPDATE ON local_review_role_migrations BEGIN SELECT RAISE(ABORT,'immutable migration record'); END;
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v37 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 37 CHECK(schema_version=37),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v37 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,37,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v37 RENAME TO runtime_database;
CREATE TRIGGER runtime_identity_immutable BEFORE UPDATE ON runtime_database
WHEN NEW.account_id IS NOT OLD.account_id OR NEW.owner_bridge_id IS NOT OLD.owner_bridge_id
 OR NEW.owner_key_id IS NOT OLD.owner_key_id OR NEW.database_id IS NOT OLD.database_id
 OR NEW.singleton IS NOT OLD.singleton
BEGIN SELECT RAISE(ABORT,'immutable runtime identity'); END;
CREATE TRIGGER runtime_identity_no_delete BEFORE DELETE ON runtime_database
BEGIN SELECT RAISE(ABORT,'immutable runtime identity'); END;
CREATE TRIGGER runtime_monotonic BEFORE UPDATE ON runtime_database
WHEN NEW.incarnation<OLD.incarnation OR NEW.commit_seq<OLD.commit_seq
 OR NEW.clock_high_ms<OLD.clock_high_ms OR NEW.clock_generation<OLD.clock_generation
 OR NEW.directory_version<OLD.directory_version
 OR (NEW.directory_version=OLD.directory_version AND NEW.directory_hash IS NOT OLD.directory_hash)
BEGIN SELECT RAISE(ABORT,'runtime versions cannot regress'); END;
CREATE TRIGGER runtime_counter_types BEFORE UPDATE ON runtime_database
WHEN typeof(NEW.incarnation)!='integer' OR NEW.incarnation<0
 OR typeof(NEW.commit_seq)!='integer' OR NEW.commit_seq<0
 OR typeof(NEW.clock_high_ms)!='integer' OR NEW.clock_high_ms<0
 OR typeof(NEW.clock_generation)!='integer' OR NEW.clock_generation<1
 OR typeof(NEW.directory_version)!='integer' OR NEW.directory_version<0
BEGIN SELECT RAISE(ABORT,'invalid runtime counter'); END;
CREATE TRIGGER intent_transition BEFORE UPDATE ON runtime_intents
WHEN typeof(NEW.attempts)!='integer' OR NEW.attempts<OLD.attempts
 OR typeof(NEW.claim_incarnation)!='integer' OR NEW.claim_incarnation<0
 OR typeof(NEW.next_retry_ms)!='integer' OR NEW.next_retry_ms<OLD.next_retry_ms
 OR (NEW.state='claimed' AND (OLD.state!='pending' OR NEW.attempts!=OLD.attempts+1
   OR NEW.claim_incarnation!=(SELECT incarnation FROM runtime_database WHERE singleton=1)))
 OR (NEW.state!='claimed' AND NEW.attempts!=OLD.attempts)
 OR (NEW.state='settled' AND NEW.published!=1) OR (NEW.state!='settled' AND NEW.published!=0)
 OR (OLD.state='pending' AND NEW.state='settled')
BEGIN SELECT RAISE(ABORT,'invalid intent transition'); END;
