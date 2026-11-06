-- V16 seals explicit native budget baselines and preserves budget evidence.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v16 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 16 CHECK(schema_version=16),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v16 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,16,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v16 RENAME TO runtime_database;
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









CREATE TABLE native_budget_baselines (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 source_revision TEXT NOT NULL, snapshot_digest TEXT NOT NULL,
 native_cutoff INTEGER NOT NULL, local_cutoff INTEGER NOT NULL,
 requirements_revision TEXT NOT NULL, configuration_revision TEXT NOT NULL,
 execution TEXT NOT NULL, activation_json TEXT NOT NULL CHECK(json_valid(activation_json)),
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,task_id)
);
CREATE TRIGGER native_budget_baseline_no_update BEFORE UPDATE ON native_budget_baselines
BEGIN SELECT RAISE(ABORT,'immutable budget baseline'); END;
CREATE TRIGGER native_budget_baseline_no_delete BEFORE DELETE ON native_budget_baselines
BEGIN SELECT RAISE(ABORT,'immutable budget baseline'); END;
CREATE TRIGGER native_budget_snapshot_sealed BEFORE INSERT ON native_history_records
WHEN EXISTS(SELECT 1 FROM native_budget_baselines b WHERE b.chain_id=NEW.chain_id AND b.task_id=NEW.task_id AND b.source_revision=NEW.source_revision)
BEGIN SELECT RAISE(ABORT,'activated native snapshot is sealed'); END;
CREATE TABLE local_budget_evidence (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 state_json TEXT NOT NULL CHECK(json_valid(state_json)),
 PRIMARY KEY(chain_id,task_id,seq)
);
CREATE TRIGGER local_budget_evidence_no_update BEFORE UPDATE ON local_budget_evidence
BEGIN SELECT RAISE(ABORT,'immutable budget evidence'); END;
CREATE TRIGGER local_budget_evidence_no_delete BEFORE DELETE ON local_budget_evidence
BEGIN SELECT RAISE(ABORT,'immutable budget evidence'); END;
