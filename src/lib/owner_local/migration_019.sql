-- V19: immutable native chain/task/comment/summary source metadata.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v19 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 19 CHECK(schema_version=19),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v19 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,19,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v19 RENAME TO runtime_database;
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












CREATE TABLE native_fact_snapshots (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN('chain','task','comment','summary')),
 owner_user_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 record_count INTEGER NOT NULL CHECK(record_count>=0 AND record_count<=100), content_digest TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,kind),
 UNIQUE(chain_id,source_revision,kind,owner_user_id),
 FOREIGN KEY(chain_id,owner_user_id) REFERENCES native_metadata_origins(chain_id,owner_user_id)
);
CREATE TABLE native_fact_chain (
 source_revision TEXT NOT NULL, snapshot_kind TEXT NOT NULL CHECK(snapshot_kind='chain'),
 chain_id TEXT NOT NULL,
 owner_user_id TEXT NOT NULL,
 title TEXT NOT NULL,
 description TEXT NOT NULL,
 publish_state TEXT NOT NULL,
 status TEXT NOT NULL,
 kind TEXT NOT NULL,
 coordinator_agent_instance_id TEXT NOT NULL,
 defaults_json TEXT NOT NULL,
 work_revision INTEGER NOT NULL CHECK(typeof(work_revision)='integer' AND work_revision>=0),
 completion_summary TEXT NOT NULL,
 last_activity_at TEXT NOT NULL,
 last_title_nudge_at TEXT NOT NULL,
 title_source TEXT NOT NULL,
 created_at TEXT NOT NULL,
 updated_at TEXT NOT NULL,
 published_at TEXT NOT NULL,
 completed_at TEXT NOT NULL,
 is_pinned INTEGER NOT NULL CHECK(typeof(is_pinned)='integer' AND is_pinned IN(0,1)),
 pinned_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,snapshot_kind),
 FOREIGN KEY(chain_id,source_revision,snapshot_kind,owner_user_id) REFERENCES native_fact_snapshots(chain_id,source_revision,kind,owner_user_id)
);
CREATE TABLE native_fact_task (
 source_revision TEXT NOT NULL, snapshot_kind TEXT NOT NULL CHECK(snapshot_kind='task'),
 task_id TEXT NOT NULL,
 chain_id TEXT NOT NULL,
 owner_user_id TEXT NOT NULL,
 title TEXT NOT NULL,
 description TEXT NOT NULL,
 publish_state TEXT NOT NULL,
 state TEXT NOT NULL,
 kind TEXT NOT NULL,
 priority TEXT NOT NULL,
 attempt_no INTEGER NOT NULL CHECK(typeof(attempt_no)='integer' AND attempt_no>=0),
 brief_json TEXT NOT NULL,
 blocked_on_json TEXT NOT NULL,
 requires_user_approval INTEGER NOT NULL CHECK(typeof(requires_user_approval)='integer' AND requires_user_approval IN(0,1)),
 ready_since TEXT NOT NULL,
 bridge_id TEXT NOT NULL,
 workflow_run_id TEXT NOT NULL,
 workflow_execution_no INTEGER NOT NULL CHECK(typeof(workflow_execution_no)='integer' AND workflow_execution_no>=0),
 stage_key TEXT NOT NULL,
 stage_index INTEGER NOT NULL CHECK(typeof(stage_index)='integer' AND stage_index>=0),
 generated_by_json TEXT NOT NULL,
 created_at TEXT NOT NULL,
 updated_at TEXT NOT NULL,
 published_at TEXT NOT NULL,
 started_at TEXT NOT NULL,
 completed_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,task_id),
 FOREIGN KEY(chain_id,source_revision,snapshot_kind,owner_user_id) REFERENCES native_fact_snapshots(chain_id,source_revision,kind,owner_user_id)
);
CREATE TABLE native_fact_comment (
 source_revision TEXT NOT NULL, snapshot_kind TEXT NOT NULL CHECK(snapshot_kind='comment'),
 delegated_client_id TEXT NOT NULL,
 delegated_grant_id TEXT NOT NULL,
 comment_id TEXT NOT NULL,
 task_id TEXT NOT NULL,
 chain_id TEXT NOT NULL,
 owner_user_id TEXT NOT NULL,
 author_agent_instance_id TEXT NOT NULL,
 body TEXT NOT NULL,
 created_at TEXT NOT NULL,
 updated_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,comment_id),
 FOREIGN KEY(chain_id,source_revision,snapshot_kind,owner_user_id) REFERENCES native_fact_snapshots(chain_id,source_revision,kind,owner_user_id)
);
CREATE TABLE native_fact_summary (
 source_revision TEXT NOT NULL, snapshot_kind TEXT NOT NULL CHECK(snapshot_kind='summary'),
 curated_body TEXT NOT NULL,
 curated_initialized INTEGER NOT NULL CHECK(typeof(curated_initialized)='integer' AND curated_initialized IN(0,1)),
 failure_fingerprint TEXT NOT NULL,
 chain_id TEXT NOT NULL,
 owner_user_id TEXT NOT NULL,
 body TEXT NOT NULL,
 line_count INTEGER NOT NULL CHECK(typeof(line_count)='integer' AND line_count>=0),
 version INTEGER NOT NULL CHECK(typeof(version)='integer' AND version>=0),
 updated_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,snapshot_kind),
 FOREIGN KEY(chain_id,source_revision,snapshot_kind,owner_user_id) REFERENCES native_fact_snapshots(chain_id,source_revision,kind,owner_user_id)
);
CREATE TRIGGER native_fact_snapshots_no_update BEFORE UPDATE ON native_fact_snapshots BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER native_fact_snapshots_no_delete BEFORE DELETE ON native_fact_snapshots BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER native_fact_chain_no_update BEFORE UPDATE ON native_fact_chain BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER native_fact_chain_no_delete BEFORE DELETE ON native_fact_chain BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER native_fact_task_no_update BEFORE UPDATE ON native_fact_task BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER native_fact_task_no_delete BEFORE DELETE ON native_fact_task BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER native_fact_comment_no_update BEFORE UPDATE ON native_fact_comment BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER native_fact_comment_no_delete BEFORE DELETE ON native_fact_comment BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER native_fact_summary_no_update BEFORE UPDATE ON native_fact_summary BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER native_fact_summary_no_delete BEFORE DELETE ON native_fact_summary BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
