-- V23: publication, proposals and mixed work.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v23 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 23 CHECK(schema_version=23),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v23 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,23,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v23 RENAME TO runtime_database;
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

CREATE TABLE local_work_chains (
 chain_id TEXT PRIMARY KEY REFERENCES task_chains(chain_id),
 publish_state TEXT NOT NULL DEFAULT 'published' CHECK(publish_state IN ('draft','published')),
 status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','completed')),
 work_revision INTEGER NOT NULL DEFAULT 0 CHECK(work_revision>=0)
);
INSERT INTO local_work_chains(chain_id) SELECT chain_id FROM task_chains;
CREATE TRIGGER local_work_chain_create AFTER INSERT ON task_chains
BEGIN INSERT INTO local_work_chains(chain_id) VALUES(NEW.chain_id); END;
CREATE TABLE local_task_publications (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 publish_state TEXT NOT NULL CHECK(publish_state IN ('draft','published')),
 PRIMARY KEY(chain_id,task_id,accepted_seq),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE local_work_proposals (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), proposal_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 proposal_json TEXT NOT NULL, created_at TEXT NOT NULL,
 actor_kind TEXT NOT NULL, actor_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,proposal_id)
);
CREATE TABLE local_work_decisions (
 chain_id TEXT NOT NULL, proposal_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 decision TEXT NOT NULL CHECK(decision IN ('approve','reject')), note TEXT NOT NULL,
 result_json TEXT NOT NULL, decided_at TEXT NOT NULL, actor_kind TEXT NOT NULL, actor_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,proposal_id),
 FOREIGN KEY(chain_id,proposal_id) REFERENCES local_work_proposals(chain_id,proposal_id)
);
CREATE TABLE local_work_dependencies (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), dependency_id TEXT NOT NULL,
 dependent_kind TEXT NOT NULL CHECK(dependent_kind IN ('task','workflow_run')), dependent_id TEXT NOT NULL,
 prerequisite_kind TEXT NOT NULL CHECK(prerequisite_kind IN ('task','workflow_run')), prerequisite_id TEXT NOT NULL,
 created_at TEXT NOT NULL, created_by_kind TEXT NOT NULL, created_by_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,dependency_id)
);
CREATE TABLE local_work_dependency_removals (
 chain_id TEXT NOT NULL, dependency_id TEXT NOT NULL,
 removed_at TEXT NOT NULL, removed_by_kind TEXT NOT NULL, removed_by_id TEXT NOT NULL, reason TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,dependency_id),
 FOREIGN KEY(chain_id,dependency_id) REFERENCES local_work_dependencies(chain_id,dependency_id)
);
CREATE VIEW local_work_active_dependencies AS SELECT d.* FROM local_work_dependencies d
WHERE NOT EXISTS(SELECT 1 FROM local_work_dependency_removals r WHERE r.chain_id=d.chain_id AND r.dependency_id=d.dependency_id);
CREATE TABLE local_work_inputs (
 receipt_id TEXT PRIMARY KEY, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 dependent_kind TEXT NOT NULL, dependent_id TEXT NOT NULL, dependent_generation INTEGER NOT NULL CHECK(dependent_generation>0),
 prerequisite_kind TEXT NOT NULL, prerequisite_id TEXT NOT NULL, prerequisite_generation INTEGER NOT NULL CHECK(prerequisite_generation>0),
 output_manifest_json TEXT NOT NULL, created_at TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(chain_id,dependent_kind,dependent_id,dependent_generation,prerequisite_kind,prerequisite_id)
);
CREATE TABLE local_work_scope (
 decision_id INTEGER PRIMARY KEY, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 item_kind TEXT NOT NULL CHECK(item_kind IN ('task','workflow_run')), item_id TEXT NOT NULL,
 action TEXT NOT NULL CHECK(action IN ('include','exclude')), reason TEXT NOT NULL,
 actor_kind TEXT NOT NULL, actor_id TEXT NOT NULL, created_at TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE local_work_completions (
 chain_id TEXT PRIMARY KEY REFERENCES task_chains(chain_id), work_revision INTEGER NOT NULL,
 summary TEXT NOT NULL, completed_at TEXT NOT NULL, actor_kind TEXT NOT NULL, actor_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE local_work_pending_runs (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), run_id TEXT NOT NULL,
 run_json TEXT NOT NULL, created_at TEXT NOT NULL, actor_kind TEXT NOT NULL, actor_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,run_id)
);
CREATE TABLE local_work_run_starts (
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 started_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,run_id),
 FOREIGN KEY(chain_id,run_id) REFERENCES local_work_pending_runs(chain_id,run_id)
);
CREATE TRIGGER local_task_publications_immutable_update BEFORE UPDATE ON local_task_publications
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_task_publications_immutable_delete BEFORE DELETE ON local_task_publications
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_proposals_immutable_update BEFORE UPDATE ON local_work_proposals
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_proposals_immutable_delete BEFORE DELETE ON local_work_proposals
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_decisions_immutable_update BEFORE UPDATE ON local_work_decisions
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_decisions_immutable_delete BEFORE DELETE ON local_work_decisions
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_dependencies_immutable_update BEFORE UPDATE ON local_work_dependencies
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_dependencies_immutable_delete BEFORE DELETE ON local_work_dependencies
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_dependency_removals_immutable_update BEFORE UPDATE ON local_work_dependency_removals
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_dependency_removals_immutable_delete BEFORE DELETE ON local_work_dependency_removals
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_inputs_immutable_update BEFORE UPDATE ON local_work_inputs
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_inputs_immutable_delete BEFORE DELETE ON local_work_inputs
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_scope_immutable_update BEFORE UPDATE ON local_work_scope
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_scope_immutable_delete BEFORE DELETE ON local_work_scope
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_completions_immutable_update BEFORE UPDATE ON local_work_completions
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_completions_immutable_delete BEFORE DELETE ON local_work_completions
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_pending_runs_immutable_update BEFORE UPDATE ON local_work_pending_runs
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_pending_runs_immutable_delete BEFORE DELETE ON local_work_pending_runs
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_run_starts_immutable_update BEFORE UPDATE ON local_work_run_starts
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER local_work_run_starts_immutable_delete BEFORE DELETE ON local_work_run_starts
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER work_revision_tasks_insert AFTER INSERT ON tasks
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_tasks_delete AFTER DELETE ON tasks
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER work_revision_task_requirements_insert AFTER INSERT ON task_requirements
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_lifecycle_state_insert AFTER INSERT ON lifecycle_state
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_lifecycle_state_update AFTER UPDATE ON lifecycle_state
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_work_attempts_insert AFTER INSERT ON local_work_attempts
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_workflow_runs_insert AFTER INSERT ON local_workflow_runs
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_workflow_runs_update AFTER UPDATE ON local_workflow_runs
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_workflow_executions_insert AFTER INSERT ON local_workflow_executions
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_workflow_executions_update AFTER UPDATE ON local_workflow_executions
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_task_publications_insert AFTER INSERT ON local_task_publications
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_work_dependencies_insert AFTER INSERT ON local_work_dependencies
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_work_dependency_removals_insert AFTER INSERT ON local_work_dependency_removals
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_work_scope_insert AFTER INSERT ON local_work_scope
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_chain_defaults_versions_insert AFTER INSERT ON local_chain_defaults_versions
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_work_pending_runs_insert AFTER INSERT ON local_work_pending_runs
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER work_revision_local_work_run_starts_insert AFTER INSERT ON local_work_run_starts
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER local_work_chain_publication AFTER UPDATE OF publish_state,status ON local_work_chains
WHEN NEW.publish_state!=OLD.publish_state OR NEW.status!=OLD.status
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER local_work_chain_completed BEFORE UPDATE ON local_work_chains
WHEN OLD.status='completed' AND (NEW.status!=OLD.status OR NEW.publish_state!=OLD.publish_state)
BEGIN SELECT RAISE(ABORT,'completed chain'); END;
CREATE TRIGGER local_work_referenced_task_no_delete BEFORE DELETE ON tasks
WHEN EXISTS(SELECT 1 FROM local_work_dependencies WHERE chain_id=OLD.chain_id AND ((dependent_kind='task' AND dependent_id=OLD.task_id) OR (prerequisite_kind='task' AND prerequisite_id=OLD.task_id)))
 OR EXISTS(SELECT 1 FROM local_work_inputs WHERE chain_id=OLD.chain_id AND ((dependent_kind='task' AND dependent_id=OLD.task_id) OR (prerequisite_kind='task' AND prerequisite_id=OLD.task_id)))
 OR EXISTS(SELECT 1 FROM local_work_scope WHERE chain_id=OLD.chain_id AND item_kind='task' AND item_id=OLD.task_id)
BEGIN SELECT RAISE(ABORT,'referenced work history'); END;

CREATE TABLE local_work_run_publications (
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,run_id),
 FOREIGN KEY(chain_id,run_id) REFERENCES local_work_pending_runs(chain_id,run_id)
);
CREATE TABLE local_work_materialized_tasks (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 proposal_id TEXT NOT NULL, spec_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,accepted_seq),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TRIGGER work_run_publications_no_update BEFORE UPDATE ON local_work_run_publications BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER work_run_publications_no_delete BEFORE DELETE ON local_work_run_publications BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER work_materialized_tasks_no_update BEFORE UPDATE ON local_work_materialized_tasks BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER work_materialized_tasks_no_delete BEFORE DELETE ON local_work_materialized_tasks BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER work_revision_run_publications AFTER INSERT ON local_work_run_publications
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;

CREATE TABLE native_work_snapshots (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('work_dependency','work_receipt','work_scope','work_run','work_execution','work_stage','work_event')),
 owner_user_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 record_count INTEGER NOT NULL CHECK(record_count>=0 AND record_count<=100), content_digest TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,kind),
 FOREIGN KEY(chain_id,owner_user_id) REFERENCES native_metadata_origins(chain_id,owner_user_id)
);
CREATE TRIGGER native_work_snapshots_no_update BEFORE UPDATE ON native_work_snapshots BEGIN SELECT RAISE(ABORT,'immutable source work snapshot'); END;
CREATE TRIGGER native_work_snapshots_no_delete BEFORE DELETE ON native_work_snapshots BEGIN SELECT RAISE(ABORT,'immutable source work snapshot'); END;
CREATE TABLE native_work_records (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL, record_key TEXT NOT NULL,
 record_json TEXT NOT NULL CHECK(json_valid(record_json)),
 PRIMARY KEY(chain_id,source_revision,kind,record_key),
 FOREIGN KEY(chain_id,source_revision,kind) REFERENCES native_work_snapshots(chain_id,source_revision,kind)
);
CREATE TRIGGER native_work_no_update BEFORE UPDATE ON native_work_records BEGIN SELECT RAISE(ABORT,'immutable source work facts'); END;
CREATE TRIGGER native_work_no_delete BEFORE DELETE ON native_work_records BEGIN SELECT RAISE(ABORT,'immutable source work facts'); END;

CREATE TABLE local_work_run_cancellations (
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL, reason TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,run_id),
 FOREIGN KEY(chain_id,run_id) REFERENCES local_work_pending_runs(chain_id,run_id)
);
CREATE TRIGGER work_run_cancellations_no_update BEFORE UPDATE ON local_work_run_cancellations BEGIN SELECT RAISE(ABORT,'immutable cancellation'); END;
CREATE TRIGGER work_run_cancellations_no_delete BEFORE DELETE ON local_work_run_cancellations BEGIN SELECT RAISE(ABORT,'immutable cancellation'); END;
CREATE TRIGGER work_revision_run_cancellations AFTER INSERT ON local_work_run_cancellations
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;

CREATE TRIGGER work_revision_local_dependencies_insert AFTER INSERT ON local_dependencies
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;

CREATE TRIGGER work_revision_local_dependencies_delete AFTER DELETE ON local_dependencies
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=OLD.chain_id; END;

CREATE TRIGGER work_revision_local_workflow_language_executions_insert AFTER INSERT ON local_workflow_language_executions
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;

CREATE TRIGGER work_revision_local_workflow_language_executions_update AFTER UPDATE ON local_workflow_language_executions
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;

CREATE TRIGGER work_revision_local_controls_insert AFTER INSERT ON local_controls
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;

CREATE TRIGGER work_revision_local_controls_update AFTER UPDATE ON local_controls
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
