-- Owner-local store schema (flat). The store has no upgrade path: migrate()
-- creates this schema on a new database and refuses any other version.
-- Change it in place and bump SCHEMA_VERSION (migrations.odin) together with
-- runtime_database.schema_version below.

CREATE TABLE IF NOT EXISTS task_chains (
 chain_id TEXT PRIMARY KEY, creator TEXT NOT NULL, creator_key TEXT NOT NULL,
 title TEXT NOT NULL, description TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0)
);
CREATE TABLE IF NOT EXISTS chain_genesis (
 chain_id TEXT PRIMARY KEY REFERENCES task_chains(chain_id),
 creation_op TEXT NOT NULL UNIQUE, genesis_digest TEXT NOT NULL, genesis_json TEXT NOT NULL
, import_manifest_hash TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS local_grants (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), principal_id TEXT NOT NULL,
 key_id TEXT NOT NULL, revision INTEGER NOT NULL, expires_ms INTEGER NOT NULL,
 can_read INTEGER NOT NULL, can_mutate INTEGER NOT NULL, revoked INTEGER NOT NULL,
 PRIMARY KEY(chain_id,principal_id,key_id)
);
CREATE TABLE IF NOT EXISTS tasks (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), task_id TEXT NOT NULL,
 title TEXT NOT NULL, body TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 PRIMARY KEY(chain_id,task_id), UNIQUE(task_id)
);
CREATE TABLE IF NOT EXISTS task_comments (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 principal_id TEXT NOT NULL, body TEXT NOT NULL, seq INTEGER NOT NULL, created_at TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(principal_id,operation_id),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS command_receipts (
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, chain_id TEXT NOT NULL,
 task_id TEXT NOT NULL, method TEXT NOT NULL, input_digest TEXT NOT NULL,
 digest_key_id TEXT NOT NULL, request_expires_ms INTEGER NOT NULL,
 result_json TEXT NOT NULL, commit_seq INTEGER NOT NULL, created_ms INTEGER NOT NULL DEFAULT 0 CHECK(created_ms>=0),
 PRIMARY KEY(principal_id,operation_id)
);
CREATE TABLE IF NOT EXISTS runtime_intents (
 intent_id TEXT PRIMARY KEY, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 commit_seq INTEGER NOT NULL, payload_json TEXT NOT NULL, published INTEGER NOT NULL DEFAULT 0
, principal_id TEXT NOT NULL DEFAULT '', operation_id TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT 'registry', destination_bridge TEXT NOT NULL DEFAULT '', exact_fence_json TEXT NOT NULL DEFAULT '{}', payload_digest TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN('pending','claimed','settled')), attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0), next_retry_ms INTEGER NOT NULL DEFAULT 0 CHECK(next_retry_ms>=0), claim_incarnation INTEGER NOT NULL DEFAULT 0 CHECK(claim_incarnation>=0), result_json TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS local_changes (
 seq INTEGER PRIMARY KEY, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 kind TEXT NOT NULL, object_id TEXT NOT NULL, object_revision INTEGER NOT NULL, operation TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS operation_tombstones (
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 task_id TEXT NOT NULL, method TEXT NOT NULL, input_digest TEXT NOT NULL, digest_key_id TEXT NOT NULL,
 request_expires_ms INTEGER NOT NULL, commit_seq INTEGER NOT NULL CHECK(commit_seq>0),
 PRIMARY KEY(principal_id,operation_id)
);
CREATE TABLE IF NOT EXISTS local_fleet (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, instance_id TEXT NOT NULL,
 configuration_revision INTEGER NOT NULL CHECK(configuration_revision>0),
 enabled INTEGER NOT NULL CHECK(enabled IN(0,1)),
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, configuration_command TEXT NOT NULL, configuration_payload TEXT NOT NULL,
 launch_epoch TEXT NOT NULL, run_count INTEGER NOT NULL CHECK(run_count>0), token_generation TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_leases (
 lease_id TEXT PRIMARY KEY, chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 instance_id TEXT NOT NULL, launch_epoch TEXT NOT NULL, run_count INTEGER NOT NULL CHECK(run_count>0),
 token_generation TEXT NOT NULL, configuration_revision INTEGER NOT NULL CHECK(configuration_revision>0),
 requirements_revision INTEGER NOT NULL CHECK(requirements_revision>0),
 expires_ms INTEGER NOT NULL, hard_ms INTEGER NOT NULL CHECK(expires_ms<=hard_ms),
 deadline_version INTEGER NOT NULL CHECK(deadline_version>0),
 capability_json TEXT NOT NULL, retired_seq INTEGER,
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS lease_receipt_pins (
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, lease_id TEXT NOT NULL REFERENCES local_leases(lease_id),
 PRIMARY KEY(principal_id,operation_id,lease_id),
 FOREIGN KEY(principal_id,operation_id) REFERENCES command_receipts(principal_id,operation_id)
);
CREATE TABLE IF NOT EXISTS lifecycle_configs (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 config_json TEXT NOT NULL, command_json TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 author_child TEXT NOT NULL, reviewer_child TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,revision), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS task_requirements (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 brief_json TEXT NOT NULL, cipher TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,revision), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS requirement_ack (
 lease_id TEXT NOT NULL REFERENCES local_leases(lease_id), revision INTEGER NOT NULL,
 presented INTEGER NOT NULL CHECK(presented=1), acknowledged INTEGER NOT NULL CHECK(acknowledged IN(0,1)),
 PRIMARY KEY(lease_id,revision)
);
CREATE TABLE IF NOT EXISTS local_submissions (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL CHECK(attempt>0),
 lease_id TEXT NOT NULL UNIQUE REFERENCES local_leases(lease_id), author_agent_id TEXT NOT NULL,
 author_child TEXT NOT NULL, requirements_revision INTEGER NOT NULL, configuration_revision INTEGER NOT NULL,
 head TEXT NOT NULL, summary TEXT NOT NULL, requirements_json TEXT NOT NULL,
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,attempt), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS lifecycle_state (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN('ready','in_review','merge_pending','merge_blocked','done')),
 attempt INTEGER NOT NULL DEFAULT 0, merge_receipt TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(chain_id,task_id), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_reviews (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL,
 reviewer_agent_id TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 requirements_revision INTEGER NOT NULL, head TEXT NOT NULL, verdict TEXT NOT NULL CHECK(verdict IN('approve','request_changes')), summary TEXT NOT NULL, principal_kind TEXT NOT NULL DEFAULT 'agent' CHECK(principal_kind IN('device','agent')),
 PRIMARY KEY(chain_id,task_id,attempt,reviewer_agent_id),
 FOREIGN KEY(chain_id,task_id,attempt) REFERENCES local_submissions(chain_id,task_id,attempt)
);
CREATE TABLE IF NOT EXISTS local_merge_preparations(intent_id TEXT PRIMARY KEY REFERENCES runtime_intents(intent_id),payload_digest TEXT NOT NULL,head TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS task_deletions(chain_id TEXT NOT NULL, task_id TEXT PRIMARY KEY, seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS search_docs(
 rowid INTEGER PRIMARY KEY, chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 kind TEXT NOT NULL, object_id TEXT NOT NULL, revision INTEGER NOT NULL,
 title TEXT NOT NULL, body TEXT NOT NULL, UNIQUE(chain_id,kind,object_id)
);
CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(title,body,content='search_docs',content_rowid='rowid',tokenize='unicode61');
CREATE TABLE IF NOT EXISTS local_controls (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 mode TEXT NOT NULL CHECK(mode IN('ready','held','blocked','cancelled')),
 resume_state TEXT NOT NULL, reason TEXT NOT NULL, waiting_on TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_handoffs (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 kind TEXT NOT NULL, lease_id TEXT NOT NULL, summary TEXT NOT NULL, next_steps TEXT NOT NULL,
 waiting_on TEXT NOT NULL, destination_task_id TEXT NOT NULL, seq INTEGER NOT NULL,
 PRIMARY KEY(principal_id,operation_id), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS control_notices (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 child_json TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN('stop','checkpoint')),
 PRIMARY KEY(principal_id,operation_id,child_json),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS intent_invalidations(intent_id TEXT PRIMARY KEY REFERENCES runtime_intents(intent_id),principal_id TEXT NOT NULL,operation_id TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS local_assignment_history (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL,
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 command_json TEXT NOT NULL, payload_json TEXT NOT NULL, child_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,revision),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_work_attempts (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL CHECK(attempt>0),
 lease_id TEXT NOT NULL UNIQUE REFERENCES local_leases(lease_id),
 PRIMARY KEY(chain_id,task_id,attempt), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_checkpoints (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, lease_id TEXT NOT NULL,
 child_json TEXT NOT NULL, capability_json TEXT NOT NULL, expires_ms INTEGER NOT NULL,
 PRIMARY KEY(chain_id,task_id,lease_id,child_json),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_grant_policy (
 chain_id TEXT PRIMARY KEY REFERENCES task_chains(chain_id),
 revision INTEGER NOT NULL CHECK(revision>0),
 recovery_enabled INTEGER NOT NULL CHECK(recovery_enabled IN(0,1))
);
CREATE TABLE IF NOT EXISTS local_grant_audit (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 seq INTEGER PRIMARY KEY, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 command_json TEXT NOT NULL, payload_json TEXT NOT NULL,
 UNIQUE(principal_id,operation_id)
);
CREATE TABLE IF NOT EXISTS local_workflow_definitions(
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), workflow_id TEXT NOT NULL, version INTEGER NOT NULL CHECK(version>0),
 definition_json TEXT NOT NULL, PRIMARY KEY(chain_id,workflow_id,version)
);
CREATE TABLE IF NOT EXISTS local_workflow_runs(
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL, workflow_id TEXT NOT NULL, definition_version INTEGER NOT NULL,
 current_execution INTEGER NOT NULL CHECK(current_execution>0), revision INTEGER NOT NULL CHECK(revision>0),
 PRIMARY KEY(chain_id,run_id), FOREIGN KEY(chain_id,workflow_id,definition_version) REFERENCES local_workflow_definitions(chain_id,workflow_id,version)
);
CREATE TABLE IF NOT EXISTS local_workflow_executions(
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL, execution INTEGER NOT NULL CHECK(execution>0),
 state TEXT NOT NULL CHECK(state IN('running','done','superseded')), PRIMARY KEY(chain_id,run_id,execution),
 FOREIGN KEY(chain_id,run_id) REFERENCES local_workflow_runs(chain_id,run_id)
);
CREATE TABLE IF NOT EXISTS local_workflow_tasks(
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL, execution INTEGER NOT NULL, stage_key TEXT NOT NULL, task_id TEXT NOT NULL UNIQUE,
 PRIMARY KEY(chain_id,run_id,execution,stage_key),
 FOREIGN KEY(chain_id,run_id,execution) REFERENCES local_workflow_executions(chain_id,run_id,execution),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_dependencies(
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, prerequisite TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,prerequisite), CHECK(task_id!=prerequisite),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id), FOREIGN KEY(chain_id,prerequisite) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_workflow_events(
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL, execution INTEGER NOT NULL, event_seq INTEGER NOT NULL UNIQUE,
 kind TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,run_id,event_seq),
 FOREIGN KEY(chain_id,run_id,execution) REFERENCES local_workflow_executions(chain_id,run_id,execution)
);
CREATE TABLE IF NOT EXISTS local_role_configs(
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 requires_user_approval INTEGER NOT NULL CHECK(requires_user_approval IN(0,1)), pairs_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,revision), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_role_pairs(
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL, role TEXT NOT NULL, agent_id TEXT NOT NULL, child_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,revision,role,agent_id),
 FOREIGN KEY(chain_id,task_id,revision) REFERENCES local_role_configs(chain_id,task_id,revision)
);
CREATE TABLE IF NOT EXISTS local_role_reviews(
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL, role_revision INTEGER NOT NULL,
 role TEXT NOT NULL, agent_id TEXT NOT NULL, principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 verdict TEXT NOT NULL CHECK(verdict IN('approve','request_changes')), summary TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,attempt,role,agent_id),
 FOREIGN KEY(chain_id,task_id,attempt) REFERENCES local_submissions(chain_id,task_id,attempt),
 FOREIGN KEY(chain_id,task_id,role_revision,role,agent_id) REFERENCES local_role_pairs(chain_id,task_id,revision,role,agent_id)
);
CREATE TABLE IF NOT EXISTS local_review_sessions(
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, attempt INTEGER NOT NULL, child TEXT NOT NULL, capability_json TEXT NOT NULL, expires_ms INTEGER NOT NULL,
 PRIMARY KEY(chain_id,task_id,attempt,child), FOREIGN KEY(chain_id,task_id,attempt) REFERENCES local_submissions(chain_id,task_id,attempt)
);
CREATE TABLE IF NOT EXISTS source_episodes(
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), origin_kind TEXT NOT NULL, origin_id TEXT NOT NULL, episode_id TEXT NOT NULL,
 source_version INTEGER NOT NULL CHECK(source_version>0), resolved INTEGER NOT NULL CHECK(resolved IN(0,1)),
 ack_floor INTEGER NOT NULL DEFAULT 0 CHECK(ack_floor>=0), retired_floor INTEGER NOT NULL DEFAULT 0 CHECK(retired_floor>=0),
 delivered_floor INTEGER NOT NULL DEFAULT 0 CHECK(delivered_floor>=0), deadline_ms INTEGER NOT NULL CHECK(deadline_ms>=0),
 card_id TEXT NOT NULL DEFAULT '', card_closed INTEGER NOT NULL DEFAULT 0 CHECK(card_closed IN(0,1)),
 body TEXT NOT NULL, PRIMARY KEY(chain_id,origin_kind,origin_id,episode_id),
 CHECK(ack_floor<=source_version AND retired_floor<=source_version AND delivered_floor<=source_version)
);
CREATE TABLE IF NOT EXISTS source_consumptions(
 chain_id TEXT NOT NULL, origin_kind TEXT NOT NULL, origin_id TEXT NOT NULL, episode_id TEXT NOT NULL,
 consumer_fence_hash TEXT NOT NULL, source_version INTEGER NOT NULL CHECK(source_version>0),
 principal_id TEXT NOT NULL, result_operation TEXT NOT NULL, commit_seq INTEGER NOT NULL, result TEXT NOT NULL,
 PRIMARY KEY(chain_id,origin_kind,origin_id,episode_id,consumer_fence_hash,source_version),
 FOREIGN KEY(chain_id,origin_kind,origin_id,episode_id) REFERENCES source_episodes(chain_id,origin_kind,origin_id,episode_id)
);
CREATE TABLE IF NOT EXISTS source_receipt_pins(
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL, chain_id TEXT NOT NULL,
 origin_kind TEXT NOT NULL, origin_id TEXT NOT NULL, episode_id TEXT NOT NULL,
 PRIMARY KEY(principal_id,operation_id,chain_id,origin_kind,origin_id,episode_id),
 FOREIGN KEY(chain_id,origin_kind,origin_id,episode_id) REFERENCES source_episodes(chain_id,origin_kind,origin_id,episode_id)
);
CREATE TABLE IF NOT EXISTS local_chain_context(
 chain_id TEXT PRIMARY KEY REFERENCES task_chains(chain_id),
 algorithm INTEGER NOT NULL, version INTEGER NOT NULL CHECK(version>0),
 source_seq INTEGER NOT NULL, source_digest TEXT NOT NULL,
 source_count INTEGER NOT NULL, body TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS local_workflow_language_runs(
 chain_id TEXT NOT NULL,run_id TEXT NOT NULL,inputs_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,run_id),FOREIGN KEY(chain_id,run_id) REFERENCES local_workflow_runs(chain_id,run_id));
CREATE TABLE IF NOT EXISTS local_workflow_language_executions(
 chain_id TEXT NOT NULL,run_id TEXT NOT NULL,execution INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN('running','done','failed','cancelled')),
 failure TEXT NOT NULL DEFAULT '',principal_id TEXT NOT NULL,operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,run_id,execution),
 FOREIGN KEY(chain_id,run_id,execution) REFERENCES local_workflow_executions(chain_id,run_id,execution));
CREATE TABLE IF NOT EXISTS local_workflow_stage_expansions(
 chain_id TEXT NOT NULL,run_id TEXT NOT NULL,execution INTEGER NOT NULL,stage_key TEXT NOT NULL,
 item_count INTEGER NOT NULL CHECK(item_count BETWEEN 0 AND 256),
 PRIMARY KEY(chain_id,run_id,execution,stage_key),
 FOREIGN KEY(chain_id,run_id,execution) REFERENCES local_workflow_executions(chain_id,run_id,execution));
CREATE TABLE IF NOT EXISTS local_workflow_language_items(
 task_id TEXT PRIMARY KEY REFERENCES local_workflow_tasks(task_id),
 stage_key TEXT NOT NULL,stage_index INTEGER NOT NULL CHECK(stage_index BETWEEN 0 AND 255),
 kind TEXT NOT NULL CHECK(kind IN('task','gate')),priority TEXT NOT NULL,
 max_parallel INTEGER NOT NULL CHECK(max_parallel BETWEEN 0 AND 50),
 requires_user_approval INTEGER NOT NULL CHECK(requires_user_approval IN(0,1)),
 provenance_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS local_workflow_outputs(
 chain_id TEXT NOT NULL,task_id TEXT NOT NULL,attempt INTEGER NOT NULL,output_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,attempt),
 FOREIGN KEY(chain_id,task_id,attempt) REFERENCES local_submissions(chain_id,task_id,attempt));
CREATE TABLE IF NOT EXISTS local_workflow_registry_envelopes(
 intent_id TEXT PRIMARY KEY REFERENCES runtime_intents(intent_id),registry_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS local_workflow_coordinators(
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),revision INTEGER NOT NULL CHECK(revision>0),
 agent_id TEXT NOT NULL,child_json TEXT NOT NULL,capability_json TEXT NOT NULL,principal_id TEXT NOT NULL,operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,revision));
CREATE TABLE IF NOT EXISTS local_workflow_trigger_failures(
 chain_id TEXT NOT NULL,source_task TEXT NOT NULL,source_attempt INTEGER NOT NULL,reason TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_task,source_attempt),
 FOREIGN KEY(chain_id,source_task,source_attempt) REFERENCES local_submissions(chain_id,task_id,attempt));
CREATE TABLE IF NOT EXISTS local_workflow_output_triggers(
 chain_id TEXT NOT NULL,source_task TEXT NOT NULL,source_attempt INTEGER NOT NULL,
 source_run TEXT,source_execution INTEGER,
 target_run TEXT NOT NULL,consumed INTEGER NOT NULL DEFAULT 0 CHECK(consumed IN(0,1)),
 CHECK((source_run IS NULL AND source_execution IS NULL) OR (source_run IS NOT NULL AND source_execution IS NOT NULL)),
 PRIMARY KEY(chain_id,source_task,source_attempt),
 FOREIGN KEY(chain_id,source_task,source_attempt) REFERENCES local_submissions(chain_id,task_id,attempt),
 FOREIGN KEY(chain_id,source_run,source_execution) REFERENCES local_workflow_executions(chain_id,run_id,execution),
 FOREIGN KEY(chain_id,target_run) REFERENCES local_workflow_runs(chain_id,run_id));
CREATE TABLE IF NOT EXISTS local_events (
 seq INTEGER PRIMARY KEY CHECK(seq>0),
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 task_id TEXT NOT NULL,
 ts_ms INTEGER CHECK(ts_ms IS NULL OR (typeof(ts_ms)='integer' AND ts_ms>=0)),
 actor_kind TEXT NOT NULL CHECK(actor_kind IN('device','agent','bridge','unknown')),
 actor_id TEXT NOT NULL, kind TEXT NOT NULL, operation_id TEXT NOT NULL,
 evidence_json TEXT NOT NULL,
 completeness TEXT NOT NULL CHECK(completeness IN('full','legacy_tag'))
);
CREATE TABLE IF NOT EXISTS local_task_retirements (
 seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 run_id TEXT NOT NULL, execution INTEGER NOT NULL CHECK(execution>0),
 lease_id TEXT NOT NULL,
 reason TEXT NOT NULL CHECK(reason='chain_closed'),
 cause TEXT NOT NULL CHECK(cause IN('workflow.retry','workflow.cancel','workflow.gate','workflow.failed')),
 PRIMARY KEY(seq,chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS native_history_records (
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
CREATE TABLE IF NOT EXISTS deferred_workflow_retirements (
 intent_id TEXT PRIMARY KEY REFERENCES runtime_intents(intent_id),
 requested_seq INTEGER REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, run_id TEXT NOT NULL, execution TEXT NOT NULL,
 cause TEXT NOT NULL CHECK(cause IN('workflow.failed','workflow.gate','workflow.cancel','workflow.retry','unknown')),
 source_completeness TEXT NOT NULL CHECK(source_completeness IN('full','incomplete')),
 CHECK((requested_seq IS NULL AND cause='unknown' AND source_completeness='incomplete') OR
   (requested_seq IS NOT NULL AND cause!='unknown' AND source_completeness='full'))
);
CREATE TABLE IF NOT EXISTS deferred_workflow_dispositions (
 intent_id TEXT PRIMARY KEY REFERENCES deferred_workflow_retirements(intent_id),
 settled_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 disposition TEXT NOT NULL CHECK(disposition='preserved_terminal'),
 head TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS local_dependency_retirements (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, seq INTEGER NOT NULL,
 lease_id TEXT NOT NULL REFERENCES local_leases(lease_id),
 PRIMARY KEY(chain_id,task_id,seq),
 FOREIGN KEY(seq) REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS local_fleet_policy_versions (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 agent_id TEXT NOT NULL, seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 provider_profile TEXT NOT NULL, capacity INTEGER NOT NULL CHECK(typeof(capacity)='integer' AND capacity>=1),
 min_warm INTEGER NOT NULL CHECK(typeof(min_warm)='integer' AND min_warm>=0),
 idle_ttl_seconds INTEGER NOT NULL CHECK(typeof(idle_ttl_seconds)='integer' AND idle_ttl_seconds>=0),
 bridge_models_json TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
 roles_json TEXT NOT NULL, bridge_id TEXT NOT NULL, paused_roles_json TEXT NOT NULL,
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,agent_id,seq)
);
CREATE TABLE IF NOT EXISTS local_fleet_policy_roles (
 chain_id TEXT NOT NULL, agent_id TEXT NOT NULL, seq INTEGER NOT NULL,
 role TEXT NOT NULL, paused INTEGER NOT NULL CHECK(paused IN(0,1)),
 PRIMARY KEY(chain_id,agent_id,seq,role,paused),
 FOREIGN KEY(chain_id,agent_id,seq) REFERENCES local_fleet_policy_versions(chain_id,agent_id,seq)
);
CREATE TABLE IF NOT EXISTS local_fleet_policy_models (
 chain_id TEXT NOT NULL, agent_id TEXT NOT NULL, seq INTEGER NOT NULL,
 bridge_id TEXT NOT NULL, provider_profile TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
 PRIMARY KEY(chain_id,agent_id,seq,bridge_id),
 FOREIGN KEY(chain_id,agent_id,seq) REFERENCES local_fleet_policy_versions(chain_id,agent_id,seq)
);
CREATE TABLE IF NOT EXISTS native_metadata_origins (
 chain_id TEXT PRIMARY KEY REFERENCES task_chains(chain_id),
 owner_user_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(chain_id,owner_user_id)
);
CREATE TABLE IF NOT EXISTS native_metadata_snapshots (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN('member','directory')),
 owner_user_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 record_count INTEGER NOT NULL CHECK(record_count>=0 AND record_count<=100),
 content_digest TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,kind),
 UNIQUE(chain_id,source_revision,kind,owner_user_id),
 FOREIGN KEY(chain_id,owner_user_id) REFERENCES native_metadata_origins(chain_id,owner_user_id)
);
CREATE TABLE IF NOT EXISTS native_metadata_members (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'member' CHECK(kind='member'),
 agent_instance_id TEXT NOT NULL, agent_id TEXT NOT NULL, owner_user_id TEXT NOT NULL,
 role TEXT NOT NULL, created_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,agent_instance_id),
 FOREIGN KEY(chain_id,source_revision,kind,owner_user_id) REFERENCES native_metadata_snapshots(chain_id,source_revision,kind,owner_user_id)
);
CREATE TABLE IF NOT EXISTS native_metadata_directories (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'directory' CHECK(kind='directory'),
 directory_id TEXT NOT NULL, owner_user_id TEXT NOT NULL, path TEXT NOT NULL, bridge_id TEXT NOT NULL,
 vcs_kind TEXT NOT NULL, vcs_info_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,directory_id),
 FOREIGN KEY(chain_id,source_revision,kind,owner_user_id) REFERENCES native_metadata_snapshots(chain_id,source_revision,kind,owner_user_id)
);
CREATE TABLE IF NOT EXISTS native_fact_snapshots (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN('chain','task','comment','summary')),
 owner_user_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 record_count INTEGER NOT NULL CHECK(record_count>=0 AND record_count<=100), content_digest TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,kind),
 UNIQUE(chain_id,source_revision,kind,owner_user_id),
 FOREIGN KEY(chain_id,owner_user_id) REFERENCES native_metadata_origins(chain_id,owner_user_id)
);
CREATE TABLE IF NOT EXISTS native_fact_chain (
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
CREATE TABLE IF NOT EXISTS native_fact_task (
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
CREATE TABLE IF NOT EXISTS native_fact_comment (
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
CREATE TABLE IF NOT EXISTS native_fact_summary (
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
CREATE TABLE IF NOT EXISTS local_task_priority_versions (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), task_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 priority TEXT NOT NULL CHECK(priority IN ('p0','p1','p2')),
 PRIMARY KEY(chain_id,task_id,accepted_seq)
);
CREATE TABLE IF NOT EXISTS native_fleet_snapshots (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind='fleet'),
 owner_user_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 record_count INTEGER NOT NULL CHECK(record_count>=0 AND record_count<=100), content_digest TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,kind), UNIQUE(chain_id,source_revision),
 FOREIGN KEY(chain_id,owner_user_id) REFERENCES native_metadata_origins(chain_id,owner_user_id)
);
CREATE TABLE IF NOT EXISTS native_fleet_policies (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, agent_id TEXT NOT NULL,
 provider_profile TEXT NOT NULL, capacity INTEGER NOT NULL CHECK(capacity>0),
 min_warm INTEGER NOT NULL CHECK(min_warm>=0), idle_ttl_seconds INTEGER NOT NULL CHECK(idle_ttl_seconds>=0),
 bridge_models_json TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, roles_json TEXT NOT NULL,
 bridge_id TEXT NOT NULL, paused_roles_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,agent_id),
 FOREIGN KEY(chain_id,source_revision) REFERENCES native_fleet_snapshots(chain_id,source_revision)
);
CREATE TABLE IF NOT EXISTS local_fleet_policy_sources (
 chain_id TEXT NOT NULL, agent_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL, source_revision TEXT NOT NULL,
 PRIMARY KEY(chain_id,agent_id,accepted_seq),
 FOREIGN KEY(chain_id,agent_id,accepted_seq) REFERENCES local_fleet_policy_versions(chain_id,agent_id,seq),
 FOREIGN KEY(chain_id,source_revision,agent_id) REFERENCES native_fleet_policies(chain_id,source_revision,agent_id)
);
CREATE TABLE IF NOT EXISTS local_chain_summary_versions (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 curated_body TEXT NOT NULL,
 PRIMARY KEY(chain_id,accepted_seq)
);
CREATE TABLE IF NOT EXISTS local_chain_defaults_versions (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 defaults_json TEXT NOT NULL CHECK(json_valid(defaults_json) AND json_type(defaults_json)='object'),
 PRIMARY KEY(chain_id,accepted_seq)
);
CREATE TABLE IF NOT EXISTS local_chain_member_versions (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 instance_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 agent_id TEXT NOT NULL, role TEXT NOT NULL CHECK(length(role)>0 AND length(role)<=160),
 enabled INTEGER NOT NULL CHECK(enabled IN (0,1)), child_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,instance_id,accepted_seq)
);
CREATE TABLE IF NOT EXISTS local_member_chains (
 instance_id TEXT PRIMARY KEY, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id)
);
CREATE TABLE IF NOT EXISTS local_chain_directory_versions (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 directory_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 enabled INTEGER NOT NULL CHECK(enabled IN (0,1)), body TEXT NOT NULL,
 PRIMARY KEY(chain_id,directory_id,accepted_seq)
);
CREATE TABLE IF NOT EXISTS local_config_revocations (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, revision INTEGER NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,task_id,revision),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_coordinator_revocations (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), revision INTEGER NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,revision)
);
CREATE TABLE IF NOT EXISTS local_brief_inputs (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, requirements_revision INTEGER NOT NULL,
 inputs_json TEXT NOT NULL CHECK(json_valid(inputs_json) AND json_type(inputs_json)='array'),
 PRIMARY KEY(chain_id,task_id,requirements_revision),
 FOREIGN KEY(chain_id,task_id,requirements_revision) REFERENCES task_requirements(chain_id,task_id,revision)
);
CREATE TABLE IF NOT EXISTS local_metadata_retirements (
 seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, lease_id TEXT NOT NULL,
 cause TEXT NOT NULL CHECK(cause IN ('chain.member.set','chain.directory.set')),
 PRIMARY KEY(seq,chain_id,task_id),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_work_chains (
 chain_id TEXT PRIMARY KEY REFERENCES task_chains(chain_id),
 publish_state TEXT NOT NULL DEFAULT 'published' CHECK(publish_state IN ('draft','published')),
 status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','completed')),
 work_revision INTEGER NOT NULL DEFAULT 0 CHECK(work_revision>=0)
);
CREATE TABLE IF NOT EXISTS local_task_publications (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 publish_state TEXT NOT NULL CHECK(publish_state IN ('draft','published')),
 PRIMARY KEY(chain_id,task_id,accepted_seq),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_work_proposals (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), proposal_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 proposal_json TEXT NOT NULL, created_at TEXT NOT NULL,
 actor_kind TEXT NOT NULL, actor_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,proposal_id)
);
CREATE TABLE IF NOT EXISTS local_work_decisions (
 chain_id TEXT NOT NULL, proposal_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 decision TEXT NOT NULL CHECK(decision IN ('approve','reject')), note TEXT NOT NULL,
 result_json TEXT NOT NULL, decided_at TEXT NOT NULL, actor_kind TEXT NOT NULL, actor_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,proposal_id),
 FOREIGN KEY(chain_id,proposal_id) REFERENCES local_work_proposals(chain_id,proposal_id)
);
CREATE TABLE IF NOT EXISTS local_work_dependencies (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), dependency_id TEXT NOT NULL,
 dependent_kind TEXT NOT NULL CHECK(dependent_kind IN ('task','workflow_run')), dependent_id TEXT NOT NULL,
 prerequisite_kind TEXT NOT NULL CHECK(prerequisite_kind IN ('task','workflow_run')), prerequisite_id TEXT NOT NULL,
 created_at TEXT NOT NULL, created_by_kind TEXT NOT NULL, created_by_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,dependency_id)
);
CREATE TABLE IF NOT EXISTS local_work_dependency_removals (
 chain_id TEXT NOT NULL, dependency_id TEXT NOT NULL,
 removed_at TEXT NOT NULL, removed_by_kind TEXT NOT NULL, removed_by_id TEXT NOT NULL, reason TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,dependency_id),
 FOREIGN KEY(chain_id,dependency_id) REFERENCES local_work_dependencies(chain_id,dependency_id)
);
CREATE TABLE IF NOT EXISTS local_work_inputs (
 receipt_id TEXT PRIMARY KEY, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 dependent_kind TEXT NOT NULL, dependent_id TEXT NOT NULL, dependent_generation INTEGER NOT NULL CHECK(dependent_generation>0),
 prerequisite_kind TEXT NOT NULL, prerequisite_id TEXT NOT NULL, prerequisite_generation INTEGER NOT NULL CHECK(prerequisite_generation>0),
 output_manifest_json TEXT NOT NULL, created_at TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 UNIQUE(chain_id,dependent_kind,dependent_id,dependent_generation,prerequisite_kind,prerequisite_id)
);
CREATE TABLE IF NOT EXISTS local_work_scope (
 decision_id INTEGER PRIMARY KEY, chain_id TEXT NOT NULL REFERENCES task_chains(chain_id),
 item_kind TEXT NOT NULL CHECK(item_kind IN ('task','workflow_run')), item_id TEXT NOT NULL,
 action TEXT NOT NULL CHECK(action IN ('include','exclude')), reason TEXT NOT NULL,
 actor_kind TEXT NOT NULL, actor_id TEXT NOT NULL, created_at TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS local_work_completions (
 chain_id TEXT PRIMARY KEY REFERENCES task_chains(chain_id), work_revision INTEGER NOT NULL,
 summary TEXT NOT NULL, completed_at TEXT NOT NULL, actor_kind TEXT NOT NULL, actor_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE IF NOT EXISTS local_work_pending_runs (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), run_id TEXT NOT NULL,
 run_json TEXT NOT NULL, created_at TEXT NOT NULL, actor_kind TEXT NOT NULL, actor_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,run_id)
);
CREATE TABLE IF NOT EXISTS local_work_run_starts (
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 started_at TEXT NOT NULL,
 PRIMARY KEY(chain_id,run_id),
 FOREIGN KEY(chain_id,run_id) REFERENCES local_work_pending_runs(chain_id,run_id)
);
CREATE TABLE IF NOT EXISTS local_work_run_publications (
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,run_id),
 FOREIGN KEY(chain_id,run_id) REFERENCES local_work_pending_runs(chain_id,run_id)
);
CREATE TABLE IF NOT EXISTS local_work_materialized_tasks (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 proposal_id TEXT NOT NULL, spec_json TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,accepted_seq),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS native_work_snapshots (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('work_dependency','work_receipt','work_scope','work_run','work_execution','work_stage','work_event')),
 owner_user_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 record_count INTEGER NOT NULL CHECK(record_count>=0 AND record_count<=100), content_digest TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,kind),
 FOREIGN KEY(chain_id,owner_user_id) REFERENCES native_metadata_origins(chain_id,owner_user_id)
);
CREATE TABLE IF NOT EXISTS native_work_records (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL, record_key TEXT NOT NULL,
 record_json TEXT NOT NULL CHECK(json_valid(record_json)),
 PRIMARY KEY(chain_id,source_revision,kind,record_key),
 FOREIGN KEY(chain_id,source_revision,kind) REFERENCES native_work_snapshots(chain_id,source_revision,kind)
);
CREATE TABLE IF NOT EXISTS local_work_run_cancellations (
 chain_id TEXT NOT NULL, run_id TEXT NOT NULL, reason TEXT NOT NULL,
 accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,run_id),
 FOREIGN KEY(chain_id,run_id) REFERENCES local_work_pending_runs(chain_id,run_id)
);
CREATE TABLE IF NOT EXISTS native_record_snapshots (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('lease','review','definition','dependency')),
 owner_user_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 record_count INTEGER NOT NULL CHECK(record_count>=0 AND record_count<=100), content_digest TEXT NOT NULL,
 PRIMARY KEY(chain_id,source_revision,kind),
 FOREIGN KEY(chain_id,owner_user_id) REFERENCES native_metadata_origins(chain_id,owner_user_id)
);
CREATE TABLE IF NOT EXISTS native_record_values (
 chain_id TEXT NOT NULL, source_revision TEXT NOT NULL, kind TEXT NOT NULL, record_key TEXT NOT NULL,
 record_json TEXT NOT NULL CHECK(json_valid(record_json)),
 PRIMARY KEY(chain_id,source_revision,kind,record_key),
 FOREIGN KEY(chain_id,source_revision,kind) REFERENCES native_record_snapshots(chain_id,source_revision,kind)
);
CREATE TABLE IF NOT EXISTS linked_identities (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), kind TEXT NOT NULL CHECK(kind IN ('message','artifact','blob')),
 object_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 task_id TEXT NOT NULL, accepted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,kind,object_id,revision)
);
CREATE TABLE IF NOT EXISTS linked_bodies (
 chain_id TEXT NOT NULL, kind TEXT NOT NULL, object_id TEXT NOT NULL, revision INTEGER NOT NULL,
 record_json TEXT NOT NULL CHECK(json_valid(record_json)), vault_id TEXT NOT NULL, key_epoch INTEGER NOT NULL CHECK(key_epoch>0),
 prose TEXT NOT NULL,
 PRIMARY KEY(chain_id,kind,object_id,revision),
 FOREIGN KEY(chain_id,kind,object_id,revision) REFERENCES linked_identities(chain_id,kind,object_id,revision)
);
CREATE TABLE IF NOT EXISTS linked_tombstones (
 chain_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('message','artifact','blob')), object_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0),
 deleted_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 PRIMARY KEY(chain_id,kind,object_id,revision),
 FOREIGN KEY(chain_id) REFERENCES task_chains(chain_id),
 FOREIGN KEY(chain_id,kind,object_id,revision) REFERENCES linked_identities(chain_id,kind,object_id,revision)
);
CREATE TABLE IF NOT EXISTS linked_references (
 chain_id TEXT NOT NULL, source_kind TEXT NOT NULL, source_id TEXT NOT NULL, source_revision INTEGER NOT NULL,
 target_kind TEXT NOT NULL, target_id TEXT NOT NULL, target_revision INTEGER NOT NULL,
 PRIMARY KEY(chain_id,source_kind,source_id,source_revision,target_kind,target_id,target_revision),
 FOREIGN KEY(chain_id,source_kind,source_id,source_revision) REFERENCES linked_bodies(chain_id,kind,object_id,revision),
 FOREIGN KEY(chain_id,target_kind,target_id,target_revision) REFERENCES linked_identities(chain_id,kind,object_id,revision)
);
CREATE TABLE IF NOT EXISTS owner_execution_journal (
 reservation_id TEXT PRIMARY KEY,
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL,
 instance_id TEXT NOT NULL, lease_id TEXT NOT NULL UNIQUE,
 operation_id TEXT NOT NULL,
 prepare_digest TEXT NOT NULL, lease_digest TEXT NOT NULL,
 prepare_json TEXT NOT NULL CHECK(json_valid(prepare_json)), lease_command TEXT NOT NULL CHECK(json_valid(lease_command)), child_json TEXT NOT NULL CHECK(json_valid(child_json)),
 prepare_seq INTEGER NOT NULL REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 prepare_until_ms INTEGER NOT NULL CHECK(prepare_until_ms>0), owner_incarnation INTEGER NOT NULL CHECK(owner_incarnation>0),
 state TEXT NOT NULL CHECK(state IN ('preparing','committed','retired')),
 receipt_json TEXT NOT NULL DEFAULT '', activation_json TEXT NOT NULL DEFAULT '',
 grant_seq INTEGER REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 retired_seq INTEGER REFERENCES local_events(seq) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id),
 UNIQUE(instance_id,operation_id),
 CHECK((state='preparing' AND grant_seq IS NULL AND retired_seq IS NULL) OR
       (state='committed' AND grant_seq IS NOT NULL AND grant_seq>prepare_seq AND retired_seq IS NULL AND json_valid(receipt_json) AND json_valid(activation_json)) OR
       (state='retired' AND retired_seq IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS owner_execution_queries (
 reservation_id TEXT PRIMARY KEY REFERENCES owner_execution_journal(reservation_id),
 prepare_receipt TEXT NOT NULL CHECK(json_valid(prepare_receipt)),
 query_json TEXT NOT NULL CHECK(json_valid(query_json))
);
CREATE TABLE IF NOT EXISTS owner_execution_bootstraps (
 reservation_id TEXT PRIMARY KEY REFERENCES owner_execution_journal(reservation_id),
 document TEXT NOT NULL CHECK(json_valid(document)), body TEXT NOT NULL,
 input_digest TEXT NOT NULL, body_digest TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS owner_execution_stop_steps (
 intent_id TEXT NOT NULL REFERENCES runtime_intents(intent_id), step INTEGER NOT NULL CHECK(step>0),
 phase TEXT NOT NULL CHECK(phase IN ('query','stop')),
 request TEXT NOT NULL CHECK(json_valid(request)), receipt TEXT NOT NULL DEFAULT '',
 outcome TEXT NOT NULL DEFAULT 'pending' CHECK(outcome IN ('pending','accepted','released')),
 PRIMARY KEY(intent_id,step)
);
CREATE TABLE IF NOT EXISTS migration_imports (
 migration_id TEXT NOT NULL, manifest_digest TEXT NOT NULL CHECK(length(manifest_digest)=64),
 chain_id TEXT NOT NULL UNIQUE REFERENCES task_chains(chain_id),
 selection_digest TEXT NOT NULL CHECK(length(selection_digest)=64),
 principal_id TEXT NOT NULL, key_id TEXT NOT NULL,
 import_seq INTEGER NOT NULL CHECK(import_seq>0),
 manifest_json TEXT NOT NULL, receipt_json TEXT NOT NULL, summary_json TEXT NOT NULL,
 activated_seq INTEGER CHECK(activated_seq IS NULL OR activated_seq>import_seq),
 PRIMARY KEY(migration_id,manifest_digest), UNIQUE(migration_id)
);
CREATE TABLE IF NOT EXISTS migration_import_documents (
 migration_id TEXT NOT NULL REFERENCES migration_imports(migration_id),
 doc_index INTEGER NOT NULL CHECK(doc_index>=0), kind TEXT NOT NULL,
 row_count INTEGER NOT NULL CHECK(row_count>0), sha256 TEXT NOT NULL CHECK(length(sha256)=64),
 body TEXT NOT NULL,
 PRIMARY KEY(migration_id,doc_index)
);
CREATE TABLE IF NOT EXISTS migration_archived_tasks (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, run_id TEXT NOT NULL, stage_key TEXT NOT NULL, kind TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id), FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS migration_abandoned (
 migration_id TEXT PRIMARY KEY REFERENCES migration_imports(migration_id)
);
CREATE TABLE IF NOT EXISTS migration_discarded (
 migration_id TEXT PRIMARY KEY, chain_id TEXT NOT NULL, manifest_digest TEXT NOT NULL,
 replaced_by TEXT NOT NULL, discarded_seq INTEGER NOT NULL CHECK(discarded_seq>0)
);
CREATE TABLE IF NOT EXISTS migration_discarding (
 chain_id TEXT PRIMARY KEY, migration_id TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS local_chain_policies (
 chain_id TEXT NOT NULL REFERENCES task_chains(chain_id), policy TEXT NOT NULL CHECK(policy IN('coordinator_force_done')),
 value TEXT NOT NULL CHECK(value IN('0','1')), accepted_seq INTEGER NOT NULL,
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,policy,accepted_seq)
);
CREATE TABLE IF NOT EXISTS local_task_links (
 chain_id TEXT NOT NULL, task_id TEXT NOT NULL, relation TEXT NOT NULL CHECK(relation IN('split_from','split_into')),
 other_task_id TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0), accepted_seq INTEGER NOT NULL,
 principal_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 PRIMARY KEY(chain_id,task_id,relation,other_task_id),
 FOREIGN KEY(chain_id,task_id) REFERENCES tasks(chain_id,task_id),
 FOREIGN KEY(chain_id,other_task_id) REFERENCES tasks(chain_id,task_id)
);
CREATE TABLE IF NOT EXISTS local_review_role_migrations (
 chain_id TEXT NOT NULL, subject TEXT NOT NULL CHECK(subject IN('requirements','workflow_definition','proposal')),
 subject_id TEXT NOT NULL, revision INTEGER NOT NULL, role TEXT NOT NULL, agent_id TEXT NOT NULL,
 source TEXT NOT NULL CHECK(source IN('task_role_pairs','fleet_role','user_approval','role_config_user_approval')),
 PRIMARY KEY(chain_id,subject,subject_id,revision,role,agent_id)
);
CREATE TABLE IF NOT EXISTS local_chain_title_state (
 chain_id TEXT PRIMARY KEY,
 title_source TEXT NOT NULL CHECK(title_source IN('default','agent','user')),
 last_activity_ms INTEGER NOT NULL DEFAULT 0,
 last_title_nudge_ms INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS runtime_database (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), account_id TEXT NOT NULL,
 owner_bridge_id TEXT NOT NULL, owner_key_id TEXT NOT NULL,
 incarnation INTEGER NOT NULL DEFAULT 0, commit_seq INTEGER NOT NULL DEFAULT 0,
 clock_high_ms INTEGER NOT NULL DEFAULT 0, directory_version INTEGER NOT NULL DEFAULT 0,
 directory_hash TEXT NOT NULL DEFAULT '', database_id TEXT NOT NULL DEFAULT '',
 schema_version INTEGER NOT NULL DEFAULT 38 CHECK(schema_version=38),
 clock_generation INTEGER NOT NULL DEFAULT 1 CHECK(clock_generation>0),
 recovery_state TEXT NOT NULL DEFAULT 'ready' CHECK(recovery_state IN ('ready','clock_uncertain','recovery_required'))
);
CREATE VIEW IF NOT EXISTS local_fleet_policy_current AS
 SELECT v.* FROM local_fleet_policy_versions v WHERE v.seq=(
 SELECT max(h.seq) FROM local_fleet_policy_versions h WHERE h.chain_id=v.chain_id AND h.agent_id=v.agent_id);
CREATE VIEW IF NOT EXISTS local_work_active_dependencies AS SELECT d.* FROM local_work_dependencies d
WHERE NOT EXISTS(SELECT 1 FROM local_work_dependency_removals r WHERE r.chain_id=d.chain_id AND r.dependency_id=d.dependency_id);
CREATE INDEX IF NOT EXISTS runtime_intents_due ON runtime_intents(state,next_retry_ms,commit_seq);
CREATE INDEX IF NOT EXISTS runtime_intents_receipt ON runtime_intents(principal_id,operation_id,state);
CREATE UNIQUE INDEX IF NOT EXISTS runtime_intents_target ON runtime_intents(principal_id,operation_id,kind,destination_bridge);
CREATE UNIQUE INDEX IF NOT EXISTS local_lease_holder ON local_leases(instance_id) WHERE retired_seq IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS local_lease_task ON local_leases(task_id) WHERE retired_seq IS NULL;
CREATE INDEX IF NOT EXISTS local_lease_expiry ON local_leases(expires_ms) WHERE retired_seq IS NULL;
CREATE INDEX IF NOT EXISTS search_scope ON search_docs(chain_id,task_id);
CREATE INDEX IF NOT EXISTS local_review_holder ON local_review_sessions(json_extract(child,'$.instance'));
CREATE INDEX IF NOT EXISTS source_recovery_inventory ON source_episodes(chain_id,origin_kind,origin_id,episode_id) WHERE resolved=0 OR (card_id!='' AND card_closed=0);
CREATE INDEX IF NOT EXISTS local_events_chain_seq ON local_events(chain_id,seq);
CREATE INDEX IF NOT EXISTS local_task_retirements_task ON local_task_retirements(chain_id,task_id,seq);
CREATE INDEX IF NOT EXISTS native_history_inventory ON native_history_records(chain_id,task_id,source_revision,record_kind,record_key);
CREATE UNIQUE INDEX IF NOT EXISTS native_event_identity ON native_history_records(chain_id,source_revision,record_key) WHERE record_kind='event';
CREATE INDEX IF NOT EXISTS linked_target ON linked_references(chain_id,target_kind,target_id,target_revision);
CREATE UNIQUE INDEX IF NOT EXISTS owner_execution_task ON owner_execution_journal(task_id) WHERE state!='retired';
CREATE UNIQUE INDEX IF NOT EXISTS owner_execution_instance ON owner_execution_journal(instance_id) WHERE state!='retired';
CREATE TRIGGER IF NOT EXISTS genesis_immutable_update BEFORE UPDATE ON chain_genesis BEGIN SELECT RAISE(ABORT,'immutable genesis'); END;
CREATE TRIGGER IF NOT EXISTS chain_identity_immutable BEFORE UPDATE ON task_chains
WHEN NEW.chain_id IS NOT OLD.chain_id OR NEW.creator IS NOT OLD.creator OR NEW.creator_key IS NOT OLD.creator_key
BEGIN SELECT RAISE(ABORT,'immutable chain identity'); END;
CREATE TRIGGER IF NOT EXISTS task_identity_immutable BEFORE UPDATE ON tasks
WHEN NEW.chain_id IS NOT OLD.chain_id OR NEW.task_id IS NOT OLD.task_id
BEGIN SELECT RAISE(ABORT,'immutable task identity'); END;
CREATE TRIGGER IF NOT EXISTS chain_revision BEFORE UPDATE ON task_chains WHEN typeof(NEW.revision)!='integer' OR NEW.revision!=OLD.revision+1
BEGIN SELECT RAISE(ABORT,'chain update requires next revision'); END;
CREATE TRIGGER IF NOT EXISTS task_revision BEFORE UPDATE ON tasks WHEN typeof(NEW.revision)!='integer' OR NEW.revision!=OLD.revision+1
BEGIN SELECT RAISE(ABORT,'task update requires next revision'); END;
CREATE TRIGGER IF NOT EXISTS grant_identity_immutable BEFORE UPDATE ON local_grants
WHEN NEW.chain_id IS NOT OLD.chain_id OR NEW.principal_id IS NOT OLD.principal_id OR NEW.key_id IS NOT OLD.key_id
BEGIN SELECT RAISE(ABORT,'immutable grant identity'); END;
CREATE TRIGGER IF NOT EXISTS grant_revision BEFORE UPDATE ON local_grants WHEN typeof(NEW.revision)!='integer' OR NEW.revision!=OLD.revision+1
BEGIN SELECT RAISE(ABORT,'grant update requires next revision'); END;
CREATE TRIGGER IF NOT EXISTS grant_valid_insert BEFORE INSERT ON local_grants
WHEN NEW.revision<1 OR NEW.expires_ms<0 OR NEW.can_read NOT IN(0,1) OR NEW.can_mutate NOT IN(0,1) OR NEW.revoked NOT IN(0,1)
BEGIN SELECT RAISE(ABORT,'invalid grant'); END;
CREATE TRIGGER IF NOT EXISTS grant_valid_update BEFORE UPDATE ON local_grants
WHEN NEW.expires_ms<0 OR NEW.can_read NOT IN(0,1) OR NEW.can_mutate NOT IN(0,1) OR NEW.revoked NOT IN(0,1)
BEGIN SELECT RAISE(ABORT,'invalid grant'); END;
CREATE TRIGGER IF NOT EXISTS receipt_no_update BEFORE UPDATE ON command_receipts
BEGIN SELECT RAISE(ABORT,'immutable receipt'); END;
CREATE TRIGGER IF NOT EXISTS tombstone_no_update BEFORE UPDATE ON operation_tombstones
BEGIN SELECT RAISE(ABORT,'immutable operation tombstone'); END;
CREATE TRIGGER IF NOT EXISTS changes_no_update BEFORE UPDATE ON local_changes
BEGIN SELECT RAISE(ABORT,'immutable local change'); END;
CREATE TRIGGER IF NOT EXISTS intent_source BEFORE INSERT ON runtime_intents
WHEN NOT EXISTS(SELECT 1 FROM command_receipts r WHERE r.principal_id=NEW.principal_id
 AND r.operation_id=NEW.operation_id AND r.chain_id=NEW.chain_id AND r.commit_seq=NEW.commit_seq)
BEGIN SELECT RAISE(ABORT,'intent requires source receipt'); END;
CREATE TRIGGER IF NOT EXISTS intent_identity_immutable BEFORE UPDATE ON runtime_intents
WHEN NEW.intent_id IS NOT OLD.intent_id OR NEW.chain_id IS NOT OLD.chain_id OR NEW.commit_seq IS NOT OLD.commit_seq
 OR NEW.principal_id IS NOT OLD.principal_id OR NEW.operation_id IS NOT OLD.operation_id OR NEW.kind IS NOT OLD.kind
 OR NEW.destination_bridge IS NOT OLD.destination_bridge OR NEW.exact_fence_json IS NOT OLD.exact_fence_json
 OR NEW.payload_json IS NOT OLD.payload_json OR NEW.payload_digest IS NOT OLD.payload_digest
BEGIN SELECT RAISE(ABORT,'immutable intent'); END;
CREATE TRIGGER IF NOT EXISTS intent_settled_immutable BEFORE UPDATE ON runtime_intents WHEN OLD.state='settled' BEGIN SELECT RAISE(ABORT,'settled intent'); END;
CREATE TRIGGER IF NOT EXISTS local_fleet_revision BEFORE UPDATE ON local_fleet
WHEN NEW.chain_id IS NOT OLD.chain_id OR NEW.task_id IS NOT OLD.task_id
 OR NEW.configuration_revision<=OLD.configuration_revision
BEGIN SELECT RAISE(ABORT,'fleet revision'); END;
CREATE TRIGGER IF NOT EXISTS local_lease_identity BEFORE UPDATE ON local_leases
WHEN NEW.lease_id IS NOT OLD.lease_id OR NEW.chain_id IS NOT OLD.chain_id OR NEW.task_id IS NOT OLD.task_id
 OR NEW.instance_id IS NOT OLD.instance_id OR NEW.launch_epoch IS NOT OLD.launch_epoch
 OR NEW.run_count IS NOT OLD.run_count OR NEW.token_generation IS NOT OLD.token_generation
 OR NEW.configuration_revision IS NOT OLD.configuration_revision OR NEW.requirements_revision IS NOT OLD.requirements_revision
 OR NEW.hard_ms IS NOT OLD.hard_ms OR OLD.retired_seq IS NOT NULL
 OR NEW.expires_ms<OLD.expires_ms
 OR (NEW.capability_json IS NOT OLD.capability_json AND NEW.deadline_version!=OLD.deadline_version+1)
 OR (NEW.retired_seq IS NOT NULL AND (NEW.capability_json IS NOT OLD.capability_json OR NEW.deadline_version!=OLD.deadline_version))
BEGIN SELECT RAISE(ABORT,'immutable lease fence'); END;
CREATE TRIGGER IF NOT EXISTS lifecycle_configs_immutable BEFORE UPDATE ON lifecycle_configs BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_submissions_immutable BEFORE UPDATE ON local_submissions BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_merge_preparations_immutable BEFORE UPDATE ON local_merge_preparations BEGIN SELECT RAISE(ABORT,'immutable merge preparation'); END;
CREATE TRIGGER IF NOT EXISTS local_merge_preparations_no_delete BEFORE DELETE ON local_merge_preparations BEGIN SELECT RAISE(ABORT,'immutable merge preparation'); END;
CREATE TRIGGER IF NOT EXISTS search_insert AFTER INSERT ON search_docs BEGIN
 INSERT INTO search_fts(rowid,title,body) VALUES(new.rowid,new.title,new.body);
END;
CREATE TRIGGER IF NOT EXISTS search_delete AFTER DELETE ON search_docs BEGIN
 INSERT INTO search_fts(search_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body);
END;
CREATE TRIGGER IF NOT EXISTS search_update AFTER UPDATE ON search_docs BEGIN
 INSERT INTO search_fts(search_fts,rowid,title,body) VALUES('delete',old.rowid,old.title,old.body);
 INSERT INTO search_fts(rowid,title,body) VALUES(new.rowid,new.title,new.body);
END;
CREATE TRIGGER IF NOT EXISTS search_task_chains_insert AFTER INSERT ON task_chains BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,'','chain',new.chain_id,new.revision,new.title,new.description) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER IF NOT EXISTS search_task_chains_update AFTER UPDATE ON task_chains BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,'','chain',new.chain_id,new.revision,new.title,new.description) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER IF NOT EXISTS search_task_chains_delete AFTER DELETE ON task_chains BEGIN DELETE FROM search_docs WHERE chain_id=old.chain_id AND kind='chain' AND object_id=old.chain_id; END;
CREATE TRIGGER IF NOT EXISTS search_tasks_delete AFTER DELETE ON tasks BEGIN DELETE FROM search_docs WHERE chain_id=old.chain_id AND kind='task' AND object_id=old.task_id; END;
CREATE TRIGGER IF NOT EXISTS search_task_comments_insert AFTER INSERT ON task_comments BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'comment',new.principal_id||':'||new.operation_id,new.seq,'',new.body) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER IF NOT EXISTS search_task_comments_update AFTER UPDATE ON task_comments BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'comment',new.principal_id||':'||new.operation_id,new.seq,'',new.body) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER IF NOT EXISTS search_task_comments_delete AFTER DELETE ON task_comments BEGIN DELETE FROM search_docs WHERE chain_id=old.chain_id AND kind='comment' AND object_id=old.principal_id||':'||old.operation_id; END;
CREATE TRIGGER IF NOT EXISTS search_task_requirements_insert AFTER INSERT ON task_requirements BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'requirements',new.task_id,new.revision,'',new.brief_json) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER IF NOT EXISTS search_task_requirements_update AFTER UPDATE ON task_requirements BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'requirements',new.task_id,new.revision,'',new.brief_json) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER IF NOT EXISTS search_task_requirements_delete AFTER DELETE ON task_requirements BEGIN DELETE FROM search_docs WHERE chain_id=old.chain_id AND kind='requirements' AND object_id=old.task_id; END;
CREATE TRIGGER IF NOT EXISTS receipt_scope BEFORE INSERT ON command_receipts
WHEN NOT EXISTS(SELECT 1 FROM task_chains WHERE chain_id=NEW.chain_id)
 OR (NEW.task_id!='' AND NOT EXISTS(SELECT 1 FROM tasks WHERE chain_id=NEW.chain_id AND task_id=NEW.task_id)
     AND NOT (NEW.method='task.delete' AND EXISTS(SELECT 1 FROM task_deletions d WHERE d.chain_id=NEW.chain_id AND d.task_id=NEW.task_id AND d.seq=NEW.commit_seq)))
 OR EXISTS(SELECT 1 FROM operation_tombstones WHERE principal_id=NEW.principal_id AND operation_id=NEW.operation_id)
BEGIN SELECT RAISE(ABORT,'receipt scope or retired operation'); END;
CREATE TRIGGER IF NOT EXISTS task_deletion_no_update BEFORE UPDATE ON task_deletions BEGIN SELECT RAISE(ABORT,'immutable deletion'); END;
CREATE TRIGGER IF NOT EXISTS task_no_resurrection BEFORE INSERT ON tasks WHEN EXISTS(SELECT 1 FROM task_deletions WHERE task_id=NEW.task_id) BEGIN SELECT RAISE(ABORT,'retired task'); END;
CREATE TRIGGER IF NOT EXISTS search_local_submissions_insert AFTER INSERT ON local_submissions BEGIN
 INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
 VALUES(new.chain_id,new.task_id,'output',new.task_id||':'||new.attempt,new.attempt,'',new.summary)
 ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,body=excluded.body;
END;
CREATE TRIGGER IF NOT EXISTS search_local_submissions_update AFTER UPDATE ON local_submissions BEGIN
 INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
 VALUES(new.chain_id,new.task_id,'output',new.task_id||':'||new.attempt,new.attempt,'',new.summary)
 ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,body=excluded.body;
END;
CREATE TRIGGER IF NOT EXISTS search_local_submissions_delete AFTER DELETE ON local_submissions BEGIN
 DELETE FROM search_docs WHERE chain_id=old.chain_id AND kind='output' AND object_id=old.task_id||':'||old.attempt;
END;
CREATE TRIGGER IF NOT EXISTS local_handoffs_immutable BEFORE UPDATE ON local_handoffs BEGIN SELECT RAISE(ABORT,'immutable handoff'); END;
CREATE TRIGGER IF NOT EXISTS control_notices_immutable BEFORE UPDATE ON control_notices BEGIN SELECT RAISE(ABORT,'immutable notice'); END;
CREATE TRIGGER IF NOT EXISTS search_local_handoffs_insert AFTER INSERT ON local_handoffs BEGIN
 INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
 VALUES(new.chain_id,new.task_id,'handoff',new.principal_id||':'||new.operation_id,new.seq,new.kind,new.summary||char(10)||new.next_steps||char(10)||new.waiting_on);
END;
CREATE TRIGGER IF NOT EXISTS intent_invalidations_no_delete BEFORE DELETE ON intent_invalidations BEGIN SELECT RAISE(ABORT,'immutable invalidation'); END;
CREATE TRIGGER IF NOT EXISTS intent_invalidations_immutable BEFORE UPDATE ON intent_invalidations BEGIN SELECT RAISE(ABORT,'immutable invalidation'); END;
CREATE TRIGGER IF NOT EXISTS local_assignment_history_immutable BEFORE UPDATE ON local_assignment_history BEGIN SELECT RAISE(ABORT,'immutable assignment'); END;
CREATE TRIGGER IF NOT EXISTS local_work_attempts_immutable BEFORE UPDATE ON local_work_attempts BEGIN SELECT RAISE(ABORT,'immutable work attempt'); END;
CREATE TRIGGER IF NOT EXISTS local_grant_audit_no_update BEFORE UPDATE ON local_grant_audit BEGIN SELECT RAISE(ABORT,'immutable grant audit'); END;
CREATE TRIGGER IF NOT EXISTS workflow_task_current_insert BEFORE INSERT ON local_workflow_tasks WHEN NOT EXISTS(
 SELECT 1 FROM local_workflow_runs r JOIN local_workflow_executions e USING(chain_id,run_id)
 WHERE r.chain_id=NEW.chain_id AND r.run_id=NEW.run_id AND r.current_execution=NEW.execution AND e.execution=NEW.execution AND e.state='running'
) BEGIN SELECT RAISE(ABORT,'workflow task requires current running execution'); END;
CREATE TRIGGER IF NOT EXISTS local_dependency_cycle BEFORE INSERT ON local_dependencies WHEN EXISTS(
 WITH RECURSIVE ancestors(id) AS (SELECT NEW.prerequisite UNION SELECT d.prerequisite FROM local_dependencies d JOIN ancestors a ON d.task_id=a.id WHERE d.chain_id=NEW.chain_id)
 SELECT 1 FROM ancestors WHERE id=NEW.task_id
) BEGIN SELECT RAISE(ABORT,'cyclic dependency'); END;
CREATE TRIGGER IF NOT EXISTS source_monotonic BEFORE UPDATE ON source_episodes WHEN
 NEW.chain_id IS NOT OLD.chain_id OR NEW.origin_kind IS NOT OLD.origin_kind OR NEW.origin_id IS NOT OLD.origin_id OR NEW.episode_id IS NOT OLD.episode_id
 OR NEW.source_version<OLD.source_version OR NEW.resolved<OLD.resolved OR NEW.ack_floor<OLD.ack_floor OR NEW.retired_floor<OLD.retired_floor OR NEW.delivered_floor<OLD.delivered_floor
 OR NEW.card_closed<OLD.card_closed OR (OLD.card_id!='' AND NEW.card_id IS NOT OLD.card_id)
 BEGIN SELECT RAISE(ABORT,'source identity or watermark regression'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_tasks_immutable BEFORE UPDATE ON local_workflow_tasks BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_events_immutable BEFORE UPDATE ON local_workflow_events BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_role_configs_immutable BEFORE UPDATE ON local_role_configs BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_role_pairs_immutable BEFORE UPDATE ON local_role_pairs BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_role_reviews_immutable BEFORE UPDATE ON local_role_reviews BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS source_consumptions_immutable BEFORE UPDATE ON source_consumptions BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS search_workflow_definition AFTER INSERT ON local_workflow_definitions BEGIN
 INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
 VALUES(new.chain_id,'','workflow',new.workflow_id||':'||new.version,new.version,json_extract(new.definition_json,'$.title'),new.definition_json);
END;
CREATE TRIGGER IF NOT EXISTS search_source_insert AFTER INSERT ON source_episodes BEGIN
 INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
 VALUES(new.chain_id,'','source',json_array(new.origin_kind,new.origin_id,new.episode_id),new.source_version,new.origin_kind,new.body);
END;
CREATE TRIGGER IF NOT EXISTS search_source_update AFTER UPDATE ON source_episodes BEGIN
 UPDATE search_docs SET revision=new.source_version,body=new.body WHERE chain_id=new.chain_id AND kind='source' AND object_id=json_array(new.origin_kind,new.origin_id,new.episode_id);
END;
CREATE TRIGGER IF NOT EXISTS workflow_run_monotonic BEFORE UPDATE ON local_workflow_runs WHEN
 NEW.chain_id IS NOT OLD.chain_id OR NEW.run_id IS NOT OLD.run_id OR NEW.workflow_id IS NOT OLD.workflow_id OR NEW.definition_version!=OLD.definition_version
 OR NEW.current_execution!=OLD.current_execution+1 OR NEW.revision!=OLD.revision+1
 BEGIN SELECT RAISE(ABORT,'workflow retry must advance exact generation'); END;
CREATE TRIGGER IF NOT EXISTS workflow_execution_transition BEFORE UPDATE ON local_workflow_executions WHEN
 NEW.chain_id IS NOT OLD.chain_id OR NEW.run_id IS NOT OLD.run_id OR NEW.execution!=OLD.execution
 OR NEW.state=OLD.state OR OLD.state='superseded' OR NEW.state='running'
 BEGIN SELECT RAISE(ABORT,'invalid execution transition'); END;
CREATE TRIGGER IF NOT EXISTS workflow_task_definition_immutable BEFORE UPDATE ON tasks WHEN
 (NEW.title IS NOT OLD.title OR NEW.body IS NOT OLD.body) AND EXISTS(SELECT 1 FROM local_workflow_tasks w WHERE w.chain_id=OLD.chain_id AND w.task_id=OLD.task_id)
 BEGIN SELECT RAISE(ABORT,'immutable generated definition'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_language_runs_immutable BEFORE UPDATE ON local_workflow_language_runs BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_stage_expansions_immutable BEFORE UPDATE ON local_workflow_stage_expansions BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_language_items_immutable BEFORE UPDATE ON local_workflow_language_items BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_language_items_no_delete BEFORE DELETE ON local_workflow_language_items BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_outputs_immutable BEFORE UPDATE ON local_workflow_outputs BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_registry_envelopes_immutable BEFORE UPDATE ON local_workflow_registry_envelopes BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_registry_envelopes_no_delete BEFORE DELETE ON local_workflow_registry_envelopes BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER IF NOT EXISTS search_workflow_output AFTER INSERT ON local_workflow_outputs BEGIN
 UPDATE search_docs SET body=body||char(10)||NEW.output_json WHERE chain_id=NEW.chain_id AND task_id=NEW.task_id AND kind='output' AND object_id=NEW.task_id||':'||NEW.attempt;
END;
CREATE TRIGGER IF NOT EXISTS local_workflow_coordinators_immutable BEFORE UPDATE ON local_workflow_coordinators BEGIN SELECT RAISE(ABORT,'immutable coordinator binding'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_trigger_failures_immutable BEFORE UPDATE ON local_workflow_trigger_failures BEGIN SELECT RAISE(ABORT,'immutable trigger outcome'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_output_trigger_identity BEFORE UPDATE ON local_workflow_output_triggers
WHEN NEW.chain_id IS NOT OLD.chain_id OR NEW.source_task IS NOT OLD.source_task
 OR NEW.source_attempt IS NOT OLD.source_attempt OR NEW.source_run IS NOT OLD.source_run
 OR NEW.source_execution IS NOT OLD.source_execution OR NEW.target_run IS NOT OLD.target_run
 OR NEW.consumed<OLD.consumed
BEGIN SELECT RAISE(ABORT,'immutable output prerequisite'); END;
CREATE TRIGGER IF NOT EXISTS local_events_no_update BEFORE UPDATE ON local_events BEGIN SELECT RAISE(ABORT,'immutable event'); END;
CREATE TRIGGER IF NOT EXISTS local_task_retirements_no_update BEFORE UPDATE ON local_task_retirements
BEGIN SELECT RAISE(ABORT,'immutable task retirement'); END;
CREATE TRIGGER IF NOT EXISTS native_history_no_update BEFORE UPDATE ON native_history_records
BEGIN SELECT RAISE(ABORT,'immutable native history'); END;
CREATE TRIGGER IF NOT EXISTS native_facet_writer BEFORE INSERT ON native_history_records WHEN NEW.record_kind='facet' AND EXISTS(
 SELECT 1 FROM native_history_records WHERE chain_id=NEW.chain_id AND task_id=NEW.task_id
 AND record_kind='facet' AND attempt_no=NEW.attempt_no AND facet_kind=NEW.facet_kind AND writer!=NEW.writer)
BEGIN SELECT RAISE(ABORT,'native facet writer mismatch'); END;
CREATE TRIGGER IF NOT EXISTS deferred_retire_no_update BEFORE UPDATE ON deferred_workflow_retirements BEGIN SELECT RAISE(ABORT,'immutable deferred retirement'); END;
CREATE TRIGGER IF NOT EXISTS deferred_disposition_no_update BEFORE UPDATE ON deferred_workflow_dispositions BEGIN SELECT RAISE(ABORT,'immutable deferred disposition'); END;
CREATE TRIGGER IF NOT EXISTS deferred_disposition_no_delete BEFORE DELETE ON deferred_workflow_dispositions BEGIN SELECT RAISE(ABORT,'immutable deferred disposition'); END;
CREATE TRIGGER IF NOT EXISTS deferred_prepared_merge_no_invalidation BEFORE INSERT ON intent_invalidations
WHEN EXISTS(SELECT 1 FROM deferred_workflow_retirements d
 WHERE d.intent_id=NEW.intent_id AND NOT EXISTS(SELECT 1 FROM deferred_workflow_dispositions r WHERE r.intent_id=d.intent_id))
BEGIN SELECT RAISE(ABORT,'unsettled prepared workflow merge'); END;
CREATE TRIGGER IF NOT EXISTS dependency_retirement_no_update BEFORE UPDATE ON local_dependency_retirements BEGIN SELECT RAISE(ABORT,'immutable dependency retirement'); END;
CREATE TRIGGER IF NOT EXISTS local_fleet_policy_versions_no_update BEFORE UPDATE ON local_fleet_policy_versions BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER IF NOT EXISTS local_fleet_policy_roles_no_update BEFORE UPDATE ON local_fleet_policy_roles BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER IF NOT EXISTS local_fleet_policy_models_no_update BEFORE UPDATE ON local_fleet_policy_models BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER IF NOT EXISTS native_metadata_origins_no_update BEFORE UPDATE ON native_metadata_origins BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER IF NOT EXISTS native_metadata_snapshots_no_update BEFORE UPDATE ON native_metadata_snapshots BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER IF NOT EXISTS native_metadata_members_no_update BEFORE UPDATE ON native_metadata_members BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER IF NOT EXISTS native_metadata_directories_no_update BEFORE UPDATE ON native_metadata_directories BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER IF NOT EXISTS native_fact_snapshots_no_update BEFORE UPDATE ON native_fact_snapshots BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER IF NOT EXISTS native_fact_chain_no_update BEFORE UPDATE ON native_fact_chain BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER IF NOT EXISTS native_fact_task_no_update BEFORE UPDATE ON native_fact_task BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER IF NOT EXISTS native_fact_comment_no_update BEFORE UPDATE ON native_fact_comment BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER IF NOT EXISTS native_fact_summary_no_update BEFORE UPDATE ON native_fact_summary BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER IF NOT EXISTS local_task_priority_scope BEFORE INSERT ON local_task_priority_versions
WHEN NOT EXISTS(SELECT 1 FROM tasks WHERE chain_id=NEW.chain_id AND task_id=NEW.task_id)
BEGIN SELECT RAISE(ABORT,'priority task scope'); END;
CREATE TRIGGER IF NOT EXISTS local_task_priority_no_update BEFORE UPDATE ON local_task_priority_versions
BEGIN SELECT RAISE(ABORT,'immutable priority history'); END;
CREATE TRIGGER IF NOT EXISTS native_history_origin BEFORE INSERT ON native_history_records
WHEN NOT EXISTS(SELECT 1 FROM native_metadata_origins o WHERE o.chain_id=NEW.chain_id AND o.owner_user_id=NEW.owner_user_id)
BEGIN SELECT RAISE(ABORT,'native history owner conflict'); END;
CREATE TRIGGER IF NOT EXISTS native_fleet_snapshots_no_update BEFORE UPDATE ON native_fleet_snapshots BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER IF NOT EXISTS native_fleet_policies_no_update BEFORE UPDATE ON native_fleet_policies BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER IF NOT EXISTS local_fleet_policy_sources_no_update BEFORE UPDATE ON local_fleet_policy_sources BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_summary_no_update BEFORE UPDATE ON local_chain_summary_versions
BEGIN SELECT RAISE(ABORT,'immutable curated summary'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_member_versions_no_update BEFORE UPDATE ON local_chain_member_versions
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER IF NOT EXISTS local_member_chains_no_update BEFORE UPDATE ON local_member_chains
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_directory_versions_no_update BEFORE UPDATE ON local_chain_directory_versions
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER IF NOT EXISTS local_config_revocations_no_update BEFORE UPDATE ON local_config_revocations
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER IF NOT EXISTS local_coordinator_revocations_no_update BEFORE UPDATE ON local_coordinator_revocations
BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER IF NOT EXISTS local_brief_inputs_no_update BEFORE UPDATE ON local_brief_inputs
BEGIN SELECT RAISE(ABORT,'immutable brief inputs'); END;
CREATE TRIGGER IF NOT EXISTS local_metadata_retirements_no_update BEFORE UPDATE ON local_metadata_retirements
BEGIN SELECT RAISE(ABORT,'immutable metadata retirement'); END;
CREATE TRIGGER IF NOT EXISTS local_work_chain_create AFTER INSERT ON task_chains
BEGIN INSERT INTO local_work_chains(chain_id) VALUES(NEW.chain_id); END;
CREATE TRIGGER IF NOT EXISTS local_task_publications_immutable_update BEFORE UPDATE ON local_task_publications
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_proposals_immutable_update BEFORE UPDATE ON local_work_proposals
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_decisions_immutable_update BEFORE UPDATE ON local_work_decisions
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_dependencies_immutable_update BEFORE UPDATE ON local_work_dependencies
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_dependency_removals_immutable_update BEFORE UPDATE ON local_work_dependency_removals
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_inputs_immutable_update BEFORE UPDATE ON local_work_inputs
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_scope_immutable_update BEFORE UPDATE ON local_work_scope
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_completions_immutable_update BEFORE UPDATE ON local_work_completions
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_pending_runs_immutable_update BEFORE UPDATE ON local_work_pending_runs
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_run_starts_immutable_update BEFORE UPDATE ON local_work_run_starts
BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS work_revision_tasks_insert AFTER INSERT ON tasks
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_tasks_delete AFTER DELETE ON tasks
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_task_requirements_insert AFTER INSERT ON task_requirements
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_lifecycle_state_insert AFTER INSERT ON lifecycle_state
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_lifecycle_state_update AFTER UPDATE ON lifecycle_state
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_work_attempts_insert AFTER INSERT ON local_work_attempts
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_workflow_runs_insert AFTER INSERT ON local_workflow_runs
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_workflow_runs_update AFTER UPDATE ON local_workflow_runs
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_workflow_executions_insert AFTER INSERT ON local_workflow_executions
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_workflow_executions_update AFTER UPDATE ON local_workflow_executions
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_task_publications_insert AFTER INSERT ON local_task_publications
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_work_dependencies_insert AFTER INSERT ON local_work_dependencies
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_work_dependency_removals_insert AFTER INSERT ON local_work_dependency_removals
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_work_scope_insert AFTER INSERT ON local_work_scope
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_chain_defaults_versions_insert AFTER INSERT ON local_chain_defaults_versions
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_work_pending_runs_insert AFTER INSERT ON local_work_pending_runs
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_work_run_starts_insert AFTER INSERT ON local_work_run_starts
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS local_work_chain_publication AFTER UPDATE OF publish_state,status ON local_work_chains
WHEN NEW.publish_state!=OLD.publish_state OR NEW.status!=OLD.status
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS local_work_chain_completed BEFORE UPDATE ON local_work_chains
WHEN OLD.status='completed' AND (NEW.status!=OLD.status OR NEW.publish_state!=OLD.publish_state)
BEGIN SELECT RAISE(ABORT,'completed chain'); END;
CREATE TRIGGER IF NOT EXISTS work_run_publications_no_update BEFORE UPDATE ON local_work_run_publications BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS work_materialized_tasks_no_update BEFORE UPDATE ON local_work_materialized_tasks BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS work_revision_run_publications AFTER INSERT ON local_work_run_publications
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS native_work_snapshots_no_update BEFORE UPDATE ON native_work_snapshots BEGIN SELECT RAISE(ABORT,'immutable source work snapshot'); END;
CREATE TRIGGER IF NOT EXISTS native_work_no_update BEFORE UPDATE ON native_work_records BEGIN SELECT RAISE(ABORT,'immutable source work facts'); END;
CREATE TRIGGER IF NOT EXISTS work_run_cancellations_no_update BEFORE UPDATE ON local_work_run_cancellations BEGIN SELECT RAISE(ABORT,'immutable cancellation'); END;
CREATE TRIGGER IF NOT EXISTS work_revision_run_cancellations AFTER INSERT ON local_work_run_cancellations
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_dependencies_insert AFTER INSERT ON local_dependencies
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_dependencies_delete AFTER DELETE ON local_dependencies
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=OLD.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_workflow_language_executions_insert AFTER INSERT ON local_workflow_language_executions
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_workflow_language_executions_update AFTER UPDATE ON local_workflow_language_executions
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_controls_insert AFTER INSERT ON local_controls
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS work_revision_local_controls_update AFTER UPDATE ON local_controls
BEGIN UPDATE local_work_chains SET work_revision=work_revision+1 WHERE chain_id=NEW.chain_id; END;
CREATE TRIGGER IF NOT EXISTS native_record_snapshots_no_update BEFORE UPDATE ON native_record_snapshots BEGIN SELECT RAISE(ABORT,'immutable native records'); END;
CREATE TRIGGER IF NOT EXISTS native_record_values_no_update BEFORE UPDATE ON native_record_values BEGIN SELECT RAISE(ABORT,'immutable native records'); END;
CREATE TRIGGER IF NOT EXISTS linked_identity_no_update BEFORE UPDATE ON linked_identities BEGIN SELECT RAISE(ABORT,'immutable linked identity'); END;
CREATE TRIGGER IF NOT EXISTS linked_body_no_update BEFORE UPDATE ON linked_bodies BEGIN SELECT RAISE(ABORT,'immutable linked body'); END;
CREATE TRIGGER IF NOT EXISTS linked_tombstone_no_update BEFORE UPDATE ON linked_tombstones BEGIN SELECT RAISE(ABORT,'immutable linked tombstone'); END;
CREATE TRIGGER IF NOT EXISTS linked_body_no_resurrection BEFORE INSERT ON linked_bodies
 WHEN EXISTS(SELECT 1 FROM linked_tombstones WHERE chain_id=NEW.chain_id AND kind=NEW.kind AND object_id=NEW.object_id AND revision=NEW.revision)
 BEGIN SELECT RAISE(ABORT,'retired linked body'); END;
CREATE TRIGGER IF NOT EXISTS linked_search_insert AFTER INSERT ON linked_bodies WHEN NEW.kind='message' BEGIN
 INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
 SELECT NEW.chain_id,i.task_id,'message',json_array(NEW.object_id,NEW.revision),NEW.revision,'',NEW.prose
 FROM linked_identities i WHERE i.chain_id=NEW.chain_id AND i.kind=NEW.kind AND i.object_id=NEW.object_id AND i.revision=NEW.revision;
END;
CREATE TRIGGER IF NOT EXISTS linked_search_delete AFTER DELETE ON linked_bodies WHEN OLD.kind='message' BEGIN
 DELETE FROM search_docs WHERE chain_id=OLD.chain_id AND kind='message' AND object_id=json_array(OLD.object_id,OLD.revision);
END;
CREATE TRIGGER IF NOT EXISTS linked_reference_no_update BEFORE UPDATE ON linked_references BEGIN SELECT RAISE(ABORT,'immutable linked reference'); END;
CREATE TRIGGER IF NOT EXISTS owner_execution_identity BEFORE UPDATE ON owner_execution_journal
WHEN NEW.reservation_id IS NOT OLD.reservation_id OR NEW.chain_id IS NOT OLD.chain_id
 OR NEW.task_id IS NOT OLD.task_id OR NEW.instance_id IS NOT OLD.instance_id
 OR NEW.lease_id IS NOT OLD.lease_id OR NEW.operation_id IS NOT OLD.operation_id
 OR NEW.prepare_digest IS NOT OLD.prepare_digest OR NEW.lease_digest IS NOT OLD.lease_digest
 OR NEW.prepare_json IS NOT OLD.prepare_json OR NEW.lease_command IS NOT OLD.lease_command
 OR NEW.child_json IS NOT OLD.child_json OR NEW.prepare_seq IS NOT OLD.prepare_seq
 OR NEW.prepare_until_ms IS NOT OLD.prepare_until_ms OR NEW.owner_incarnation IS NOT OLD.owner_incarnation
 OR OLD.state='retired' OR (OLD.state='committed' AND NEW.state NOT IN('committed','retired'))
 OR (OLD.state='committed' AND (NEW.receipt_json IS NOT OLD.receipt_json
   OR NEW.activation_json IS NOT OLD.activation_json OR NEW.grant_seq IS NOT OLD.grant_seq))
BEGIN SELECT RAISE(ABORT,'immutable owner execution'); END;
CREATE TRIGGER IF NOT EXISTS owner_execution_query_no_update BEFORE UPDATE ON owner_execution_queries
 BEGIN SELECT RAISE(ABORT,'immutable execution query'); END;
CREATE TRIGGER IF NOT EXISTS owner_execution_query_no_delete BEFORE DELETE ON owner_execution_queries
 BEGIN SELECT RAISE(ABORT,'retain execution query'); END;
CREATE TRIGGER IF NOT EXISTS owner_bootstrap_no_update BEFORE UPDATE ON owner_execution_bootstraps
 BEGIN SELECT RAISE(ABORT,'immutable owner bootstrap'); END;
CREATE TRIGGER IF NOT EXISTS owner_bootstrap_no_delete BEFORE DELETE ON owner_execution_bootstraps
 BEGIN SELECT RAISE(ABORT,'retained owner bootstrap'); END;
CREATE TRIGGER IF NOT EXISTS owner_stop_step_identity BEFORE UPDATE ON owner_execution_stop_steps
WHEN NEW.intent_id IS NOT OLD.intent_id OR NEW.step IS NOT OLD.step OR NEW.phase IS NOT OLD.phase OR NEW.request IS NOT OLD.request
 OR OLD.outcome!='pending' OR NEW.outcome='pending' OR NEW.receipt=''
BEGIN SELECT RAISE(ABORT,'immutable stop step'); END;
CREATE TRIGGER IF NOT EXISTS owner_stop_step_no_delete BEFORE DELETE ON owner_execution_stop_steps
BEGIN SELECT RAISE(ABORT,'retained stop step'); END;
CREATE TRIGGER IF NOT EXISTS migration_import_identity BEFORE UPDATE ON migration_imports
WHEN NEW.migration_id IS NOT OLD.migration_id OR NEW.manifest_digest IS NOT OLD.manifest_digest
 OR NEW.chain_id IS NOT OLD.chain_id OR NEW.selection_digest IS NOT OLD.selection_digest
 OR NEW.principal_id IS NOT OLD.principal_id OR NEW.key_id IS NOT OLD.key_id
 OR NEW.import_seq IS NOT OLD.import_seq OR NEW.manifest_json IS NOT OLD.manifest_json
 OR NEW.receipt_json IS NOT OLD.receipt_json OR NEW.summary_json IS NOT OLD.summary_json
 OR OLD.activated_seq IS NOT NULL OR NEW.activated_seq IS NULL
BEGIN SELECT RAISE(ABORT,'immutable migration import'); END;
CREATE TRIGGER IF NOT EXISTS migration_import_document_no_update BEFORE UPDATE ON migration_import_documents
BEGIN SELECT RAISE(ABORT,'immutable migration document'); END;
CREATE TRIGGER IF NOT EXISTS migration_archived_task_no_update BEFORE UPDATE ON migration_archived_tasks
BEGIN SELECT RAISE(ABORT,'immutable archived task'); END;
CREATE TRIGGER IF NOT EXISTS migration_abandoned_never_activated BEFORE UPDATE ON migration_imports
WHEN NEW.activated_seq IS NOT NULL AND EXISTS(SELECT 1 FROM migration_abandoned a WHERE a.migration_id=NEW.migration_id)
BEGIN SELECT RAISE(ABORT,'abandoned import cannot be activated'); END;
CREATE TRIGGER IF NOT EXISTS migration_discarded_no_update BEFORE UPDATE ON migration_discarded
BEGIN SELECT RAISE(ABORT,'immutable discarded import'); END;
CREATE TRIGGER IF NOT EXISTS migration_discarded_no_delete BEFORE DELETE ON migration_discarded
BEGIN SELECT RAISE(ABORT,'immutable discarded import'); END;
CREATE TRIGGER IF NOT EXISTS search_tasks_insert AFTER INSERT ON tasks
WHEN NOT EXISTS(SELECT 1 FROM migration_archived_tasks a WHERE a.chain_id=new.chain_id AND a.task_id=new.task_id)
BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'task',new.task_id,new.revision,new.title,new.body) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER IF NOT EXISTS search_tasks_update AFTER UPDATE ON tasks
WHEN NOT EXISTS(SELECT 1 FROM migration_archived_tasks a WHERE a.chain_id=new.chain_id AND a.task_id=new.task_id)
BEGIN INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body) VALUES(new.chain_id,new.task_id,'task',new.task_id,new.revision,new.title,new.body) ON CONFLICT(chain_id,kind,object_id) DO UPDATE SET revision=excluded.revision,title=excluded.title,body=excluded.body; END;
CREATE TRIGGER IF NOT EXISTS migration_discarding_abandoned_only BEFORE INSERT ON migration_discarding
 WHEN NOT EXISTS(SELECT 1 FROM migration_imports m JOIN migration_abandoned a ON a.migration_id=m.migration_id
  WHERE m.migration_id=NEW.migration_id AND m.chain_id=NEW.chain_id AND m.activated_seq IS NULL)
 BEGIN SELECT RAISE(ABORT,'discard marker requires an abandoned import'); END;
CREATE TRIGGER IF NOT EXISTS migration_discarding_immutable BEFORE UPDATE ON migration_discarding
 BEGIN SELECT RAISE(ABORT,'immutable discard marker'); END;
CREATE TRIGGER IF NOT EXISTS genesis_immutable_delete BEFORE DELETE ON chain_genesis
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable genesis'); END;
CREATE TRIGGER IF NOT EXISTS receipt_no_forget BEFORE DELETE ON command_receipts
 WHEN (NOT EXISTS(SELECT 1 FROM operation_tombstones t WHERE t.principal_id=OLD.principal_id AND t.operation_id=OLD.operation_id AND t.input_digest=OLD.input_digest AND t.method=OLD.method AND t.chain_id=OLD.chain_id AND t.task_id=OLD.task_id AND t.commit_seq=OLD.commit_seq)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'receipt requires retained tombstone'); END;
CREATE TRIGGER IF NOT EXISTS control_notices_no_delete BEFORE DELETE ON control_notices
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable notice'); END;
CREATE TRIGGER IF NOT EXISTS deferred_retire_no_delete BEFORE DELETE ON deferred_workflow_retirements
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable deferred retirement'); END;
CREATE TRIGGER IF NOT EXISTS lifecycle_configs_no_delete BEFORE DELETE ON lifecycle_configs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER IF NOT EXISTS linked_body_delete_guard BEFORE DELETE ON linked_bodies
 WHEN (NOT EXISTS(SELECT 1 FROM linked_tombstones WHERE chain_id=OLD.chain_id AND kind=OLD.kind AND object_id=OLD.object_id AND revision=OLD.revision)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'tombstone before body GC'); END;
CREATE TRIGGER IF NOT EXISTS linked_identity_no_delete BEFORE DELETE ON linked_identities
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain linked identity'); END;
CREATE TRIGGER IF NOT EXISTS linked_reference_delete_guard BEFORE DELETE ON linked_references
 WHEN (NOT EXISTS(SELECT 1 FROM linked_tombstones WHERE chain_id=OLD.chain_id AND kind=OLD.source_kind AND object_id=OLD.source_id AND revision=OLD.source_revision)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'tombstone before reference GC'); END;
CREATE TRIGGER IF NOT EXISTS linked_tombstone_no_delete BEFORE DELETE ON linked_tombstones
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain linked tombstone'); END;
CREATE TRIGGER IF NOT EXISTS local_assignment_history_no_delete BEFORE DELETE ON local_assignment_history
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable assignment'); END;
CREATE TRIGGER IF NOT EXISTS local_brief_inputs_no_delete BEFORE DELETE ON local_brief_inputs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable brief inputs'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_defaults_no_delete BEFORE DELETE ON local_chain_defaults_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable defaults history'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_directory_versions_no_delete BEFORE DELETE ON local_chain_directory_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_member_versions_no_delete BEFORE DELETE ON local_chain_member_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_summary_no_delete BEFORE DELETE ON local_chain_summary_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable curated summary'); END;
CREATE TRIGGER IF NOT EXISTS local_config_revocations_no_delete BEFORE DELETE ON local_config_revocations
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER IF NOT EXISTS local_coordinator_revocations_no_delete BEFORE DELETE ON local_coordinator_revocations
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER IF NOT EXISTS dependency_retirement_no_delete BEFORE DELETE ON local_dependency_retirements
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable dependency retirement'); END;
CREATE TRIGGER IF NOT EXISTS local_events_no_delete BEFORE DELETE ON local_events
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable event'); END;
CREATE TRIGGER IF NOT EXISTS local_fleet_policy_models_no_delete BEFORE DELETE ON local_fleet_policy_models
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER IF NOT EXISTS local_fleet_policy_roles_no_delete BEFORE DELETE ON local_fleet_policy_roles
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER IF NOT EXISTS local_fleet_policy_sources_no_delete BEFORE DELETE ON local_fleet_policy_sources
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER IF NOT EXISTS local_fleet_policy_versions_no_delete BEFORE DELETE ON local_fleet_policy_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet policy'); END;
CREATE TRIGGER IF NOT EXISTS local_grant_audit_no_delete BEFORE DELETE ON local_grant_audit
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable grant audit'); END;
CREATE TRIGGER IF NOT EXISTS local_handoffs_no_delete BEFORE DELETE ON local_handoffs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable handoff'); END;
CREATE TRIGGER IF NOT EXISTS local_member_chains_no_delete BEFORE DELETE ON local_member_chains
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable operational metadata'); END;
CREATE TRIGGER IF NOT EXISTS local_metadata_retirements_no_delete BEFORE DELETE ON local_metadata_retirements
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable metadata retirement'); END;
CREATE TRIGGER IF NOT EXISTS local_reviews_no_delete BEFORE DELETE ON local_reviews
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_role_configs_no_delete BEFORE DELETE ON local_role_configs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_role_pairs_no_delete BEFORE DELETE ON local_role_pairs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_role_reviews_no_delete BEFORE DELETE ON local_role_reviews
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_submissions_no_delete BEFORE DELETE ON local_submissions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_task_priority_no_delete BEFORE DELETE ON local_task_priority_versions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable priority history'); END;
CREATE TRIGGER IF NOT EXISTS local_task_publications_immutable_delete BEFORE DELETE ON local_task_publications
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_task_retirements_no_delete BEFORE DELETE ON local_task_retirements
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable task retirement'); END;
CREATE TRIGGER IF NOT EXISTS local_work_attempts_no_delete BEFORE DELETE ON local_work_attempts
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work attempt'); END;
CREATE TRIGGER IF NOT EXISTS local_work_completions_immutable_delete BEFORE DELETE ON local_work_completions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_decisions_immutable_delete BEFORE DELETE ON local_work_decisions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_dependencies_immutable_delete BEFORE DELETE ON local_work_dependencies
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_dependency_removals_immutable_delete BEFORE DELETE ON local_work_dependency_removals
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_inputs_immutable_delete BEFORE DELETE ON local_work_inputs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS work_materialized_tasks_no_delete BEFORE DELETE ON local_work_materialized_tasks
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_pending_runs_immutable_delete BEFORE DELETE ON local_work_pending_runs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_proposals_immutable_delete BEFORE DELETE ON local_work_proposals
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS work_run_cancellations_no_delete BEFORE DELETE ON local_work_run_cancellations
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable cancellation'); END;
CREATE TRIGGER IF NOT EXISTS work_run_publications_no_delete BEFORE DELETE ON local_work_run_publications
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_run_starts_immutable_delete BEFORE DELETE ON local_work_run_starts
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_work_scope_immutable_delete BEFORE DELETE ON local_work_scope
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable work history'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_coordinators_no_delete BEFORE DELETE ON local_workflow_coordinators
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable coordinator binding'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_definitions_no_delete BEFORE DELETE ON local_workflow_definitions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_events_no_delete BEFORE DELETE ON local_workflow_events
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS workflow_execution_no_delete BEFORE DELETE ON local_workflow_executions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable execution history'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_language_runs_no_delete BEFORE DELETE ON local_workflow_language_runs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_output_trigger_no_delete BEFORE DELETE ON local_workflow_output_triggers
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable output prerequisite'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_outputs_no_delete BEFORE DELETE ON local_workflow_outputs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER IF NOT EXISTS workflow_run_no_delete BEFORE DELETE ON local_workflow_runs
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable workflow history'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_stage_expansions_no_delete BEFORE DELETE ON local_workflow_stage_expansions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable workflow evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_tasks_no_delete BEFORE DELETE ON local_workflow_tasks
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_trigger_failures_no_delete BEFORE DELETE ON local_workflow_trigger_failures
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable trigger outcome'); END;
CREATE TRIGGER IF NOT EXISTS migration_abandoned_no_delete BEFORE DELETE ON migration_abandoned
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.migration_id=OLD.migration_id)
 BEGIN SELECT RAISE(ABORT,'abandoned import stays abandoned'); END;
CREATE TRIGGER IF NOT EXISTS migration_archived_task_no_delete BEFORE DELETE ON migration_archived_tasks
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable archived task'); END;
CREATE TRIGGER IF NOT EXISTS migration_import_document_no_delete BEFORE DELETE ON migration_import_documents
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.migration_id=OLD.migration_id)
 BEGIN SELECT RAISE(ABORT,'immutable migration document'); END;
CREATE TRIGGER IF NOT EXISTS migration_import_no_delete BEFORE DELETE ON migration_imports
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retained migration import'); END;
CREATE TRIGGER IF NOT EXISTS native_fact_chain_no_delete BEFORE DELETE ON native_fact_chain
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER IF NOT EXISTS native_fact_comment_no_delete BEFORE DELETE ON native_fact_comment
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER IF NOT EXISTS native_fact_snapshots_no_delete BEFORE DELETE ON native_fact_snapshots
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER IF NOT EXISTS native_fact_summary_no_delete BEFORE DELETE ON native_fact_summary
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER IF NOT EXISTS native_fact_task_no_delete BEFORE DELETE ON native_fact_task
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native fact'); END;
CREATE TRIGGER IF NOT EXISTS native_fleet_policies_no_delete BEFORE DELETE ON native_fleet_policies
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER IF NOT EXISTS native_fleet_snapshots_no_delete BEFORE DELETE ON native_fleet_snapshots
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable fleet source'); END;
CREATE TRIGGER IF NOT EXISTS native_history_no_delete BEFORE DELETE ON native_history_records
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native history'); END;
CREATE TRIGGER IF NOT EXISTS native_metadata_directories_no_delete BEFORE DELETE ON native_metadata_directories
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER IF NOT EXISTS native_metadata_members_no_delete BEFORE DELETE ON native_metadata_members
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER IF NOT EXISTS native_metadata_origins_no_delete BEFORE DELETE ON native_metadata_origins
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER IF NOT EXISTS native_metadata_snapshots_no_delete BEFORE DELETE ON native_metadata_snapshots
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native metadata'); END;
CREATE TRIGGER IF NOT EXISTS native_record_snapshots_no_delete BEFORE DELETE ON native_record_snapshots
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native records'); END;
CREATE TRIGGER IF NOT EXISTS native_record_values_no_delete BEFORE DELETE ON native_record_values
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable native records'); END;
CREATE TRIGGER IF NOT EXISTS native_work_no_delete BEFORE DELETE ON native_work_records
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable source work facts'); END;
CREATE TRIGGER IF NOT EXISTS native_work_snapshots_no_delete BEFORE DELETE ON native_work_snapshots
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable source work snapshot'); END;
CREATE TRIGGER IF NOT EXISTS tombstone_no_delete BEFORE DELETE ON operation_tombstones
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain operation tombstone'); END;
CREATE TRIGGER IF NOT EXISTS owner_execution_no_delete BEFORE DELETE ON owner_execution_journal
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain execution identity'); END;
CREATE TRIGGER IF NOT EXISTS intent_no_delete BEFORE DELETE ON runtime_intents
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain intent outcome'); END;
CREATE TRIGGER IF NOT EXISTS source_consumptions_no_delete BEFORE DELETE ON source_consumptions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS source_pending_card_no_delete BEFORE DELETE ON source_episodes
 WHEN (OLD.resolved=0 OR (OLD.card_id!='' AND OLD.card_closed=0)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'source still requires discovery'); END;
CREATE TRIGGER IF NOT EXISTS task_deletion_no_delete BEFORE DELETE ON task_deletions
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'retain deletion'); END;
CREATE TRIGGER IF NOT EXISTS task_requirements_no_delete BEFORE DELETE ON task_requirements
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_work_referenced_task_no_delete BEFORE DELETE ON tasks
 WHEN (EXISTS(SELECT 1 FROM local_work_dependencies WHERE chain_id=OLD.chain_id AND ((dependent_kind='task' AND dependent_id=OLD.task_id) OR (prerequisite_kind='task' AND prerequisite_id=OLD.task_id))) OR EXISTS(SELECT 1 FROM local_work_inputs WHERE chain_id=OLD.chain_id AND ((dependent_kind='task' AND dependent_id=OLD.task_id) OR (prerequisite_kind='task' AND prerequisite_id=OLD.task_id))) OR EXISTS(SELECT 1 FROM local_work_scope WHERE chain_id=OLD.chain_id AND item_kind='task' AND item_id=OLD.task_id)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'referenced work history'); END;
CREATE TRIGGER IF NOT EXISTS workflow_task_no_delete BEFORE DELETE ON tasks
 WHEN (EXISTS(SELECT 1 FROM local_workflow_tasks w WHERE w.chain_id=OLD.chain_id AND w.task_id=OLD.task_id)) AND NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id)
 BEGIN SELECT RAISE(ABORT,'immutable generated history'); END;
CREATE TRIGGER IF NOT EXISTS local_reviews_immutable BEFORE UPDATE ON local_reviews BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_policies_immutable BEFORE UPDATE ON local_chain_policies BEGIN SELECT RAISE(ABORT,'immutable chain policy'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_policies_no_delete BEFORE DELETE ON local_chain_policies
 WHEN NOT EXISTS(SELECT 1 FROM migration_discarding d WHERE d.chain_id=OLD.chain_id) BEGIN SELECT RAISE(ABORT,'immutable chain policy'); END;
CREATE TRIGGER IF NOT EXISTS local_task_links_immutable BEFORE UPDATE ON local_task_links BEGIN SELECT RAISE(ABORT,'immutable task link'); END;
CREATE TRIGGER IF NOT EXISTS local_review_role_migrations_immutable BEFORE UPDATE ON local_review_role_migrations BEGIN SELECT RAISE(ABORT,'immutable migration record'); END;
CREATE TRIGGER IF NOT EXISTS task_requirements_immutable BEFORE UPDATE ON task_requirements BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_definitions_immutable BEFORE UPDATE ON local_workflow_definitions BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_defaults_no_update BEFORE UPDATE ON local_chain_defaults_versions
BEGIN SELECT RAISE(ABORT,'immutable defaults history'); END;
CREATE TRIGGER IF NOT EXISTS runtime_identity_immutable BEFORE UPDATE ON runtime_database
WHEN NEW.account_id IS NOT OLD.account_id OR NEW.owner_bridge_id IS NOT OLD.owner_bridge_id
 OR NEW.owner_key_id IS NOT OLD.owner_key_id OR NEW.database_id IS NOT OLD.database_id
 OR NEW.singleton IS NOT OLD.singleton
BEGIN SELECT RAISE(ABORT,'immutable runtime identity'); END;
CREATE TRIGGER IF NOT EXISTS runtime_identity_no_delete BEFORE DELETE ON runtime_database
BEGIN SELECT RAISE(ABORT,'immutable runtime identity'); END;
CREATE TRIGGER IF NOT EXISTS runtime_monotonic BEFORE UPDATE ON runtime_database
WHEN NEW.incarnation<OLD.incarnation OR NEW.commit_seq<OLD.commit_seq
 OR NEW.clock_high_ms<OLD.clock_high_ms OR NEW.clock_generation<OLD.clock_generation
 OR NEW.directory_version<OLD.directory_version
 OR (NEW.directory_version=OLD.directory_version AND NEW.directory_hash IS NOT OLD.directory_hash)
BEGIN SELECT RAISE(ABORT,'runtime versions cannot regress'); END;
CREATE TRIGGER IF NOT EXISTS runtime_counter_types BEFORE UPDATE ON runtime_database
WHEN typeof(NEW.incarnation)!='integer' OR NEW.incarnation<0
 OR typeof(NEW.commit_seq)!='integer' OR NEW.commit_seq<0
 OR typeof(NEW.clock_high_ms)!='integer' OR NEW.clock_high_ms<0
 OR typeof(NEW.clock_generation)!='integer' OR NEW.clock_generation<1
 OR typeof(NEW.directory_version)!='integer' OR NEW.directory_version<0
BEGIN SELECT RAISE(ABORT,'invalid runtime counter'); END;
CREATE TRIGGER IF NOT EXISTS intent_transition BEFORE UPDATE ON runtime_intents
WHEN typeof(NEW.attempts)!='integer' OR NEW.attempts<OLD.attempts
 OR typeof(NEW.claim_incarnation)!='integer' OR NEW.claim_incarnation<0
 OR typeof(NEW.next_retry_ms)!='integer' OR NEW.next_retry_ms<OLD.next_retry_ms
 OR (NEW.state='claimed' AND (OLD.state!='pending' OR NEW.attempts!=OLD.attempts+1
   OR NEW.claim_incarnation!=(SELECT incarnation FROM runtime_database WHERE singleton=1)))
 OR (NEW.state!='claimed' AND NEW.attempts!=OLD.attempts)
 OR (NEW.state='settled' AND NEW.published!=1) OR (NEW.state!='settled' AND NEW.published!=0)
 OR (OLD.state='pending' AND NEW.state='settled')
BEGIN SELECT RAISE(ABORT,'invalid intent transition'); END;
