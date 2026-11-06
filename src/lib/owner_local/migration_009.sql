-- V9 adds workflows and source recovery after the accepted V8 grants migration.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v9 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 9 CHECK(schema_version=9),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v9 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,9,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v9 RENAME TO runtime_database;
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






CREATE TABLE local_workflow_definitions(
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), workflow_id TEXT NOT NULL, version INTEGER NOT NULL CHECK(version>0),
 definition_json TEXT NOT NULL, PRIMARY KEY(chain_id,workflow_id,version)
);
CREATE TABLE local_workflow_runs(
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL, workflow_id TEXT NOT NULL, definition_version INTEGER NOT NULL,
 current_execution INTEGER NOT NULL CHECK(current_execution>0), revision INTEGER NOT NULL CHECK(revision>0),
 PRIMARY KEY(chain_id,run_id), FOREIGN KEY(chain_id,workflow_id,definition_version) REFERENCES local_workflow_definitions(chain_id,workflow_id,version)
);
CREATE TABLE local_workflow_executions(
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL, execution INTEGER NOT NULL CHECK(execution>0),
 state TEXT NOT NULL CHECK(state IN('running','done','superseded')), PRIMARY KEY(chain_id,run_id,execution),
 FOREIGN KEY(chain_id,run_id) REFERENCES local_workflow_runs(chain_id,run_id)
);
CREATE TABLE local_workflow_tasks(
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL, execution INTEGER NOT NULL, stage_key TEXT NOT NULL, task_id TEXT NOT NULL UNIQUE,
 PRIMARY KEY(chain_id,run_id,execution,stage_key),
 FOREIGN KEY(chain_id,run_id,execution) REFERENCES local_workflow_executions(chain_id,run_id,execution),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TRIGGER workflow_task_current_insert BEFORE INSERT ON local_workflow_tasks WHEN NOT EXISTS(
 SELECT 1 FROM local_workflow_runs r JOIN local_workflow_executions e USING(chain_id,run_id)
 WHERE r.chain_id=NEW.chain_id AND r.run_id=NEW.run_id AND r.current_execution=NEW.execution AND e.execution=NEW.execution AND e.state='running'
) BEGIN SELECT RAISE(ABORT,'workflow task requires current running execution'); END;
CREATE TABLE local_dependencies(
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, prerequisite TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,prerequisite), CHECK(task_id!=prerequisite),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id), FOREIGN KEY(chain_id,prerequisite) REFERENCES tasks(chain_id,task_id)
);
CREATE TRIGGER local_dependency_cycle BEFORE INSERT ON local_dependencies WHEN EXISTS(
 WITH RECURSIVE ancestors(id) AS (SELECT NEW.prerequisite UNION SELECT d.prerequisite FROM local_dependencies d JOIN ancestors a ON d.task_id=a.id WHERE d.chain_id=NEW.chain_id)
 SELECT 1 FROM ancestors WHERE id=NEW.task_id
) BEGIN SELECT RAISE(ABORT,'cyclic dependency'); END;
CREATE TABLE local_workflow_events(
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL, execution INTEGER NOT NULL, event_seq INTEGER NOT NULL UNIQUE,
 kind TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,run_id,event_seq),
 FOREIGN KEY(chain_id,run_id,execution) REFERENCES local_workflow_executions(chain_id,run_id,execution)
);

CREATE TABLE local_role_configs(
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 requires_user_approval INTEGER NOT NULL CHECK(requires_user_approval IN(0,1)), pairs_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,revision), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE local_role_pairs(
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL, role TEXT NOT NULL, agent_id TEXT NOT NULL, child_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,revision,role,agent_id),
 FOREIGN KEY(chain_id,task_id,revision) REFERENCES local_role_configs(chain_id,task_id,revision)
);
CREATE TABLE local_role_reviews(
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL, role_revision INTEGER NOT NULL,
 role TEXT NOT NULL, agent_id TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 verdict TEXT NOT NULL CHECK(verdict IN('approve','request_changes')), summary TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,attempt,role,agent_id),
 FOREIGN KEY(chain_id,task_id,attempt) REFERENCES local_submissions(chain_id,task_id,attempt),
 FOREIGN KEY(chain_id,task_id,role_revision,role,agent_id) REFERENCES local_role_pairs(chain_id,task_id,revision,role,agent_id)
);
DROP INDEX local_review_holder;
ALTER TABLE local_review_sessions RENAME TO local_review_sessions_v7;
CREATE TABLE local_review_sessions(
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL, child TEXT NOT NULL, capability_json TEXT NOT NULL, expires_ms INTEGER NOT NULL,
 PRIMARY KEY(chain_id,task_id,attempt,child), FOREIGN KEY(chain_id,task_id,attempt) REFERENCES local_submissions(chain_id,task_id,attempt)
);
INSERT INTO local_review_sessions SELECT * FROM local_review_sessions_v7;
DROP TABLE local_review_sessions_v7;
CREATE INDEX local_review_holder ON local_review_sessions(json_extract(child,'$.instance'));

CREATE TABLE source_episodes(
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), origin_kind TEXT NOT NULL, origin_id TEXT NOT NULL, episode_id TEXT NOT NULL,
 source_version INTEGER NOT NULL CHECK(source_version>0), resolved INTEGER NOT NULL CHECK(resolved IN(0,1)),
 ack_floor INTEGER NOT NULL DEFAULT 0 CHECK(ack_floor>=0), retired_floor INTEGER NOT NULL DEFAULT 0 CHECK(retired_floor>=0),
 delivered_floor INTEGER NOT NULL DEFAULT 0 CHECK(delivered_floor>=0), deadline_ms INTEGER NOT NULL CHECK(deadline_ms>=0),
 card_id TEXT NOT NULL DEFAULT '', card_closed INTEGER NOT NULL DEFAULT 0 CHECK(card_closed IN(0,1)),
 body TEXT NOT NULL, PRIMARY KEY(chain_id,origin_kind,origin_id,episode_id),
 CHECK(ack_floor<=source_version AND retired_floor<=source_version AND delivered_floor<=source_version)
);
CREATE INDEX source_recovery_inventory ON source_episodes(chain_id,origin_kind,origin_id,episode_id) WHERE resolved=0 OR (card_id!='' AND card_closed=0);
CREATE TRIGGER source_monotonic BEFORE UPDATE ON source_episodes WHEN
 NEW.chain_id IS NOT OLD.chain_id OR NEW.origin_kind IS NOT OLD.origin_kind OR NEW.origin_id IS NOT OLD.origin_id OR NEW.episode_id IS NOT OLD.episode_id
 OR NEW.source_version<OLD.source_version OR NEW.resolved<OLD.resolved OR NEW.ack_floor<OLD.ack_floor OR NEW.retired_floor<OLD.retired_floor OR NEW.delivered_floor<OLD.delivered_floor
 OR NEW.card_closed<OLD.card_closed OR (OLD.card_id!='' AND NEW.card_id IS NOT OLD.card_id)
 BEGIN SELECT RAISE(ABORT,'source identity or watermark regression'); END;
CREATE TABLE source_consumptions(
 chain_id TEXT NOT NULL, origin_kind TEXT NOT NULL, origin_id TEXT NOT NULL, episode_id TEXT NOT NULL,
 consumer_fence_hash TEXT NOT NULL, source_version INTEGER NOT NULL CHECK(source_version>0),
 principal_id TEXT NOT NULL, result_operation TEXT NOT NULL, commit_seq INTEGER NOT NULL, result TEXT NOT NULL,
 PRIMARY KEY(chain_id,origin_kind,origin_id,episode_id,consumer_fence_hash,source_version),
 FOREIGN KEY(chain_id,origin_kind,origin_id,episode_id) REFERENCES source_episodes(chain_id,origin_kind,origin_id,episode_id)
);
CREATE TRIGGER source_pending_card_no_delete BEFORE DELETE ON source_episodes
 WHEN OLD.resolved=0 OR (OLD.card_id!='' AND OLD.card_closed=0)
 BEGIN SELECT RAISE(ABORT,'source still requires discovery'); END;
CREATE TABLE source_receipt_pins(
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, chain_id TEXT NOT NULL,
 origin_kind TEXT NOT NULL, origin_id TEXT NOT NULL, episode_id TEXT NOT NULL,
 PRIMARY KEY(principal_id,operation_id,chain_id,origin_kind,origin_id,episode_id),
 FOREIGN KEY(chain_id,origin_kind,origin_id,episode_id) REFERENCES source_episodes(chain_id,origin_kind,origin_id,episode_id)
);

CREATE TRIGGER local_workflow_definitions_immutable BEFORE UPDATE ON local_workflow_definitions BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER local_workflow_definitions_no_delete BEFORE DELETE ON local_workflow_definitions BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;

CREATE TRIGGER local_workflow_tasks_immutable BEFORE UPDATE ON local_workflow_tasks BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER local_workflow_tasks_no_delete BEFORE DELETE ON local_workflow_tasks BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;

CREATE TRIGGER local_workflow_events_immutable BEFORE UPDATE ON local_workflow_events BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER local_workflow_events_no_delete BEFORE DELETE ON local_workflow_events BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;

CREATE TRIGGER local_role_configs_immutable BEFORE UPDATE ON local_role_configs BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER local_role_configs_no_delete BEFORE DELETE ON local_role_configs BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;

CREATE TRIGGER local_role_pairs_immutable BEFORE UPDATE ON local_role_pairs BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER local_role_pairs_no_delete BEFORE DELETE ON local_role_pairs BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;

CREATE TRIGGER local_role_reviews_immutable BEFORE UPDATE ON local_role_reviews BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER local_role_reviews_no_delete BEFORE DELETE ON local_role_reviews BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;

CREATE TRIGGER source_consumptions_immutable BEFORE UPDATE ON source_consumptions BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER source_consumptions_no_delete BEFORE DELETE ON source_consumptions BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;

CREATE TRIGGER search_workflow_definition AFTER INSERT ON local_workflow_definitions BEGIN
 INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
 VALUES(new.chain_id,'','workflow',new.workflow_id||':'||new.version,new.version,json_extract(new.definition_json,'$.title'),new.definition_json);
END;
CREATE TRIGGER search_source_insert AFTER INSERT ON source_episodes BEGIN
 INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
 VALUES(new.chain_id,'','source',json_array(new.origin_kind,new.origin_id,new.episode_id),new.source_version,new.origin_kind,new.body);
END;
CREATE TRIGGER search_source_update AFTER UPDATE ON source_episodes BEGIN
 UPDATE search_docs SET revision=new.source_version,body=new.body WHERE chain_id=new.chain_id AND kind='source' AND object_id=json_array(new.origin_kind,new.origin_id,new.episode_id);
END;

CREATE TRIGGER workflow_run_monotonic BEFORE UPDATE ON local_workflow_runs WHEN
 NEW.chain_id IS NOT OLD.chain_id OR NEW.run_id IS NOT OLD.run_id OR NEW.workflow_id IS NOT OLD.workflow_id OR NEW.definition_version!=OLD.definition_version
 OR NEW.current_execution!=OLD.current_execution+1 OR NEW.revision!=OLD.revision+1
 BEGIN SELECT RAISE(ABORT,'workflow retry must advance exact generation'); END;
CREATE TRIGGER workflow_run_no_delete BEFORE DELETE ON local_workflow_runs BEGIN SELECT RAISE(ABORT,'immutable workflow history'); END;
CREATE TRIGGER workflow_execution_transition BEFORE UPDATE ON local_workflow_executions WHEN
 NEW.chain_id IS NOT OLD.chain_id OR NEW.run_id IS NOT OLD.run_id OR NEW.execution!=OLD.execution
 OR NEW.state=OLD.state OR OLD.state='superseded' OR NEW.state='running'
 BEGIN SELECT RAISE(ABORT,'invalid execution transition'); END;
CREATE TRIGGER workflow_execution_no_delete BEFORE DELETE ON local_workflow_executions BEGIN SELECT RAISE(ABORT,'immutable execution history'); END;
CREATE TRIGGER workflow_task_definition_immutable BEFORE UPDATE ON tasks WHEN
 (NEW.title IS NOT OLD.title OR NEW.body IS NOT OLD.body) AND EXISTS(SELECT 1 FROM local_workflow_tasks w WHERE w.chain_id=OLD.chain_id AND w.task_id=OLD.task_id)
 BEGIN SELECT RAISE(ABORT,'immutable generated definition'); END;
CREATE TRIGGER workflow_task_no_delete BEFORE DELETE ON tasks WHEN EXISTS(SELECT 1 FROM local_workflow_tasks w WHERE w.chain_id=OLD.chain_id AND w.task_id=OLD.task_id)
 BEGIN SELECT RAISE(ABORT,'immutable generated history'); END;
