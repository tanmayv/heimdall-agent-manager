-- V10 adds original workflow.v1 execution evidence after V9.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v10 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 10 CHECK(schema_version=10),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v10 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,10,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v10 RENAME TO runtime_database;
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







CREATE TABLE local_workflow_language_runs(
 chain_id TEXT NOT NULL,run_id TEXT NOT NULL,inputs_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,run_id),FOREIGN KEY(chain_id,run_id) REFERENCES local_workflow_runs(chain_id,run_id));
CREATE TABLE local_workflow_language_executions(
 chain_id TEXT NOT NULL,run_id TEXT NOT NULL,execution INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN('running','done','failed','cancelled')),
 failure TEXT NOT NULL DEFAULT '',principal_id TEXT NOT NULL,operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,run_id,execution),
 FOREIGN KEY(chain_id,run_id,execution) REFERENCES local_workflow_executions(chain_id,run_id,execution));
CREATE TABLE local_workflow_stage_expansions(
 chain_id TEXT NOT NULL,run_id TEXT NOT NULL,execution INTEGER NOT NULL,stage_key TEXT NOT NULL,
 item_count INTEGER NOT NULL CHECK(item_count BETWEEN 0 AND 256),
 PRIMARY KEY(chain_id,run_id,execution,stage_key),
 FOREIGN KEY(chain_id,run_id,execution) REFERENCES local_workflow_executions(chain_id,run_id,execution));
CREATE TABLE local_workflow_language_items(
 task_id TEXT PRIMARY KEY REFERENCES local_workflow_tasks(task_id),
 stage_key TEXT NOT NULL,stage_index INTEGER NOT NULL CHECK(stage_index BETWEEN 0 AND 255),
 kind TEXT NOT NULL CHECK(kind IN('task','gate')),priority TEXT NOT NULL,
 max_parallel INTEGER NOT NULL CHECK(max_parallel BETWEEN 0 AND 50),
 requires_user_approval INTEGER NOT NULL CHECK(requires_user_approval IN(0,1)),
 provenance_json TEXT NOT NULL);
CREATE TABLE local_workflow_outputs(
 chain_id TEXT NOT NULL,task_id TEXT NOT NULL,attempt INTEGER NOT NULL,output_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,attempt),
 FOREIGN KEY(chain_id,task_id,attempt) REFERENCES local_submissions(chain_id,task_id,attempt));
CREATE TABLE local_workflow_output_triggers(
 chain_id TEXT NOT NULL,source_task TEXT NOT NULL,source_attempt INTEGER NOT NULL,
 source_run TEXT NOT NULL,source_execution INTEGER NOT NULL,
 target_run TEXT NOT NULL,consumed INTEGER NOT NULL DEFAULT 0 CHECK(consumed IN(0,1)),
 PRIMARY KEY(chain_id,source_task,source_attempt),
 FOREIGN KEY(chain_id,source_task,source_attempt) REFERENCES local_submissions(chain_id,task_id,attempt),
 FOREIGN KEY(chain_id,source_run,source_execution) REFERENCES local_workflow_executions(chain_id,run_id,execution),
 FOREIGN KEY(chain_id,target_run) REFERENCES local_workflow_runs(chain_id,run_id));
CREATE TABLE local_workflow_registry_envelopes(
 intent_id TEXT PRIMARY KEY REFERENCES runtime_intents(intent_id),registry_json TEXT NOT NULL);
CREATE TRIGGER local_workflow_language_runs_immutable BEFORE UPDATE ON local_workflow_language_runs BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER local_workflow_language_runs_no_delete BEFORE DELETE ON local_workflow_language_runs BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER local_workflow_stage_expansions_immutable BEFORE UPDATE ON local_workflow_stage_expansions BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER local_workflow_stage_expansions_no_delete BEFORE DELETE ON local_workflow_stage_expansions BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER local_workflow_language_items_immutable BEFORE UPDATE ON local_workflow_language_items BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER local_workflow_language_items_no_delete BEFORE DELETE ON local_workflow_language_items BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER local_workflow_outputs_immutable BEFORE UPDATE ON local_workflow_outputs BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER local_workflow_outputs_no_delete BEFORE DELETE ON local_workflow_outputs BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER local_workflow_registry_envelopes_immutable BEFORE UPDATE ON local_workflow_registry_envelopes BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER local_workflow_registry_envelopes_no_delete BEFORE DELETE ON local_workflow_registry_envelopes BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;

CREATE TRIGGER search_workflow_output AFTER INSERT ON local_workflow_outputs BEGIN
 UPDATE search_docs SET body=body||char(10)||NEW.output_json WHERE chain_id=NEW.chain_id AND task_id=NEW.task_id AND kind='output' AND object_id=NEW.task_id||':'||NEW.attempt;
END;

CREATE TABLE local_workflow_coordinators(
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),revision INTEGER NOT NULL CHECK(revision>0),
 agent_id TEXT NOT NULL,child_json TEXT NOT NULL,capability_json TEXT NOT NULL,principal_id TEXT NOT NULL,operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,revision));
CREATE TRIGGER local_workflow_coordinators_immutable BEFORE UPDATE ON local_workflow_coordinators BEGIN SELECT RAISE(ABORT,'immutable coordinator binding'); END;
CREATE TRIGGER local_workflow_coordinators_no_delete BEFORE DELETE ON local_workflow_coordinators BEGIN SELECT RAISE(ABORT,'immutable coordinator binding'); END;

CREATE TABLE local_workflow_trigger_failures(
 chain_id TEXT NOT NULL,source_task TEXT NOT NULL,source_attempt INTEGER NOT NULL,reason TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_task,source_attempt),
 FOREIGN KEY(chain_id,source_task,source_attempt) REFERENCES local_submissions(chain_id,task_id,attempt));
CREATE TRIGGER local_workflow_trigger_failures_immutable BEFORE UPDATE ON local_workflow_trigger_failures BEGIN SELECT RAISE(ABORT,'immutable trigger outcome'); END;
CREATE TRIGGER local_workflow_trigger_failures_no_delete BEFORE DELETE ON local_workflow_trigger_failures BEGIN SELECT RAISE(ABORT,'immutable trigger outcome'); END;
