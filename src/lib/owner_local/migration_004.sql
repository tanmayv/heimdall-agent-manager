-- V2 constrained runtime_database.schema_version to exactly 2. Rebuild it
-- transactionally, preserving identity, clocks and pins, before adding leases.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v4 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 4 CHECK(schema_version=4),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v4 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,4,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v4 RENAME TO runtime_database;
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


CREATE TABLE lifecycle_configs (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 config_json TEXT NOT NULL, command_json TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 author_child TEXT NOT NULL, reviewer_child TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,revision), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE task_requirements (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 brief_json TEXT NOT NULL, cipher TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,revision), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE requirement_ack (
 lease_id TEXT NOT NULL REFERENCES local_leases(lease_id), revision INTEGER NOT NULL,
 presented INTEGER NOT NULL CHECK(presented=1), acknowledged INTEGER NOT NULL CHECK(acknowledged IN(0,1)),
 PRIMARY KEY(lease_id,revision)
);
CREATE TABLE local_submissions (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL CHECK(attempt>0),
 lease_id TEXT NOT NULL UNIQUE REFERENCES local_leases(lease_id), author_agent_id TEXT NOT NULL,
 author_child TEXT NOT NULL, requirements_revision INTEGER NOT NULL, configuration_revision INTEGER NOT NULL,
 head TEXT NOT NULL, summary TEXT NOT NULL, requirements_json TEXT NOT NULL,
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,attempt), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE lifecycle_state (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN('ready','in_review','merge_pending','merge_blocked','done')),
 attempt INTEGER NOT NULL DEFAULT 0, merge_receipt TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(chain_id,task_id), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE local_review_sessions (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL, child TEXT NOT NULL,
 capability_json TEXT NOT NULL, expires_ms INTEGER NOT NULL,
 PRIMARY KEY(chain_id,task_id,attempt)
);
CREATE TABLE local_reviews (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL,
 reviewer_agent_id TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 requirements_revision INTEGER NOT NULL, head TEXT NOT NULL, verdict TEXT NOT NULL CHECK(verdict IN('approve','request_changes')), summary TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,attempt,reviewer_agent_id),
 FOREIGN KEY(chain_id,task_id,attempt) REFERENCES local_submissions(chain_id,task_id,attempt)
);
CREATE TRIGGER lifecycle_configs_immutable BEFORE UPDATE ON lifecycle_configs BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER lifecycle_configs_no_delete BEFORE DELETE ON lifecycle_configs BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER task_requirements_immutable BEFORE UPDATE ON task_requirements BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER task_requirements_no_delete BEFORE DELETE ON task_requirements BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER local_submissions_immutable BEFORE UPDATE ON local_submissions BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER local_submissions_no_delete BEFORE DELETE ON local_submissions BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER local_reviews_immutable BEFORE UPDATE ON local_reviews BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER local_reviews_no_delete BEFORE DELETE ON local_reviews BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;

CREATE TABLE local_merge_preparations(intent_id TEXT PRIMARY KEY REFERENCES runtime_intents(intent_id),payload_digest TEXT NOT NULL,head TEXT NOT NULL);

CREATE TRIGGER local_merge_preparations_immutable BEFORE UPDATE ON local_merge_preparations BEGIN SELECT RAISE(ABORT,'immutable merge preparation'); END;
CREATE TRIGGER local_merge_preparations_no_delete BEFORE DELETE ON local_merge_preparations BEGIN SELECT RAISE(ABORT,'immutable merge preparation'); END;
