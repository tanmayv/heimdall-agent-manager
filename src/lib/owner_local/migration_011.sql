-- V11 adds ordinary task-attempt output prerequisites, preserving V10 evidence.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v11 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 11 CHECK(schema_version=11),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v11 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,11,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v11 RENAME TO runtime_database;
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







CREATE TABLE local_workflow_output_triggers_v11(
 chain_id TEXT NOT NULL,source_task TEXT NOT NULL,source_attempt INTEGER NOT NULL,
 source_run TEXT,source_execution INTEGER,
 target_run TEXT NOT NULL,consumed INTEGER NOT NULL DEFAULT 0 CHECK(consumed IN(0,1)),
 CHECK((source_run IS NULL AND source_execution IS NULL) OR (source_run IS NOT NULL AND source_execution IS NOT NULL)),
 PRIMARY KEY(chain_id,source_task,source_attempt),
 FOREIGN KEY(chain_id,source_task,source_attempt) REFERENCES local_submissions(chain_id,task_id,attempt),
 FOREIGN KEY(chain_id,source_run,source_execution) REFERENCES local_workflow_executions(chain_id,run_id,execution),
 FOREIGN KEY(chain_id,target_run) REFERENCES local_workflow_runs(chain_id,run_id));

INSERT INTO local_workflow_output_triggers_v11 SELECT * FROM local_workflow_output_triggers;
DROP TABLE local_workflow_output_triggers;
ALTER TABLE local_workflow_output_triggers_v11 RENAME TO local_workflow_output_triggers;
CREATE TRIGGER local_workflow_output_trigger_identity BEFORE UPDATE ON local_workflow_output_triggers
WHEN NEW.chain_id IS NOT OLD.chain_id OR NEW.source_task IS NOT OLD.source_task
 OR NEW.source_attempt IS NOT OLD.source_attempt OR NEW.source_run IS NOT OLD.source_run
 OR NEW.source_execution IS NOT OLD.source_execution OR NEW.target_run IS NOT OLD.target_run
 OR NEW.consumed<OLD.consumed
BEGIN SELECT RAISE(ABORT,'immutable output prerequisite'); END;
CREATE TRIGGER local_workflow_output_trigger_no_delete BEFORE DELETE ON local_workflow_output_triggers
BEGIN SELECT RAISE(ABORT,'immutable output prerequisite'); END;
