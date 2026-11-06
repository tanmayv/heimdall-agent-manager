-- V2 constrained runtime_database.schema_version to exactly 2. Rebuild it
-- transactionally, preserving identity, clocks and pins, before adding leases.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v7 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 7 CHECK(schema_version=7),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v7 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,7,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v7 RENAME TO runtime_database;
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





CREATE TABLE local_controls (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 mode TEXT NOT NULL CHECK(mode IN('ready','held','blocked','cancelled')),
 resume_state TEXT NOT NULL, reason TEXT NOT NULL, waiting_on TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE local_handoffs (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 kind TEXT NOT NULL, lease_id TEXT NOT NULL, summary TEXT NOT NULL, next_steps TEXT NOT NULL,
 waiting_on TEXT NOT NULL, destination_task_id TEXT NOT NULL, seq INTEGER NOT NULL,
 PRIMARY KEY(principal_id,operation_id), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TRIGGER local_handoffs_immutable BEFORE UPDATE ON local_handoffs BEGIN SELECT RAISE(ABORT,'immutable handoff'); END;
CREATE TRIGGER local_handoffs_no_delete BEFORE DELETE ON local_handoffs BEGIN SELECT RAISE(ABORT,'immutable handoff'); END;
CREATE TABLE control_notices (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 child_json TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN('stop','checkpoint')),
 PRIMARY KEY(principal_id,operation_id,child_json),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TRIGGER control_notices_immutable BEFORE UPDATE ON control_notices BEGIN SELECT RAISE(ABORT,'immutable notice'); END;
CREATE TRIGGER control_notices_no_delete BEFORE DELETE ON control_notices BEGIN SELECT RAISE(ABORT,'immutable notice'); END;
CREATE TRIGGER search_local_handoffs_insert AFTER INSERT ON local_handoffs BEGIN
 INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
 VALUES(new.chain_id,new.task_id,'handoff',new.principal_id||':'||new.operation_id,new.seq,new.kind,new.summary||char(10)||new.next_steps||char(10)||new.waiting_on);
END;

CREATE TABLE intent_invalidations(intent_id TEXT PRIMARY KEY REFERENCES runtime_intents(intent_id),principal_id TEXT NOT NULL,operation_id TEXT NOT NULL);
CREATE TRIGGER intent_invalidations_no_delete BEFORE DELETE ON intent_invalidations BEGIN SELECT RAISE(ABORT,'immutable invalidation'); END;
CREATE TRIGGER intent_invalidations_immutable BEFORE UPDATE ON intent_invalidations BEGIN SELECT RAISE(ABORT,'immutable invalidation'); END;

CREATE TABLE local_assignment_history (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL,
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 command_json TEXT NOT NULL, payload_json TEXT NOT NULL, child_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,revision),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
INSERT INTO local_assignment_history
 SELECT f.chain_id,f.task_id,f.configuration_revision,f.principal_id,f.operation_id,
 f.configuration_command,f.configuration_payload,
 json_object('instance',f.instance_id,'epoch',f.launch_epoch,'token_generation',f.token_generation,
 'run_count',f.run_count,'agent_id',COALESCE((SELECT json_extract(c.config_json,'$.author_agent_id') FROM lifecycle_configs c
 WHERE c.chain_id=f.chain_id AND c.task_id=f.task_id ORDER BY c.revision DESC LIMIT 1),''))
 FROM local_fleet f;
CREATE TRIGGER local_assignment_history_immutable BEFORE UPDATE ON local_assignment_history BEGIN SELECT RAISE(ABORT,'immutable assignment'); END;
CREATE TRIGGER local_assignment_history_no_delete BEFORE DELETE ON local_assignment_history BEGIN SELECT RAISE(ABORT,'immutable assignment'); END;

CREATE TABLE local_work_attempts (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL CHECK(attempt>0),
 lease_id TEXT NOT NULL UNIQUE REFERENCES local_leases(lease_id),
 PRIMARY KEY(chain_id,task_id,attempt), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
INSERT INTO local_work_attempts SELECT chain_id,task_id,row_number() OVER(PARTITION BY chain_id,task_id ORDER BY rowid),lease_id FROM local_leases;
CREATE TRIGGER local_work_attempts_immutable BEFORE UPDATE ON local_work_attempts BEGIN SELECT RAISE(ABORT,'immutable work attempt'); END;
CREATE TRIGGER local_work_attempts_no_delete BEFORE DELETE ON local_work_attempts BEGIN SELECT RAISE(ABORT,'immutable work attempt'); END;

CREATE TABLE local_checkpoints (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, lease_id TEXT NOT NULL,
 child_json TEXT NOT NULL, capability_json TEXT NOT NULL, expires_ms INTEGER NOT NULL,
 PRIMARY KEY(chain_id,task_id,lease_id,child_json),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);

CREATE INDEX local_review_holder ON local_review_sessions(json_extract(child,'$.instance'));
