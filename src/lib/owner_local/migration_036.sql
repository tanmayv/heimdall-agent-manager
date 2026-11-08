-- V36 (P-CS CC-B): coordinator force-done policy and split links.
-- local_chain_policies: a device-signed chain policy, newest accepted version
-- wins. coordinator_force_done (default on when no row exists) gates the
-- coordinator's task.complete --force; only chain.policy.set (device) writes it.
-- local_task_links: split_from / split_into links written by task.split in the
-- same transaction that creates the children and cancels the original.
-- Both tables are created IF NOT EXISTS so the migration is re-runnable after a
-- test downgrade of the version (as V35's column).
-- runtime_database.schema_version is pinned per version: rebuild it as V35 did.
CREATE TABLE IF NOT EXISTS local_chain_policies (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), policy TEXT NOT NULL CHECK(policy IN('coordinator_force_done')),
 value TEXT NOT NULL CHECK(value IN('0','1')), accepted_seq INTEGER NOT NULL,
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,policy,accepted_seq)
);
CREATE TRIGGER IF NOT EXISTS local_chain_policies_immutable BEFORE UPDATE ON local_chain_policies BEGIN SELECT RAISE(ABORT,'immutable chain policy'); END;
-- An abandoned, never-activated migration import may discard its chain.
CREATE TRIGGER IF NOT EXISTS local_chain_policies_no_delete BEFORE DELETE ON local_chain_policies
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id) BEGIN SELECT RAISE(ABORT,'immutable chain policy'); END;
CREATE TABLE IF NOT EXISTS local_task_links (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, relation TEXT NOT NULL CHECK(relation IN('split_from','split_into')),
 other_task_id TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0), accepted_seq INTEGER NOT NULL,
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,relation,other_task_id),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id),
 FOREIGN KEY(chain_id,other_task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TRIGGER IF NOT EXISTS local_task_links_immutable BEFORE UPDATE ON local_task_links BEGIN SELECT RAISE(ABORT,'immutable task link'); END;
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v36 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 36 CHECK(schema_version=36),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v36 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,36,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v36 RENAME TO runtime_database;
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
