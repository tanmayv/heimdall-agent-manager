BEGIN IMMEDIATE;
-- R3 cutover. A migration becomes 'imported' only in the Hub transaction that
-- verified the owner's signed import receipt and registered owner-local
-- routing. 'imported' is terminal and keeps every legacy canonical write guard
-- (the guards below now name both frozen and imported), so the legacy writer
-- is permanently disabled before the owner Bridge activates local admission.
-- Every trigger that names owner_legacy_migrations is dropped and recreated
-- around the table rebuild because SQLite cannot widen a CHECK in place.
DROP TRIGGER owner_legacy_guard_task_chains_insert;
DROP TRIGGER owner_legacy_guard_task_chains_update;
DROP TRIGGER owner_legacy_guard_task_chains_delete;
DROP TRIGGER owner_legacy_guard_tasks_insert;
DROP TRIGGER owner_legacy_guard_tasks_update;
DROP TRIGGER owner_legacy_guard_tasks_delete;
DROP TRIGGER owner_legacy_guard_task_chain_members_insert;
DROP TRIGGER owner_legacy_guard_task_chain_members_update;
DROP TRIGGER owner_legacy_guard_task_chain_members_delete;
DROP TRIGGER owner_legacy_guard_task_chain_directories_insert;
DROP TRIGGER owner_legacy_guard_task_chain_directories_update;
DROP TRIGGER owner_legacy_guard_task_chain_directories_delete;
DROP TRIGGER owner_legacy_guard_chain_summaries_insert;
DROP TRIGGER owner_legacy_guard_chain_summaries_update;
DROP TRIGGER owner_legacy_guard_chain_summaries_delete;
DROP TRIGGER owner_legacy_guard_workflow_runs_insert;
DROP TRIGGER owner_legacy_guard_workflow_runs_update;
DROP TRIGGER owner_legacy_guard_workflow_runs_delete;
DROP TRIGGER owner_legacy_guard_workflow_run_executions_insert;
DROP TRIGGER owner_legacy_guard_workflow_run_executions_update;
DROP TRIGGER owner_legacy_guard_workflow_run_executions_delete;
DROP TRIGGER owner_legacy_guard_workflow_stage_executions_insert;
DROP TRIGGER owner_legacy_guard_workflow_stage_executions_update;
DROP TRIGGER owner_legacy_guard_workflow_stage_executions_delete;
DROP TRIGGER owner_legacy_guard_workflow_run_events_insert;
DROP TRIGGER owner_legacy_guard_workflow_run_events_update;
DROP TRIGGER owner_legacy_guard_workflow_run_events_delete;
DROP TRIGGER owner_legacy_guard_work_dependencies_insert;
DROP TRIGGER owner_legacy_guard_work_dependencies_update;
DROP TRIGGER owner_legacy_guard_work_dependencies_delete;
DROP TRIGGER owner_legacy_guard_work_input_receipts_insert;
DROP TRIGGER owner_legacy_guard_work_input_receipts_update;
DROP TRIGGER owner_legacy_guard_work_input_receipts_delete;
DROP TRIGGER owner_legacy_guard_work_scope_decisions_insert;
DROP TRIGGER owner_legacy_guard_work_scope_decisions_update;
DROP TRIGGER owner_legacy_guard_work_scope_decisions_delete;
DROP TRIGGER owner_legacy_guard_work_chain_completions_insert;
DROP TRIGGER owner_legacy_guard_work_chain_completions_update;
DROP TRIGGER owner_legacy_guard_work_chain_completions_delete;
DROP TRIGGER owner_legacy_guard_chat_conversations_insert;
DROP TRIGGER owner_legacy_guard_chat_conversations_update;
DROP TRIGGER owner_legacy_guard_chat_conversations_delete;
DROP TRIGGER owner_legacy_guard_task_comments_insert;
DROP TRIGGER owner_legacy_guard_task_comments_update;
DROP TRIGGER owner_legacy_guard_task_comments_delete;
DROP TRIGGER owner_legacy_guard_task_dependencies_insert;
DROP TRIGGER owner_legacy_guard_task_dependencies_update;
DROP TRIGGER owner_legacy_guard_task_dependencies_delete;
DROP TRIGGER owner_legacy_guard_task_events_insert;
DROP TRIGGER owner_legacy_guard_task_events_update;
DROP TRIGGER owner_legacy_guard_task_events_delete;
DROP TRIGGER owner_legacy_guard_task_attempts_insert;
DROP TRIGGER owner_legacy_guard_task_attempts_update;
DROP TRIGGER owner_legacy_guard_task_attempts_delete;
DROP TRIGGER owner_legacy_guard_task_attempt_facets_insert;
DROP TRIGGER owner_legacy_guard_task_attempt_facets_update;
DROP TRIGGER owner_legacy_guard_task_attempt_facets_delete;
DROP TRIGGER owner_legacy_guard_task_leases_insert;
DROP TRIGGER owner_legacy_guard_task_leases_update;
DROP TRIGGER owner_legacy_guard_task_leases_delete;
DROP TRIGGER owner_legacy_guard_task_reviews_insert;
DROP TRIGGER owner_legacy_guard_task_reviews_update;
DROP TRIGGER owner_legacy_guard_task_reviews_delete;
DROP TRIGGER owner_legacy_guard_artifacts_insert;
DROP TRIGGER owner_legacy_guard_artifacts_update;
DROP TRIGGER owner_legacy_guard_artifacts_delete;
DROP TRIGGER owner_legacy_guard_task_chain_fleets_insert;
DROP TRIGGER owner_legacy_guard_task_chain_fleets_update;
DROP TRIGGER owner_legacy_guard_task_chain_fleets_delete;
DROP TRIGGER owner_legacy_guard_chat_messages_insert;
DROP TRIGGER owner_legacy_guard_chat_messages_update;
DROP TRIGGER owner_legacy_guard_chat_messages_delete;
DROP TRIGGER owner_legacy_no_new_lease;
DROP TRIGGER owner_legacy_no_replaced_lease;
DROP TRIGGER owner_legacy_effect_admission;
DROP TRIGGER owner_legacy_migration_identity;
DROP TRIGGER owner_legacy_migration_no_delete;
DROP TRIGGER owner_legacy_migration_freeze_requires_quiescence;
CREATE TABLE owner_legacy_migrations_v207 (
  migration_id TEXT PRIMARY KEY,
  chain_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  owner_bridge_id TEXT NOT NULL,
  owner_key_id TEXT NOT NULL,
  selection_digest TEXT NOT NULL CHECK(length(selection_digest)=64),
  state TEXT NOT NULL CHECK(state IN ('draining','frozen','imported')),
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision > 0),
  frozen_generation INTEGER NOT NULL DEFAULT 0 CHECK(frozen_generation >= 0),
  quiescence_digest TEXT NOT NULL DEFAULT '',
  manifest_digest TEXT NOT NULL DEFAULT '',
  receipt_digest TEXT NOT NULL DEFAULT '',
  UNIQUE(chain_id),
  FOREIGN KEY(chain_id,account_id) REFERENCES owner_legacy_source_generations(chain_id,account_id),
  CHECK((state='draining' AND quiescence_digest='' AND frozen_generation=0) OR
        (state IN ('frozen','imported') AND length(quiescence_digest)=64)),
  CHECK((state!='imported' AND manifest_digest='' AND receipt_digest='') OR
        (state='imported' AND length(manifest_digest)=64 AND length(receipt_digest)=64))
);
INSERT INTO owner_legacy_migrations_v207(migration_id,chain_id,account_id,owner_bridge_id,owner_key_id,selection_digest,state,revision,frozen_generation,quiescence_digest)
  SELECT migration_id,chain_id,account_id,owner_bridge_id,owner_key_id,selection_digest,state,revision,frozen_generation,quiescence_digest FROM owner_legacy_migrations;
DROP TABLE owner_legacy_migrations;
ALTER TABLE owner_legacy_migrations_v207 RENAME TO owner_legacy_migrations;
CREATE TRIGGER owner_legacy_migration_identity BEFORE UPDATE ON owner_legacy_migrations
WHEN NEW.migration_id!=OLD.migration_id OR NEW.chain_id!=OLD.chain_id OR NEW.account_id!=OLD.account_id
  OR NEW.owner_bridge_id!=OLD.owner_bridge_id OR NEW.owner_key_id!=OLD.owner_key_id
  OR NEW.selection_digest!=OLD.selection_digest OR NEW.revision!=OLD.revision+1
  OR NOT ((OLD.state='draining' AND NEW.state='frozen')
       OR (OLD.state='frozen' AND NEW.state='imported' AND NEW.frozen_generation=OLD.frozen_generation
           AND NEW.quiescence_digest=OLD.quiescence_digest))
BEGIN SELECT RAISE(ABORT,'legacy migration identity or transition conflicts'); END;
CREATE TRIGGER owner_legacy_migration_no_delete BEFORE DELETE ON owner_legacy_migrations
BEGIN SELECT RAISE(ABORT,'legacy migration fence is permanent'); END;
CREATE TRIGGER owner_legacy_migration_freeze_requires_quiescence BEFORE UPDATE ON owner_legacy_migrations
WHEN NEW.state='frozen' AND (
  NOT EXISTS(SELECT 1 FROM owner_legacy_source_generations g WHERE g.chain_id=NEW.chain_id
    AND g.account_id=NEW.account_id AND g.generation=NEW.frozen_generation)
  OR EXISTS(SELECT 1 FROM task_leases l WHERE l.chain_id=NEW.chain_id)
  OR EXISTS(SELECT 1 FROM owner_legacy_source_effects e WHERE e.chain_id=NEW.chain_id AND e.state='outstanding'))
BEGIN SELECT RAISE(ABORT,'legacy source remains unresolved'); END;
-- Cutover inserts the owner-local route first; the import state names it.
CREATE TRIGGER owner_legacy_migration_import_requires_route BEFORE UPDATE ON owner_legacy_migrations
WHEN NEW.state='imported' AND NOT EXISTS(SELECT 1 FROM owner_local_chains c WHERE c.chain_id=NEW.chain_id
  AND c.account_id=NEW.account_id AND c.owner_bridge_id=NEW.owner_bridge_id AND c.owner_key_id=NEW.owner_key_id)
BEGIN SELECT RAISE(ABORT,'imported migration requires its owner-local route'); END;
CREATE TRIGGER owner_legacy_no_new_lease BEFORE INSERT ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.chain_id=NEW.chain_id
  OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id))
BEGIN SELECT RAISE(ABORT,'legacy source grants are draining'); END;
CREATE TRIGGER owner_legacy_no_replaced_lease BEFORE UPDATE ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.chain_id=OLD.chain_id
  OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id))
 AND (NEW.lease_id!=OLD.lease_id OR NEW.task_id!=OLD.task_id OR NEW.chain_id!=OLD.chain_id
   OR NEW.owner_user_id!=OLD.owner_user_id OR NEW.holder_instance_id!=OLD.holder_instance_id
   OR NEW.attempt_no!=OLD.attempt_no OR NEW.kind!=OLD.kind OR NEW.review_role!=OLD.review_role
   OR NEW.granted_at!=OLD.granted_at)
BEGIN SELECT RAISE(ABORT,'legacy source grants are draining'); END;
CREATE TRIGGER owner_legacy_effect_admission BEFORE INSERT ON owner_legacy_source_effects
WHEN NEW.state!='outstanding' OR NOT EXISTS(SELECT 1 FROM owner_legacy_source_generations g
  WHERE g.chain_id=NEW.chain_id AND g.account_id=NEW.account_id AND g.generation=NEW.generation)
  OR EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.chain_id=NEW.chain_id)
BEGIN SELECT RAISE(ABORT,'legacy source dispatch is fenced'); END;
CREATE TRIGGER owner_legacy_guard_task_chains_insert BEFORE INSERT ON task_chains
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chains_update BEFORE UPDATE ON task_chains
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chains_delete BEFORE DELETE ON task_chains
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_tasks_insert BEFORE INSERT ON tasks
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_tasks_update BEFORE UPDATE ON tasks
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_tasks_delete BEFORE DELETE ON tasks
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_members_insert BEFORE INSERT ON task_chain_members
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_members_update BEFORE UPDATE ON task_chain_members
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_members_delete BEFORE DELETE ON task_chain_members
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_directories_insert BEFORE INSERT ON task_chain_directories
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_directories_update BEFORE UPDATE ON task_chain_directories
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_directories_delete BEFORE DELETE ON task_chain_directories
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_chain_summaries_insert BEFORE INSERT ON chain_summaries
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_chain_summaries_update BEFORE UPDATE ON chain_summaries
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_chain_summaries_delete BEFORE DELETE ON chain_summaries
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_runs_insert BEFORE INSERT ON workflow_runs
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_runs_update BEFORE UPDATE ON workflow_runs
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_runs_delete BEFORE DELETE ON workflow_runs
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_run_executions_insert BEFORE INSERT ON workflow_run_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_run_executions_update BEFORE UPDATE ON workflow_run_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_run_executions_delete BEFORE DELETE ON workflow_run_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_stage_executions_insert BEFORE INSERT ON workflow_stage_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_stage_executions_update BEFORE UPDATE ON workflow_stage_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_stage_executions_delete BEFORE DELETE ON workflow_stage_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_run_events_insert BEFORE INSERT ON workflow_run_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_run_events_update BEFORE UPDATE ON workflow_run_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_workflow_run_events_delete BEFORE DELETE ON workflow_run_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_dependencies_insert BEFORE INSERT ON work_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_dependencies_update BEFORE UPDATE ON work_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_dependencies_delete BEFORE DELETE ON work_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_input_receipts_insert BEFORE INSERT ON work_input_receipts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_input_receipts_update BEFORE UPDATE ON work_input_receipts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_input_receipts_delete BEFORE DELETE ON work_input_receipts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_scope_decisions_insert BEFORE INSERT ON work_scope_decisions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_scope_decisions_update BEFORE UPDATE ON work_scope_decisions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_scope_decisions_delete BEFORE DELETE ON work_scope_decisions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_chain_completions_insert BEFORE INSERT ON work_chain_completions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_chain_completions_update BEFORE UPDATE ON work_chain_completions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_work_chain_completions_delete BEFORE DELETE ON work_chain_completions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_chat_conversations_insert BEFORE INSERT ON chat_conversations
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_chat_conversations_update BEFORE UPDATE ON chat_conversations
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_chat_conversations_delete BEFORE DELETE ON chat_conversations
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_comments_insert BEFORE INSERT ON task_comments
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_comments_update BEFORE UPDATE ON task_comments
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_comments_delete BEFORE DELETE ON task_comments
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_dependencies_insert BEFORE INSERT ON task_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id) OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.depends_on_task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_dependencies_update BEFORE UPDATE ON task_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.depends_on_task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id) OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.depends_on_task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_dependencies_delete BEFORE DELETE ON task_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.depends_on_task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_events_insert BEFORE INSERT ON task_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_events_update BEFORE UPDATE ON task_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_events_delete BEFORE DELETE ON task_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_attempts_insert BEFORE INSERT ON task_attempts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_attempts_update BEFORE UPDATE ON task_attempts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_attempts_delete BEFORE DELETE ON task_attempts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_attempt_facets_insert BEFORE INSERT ON task_attempt_facets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_attempt_facets_update BEFORE UPDATE ON task_attempt_facets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_attempt_facets_delete BEFORE DELETE ON task_attempt_facets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_leases_insert BEFORE INSERT ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_leases_update BEFORE UPDATE ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_leases_delete BEFORE DELETE ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_reviews_insert BEFORE INSERT ON task_reviews
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_reviews_update BEFORE UPDATE ON task_reviews
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_reviews_delete BEFORE DELETE ON task_reviews
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_artifacts_insert BEFORE INSERT ON artifacts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_artifacts_update BEFORE UPDATE ON artifacts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_artifacts_delete BEFORE DELETE ON artifacts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_fleets_insert BEFORE INSERT ON task_chain_fleets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=NEW.task_chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_fleets_update BEFORE UPDATE ON task_chain_fleets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.task_chain_id OR m.chain_id=NEW.task_chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_task_chain_fleets_delete BEFORE DELETE ON task_chain_fleets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=OLD.task_chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_chat_messages_insert BEFORE INSERT ON chat_messages
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=NEW.conversation_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_chat_messages_update BEFORE UPDATE ON chat_messages
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=OLD.conversation_id) OR m.chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=NEW.conversation_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_guard_chat_messages_delete BEFORE DELETE ON chat_messages
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state IN ('frozen','imported') AND (m.chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=OLD.conversation_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
INSERT INTO schema_migrations(version) VALUES('207_owner_legacy_import_cutover.sql');
COMMIT;
