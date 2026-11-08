-- V34: static exemption for migration_discard. Replacing an abandoned,
-- never-activated import used to drop and recreate every append-only delete
-- guard of the chain-scoped tables; a guard is now lifted only while a
-- migration_discarding marker names the chain (or, for the migration_id-keyed
-- import tables, the migration). migration_discard inserts the marker, deletes
-- the rows and removes the marker in one transaction, so the marker table is
-- empty outside it. A marker may only name an abandoned, never-activated import
-- of that chain. Every BEFORE DELETE guard on a table migration_discard deletes
-- from must carry this exemption (asserted by migration_import_test).
-- runtime_database.schema_version is pinned per version: rebuild it as V33 did.
DROP TRIGGER intent_transition;
CREATE TABLE runtime_database_v34 (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 34 CHECK(schema_version=34),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
INSERT INTO runtime_database_v34 SELECT singleton,account_id,owner_bridge_id,owner_key_id,
 incarnation,commit_seq,clock_high_ms,directory_version,directory_hash,database_id,34,clock_generation,recovery_state FROM runtime_database;
DROP TABLE runtime_database;
ALTER TABLE runtime_database_v34 RENAME TO runtime_database;
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
CREATE TABLE IF NOT EXISTS migration_discarding (
 chain_id TEXT PRIMARY KEY, migration_id TEXT NOT NULL UNIQUE
);
DROP TRIGGER IF EXISTS migration_discarding_abandoned_only;
CREATE TRIGGER migration_discarding_abandoned_only BEFORE INSERT ON migration_discarding
 WHEN NOT EXISTS(SELECT 1 FROM migration_imports m JOIN migration_abandoned a ON a.migration_id=m.migration_id
  WHERE m.migration_id=NEW.migration_id AND m.chain_id=NEW.chain_id AND m.activated_seq IS NULL)
 BEGIN SELECT RAISE(ABORT,'discard marker requires an abandoned import'); END;
DROP TRIGGER IF EXISTS migration_discarding_immutable;
CREATE TRIGGER migration_discarding_immutable BEFORE UPDATE ON migration_discarding
 BEGIN SELECT RAISE(ABORT,'immutable discard marker'); END;
DROP TRIGGER IF EXISTS genesis_immutable_delete;
CREATE TRIGGER genesis_immutable_delete BEFORE DELETE ON chain_genesis
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable genesis'); END;
DROP TRIGGER IF EXISTS receipt_no_forget;
CREATE TRIGGER receipt_no_forget BEFORE DELETE ON command_receipts
 WHEN (NOT EXISTS(SELECT 1 FROM operation_tombstones t WHERE t.principal_id=OLD.principal_id AND t.operation_id=OLD.operation_id AND t.input_digest=OLD.input_digest AND t.method=OLD.method AND t.chain_id=OLD.chain_id AND t.task_id=OLD.task_id AND t.commit_seq=OLD.commit_seq)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'receipt requires retained tombstone'); END;
DROP TRIGGER IF EXISTS control_notices_no_delete;
CREATE TRIGGER control_notices_no_delete BEFORE DELETE ON control_notices
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable notice'); END;
DROP TRIGGER IF EXISTS deferred_retire_no_delete;
CREATE TRIGGER deferred_retire_no_delete BEFORE DELETE ON deferred_workflow_retirements
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable deferred retirement'); END;
DROP TRIGGER IF EXISTS lifecycle_configs_no_delete;
CREATE TRIGGER lifecycle_configs_no_delete BEFORE DELETE ON lifecycle_configs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
DROP TRIGGER IF EXISTS linked_body_delete_guard;
CREATE TRIGGER linked_body_delete_guard BEFORE DELETE ON linked_bodies
 WHEN (NOT EXISTS(SELECT 1 FROM linked_tombstones WHERE chain_id=OLD.chain_id AND kind=OLD.kind AND object_id=OLD.object_id AND revision=OLD.revision)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'tombstone before body GC'); END;
DROP TRIGGER IF EXISTS linked_identity_no_delete;
CREATE TRIGGER linked_identity_no_delete BEFORE DELETE ON linked_identities
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain linked identity'); END;
DROP TRIGGER IF EXISTS linked_reference_delete_guard;
CREATE TRIGGER linked_reference_delete_guard BEFORE DELETE ON linked_references
 WHEN (NOT EXISTS(SELECT 1 FROM linked_tombstones WHERE chain_id=OLD.chain_id AND kind=OLD.source_kind AND object_id=OLD.source_id AND revision=OLD.source_revision)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'tombstone before reference GC'); END;
DROP TRIGGER IF EXISTS linked_tombstone_no_delete;
CREATE TRIGGER linked_tombstone_no_delete BEFORE DELETE ON linked_tombstones
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain linked tombstone'); END;
DROP TRIGGER IF EXISTS local_assignment_history_no_delete;
CREATE TRIGGER local_assignment_history_no_delete BEFORE DELETE ON local_assignment_history
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable assignment'); END;
DROP TRIGGER IF EXISTS local_brief_inputs_no_delete;
CREATE TRIGGER local_brief_inputs_no_delete BEFORE DELETE ON local_brief_inputs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable brief inputs'); END;
DROP TRIGGER IF EXISTS local_chain_defaults_no_delete;
CREATE TRIGGER local_chain_defaults_no_delete BEFORE DELETE ON local_chain_defaults_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable defaults history'); END;
DROP TRIGGER IF EXISTS local_chain_directory_versions_no_delete;
CREATE TRIGGER local_chain_directory_versions_no_delete BEFORE DELETE ON local_chain_directory_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
DROP TRIGGER IF EXISTS local_chain_member_versions_no_delete;
CREATE TRIGGER local_chain_member_versions_no_delete BEFORE DELETE ON local_chain_member_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
DROP TRIGGER IF EXISTS local_chain_summary_no_delete;
CREATE TRIGGER local_chain_summary_no_delete BEFORE DELETE ON local_chain_summary_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable curated summary'); END;
DROP TRIGGER IF EXISTS local_config_revocations_no_delete;
CREATE TRIGGER local_config_revocations_no_delete BEFORE DELETE ON local_config_revocations
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
DROP TRIGGER IF EXISTS local_coordinator_revocations_no_delete;
CREATE TRIGGER local_coordinator_revocations_no_delete BEFORE DELETE ON local_coordinator_revocations
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
DROP TRIGGER IF EXISTS dependency_retirement_no_delete;
CREATE TRIGGER dependency_retirement_no_delete BEFORE DELETE ON local_dependency_retirements
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable dependency retirement'); END;
DROP TRIGGER IF EXISTS local_events_no_delete;
CREATE TRIGGER local_events_no_delete BEFORE DELETE ON local_events
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable event'); END;
DROP TRIGGER IF EXISTS local_fleet_policy_models_no_delete;
CREATE TRIGGER local_fleet_policy_models_no_delete BEFORE DELETE ON local_fleet_policy_models
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
DROP TRIGGER IF EXISTS local_fleet_policy_roles_no_delete;
CREATE TRIGGER local_fleet_policy_roles_no_delete BEFORE DELETE ON local_fleet_policy_roles
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
DROP TRIGGER IF EXISTS local_fleet_policy_sources_no_delete;
CREATE TRIGGER local_fleet_policy_sources_no_delete BEFORE DELETE ON local_fleet_policy_sources
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
DROP TRIGGER IF EXISTS local_fleet_policy_versions_no_delete;
CREATE TRIGGER local_fleet_policy_versions_no_delete BEFORE DELETE ON local_fleet_policy_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
DROP TRIGGER IF EXISTS local_grant_audit_no_delete;
CREATE TRIGGER local_grant_audit_no_delete BEFORE DELETE ON local_grant_audit
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable grant audit'); END;
DROP TRIGGER IF EXISTS local_handoffs_no_delete;
CREATE TRIGGER local_handoffs_no_delete BEFORE DELETE ON local_handoffs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable handoff'); END;
DROP TRIGGER IF EXISTS local_member_chains_no_delete;
CREATE TRIGGER local_member_chains_no_delete BEFORE DELETE ON local_member_chains
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
DROP TRIGGER IF EXISTS local_metadata_retirements_no_delete;
CREATE TRIGGER local_metadata_retirements_no_delete BEFORE DELETE ON local_metadata_retirements
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable metadata retirement'); END;
DROP TRIGGER IF EXISTS local_reviews_no_delete;
CREATE TRIGGER local_reviews_no_delete BEFORE DELETE ON local_reviews
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
DROP TRIGGER IF EXISTS local_role_configs_no_delete;
CREATE TRIGGER local_role_configs_no_delete BEFORE DELETE ON local_role_configs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
DROP TRIGGER IF EXISTS local_role_pairs_no_delete;
CREATE TRIGGER local_role_pairs_no_delete BEFORE DELETE ON local_role_pairs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
DROP TRIGGER IF EXISTS local_role_reviews_no_delete;
CREATE TRIGGER local_role_reviews_no_delete BEFORE DELETE ON local_role_reviews
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
DROP TRIGGER IF EXISTS local_submissions_no_delete;
CREATE TRIGGER local_submissions_no_delete BEFORE DELETE ON local_submissions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
DROP TRIGGER IF EXISTS local_task_priority_no_delete;
CREATE TRIGGER local_task_priority_no_delete BEFORE DELETE ON local_task_priority_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable priority history'); END;
DROP TRIGGER IF EXISTS local_task_publications_immutable_delete;
CREATE TRIGGER local_task_publications_immutable_delete BEFORE DELETE ON local_task_publications
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS local_task_retirements_no_delete;
CREATE TRIGGER local_task_retirements_no_delete BEFORE DELETE ON local_task_retirements
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable task retirement'); END;
DROP TRIGGER IF EXISTS local_work_attempts_no_delete;
CREATE TRIGGER local_work_attempts_no_delete BEFORE DELETE ON local_work_attempts
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work attempt'); END;
DROP TRIGGER IF EXISTS local_work_completions_immutable_delete;
CREATE TRIGGER local_work_completions_immutable_delete BEFORE DELETE ON local_work_completions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS local_work_decisions_immutable_delete;
CREATE TRIGGER local_work_decisions_immutable_delete BEFORE DELETE ON local_work_decisions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS local_work_dependencies_immutable_delete;
CREATE TRIGGER local_work_dependencies_immutable_delete BEFORE DELETE ON local_work_dependencies
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS local_work_dependency_removals_immutable_delete;
CREATE TRIGGER local_work_dependency_removals_immutable_delete BEFORE DELETE ON local_work_dependency_removals
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS local_work_inputs_immutable_delete;
CREATE TRIGGER local_work_inputs_immutable_delete BEFORE DELETE ON local_work_inputs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS work_materialized_tasks_no_delete;
CREATE TRIGGER work_materialized_tasks_no_delete BEFORE DELETE ON local_work_materialized_tasks
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS local_work_pending_runs_immutable_delete;
CREATE TRIGGER local_work_pending_runs_immutable_delete BEFORE DELETE ON local_work_pending_runs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS local_work_proposals_immutable_delete;
CREATE TRIGGER local_work_proposals_immutable_delete BEFORE DELETE ON local_work_proposals
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS work_run_cancellations_no_delete;
CREATE TRIGGER work_run_cancellations_no_delete BEFORE DELETE ON local_work_run_cancellations
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable cancellation'); END;
DROP TRIGGER IF EXISTS work_run_publications_no_delete;
CREATE TRIGGER work_run_publications_no_delete BEFORE DELETE ON local_work_run_publications
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS local_work_run_starts_immutable_delete;
CREATE TRIGGER local_work_run_starts_immutable_delete BEFORE DELETE ON local_work_run_starts
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS local_work_scope_immutable_delete;
CREATE TRIGGER local_work_scope_immutable_delete BEFORE DELETE ON local_work_scope
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
DROP TRIGGER IF EXISTS local_workflow_coordinators_no_delete;
CREATE TRIGGER local_workflow_coordinators_no_delete BEFORE DELETE ON local_workflow_coordinators
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable coordinator binding'); END;
DROP TRIGGER IF EXISTS local_workflow_definitions_no_delete;
CREATE TRIGGER local_workflow_definitions_no_delete BEFORE DELETE ON local_workflow_definitions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
DROP TRIGGER IF EXISTS local_workflow_events_no_delete;
CREATE TRIGGER local_workflow_events_no_delete BEFORE DELETE ON local_workflow_events
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
DROP TRIGGER IF EXISTS workflow_execution_no_delete;
CREATE TRIGGER workflow_execution_no_delete BEFORE DELETE ON local_workflow_executions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable execution history'); END;
DROP TRIGGER IF EXISTS local_workflow_language_runs_no_delete;
CREATE TRIGGER local_workflow_language_runs_no_delete BEFORE DELETE ON local_workflow_language_runs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
DROP TRIGGER IF EXISTS local_workflow_output_trigger_no_delete;
CREATE TRIGGER local_workflow_output_trigger_no_delete BEFORE DELETE ON local_workflow_output_triggers
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable output prerequisite'); END;
DROP TRIGGER IF EXISTS local_workflow_outputs_no_delete;
CREATE TRIGGER local_workflow_outputs_no_delete BEFORE DELETE ON local_workflow_outputs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
DROP TRIGGER IF EXISTS workflow_run_no_delete;
CREATE TRIGGER workflow_run_no_delete BEFORE DELETE ON local_workflow_runs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable workflow history'); END;
DROP TRIGGER IF EXISTS local_workflow_stage_expansions_no_delete;
CREATE TRIGGER local_workflow_stage_expansions_no_delete BEFORE DELETE ON local_workflow_stage_expansions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
DROP TRIGGER IF EXISTS local_workflow_tasks_no_delete;
CREATE TRIGGER local_workflow_tasks_no_delete BEFORE DELETE ON local_workflow_tasks
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
DROP TRIGGER IF EXISTS local_workflow_trigger_failures_no_delete;
CREATE TRIGGER local_workflow_trigger_failures_no_delete BEFORE DELETE ON local_workflow_trigger_failures
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable trigger outcome'); END;
DROP TRIGGER IF EXISTS migration_abandoned_no_delete;
CREATE TRIGGER migration_abandoned_no_delete BEFORE DELETE ON migration_abandoned
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.migration_id=OLD.migration_id)
 BEGIN SELECT RAISE(ABORT,'abandoned import stays abandoned'); END;
DROP TRIGGER IF EXISTS migration_archived_task_no_delete;
CREATE TRIGGER migration_archived_task_no_delete BEFORE DELETE ON migration_archived_tasks
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable archived task'); END;
DROP TRIGGER IF EXISTS migration_import_document_no_delete;
CREATE TRIGGER migration_import_document_no_delete BEFORE DELETE ON migration_import_documents
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.migration_id=OLD.migration_id)
 BEGIN SELECT RAISE(ABORT,'immutable migration document'); END;
DROP TRIGGER IF EXISTS migration_import_no_delete;
CREATE TRIGGER migration_import_no_delete BEFORE DELETE ON migration_imports
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retained migration import'); END;
DROP TRIGGER IF EXISTS native_fact_chain_no_delete;
CREATE TRIGGER native_fact_chain_no_delete BEFORE DELETE ON native_fact_chain
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
DROP TRIGGER IF EXISTS native_fact_comment_no_delete;
CREATE TRIGGER native_fact_comment_no_delete BEFORE DELETE ON native_fact_comment
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
DROP TRIGGER IF EXISTS native_fact_snapshots_no_delete;
CREATE TRIGGER native_fact_snapshots_no_delete BEFORE DELETE ON native_fact_snapshots
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
DROP TRIGGER IF EXISTS native_fact_summary_no_delete;
CREATE TRIGGER native_fact_summary_no_delete BEFORE DELETE ON native_fact_summary
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
DROP TRIGGER IF EXISTS native_fact_task_no_delete;
CREATE TRIGGER native_fact_task_no_delete BEFORE DELETE ON native_fact_task
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
DROP TRIGGER IF EXISTS native_fleet_policies_no_delete;
CREATE TRIGGER native_fleet_policies_no_delete BEFORE DELETE ON native_fleet_policies
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
DROP TRIGGER IF EXISTS native_fleet_snapshots_no_delete;
CREATE TRIGGER native_fleet_snapshots_no_delete BEFORE DELETE ON native_fleet_snapshots
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
DROP TRIGGER IF EXISTS native_history_no_delete;
CREATE TRIGGER native_history_no_delete BEFORE DELETE ON native_history_records
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native history'); END;
DROP TRIGGER IF EXISTS native_metadata_directories_no_delete;
CREATE TRIGGER native_metadata_directories_no_delete BEFORE DELETE ON native_metadata_directories
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
DROP TRIGGER IF EXISTS native_metadata_members_no_delete;
CREATE TRIGGER native_metadata_members_no_delete BEFORE DELETE ON native_metadata_members
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
DROP TRIGGER IF EXISTS native_metadata_origins_no_delete;
CREATE TRIGGER native_metadata_origins_no_delete BEFORE DELETE ON native_metadata_origins
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
DROP TRIGGER IF EXISTS native_metadata_snapshots_no_delete;
CREATE TRIGGER native_metadata_snapshots_no_delete BEFORE DELETE ON native_metadata_snapshots
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
DROP TRIGGER IF EXISTS native_record_snapshots_no_delete;
CREATE TRIGGER native_record_snapshots_no_delete BEFORE DELETE ON native_record_snapshots
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native records'); END;
DROP TRIGGER IF EXISTS native_record_values_no_delete;
CREATE TRIGGER native_record_values_no_delete BEFORE DELETE ON native_record_values
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native records'); END;
DROP TRIGGER IF EXISTS native_work_no_delete;
CREATE TRIGGER native_work_no_delete BEFORE DELETE ON native_work_records
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable source work facts'); END;
DROP TRIGGER IF EXISTS native_work_snapshots_no_delete;
CREATE TRIGGER native_work_snapshots_no_delete BEFORE DELETE ON native_work_snapshots
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable source work snapshot'); END;
DROP TRIGGER IF EXISTS tombstone_no_delete;
CREATE TRIGGER tombstone_no_delete BEFORE DELETE ON operation_tombstones
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain operation tombstone'); END;
DROP TRIGGER IF EXISTS owner_execution_no_delete;
CREATE TRIGGER owner_execution_no_delete BEFORE DELETE ON owner_execution_journal
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain execution identity'); END;
DROP TRIGGER IF EXISTS intent_no_delete;
CREATE TRIGGER intent_no_delete BEFORE DELETE ON runtime_intents
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain intent outcome'); END;
DROP TRIGGER IF EXISTS source_consumptions_no_delete;
CREATE TRIGGER source_consumptions_no_delete BEFORE DELETE ON source_consumptions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
DROP TRIGGER IF EXISTS source_pending_card_no_delete;
CREATE TRIGGER source_pending_card_no_delete BEFORE DELETE ON source_episodes
 WHEN (OLD.resolved=0 OR (OLD.card_id!='' AND OLD.card_closed=0)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'source still requires discovery'); END;
DROP TRIGGER IF EXISTS task_deletion_no_delete;
CREATE TRIGGER task_deletion_no_delete BEFORE DELETE ON task_deletions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain deletion'); END;
DROP TRIGGER IF EXISTS task_requirements_no_delete;
CREATE TRIGGER task_requirements_no_delete BEFORE DELETE ON task_requirements
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
DROP TRIGGER IF EXISTS local_work_referenced_task_no_delete;
CREATE TRIGGER local_work_referenced_task_no_delete BEFORE DELETE ON tasks
 WHEN (EXISTS(SELECT 1 FROM local_work_dependencies WHERE chain_id=OLD.chain_id AND ((dependent_kind='task' AND dependent_id=OLD.task_id) OR (prerequisite_kind='task' AND prerequisite_id=OLD.task_id))) OR EXISTS(SELECT 1 FROM local_work_inputs WHERE chain_id=OLD.chain_id AND ((dependent_kind='task' AND dependent_id=OLD.task_id) OR (prerequisite_kind='task' AND prerequisite_id=OLD.task_id))) OR EXISTS(SELECT 1 FROM local_work_scope WHERE chain_id=OLD.chain_id AND item_kind='task' AND item_id=OLD.task_id)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'referenced work history'); END;
DROP TRIGGER IF EXISTS workflow_task_no_delete;
CREATE TRIGGER workflow_task_no_delete BEFORE DELETE ON tasks
 WHEN (EXISTS(SELECT 1 FROM local_workflow_tasks w WHERE w.chain_id=OLD.chain_id AND w.task_id=OLD.task_id)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable generated history'); END;
