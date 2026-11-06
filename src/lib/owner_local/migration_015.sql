-- V15 adds task-scoped workflow retirement evidence; earlier events remain immutable.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v15 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 15 CHECK(schema_version=15),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v15 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,15,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v15 RENAME TO runtime_database;
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









CREATE TABLE native_history_records (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), task_id TEXT NOT NULL,
 source_revision TEXT NOT NULL, record_kind TEXT NOT NULL CHECK(record_kind IN('attempt','event','facet')),
 record_key TEXT NOT NULL, owner_user_id TEXT NOT NULL,
 completeness TEXT NOT NULL CHECK(completeness IN('full','incomplete')),
 attempt_no TEXT NOT NULL, facet_kind TEXT NOT NULL, facet_version TEXT NOT NULL,
 writer TEXT NOT NULL, record_json TEXT NOT NULL CHECK(json_valid(record_json)),
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 parent_kind TEXT, parent_key TEXT,
 PRIMARY KEY(chain_id,task_id,source_revision,record_kind,record_key),
 FOREIGN KEY(chain_id,task_id,source_revision,parent_kind,parent_key)
 REFERENCES native_history_records(chain_id,task_id,source_revision,record_kind,record_key)
 DEFERRABLE INITIALLY DEFERRED,
 CHECK((record_kind='facet' AND facet_kind!='' AND facet_version!='' AND
       ((attempt_no='0' AND facet_kind='placement' AND parent_kind IS NULL AND parent_key IS NULL)
        OR (attempt_no!='0' AND parent_kind IS 'attempt' AND parent_key IS attempt_no)))
    OR (record_kind!='facet' AND parent_kind IS NULL AND parent_key IS NULL))
);
CREATE INDEX native_history_inventory ON native_history_records(chain_id,task_id,source_revision,record_kind,record_key);
CREATE UNIQUE INDEX native_event_identity ON native_history_records(chain_id,source_revision,record_key) WHERE record_kind='event';
CREATE TRIGGER native_history_no_update BEFORE UPDATE ON native_history_records
BEGIN SELECT RAISE(ABORT,'immutable native history'); END;
CREATE TRIGGER native_history_no_delete BEFORE DELETE ON native_history_records
BEGIN SELECT RAISE(ABORT,'immutable native history'); END;
CREATE TRIGGER native_facet_writer BEFORE INSERT ON native_history_records WHEN NEW.record_kind='facet' AND EXISTS(
 SELECT 1 FROM native_history_records WHERE chain_id=NEW.chain_id AND task_id=NEW.task_id
 AND record_kind='facet' AND attempt_no=NEW.attempt_no AND facet_kind=NEW.facet_kind AND writer!=NEW.writer)
BEGIN SELECT RAISE(ABORT,'native facet writer mismatch'); END;
CREATE TABLE deferred_workflow_retirements (
 intent_id TEXT PRIMARY KEY REFERENCES runtime_intents(intent_id),
 requested_seq INTEGER REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, run_id TEXT NOT NULL, execution TEXT NOT NULL,
 cause TEXT NOT NULL CHECK(cause IN('workflow.failed','workflow.gate','workflow.cancel','workflow.retry','unknown')),
 source_completeness TEXT NOT NULL CHECK(source_completeness IN('full','incomplete')),
 CHECK((requested_seq IS NULL AND cause='unknown' AND source_completeness='incomplete') OR
   (requested_seq IS NOT NULL AND cause!='unknown' AND source_completeness='full'))
);
CREATE TABLE deferred_workflow_dispositions (
 intent_id TEXT PRIMARY KEY REFERENCES deferred_workflow_retirements(intent_id),
 settled_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 disposition TEXT NOT NULL CHECK(disposition='preserved_terminal'),
 head TEXT NOT NULL
);
-- Observe pre-V15 orphaned workflow stops without inventing their lost request
-- event, actor, cause or time. Only the exact extant intent/task/run binding is
-- known. Settlement later appends its own current, complete bridge evidence.
INSERT INTO deferred_workflow_retirements
 SELECT n.intent_id,NULL,n.chain_id,t.task_id,t.run_id,CAST(t.execution AS TEXT),'unknown','incomplete'
 FROM runtime_intents n JOIN local_workflow_tasks t ON t.chain_id=n.chain_id AND t.task_id=json_extract(n.exact_fence_json,'$.task_id')
 JOIN local_workflow_language_executions e ON e.chain_id=t.chain_id AND e.run_id=t.run_id AND e.execution=t.execution
 JOIN lifecycle_state l ON l.chain_id=t.chain_id AND l.task_id=t.task_id
 WHERE n.kind='merge' AND n.state!='settled' AND e.state IN('failed','cancelled')
 AND l.state IN('merge_pending','merge_blocked') AND NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=n.intent_id);
CREATE TRIGGER deferred_retire_no_update BEFORE UPDATE ON deferred_workflow_retirements BEGIN SELECT RAISE(ABORT,'immutable deferred retirement'); END;
CREATE TRIGGER deferred_retire_no_delete BEFORE DELETE ON deferred_workflow_retirements BEGIN SELECT RAISE(ABORT,'immutable deferred retirement'); END;
CREATE TRIGGER deferred_disposition_no_update BEFORE UPDATE ON deferred_workflow_dispositions BEGIN SELECT RAISE(ABORT,'immutable deferred disposition'); END;
CREATE TRIGGER deferred_disposition_no_delete BEFORE DELETE ON deferred_workflow_dispositions BEGIN SELECT RAISE(ABORT,'immutable deferred disposition'); END;
-- Never strand a prepared CAS callback after a deferred workflow stop.
CREATE TRIGGER deferred_prepared_merge_no_invalidation BEFORE INSERT ON intent_invalidations
WHEN EXISTS(SELECT 1 FROM deferred_workflow_retirements d
 WHERE d.intent_id=NEW.intent_id AND NOT EXISTS(SELECT 1 FROM deferred_workflow_dispositions r WHERE r.intent_id=d.intent_id))
BEGIN SELECT RAISE(ABORT,'unsettled prepared workflow merge'); END;
