BEGIN IMMEDIATE;
-- Source-side metadata only. Never store export bodies, task snapshots,
-- plaintext search terms or original command payloads in these tables.
CREATE TABLE owner_legacy_source_generations (
  chain_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK(typeof(generation)='integer' AND generation >= 0),
  UNIQUE(chain_id,account_id)
);
CREATE TABLE owner_legacy_migrations (
  migration_id TEXT PRIMARY KEY,
  chain_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  owner_bridge_id TEXT NOT NULL,
  owner_key_id TEXT NOT NULL,
  selection_digest TEXT NOT NULL CHECK(length(selection_digest)=64),
  state TEXT NOT NULL CHECK(state IN ('draining','frozen')),
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision > 0),
  frozen_generation INTEGER NOT NULL DEFAULT 0 CHECK(frozen_generation >= 0),
  quiescence_digest TEXT NOT NULL DEFAULT '',
  UNIQUE(chain_id),
  FOREIGN KEY(chain_id,account_id) REFERENCES owner_legacy_source_generations(chain_id,account_id),
  CHECK((state='draining' AND quiescence_digest='' AND frozen_generation=0) OR
        (state='frozen' AND length(quiescence_digest)=64))
);
CREATE TABLE owner_legacy_source_effects (
  effect_id TEXT PRIMARY KEY,
  chain_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  bridge_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('wake','stop','merge')),
  input_digest TEXT NOT NULL CHECK(length(input_digest)=64),
  generation INTEGER NOT NULL CHECK(typeof(generation)='integer' AND generation > 0),
  -- Delivered/accepted is intentionally NOT a terminal state: execution or
  -- a merge can still be live. Only verified drain will retire an effect.
  state TEXT NOT NULL CHECK(state IN ('outstanding','retired')),
  retirement_digest TEXT NOT NULL DEFAULT '',
  FOREIGN KEY(chain_id,account_id) REFERENCES owner_legacy_source_generations(chain_id,account_id),
  UNIQUE(chain_id,generation),
  CHECK((state='outstanding' AND retirement_digest='') OR
        (state='retired' AND length(retirement_digest)=64))
);
CREATE INDEX owner_legacy_effects_outstanding ON owner_legacy_source_effects(chain_id,state,generation);
CREATE INDEX owner_legacy_effects_account ON owner_legacy_source_effects(account_id);
CREATE TRIGGER owner_legacy_source_identity BEFORE UPDATE ON owner_legacy_source_generations
WHEN NEW.chain_id!=OLD.chain_id OR NEW.account_id!=OLD.account_id OR NEW.generation!=OLD.generation+1
BEGIN SELECT RAISE(ABORT,'legacy source generation must advance exactly once'); END;
CREATE TRIGGER owner_legacy_source_no_delete BEFORE DELETE ON owner_legacy_source_generations
BEGIN SELECT RAISE(ABORT,'legacy source fence is permanent'); END;
CREATE TRIGGER owner_legacy_migration_identity BEFORE UPDATE ON owner_legacy_migrations
WHEN NEW.migration_id!=OLD.migration_id OR NEW.chain_id!=OLD.chain_id OR NEW.account_id!=OLD.account_id
  OR NEW.owner_bridge_id!=OLD.owner_bridge_id OR NEW.owner_key_id!=OLD.owner_key_id
  OR NEW.selection_digest!=OLD.selection_digest OR NEW.revision!=OLD.revision+1
  OR OLD.state!='draining' OR NEW.state!='frozen'
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
CREATE TRIGGER owner_legacy_effect_identity BEFORE UPDATE ON owner_legacy_source_effects
WHEN NEW.effect_id!=OLD.effect_id OR NEW.chain_id!=OLD.chain_id OR NEW.account_id!=OLD.account_id
  OR NEW.bridge_id!=OLD.bridge_id OR NEW.kind!=OLD.kind OR NEW.input_digest!=OLD.input_digest
  OR NEW.generation!=OLD.generation OR OLD.state!='outstanding' OR NEW.state!='retired'
BEGIN SELECT RAISE(ABORT,'legacy effect identity or transition conflicts'); END;
CREATE TRIGGER owner_legacy_effect_no_delete BEFORE DELETE ON owner_legacy_source_effects
BEGIN SELECT RAISE(ABORT,'legacy effect replay fence is permanent'); END;
CREATE TRIGGER owner_legacy_effect_admission BEFORE INSERT ON owner_legacy_source_effects
WHEN NEW.state!='outstanding' OR NOT EXISTS(SELECT 1 FROM owner_legacy_source_generations g
  WHERE g.chain_id=NEW.chain_id AND g.account_id=NEW.account_id AND g.generation=NEW.generation)
  OR EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.chain_id=NEW.chain_id
  AND (m.state='frozen' OR NEW.kind='wake'))
BEGIN SELECT RAISE(ABORT,'legacy source dispatch is fenced'); END;
-- A source freeze cannot race a new lease, including matcher/reaper/workflow
-- entry points that do not use the migration API. Existing holders can drain.
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

-- Explicit effective canonical aggregate; no inferred global other-domain guard.
CREATE TRIGGER owner_legacy_guard_task_chains_insert BEFORE INSERT ON task_chains
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chains_insert AFTER INSERT ON task_chains
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chains_update BEFORE UPDATE ON task_chains
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chains_update AFTER UPDATE ON task_chains
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chains_delete BEFORE DELETE ON task_chains
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chains_delete AFTER DELETE ON task_chains
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_tasks_insert BEFORE INSERT ON tasks
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_tasks_insert AFTER INSERT ON tasks
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_tasks_update BEFORE UPDATE ON tasks
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_tasks_update AFTER UPDATE ON tasks
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_tasks_delete BEFORE DELETE ON tasks
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_tasks_delete AFTER DELETE ON tasks
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chain_members_insert BEFORE INSERT ON task_chain_members
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chain_members_insert AFTER INSERT ON task_chain_members
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chain_members_update BEFORE UPDATE ON task_chain_members
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chain_members_update AFTER UPDATE ON task_chain_members
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chain_members_delete BEFORE DELETE ON task_chain_members
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chain_members_delete AFTER DELETE ON task_chain_members
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chain_directories_insert BEFORE INSERT ON task_chain_directories
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chain_directories_insert AFTER INSERT ON task_chain_directories
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chain_directories_update BEFORE UPDATE ON task_chain_directories
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chain_directories_update AFTER UPDATE ON task_chain_directories
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chain_directories_delete BEFORE DELETE ON task_chain_directories
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chain_directories_delete AFTER DELETE ON task_chain_directories
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_chain_summaries_insert BEFORE INSERT ON chain_summaries
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_chain_summaries_insert AFTER INSERT ON chain_summaries
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_chain_summaries_update BEFORE UPDATE ON chain_summaries
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_chain_summaries_update AFTER UPDATE ON chain_summaries
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_chain_summaries_delete BEFORE DELETE ON chain_summaries
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_chain_summaries_delete AFTER DELETE ON chain_summaries
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_runs_insert BEFORE INSERT ON workflow_runs
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_runs_insert AFTER INSERT ON workflow_runs
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_runs_update BEFORE UPDATE ON workflow_runs
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_runs_update AFTER UPDATE ON workflow_runs
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_runs_delete BEFORE DELETE ON workflow_runs
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_runs_delete AFTER DELETE ON workflow_runs
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_run_executions_insert BEFORE INSERT ON workflow_run_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_run_executions_insert AFTER INSERT ON workflow_run_executions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_run_executions_update BEFORE UPDATE ON workflow_run_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_run_executions_update AFTER UPDATE ON workflow_run_executions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_run_executions_delete BEFORE DELETE ON workflow_run_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_run_executions_delete AFTER DELETE ON workflow_run_executions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_stage_executions_insert BEFORE INSERT ON workflow_stage_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_stage_executions_insert AFTER INSERT ON workflow_stage_executions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_stage_executions_update BEFORE UPDATE ON workflow_stage_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_stage_executions_update AFTER UPDATE ON workflow_stage_executions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_stage_executions_delete BEFORE DELETE ON workflow_stage_executions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_stage_executions_delete AFTER DELETE ON workflow_stage_executions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_run_events_insert BEFORE INSERT ON workflow_run_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_run_events_insert AFTER INSERT ON workflow_run_events
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_run_events_update BEFORE UPDATE ON workflow_run_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_run_events_update AFTER UPDATE ON workflow_run_events
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_workflow_run_events_delete BEFORE DELETE ON workflow_run_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_workflow_run_events_delete AFTER DELETE ON workflow_run_events
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_dependencies_insert BEFORE INSERT ON work_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_dependencies_insert AFTER INSERT ON work_dependencies
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_dependencies_update BEFORE UPDATE ON work_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_dependencies_update AFTER UPDATE ON work_dependencies
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_dependencies_delete BEFORE DELETE ON work_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_dependencies_delete AFTER DELETE ON work_dependencies
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_input_receipts_insert BEFORE INSERT ON work_input_receipts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_input_receipts_insert AFTER INSERT ON work_input_receipts
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_input_receipts_update BEFORE UPDATE ON work_input_receipts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_input_receipts_update AFTER UPDATE ON work_input_receipts
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_input_receipts_delete BEFORE DELETE ON work_input_receipts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_input_receipts_delete AFTER DELETE ON work_input_receipts
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_scope_decisions_insert BEFORE INSERT ON work_scope_decisions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_scope_decisions_insert AFTER INSERT ON work_scope_decisions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_scope_decisions_update BEFORE UPDATE ON work_scope_decisions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_scope_decisions_update AFTER UPDATE ON work_scope_decisions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_scope_decisions_delete BEFORE DELETE ON work_scope_decisions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_scope_decisions_delete AFTER DELETE ON work_scope_decisions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_chain_completions_insert BEFORE INSERT ON work_chain_completions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_chain_completions_insert AFTER INSERT ON work_chain_completions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_chain_completions_update BEFORE UPDATE ON work_chain_completions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_chain_completions_update AFTER UPDATE ON work_chain_completions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_work_chain_completions_delete BEFORE DELETE ON work_chain_completions
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_work_chain_completions_delete AFTER DELETE ON work_chain_completions
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_chat_conversations_insert BEFORE INSERT ON chat_conversations
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_chat_conversations_insert AFTER INSERT ON chat_conversations
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_chat_conversations_update BEFORE UPDATE ON chat_conversations
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=NEW.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_chat_conversations_update AFTER UPDATE ON chat_conversations
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=NEW.chain_id; END;
CREATE TRIGGER owner_legacy_guard_chat_conversations_delete BEFORE DELETE ON chat_conversations
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_chat_conversations_delete AFTER DELETE ON chat_conversations
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_comments_insert BEFORE INSERT ON task_comments
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_comments_insert AFTER INSERT ON task_comments
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_comments_update BEFORE UPDATE ON task_comments
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_comments_update AFTER UPDATE ON task_comments
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_comments_delete BEFORE DELETE ON task_comments
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_comments_delete AFTER DELETE ON task_comments
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_dependencies_insert BEFORE INSERT ON task_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id) OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.depends_on_task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_dependencies_insert AFTER INSERT ON task_dependencies
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id) OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.depends_on_task_id); END;
CREATE TRIGGER owner_legacy_guard_task_dependencies_update BEFORE UPDATE ON task_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.depends_on_task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id) OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.depends_on_task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_dependencies_update AFTER UPDATE ON task_dependencies
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.depends_on_task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id) OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.depends_on_task_id); END;
CREATE TRIGGER owner_legacy_guard_task_dependencies_delete BEFORE DELETE ON task_dependencies
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.depends_on_task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_dependencies_delete AFTER DELETE ON task_dependencies
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.depends_on_task_id); END;
CREATE TRIGGER owner_legacy_guard_task_events_insert BEFORE INSERT ON task_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_events_insert AFTER INSERT ON task_events
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_events_update BEFORE UPDATE ON task_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_events_update AFTER UPDATE ON task_events
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_events_delete BEFORE DELETE ON task_events
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_events_delete AFTER DELETE ON task_events
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_attempts_insert BEFORE INSERT ON task_attempts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_attempts_insert AFTER INSERT ON task_attempts
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_attempts_update BEFORE UPDATE ON task_attempts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_attempts_update AFTER UPDATE ON task_attempts
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_attempts_delete BEFORE DELETE ON task_attempts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_attempts_delete AFTER DELETE ON task_attempts
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_attempt_facets_insert BEFORE INSERT ON task_attempt_facets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_attempt_facets_insert AFTER INSERT ON task_attempt_facets
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_attempt_facets_update BEFORE UPDATE ON task_attempt_facets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_attempt_facets_update AFTER UPDATE ON task_attempt_facets
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_attempt_facets_delete BEFORE DELETE ON task_attempt_facets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_attempt_facets_delete AFTER DELETE ON task_attempt_facets
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_leases_insert BEFORE INSERT ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_leases_insert AFTER INSERT ON task_leases
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_leases_update BEFORE UPDATE ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_leases_update AFTER UPDATE ON task_leases
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_leases_delete BEFORE DELETE ON task_leases
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_leases_delete AFTER DELETE ON task_leases
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_reviews_insert BEFORE INSERT ON task_reviews
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_reviews_insert AFTER INSERT ON task_reviews
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_reviews_update BEFORE UPDATE ON task_reviews
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_reviews_update AFTER UPDATE ON task_reviews
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_reviews_delete BEFORE DELETE ON task_reviews
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_reviews_delete AFTER DELETE ON task_reviews
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id); END;
CREATE TRIGGER owner_legacy_guard_artifacts_insert BEFORE INSERT ON artifacts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_artifacts_insert AFTER INSERT ON artifacts
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_artifacts_update BEFORE UPDATE ON artifacts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR m.chain_id=NEW.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_artifacts_update AFTER UPDATE ON artifacts
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id) OR chain_id=NEW.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=NEW.task_id); END;
CREATE TRIGGER owner_legacy_guard_artifacts_delete BEFORE DELETE ON artifacts
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.chain_id OR m.chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_artifacts_delete AFTER DELETE ON artifacts
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.chain_id OR chain_id=(SELECT chain_id FROM tasks WHERE task_id=OLD.task_id); END;
CREATE TRIGGER owner_legacy_guard_task_chain_fleets_insert BEFORE INSERT ON task_chain_fleets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=NEW.task_chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chain_fleets_insert AFTER INSERT ON task_chain_fleets
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=NEW.task_chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chain_fleets_update BEFORE UPDATE ON task_chain_fleets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.task_chain_id OR m.chain_id=NEW.task_chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chain_fleets_update AFTER UPDATE ON task_chain_fleets
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.task_chain_id OR chain_id=NEW.task_chain_id; END;
CREATE TRIGGER owner_legacy_guard_task_chain_fleets_delete BEFORE DELETE ON task_chain_fleets
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=OLD.task_chain_id))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_task_chain_fleets_delete AFTER DELETE ON task_chain_fleets
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=OLD.task_chain_id; END;
CREATE TRIGGER owner_legacy_guard_chat_messages_insert BEFORE INSERT ON chat_messages
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=NEW.conversation_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_chat_messages_insert AFTER INSERT ON chat_messages
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=NEW.conversation_id); END;
CREATE TRIGGER owner_legacy_guard_chat_messages_update BEFORE UPDATE ON chat_messages
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=OLD.conversation_id) OR m.chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=NEW.conversation_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_chat_messages_update AFTER UPDATE ON chat_messages
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=OLD.conversation_id) OR chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=NEW.conversation_id); END;
CREATE TRIGGER owner_legacy_guard_chat_messages_delete BEFORE DELETE ON chat_messages
WHEN EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.state='frozen' AND (m.chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=OLD.conversation_id)))
BEGIN SELECT RAISE(ABORT,'legacy canonical source is frozen'); END;
CREATE TRIGGER owner_legacy_generation_chat_messages_delete AFTER DELETE ON chat_messages
BEGIN UPDATE owner_legacy_source_generations SET generation=generation+1 WHERE chain_id=(SELECT chain_id FROM chat_conversations WHERE conversation_id=OLD.conversation_id); END;
-- The marker shares the schema transaction: a crash after COMMIT cannot make
-- startup attempt to recreate a half-acknowledged fencing schema.
INSERT INTO schema_migrations(version) VALUES('204_owner_legacy_source_fences.sql');
COMMIT;
