package sqlite

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"

// Every migration is embedded straight from its .sql file with #load, so the
// embedded copy and the on-disk copy in migrations/ are the same bytes by
// construction. Keep it that way: never transcribe a migration's SQL into a
// string literal here. run_migrations falls back to these constants whenever
// migrations_dir does not resolve -- which is what a packaged binary run
// outside the repo does -- and a hand-copied literal that drifts from its file
// silently bootstraps a fresh database onto a stale schema (BUG-14).
MIGRATION_001_FOUNDATION :: #load("migrations/001_foundation.sql", string)
MIGRATION_002_OWNER_SCOPED_CORE :: #load("migrations/002_owner_scoped_core.sql", string)

// MIGRATION_003_DEVICE_TOKENS is the embedded fallback for the token-provenance
// migration (ELDA-4). The canonical source is
// src/hub/repository/sqlite/migrations/003_device_tokens.sql.
MIGRATION_003_DEVICE_TOKENS :: #load("migrations/003_device_tokens.sql", string)

MIGRATION_004_DEFAULT_SKILL_MEMORY :: #load("migrations/004_default_skill_memory.sql", string)

MIGRATION_005_AGENT_TO_AGENT_CROSS_CHAIN_MEMORY :: #load(
	"migrations/005_agent_to_agent_cross_chain_memory.sql",
	string,
)

MIGRATION_006_LIVE_AGENTS_SKILL_MEMORY :: #load(
	"migrations/006_live_agents_skill_memory.sql",
	string,
)

MIGRATION_007_HIDE_AGENT_TO_AGENT_FROM_USER_CHAT :: #load(
	"migrations/007_hide_agent_to_agent_from_user_chat.sql",
	string,
)

MIGRATION_008_READ_INBOUND_MESSAGES_SKILL_MEMORY :: #load(
	"migrations/008_read_inbound_messages_skill_memory.sql",
	string,
)

MIGRATION_009_ARTIFACT_METADATA :: #load("migrations/009_artifact_metadata.sql", string)

MIGRATION_010_ARTIFACT_USAGE_SKILL_MEMORY :: #load(
	"migrations/010_artifact_usage_skill_memory.sql",
	string,
)

MIGRATION_011_ARTIFACT_DOWNLOAD_SKILL_MEMORY :: #load(
	"migrations/011_artifact_download_skill_memory.sql",
	string,
)

MIGRATION_012_TASK_CHAINS_V2 :: #load("migrations/012_task_chains_v2.sql", string)

MIGRATION_013_TASK_WORKFLOW_SKILL_MEMORY :: #load(
	"migrations/013_task_workflow_skill_memory.sql",
	string,
)

MIGRATION_014_TASK_WORKFLOW_SKILL_COMMENTS :: #load(
	"migrations/014_task_workflow_skill_comments.sql",
	string,
)

MIGRATION_015_MEMORY_TARGET_SCOPE :: #load("migrations/015_memory_target_scope.sql", string)

MIGRATION_018_COORDINATOR_MEMBER_BACKFILL :: #load(
	"migrations/018_coordinator_member_backfill.sql",
	string,
)

MIGRATION_017_CHAT_MESSAGE_TYPES :: #load("migrations/017_chat_message_types.sql", string)

MIGRATION_016_MEMORY_WORKFLOW_SKILL_MEMORY :: #load(
	"migrations/016_memory_workflow_skill_memory.sql",
	string,
)

MIGRATION_019_CURRENT_TASK_AND_PRIORITY :: #load(
	"migrations/019_current_task_and_priority.sql",
	string,
)

// MIGRATION_020_TITLE_TRACKING adds per-run auto-title tracking fields to
// conversations and task chains, plus a per-agent monotonic counter table used
// to mint default titles of the form "<agent-name> #<n>". The embedded fallback
// mirrors src/hub/repository/sqlite/migrations/020_title_tracking.sql.
MIGRATION_020_TITLE_TRACKING :: #load("migrations/020_title_tracking.sql", string)

// MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME adds human-readable display_name
// support to agent_instances, defaulting to "<agent-name> #<n>".
MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME :: #load(
	"migrations/021_agent_instance_display_name.sql",
	string,
)

// MIGRATION_022_SCHEDULED_PROMPTS adds the scheduled_prompts table for
// delayed and recurring prompt injection into agent instances.
MIGRATION_022_SCHEDULED_PROMPTS :: #load("migrations/022_scheduled_prompts.sql", string)

// MIGRATION_023_ACTIONS creates the actions table with recurring-schedule fields,
// replacing scheduled_prompts and migrating existing rows.
MIGRATION_023_ACTIONS :: #load("migrations/023_actions.sql", string)

// MIGRATION_024_PUSH_SUBSCRIPTIONS creates the push_subscriptions table storing
// per-user browser Web Push subscriptions (WP-STORE-1). endpoint is unique so a
// re-subscribe upserts the keys; owner_user_id is immutable via a trigger.
MIGRATION_024_PUSH_SUBSCRIPTIONS :: #load("migrations/024_push_subscriptions.sql", string)

// Mirrors src/hub/repository/sqlite/migrations/025_lookup_indexes.sql — see that
// file for why each index exists.
MIGRATION_025_LOOKUP_INDEXES :: #load("migrations/025_lookup_indexes.sql", string)

// MIGRATION_026_MEMORY_SCOPE_LISTS converts memory targeting from single scalar
// scope columns (agent_id/project_id/template_id/bridge_id) to JSON-array list
// columns (agent_ids/project_ids/template_ids/bridge_ids). An empty list ('[]')
// means "applies to all" for that dimension; a non-empty list means the value
// must be a member. It backfills each list from the prior scalar (empty scalar
// -> '[]', non-empty -> a single-element array) and then drops the scalars. The
// earlier seed migrations (004/013/016) still insert the scalar columns, which
// this migration folds into the lists — the list columns do not exist until this
// point, so the append-only ledger requires the backfill here rather than
// rewriting those historical seeds. Scope ids are safe identifier tokens
// (agt_/proj_/tmpl_/brg_), so simple JSON string quoting is sufficient.
MIGRATION_026_MEMORY_SCOPE_LISTS :: #load("migrations/026_memory_scope_lists.sql", string)

// MIGRATION_027_DEFAULT_COORDINATOR_AGENT seeds a durable 'coordinator' agent for
// every existing user that lacks one and remaps agents off the removed built-in
// 'System Reviewer' template onto the default 'tmpl_empty'. Idempotent via the
// NOT EXISTS guard + deterministic agent_id and the template WHERE clause. Kept
// byte-identical to 027_default_coordinator_agent.sql.
MIGRATION_027_DEFAULT_COORDINATOR_AGENT :: #load(
	"migrations/027_default_coordinator_agent.sql",
	string,
)

// MIGRATION_028_MEMORY_DESCRIPTION_AND_CLEANUP adds first-class description to
// memories and deletes legacy seeded system memories in favor of static skills.
MIGRATION_028_MEMORY_DESCRIPTION_AND_CLEANUP :: #load(
	"migrations/028_memory_description_and_cleanup.sql",
	string,
)

// MIGRATION_029_SEARCH_FTS_COMMENTS adds an external-content FTS5 index over
// task_comments.body so comment search is tokenized + multi-word + relevance-
// ranked (retiring the LIKE '%q%' full scan). Embedded via #load of the on-disk
// twin so the copy is byte-identical BY CONSTRUCTION (no hand-copy drift).
// Idempotent (IF NOT EXISTS + 'rebuild' backfill); run_migrations skips it (marking
// applied) when FTS5 is unavailable or the vtable already exists, so non-FTS builds
// still boot on the indexed-LIKE fallback.
MIGRATION_029_SEARCH_FTS_COMMENTS :: #load("migrations/029_search_fts_comments.sql", string)

// MIGRATION_030_SEARCH_FTS_ALL broadens the SEARCH-6 FTS5 foundation to every
// text-bearing scope (conversations/agents/agent_instances/task-chains/tasks/
// projects/artifacts/memories) as per-table external-content FTS5 vtables + sync
// triggers + idempotent backfill. It is embedded via #load of the on-disk twin so
// the embedded copy is byte-identical BY CONSTRUCTION (no hand-copy drift). Same
// boot-safe guard as 029: skipped (marked applied) when FTS5 is unavailable or the
// vtables already exist, so non-FTS builds boot on the indexed-LIKE fallback.
MIGRATION_030_SEARCH_FTS_ALL :: #load("migrations/030_search_fts_all.sql", string)

// MIGRATION_031_SEARCH_FTS_MESSAGES adds an external-content FTS5 index over
// chat_messages.body (MSG-1) so chat MESSAGE content is searchable (previously only
// conversation titles were indexed). Same wiring/guard as 029/030; the backfill
// uses the correct 'rebuild' op (the 'WHERE rowid NOT IN' guard is a no-op on
// external-content, which is why 029/030's backfill was fixed to 'rebuild' too).
MIGRATION_031_SEARCH_FTS_MESSAGES :: #load("migrations/031_search_fts_messages.sql", string)

// MIGRATION_032_AI_NATIVE_TEMPLATES seeds built-in AI-native role templates into
// the templates table: coordinator, worker, reviewer, and empty system templates.
MIGRATION_032_AI_NATIVE_TEMPLATES :: #load("migrations/032_ai_native_templates.sql", string)

// MIGRATION_033_DEFAULT_AGENTS_AND_CONVERSATION_PROJECT seeds canonical durable
// agents (coordinator, worker, reviewer) and the dedicated Conversation project for all users.
MIGRATION_033_DEFAULT_AGENTS_AND_CONVERSATION_PROJECT :: #load(
	"migrations/033_default_agents_and_conversation_project.sql",
	string,
)

// MIGRATION_034_CARDS creates the cards table, indexes, and owner-immutable trigger
// for Curator action cards (REQ-CARD-1).
MIGRATION_034_CARDS :: #load("migrations/034_cards.sql", string)

// MIGRATION_035_CURATOR_TEMPLATE seeds the built-in Curator system template
// (tmpl_curator) for activity-driven Action Cards (REQ-AGENT-1).
MIGRATION_035_CURATOR_TEMPLATE :: #load("migrations/035_curator_template.sql", string)

// MIGRATION_036_ACTION_TARGETS adds target_agent_id, target_bridge_id, target_provider,
// target_model, target_project_id to actions table (REQ-SCHED-1).
MIGRATION_036_ACTION_TARGETS :: #load("migrations/036_action_targets.sql", string)

// MIGRATION_037_PROJECT_STATE adds the soft-archive `state` column to projects
// (mirrors the agents `state` column). Default 'active'; archiving is reversible.
MIGRATION_037_PROJECT_STATE :: #load("migrations/037_project_state.sql", string)

// MIGRATION_038_ACTION_INSTANCE_STRATEGY adds instance_strategy + last_spawned_instance_id
// to actions (REQ-SCHED-2). Defaults keep existing rows on the legacy "reuse" behavior.
MIGRATION_038_ACTION_INSTANCE_STRATEGY :: #load(
	"migrations/038_action_instance_strategy.sql",
	string,
)

// MIGRATION_039_SHELL_JOBS adds the shell_jobs table tracking bridge-executed shell
// commands (REQ-15). Status/metadata only — command output lives on the bridge host
// and is never stored in the hub.
MIGRATION_039_SHELL_JOBS :: #load("migrations/039_shell_jobs.sql", string)

// MIGRATION_040_ARTIFACT_LIST_INDEXES creates composite covering indexes on the
// artifacts table for fast filtering and pagination (REQ-ARTIFACT-DB-INDEXES).
MIGRATION_040_ARTIFACT_LIST_INDEXES :: #load("migrations/040_artifact_list_indexes.sql", string)

// MIGRATION_041_SHELL_SESSIONS creates the shell_sessions table replacing
// shell_jobs as the unified session concept (REQ-SH-CONTRACT §1).
MIGRATION_041_SHELL_SESSIONS :: #load("migrations/041_shell_sessions.sql", string)

// MIGRATION_042_PINNED_TASK_CHAINS adds is_pinned and pinned_at to task_chains.
MIGRATION_042_PINNED_TASK_CHAINS :: #load("migrations/042_pinned_task_chains.sql", string)

// MIGRATION_043_EXPERIMENTS creates the experiments table for Hub-persisted
// feature flags (REQ-EXP-1). One row per (owner_user_id, key) pair.
MIGRATION_043_EXPERIMENTS :: #load("migrations/043_experiments.sql", string)

// MIGRATION_044_LSP_SERVERS creates the lsp_server_configs table for
// Hub-persisted LSP server configurations (REQ-LSP-CFG-1). Unique on
// (owner_user_id, bridge_id, language, dir_prefix).
MIGRATION_044_LSP_SERVERS :: #load("migrations/044_lsp_servers.sql", string)

// MIGRATION_043_TASK_CHAIN_DIRECTORIES creates the task_chain_directories table
// storing extra relevant directories for a task chain (REQ-BE-TASK-CHAIN-RELEVANT-DIRECTORIES).
MIGRATION_043_TASK_CHAIN_DIRECTORIES :: #load("migrations/043_task_chain_directories.sql", string)

// MIGRATION_044_ISSUES creates issues, issue_comments, and issue_votes tables (REQ-ISSUES-BACKEND-SCHEMA-SERVICE).
MIGRATION_044_ISSUES :: #load("migrations/044_issues.sql", string)

// MIGRATION_045_LSP_SERVER_PATTERNS adds dir_pattern to lsp_server_configs (REQ-LSP-DIR-PAT-1).
MIGRATION_045_LSP_SERVER_PATTERNS :: #load("migrations/045_lsp_server_patterns.sql", string)

// MIGRATION_046_TASK_CHAIN_FLEETS creates task_chain_fleets table for role-based
// agent instance pooling (REQ-FLEET-SCHEMA-1).
MIGRATION_046_TASK_CHAIN_FLEETS :: #load("migrations/046_task_chain_fleets.sql", string)


// MIGRATION_048_TASK_SUBSCRIPTIONS creates task_subscriptions table for
// reactive status event fanout (REQ-TCC-2).
MIGRATION_048_TASK_SUBSCRIPTIONS :: #load("migrations/048_task_subscriptions.sql", string)

// MIGRATION_048_SHELL_SESSIONS_KIND_AND_KEY collapses shell_sessions.kind to
// run|shell|server (dropping the dead 'agent' rows) and rebuilds the table with
// PRIMARY KEY (bridge_id, session_id) so one bridge cannot overwrite another's
// row (REQ-SHELL-1 §1, §7).
MIGRATION_048_SHELL_SESSIONS_KIND_AND_KEY :: #load(
	"migrations/048_shell_sessions_kind_and_key.sql",
	string,
)

// MIGRATION_049_SHELL_SESSIONS_BACKGROUND_AND_CONVERSATION adds the two columns
// explicit backgrounding needs on the row: `background` (REQ-SHELL-2 deletes the
// implicit 15s rule, so foreground/background becomes a stored property rather
// than an elapsed-time accident) and `conversation_id` (the TRIGGERING
// conversation, which REQ-SHELL-5 scopes the completion marker to and REQ-SHELL-6
// filters on).
MIGRATION_049_SHELL_SESSIONS_BACKGROUND_AND_CONVERSATION :: #load(
	"migrations/049_shell_sessions_background_and_conversation.sql",
	string,
)

// MIGRATION_050_SHELL_SESSIONS_KILL_INTENT adds kill_requested_at (REQ-SHELL-3):
// the durable record that a kill was ACCEPTED for a session. Before it, a kill
// requested while the bridge was offline failed and persisted nothing, so nothing
// re-issued it on reconnect and the process ran forever. With it the accept
// succeeds, the intent survives the disconnect, and the hub replays outstanding
// intents when the bridge's WS comes back.
MIGRATION_050_SHELL_SESSIONS_KILL_INTENT :: #load(
	"migrations/050_shell_sessions_kill_intent.sql",
	string,
)

// MIGRATION_051_SHELL_SESSIONS_RUN_SEQ adds run_seq (REQ-SHELL-4): which RUN of a
// session an exit report is about. A durable exit outbox can deliver an exit after
// the session has been restarted under the same session_id, and without this the
// hub would mark a live session terminal on a stale exit. See the migration file.
MIGRATION_051_SHELL_SESSIONS_RUN_SEQ :: #load("migrations/051_shell_sessions_run_seq.sql", string)

// MIGRATION_052_DROP_SHELL_JOBS drops the shell_jobs table (REQ-SHELL-7). The whole
// shell_jobs stack — domain type, service, repository, routes and UI — is deleted in
// the same commit; 039 created the table, 041 replaced the CONCEPT with
// shell_sessions but left the table behind, and this removes it. Metadata only, no
// output column, so nothing recoverable is lost. See the migration file.
MIGRATION_052_DROP_SHELL_JOBS :: #load("migrations/052_drop_shell_jobs.sql", string)

// MIGRATION_053_BRIDGE_VERSION_AND_UPDATES adds version, commit_sha, build_timestamp, update_status, and update_error to bridges (REQ-BUPD-1).
MIGRATION_053_BRIDGE_VERSION_AND_UPDATES :: #load(
	"migrations/053_bridge_version_and_updates.sql",
	string,
)

// MIGRATION_054_BRIDGE_TELEMETRY adds telemetry_enabled to bridges (REQ-TEL-1).
MIGRATION_054_BRIDGE_TELEMETRY :: #load("migrations/054_bridge_telemetry.sql", string)

// MIGRATION_055_MEMORY_ACTION_EXPIRY adds expires_at to memories and backfills
// pending memories and cards to expire 24h after creation (REQ-EXPIRY-SCHEMA-1).
MIGRATION_055_MEMORY_ACTION_EXPIRY :: #load("migrations/055_memory_action_expiry.sql", string)

// MIGRATION_056_BRIDGE_VAULT_STATUS adds vault_status to bridges (REQ-BVS-1): the
// bridge's self-reported "unlocked"/"locked", defaulting to '' for a bridge
// that has never reported one. UX indicator only; nothing gates on it.
MIGRATION_056_BRIDGE_VAULT_STATUS :: #load("migrations/056_bridge_vault_status.sql", string)

// MIGRATION_057_BRIDGE_TOKENS creates bridge_tokens, the expiring `hba_`/`hbf_`
// credential pair plus the rotation lineage that makes refresh-token reuse
// detectable (REQ-IMPL-3 / design §7.4). See the .sql file for why the lineage
// needs its own table rather than more columns on `bridges`.
MIGRATION_057_BRIDGE_TOKENS :: #load("migrations/057_bridge_tokens.sql", string)

// MIGRATION_058_PROVIDER_CATALOG seeds the Hub-owned recipes, literal model ids,
// catalog etag, and locally served icon bytes (REQ-PROVIDER-CATALOG-1).
MIGRATION_058_PROVIDER_CATALOG :: #load("migrations/058_provider_catalog.sql", string)

MIGRATION_059_BRIDGE_PROVIDER_STATE :: #load("migrations/059_bridge_provider_state.sql", string)
MIGRATION_060_EXPLICIT_PROVIDER_MODELS :: #load(
	"migrations/060_explicit_provider_models.sql",
	string,
)
MIGRATION_061_CODEX_LAUNCH_RECIPE :: #load("migrations/061_codex_launch_recipe.sql", string)
MIGRATION_062_CLAUDE_STARTUP_DETECTION :: #load(
	"migrations/062_claude_startup_detection.sql",
	string,
)
MIGRATION_063_CLAUDE_LOGIN_METHOD_DETECTION :: #load(
	"migrations/063_claude_login_method_detection.sql",
	string,
)
MIGRATION_064_CODEX_TRUST_DETECTION :: #load(
	"migrations/064_codex_trust_detection.sql",
	string,
)
MIGRATION_065_ANTIGRAVITY_LAUNCH_RECIPE :: #load(
	"migrations/065_antigravity_launch_recipe.sql",
	string,
)
MIGRATION_066_ANTIGRAVITY_TRUST_DETECTION :: #load(
	"migrations/066_antigravity_trust_detection.sql",
	string,
)
MIGRATION_067_CODEX_SANDBOX_AND_MODELS :: #load(
	"migrations/067_codex_sandbox_and_models.sql",
	string,
)
MIGRATION_068_REPAIR_PROVIDER_CATALOG_ETAG :: #load(
	"migrations/068_repair_provider_catalog_etag.sql",
	string,
)

MIGRATION_069_ACCOUNT_BILLING :: #load("migrations/069_account_billing.sql", string)

MIGRATION_070_FREE_ONE_BRIDGE :: #load("migrations/070_free_one_bridge.sql", string)

MIGRATION_072_INSTANCE_RECONFIGURATION :: #load("migrations/072_instance_reconfiguration.sql", string)

MIGRATION_071_CODEX_FOLDER_ACCESS_TRUST :: #load("migrations/071_codex_folder_access_trust.sql", string)
MIGRATION_072_BRIDGE_UPDATE_PROGRESS :: #load("migrations/072_bridge_update_progress.sql", string)

MIGRATION_073_CLAUDE_CURRENT_MODELS :: #load("migrations/073_claude_current_models.sql", string)

MIGRATION_074_RECONFIGURATION_RECOVERY_STOP :: #load("migrations/074_reconfiguration_recovery_stop.sql", string)

MIGRATION_076_FLEET_BRIDGE_MODELS :: #load("migrations/076_fleet_bridge_models.sql", string)

MIGRATION_077_SOLOIST_AGENT :: #load("migrations/077_soloist_agent.sql", string)

MIGRATION_078_DROP_STALE_BUILTIN_TEMPLATE_ROWS :: #load("migrations/078_drop_stale_builtin_template_rows.sql", string)

MIGRATION_079_REPAIR_PROVIDER_CATALOG_ETAG :: #load("migrations/079_repair_provider_catalog_etag.sql", string)

MIGRATION_080_COPILOT_LAUNCH_RECIPE :: #load("migrations/080_copilot_launch_recipe.sql", string)

MIGRATION_081_ANTIGRAVITY_MODELS :: #load("migrations/081_antigravity_models.sql", string)

MIGRATION_082_PI_PROVIDER :: #load("migrations/082_pi_provider.sql", string)

MIGRATION_083_TASK_CHAIN_SEARCH_FEED :: #load("migrations/083_task_chain_search_feed.sql", string)

MIGRATION_084_BRIDGE_LOG_EVENTS :: #load("migrations/084_bridge_log_events.sql", string)

MIGRATION_085_AGENT_INSTANCE_LAST_ERROR :: #load("migrations/085_agent_instance_last_error.sql", string)

MIGRATION_086_CLAUDE_BYPASS_PERMISSIONS_DETECTION :: #load("migrations/086_claude_bypass_permissions_detection.sql", string)

MIGRATION_087_ATTENTION_CARDS :: #load("migrations/087_attention_cards.sql", string)
// MIGRATION_088_BRIDGE_ENROLLMENT_PENDING adds enrollment_pending_until
// to bridges (REQ-EA-1): a bridge is pending until its vault key is delivered.
MIGRATION_088_BRIDGE_ENROLLMENT_PENDING :: #load("migrations/088_bridge_enrollment_pending.sql", string)
// MIGRATION_089_MEMORY_PROPOSER records who proposed a memory and on which
// chain (attention deck memory cards).
MIGRATION_089_MEMORY_PROPOSER :: #load("migrations/089_memory_proposer.sql", string)

// MIGRATION_090_TASK_V2 is the Task System v2 cutover: the event-sourced engine
// tables (task_events/attempts/facets/leases/reviews, chain_summaries,
// workflow_definitions), the new task/chain/fleet columns, and the one-shot
// legacy status → state / reviewer-ref → fleet-role data migration. The legacy
// columns and tables are dropped afterwards by upgrade_task_v2_schema.
MIGRATION_090_TASK_V2 :: #load("migrations/090_task_v2.sql", string)

// 091: agent_instances.stopped_by — a user stop sticks (Task System v2 F4).
MIGRATION_091_AGENT_INSTANCE_STOPPED_BY :: #load("migrations/091_agent_instance_stopped_by.sql", string)

// 092: passwordless vault device directory (vault_directories, vault_devices,
// vault_epochs, vault_wrapped_keyrings). Idempotent; re-run by upgrade_vault_directory_schema.
MIGRATION_092_VAULT_DEVICE_DIRECTORY :: #load("migrations/092_vault_device_directory.sql", string)

// 093: drops the pre-log vault tables (no backward compatibility; dev data wiped).
// upgrade_vault_directory_schema re-creates them from 092 (signed-log shape).
MIGRATION_093_VAULT_SIGNED_LOG :: #load("migrations/093_vault_signed_log.sql", string)

// 094: hub-blind pairing; drops the vault tables (no backward compatibility) and
// upgrade_vault_directory_schema re-creates them from 092 (pair_lookup, no user_code).
MIGRATION_094_VAULT_HUB_BLIND_PAIRING :: #load("migrations/094_vault_hub_blind_pairing.sql", string)
// MIGRATION_096_DROP_PASSWORD_VAULT removes the password-era vault table (the
// passwordless vault replaced it; no backward compatibility). Migration
// 047 that created it is gone from the order and the tree.
MIGRATION_096_DROP_PASSWORD_VAULT :: #load("migrations/096_drop_password_vault.sql", string)

// 095: pairing stretch (pair_salt on pending devices); drops the vault tables (no
// backward compatibility) and upgrade_vault_directory_schema re-creates them from 092.
MIGRATION_095_VAULT_PAIRING_STRETCH :: #load("migrations/095_vault_pairing_stretch.sql", string)

MIGRATION_075_CONVERSATION_LAUNCH_PREFERENCES :: #load("migrations/075_conversation_launch_preferences.sql", string)

MIGRATION_097_WORKFLOW_RUNS :: #load("migrations/097_workflow_runs.sql", string)

MIGRATION_098_MIXED_WORK_GRAPH :: #load("migrations/098_mixed_work_graph.sql", string)

MIGRATION_099_MIXED_WORK_EXECUTION :: #load("migrations/099_mixed_work_execution.sql", string)

// 100: the pending device's declared pairing hub origin (vault_devices.pair_hub_origin).
// An ALTER (keeps existing vault data); fresh databases get the column from 092.
MIGRATION_100_VAULT_PAIR_HUB_ORIGIN :: #load("migrations/100_vault_pair_hub_origin.sql", string)

// 101: Codex/Pi GPT-6 models (codex-cli 0.162); retires the GPT-5.6 rows.
MIGRATION_101_CODEX_GPT6_MODELS :: #load("migrations/101_codex_gpt6_models.sql", string)

// 102: drops the never-used bridge_enrollments table from 002 and its owner trigger.
MIGRATION_102_DROP_BRIDGE_ENROLLMENTS :: #load("migrations/102_drop_bridge_enrollments.sql", string)
MIGRATION_103_PLAN_ENFORCEMENT :: #load("migrations/103_plan_enforcement.sql", string)

// 104: chat FTS update triggers fire only when indexed text changes (read metadata
// no longer rewrites the FTS rows). Skipped unless both chat vtables exist.
MIGRATION_104_GUARD_CHAT_FTS_UPDATES :: #load("migrations/104_guard_chat_fts_updates.sql", string)
// 105: live-by-kind, shell retention and dependency-by-chain indexes (REQ-INDEX).
// Plain CREATE INDEX IF NOT EXISTS, so a re-apply is a no-op.
MIGRATION_105_FULL_SCAN_INDEXES :: #load("migrations/105_full_scan_indexes.sql", string)

// 106: provider extension event log and per-instance extension identity.
MIGRATION_106_AGENT_EXTENSION_EVENTS :: #load("migrations/106_agent_extension_events.sql", string)

// 107: provider_catalog.extension descriptor and the measured extension state
// in bridge_provider_status (REQ-EXT-DET-1).
MIGRATION_107_PROVIDER_EXTENSION :: #load("migrations/107_provider_extension.sql", string)

// 108: agents.permission_mode ('yolo' default | 'ask'); 'ask' launches without
// the catalog yolo_args (REQ-EXT-PERM-2).
MIGRATION_108_AGENT_PERMISSION_MODE :: #load("migrations/108_agent_permission_mode.sql", string)

// 109: agent_instances.permission_mode ('' inherits the agent | 'yolo' | 'ask')
// and the reconfiguration commit trigger applying $.destination.permission_mode.
MIGRATION_109_INSTANCE_PERMISSION_MODE :: #load("migrations/109_instance_permission_mode.sql", string)

// 110: provider_catalog.ask_args, appended instead of yolo_args when the
// effective permission_mode is 'ask' (claude: --permission-mode default).
MIGRATION_110_PROVIDER_ASK_ARGS :: #load("migrations/110_provider_ask_args.sql", string)

MIGRATION_111_EXTENSION_STARTUP_LOADING :: #load("migrations/111_extension_startup_loading.sql", string)
MIGRATION_112_CODEX_EXTENSION :: #load("migrations/112_codex_extension.sql", string)
MIGRATION_113_ANTIGRAVITY_EXTENSION :: #load("migrations/113_antigravity_extension.sql", string)
MIGRATION_114_EXTENSION_VERSION_SYNC :: #load("migrations/114_extension_version_sync.sql", string)
MIGRATION_115_PROVIDER_EXTENSION_COMMANDS :: #load("migrations/115_provider_extension_commands.sql", string)

MIGRATION_116_EXTENSION_VERSION_SYNC :: #load("migrations/116_extension_version_sync_0_4_33.sql", string)

MIGRATION_117_EXTENSION_VERSION_SYNC :: #load("migrations/117_extension_version_sync_0_4_34.sql", string)

MIGRATION_118_EXTENSION_VERSION_SYNC :: #load("migrations/118_extension_version_sync_0_4_35.sql", string)

MIGRATION_119_EXTENSION_VERSION_SYNC :: #load("migrations/119_extension_version_sync_0_4_36.sql", string)

MIGRATION_120_EXTENSION_VERSION_SYNC :: #load("migrations/120_extension_version_sync_0_4_37.sql", string)

MIGRATION_121_EXTENSION_VERSION_SYNC :: #load("migrations/121_extension_version_sync_0_4_38.sql", string)
MIGRATION_126_ACTION_SCHEDULE_REVISION :: #load("migrations/126_action_schedule_revision.sql", string)
MIGRATION_125_TRANSIENT_EXTENSION_SIGNALS :: #load("migrations/125_transient_extension_signals.sql", string)

MIGRATION_122_EXTENSION_VERSION_SYNC :: #load("migrations/122_extension_version_sync_0_4_39.sql", string)

MIGRATION_123_EXTENSION_VERSION_SYNC :: #load("migrations/123_extension_version_sync_0_4_40.sql", string)

MIGRATION_124_EXTENSION_VERSION_SYNC :: #load("migrations/124_extension_version_sync_0_4_41.sql", string)

MIGRATION_127_EXTENSION_VERSION_SYNC :: #load("migrations/127_extension_version_sync_0_4_42.sql", string)
MIGRATION_128_EXTENSION_VERSION_SYNC :: #load("migrations/128_extension_version_sync_0_4_43.sql", string)

MIGRATION_129_REMOVE_TASK_VERIFY :: #load("migrations/129_remove_task_verify.sql", string)
MIGRATION_130_EXTENSION_VERSION_SYNC :: #load("migrations/130_extension_version_sync_0_4_44.sql", string)

MIGRATION_131_FLEET_PAUSE :: #load("migrations/131_fleet_pause.sql", string)

MIGRATION_132_EXTENSION_VERSION_SYNC :: #load("migrations/132_extension_version_sync_0_4_45.sql", string)

MIGRATION_133_EXTENSION_VERSION_SYNC :: #load("migrations/133_extension_version_sync_0_4_46.sql", string)
// Native-app OIDC identities and durable v2 device-proof nonces. It lives in its
// own namespace: deployed native hubs recorded it as 113_oidc_identities.sql,
// 115_oidc_identities.sql or native_001_oidc_identities.sql, and upstream later
// reused 113/115 for unrelated files. See the alias handling in run_migrations.
MIGRATION_NATIVE_001_OIDC_IDENTITIES :: #load("migrations/native_001_oidc_identities.sql", string)
MIGRATION_134_USER_SESSIONS :: #load("migrations/134_user_sessions.sql", string)
MIGRATION_135_CLEAR_USER_API_TOKENS :: #load("migrations/135_clear_user_api_tokens.sql", string)

// Native identities have their own namespace; upstream numbers remain untouched.
MIGRATION_136_EXTENSION_VERSION_SYNC :: #load("migrations/136_extension_version_sync_0_5_0.sql", string)

MIGRATION_137_EXTENSION_VERSION_SYNC :: #load("migrations/137_extension_version_sync_0_5_1.sql", string)

// MIGRATION_138: bridge_tokens.rotation_request_hash (refresh retry identity).
MIGRATION_138_BRIDGE_TOKEN_ROTATION_REQUEST :: #load("migrations/138_bridge_token_rotation_request.sql", string)

// MIGRATION_139: bridge_tokens.first_used_at / regrant_claim (retry grace hardening).
MIGRATION_139_BRIDGE_TOKEN_DELIVERY_AND_REGRANT :: #load("migrations/139_bridge_token_delivery_and_regrant.sql", string)

// MIGRATION_140: unique (family_id, kind, generation) on bridge_tokens, guarded.
MIGRATION_140_BRIDGE_TOKENS_UNIQUE_GENERATION :: #load("migrations/140_bridge_tokens_unique_generation.sql", string)

MIGRATION_141_EXTENSION_VERSION_SYNC :: #load("migrations/141_extension_version_sync_0_5_2.sql", string)

MIGRATION_142_EXTENSION_VERSION_SYNC :: #load("migrations/142_extension_version_sync_0_5_3.sql", string)

MIGRATION_143_EXTENSION_VERSION_SYNC :: #load("migrations/143_extension_version_sync_0_5_4.sql", string)

MIGRATION_144_EXTENSION_VERSION_SYNC :: #load("migrations/144_extension_version_sync_0_5_5.sql", string)

MIGRATION_145_EXTENSION_VERSION_SYNC :: #load("migrations/145_extension_version_sync_0_5_6.sql", string)

MIGRATION_146_EXTENSION_VERSION_SYNC :: #load("migrations/146_extension_version_sync_0_5_7.sql", string)

MIGRATION_147_EXTENSION_VERSION_SYNC :: #load("migrations/147_extension_version_sync_0_5_8.sql", string)

MIGRATION_148_BRIDGE_PROVIDER_MODELS :: #load("migrations/148_bridge_provider_models.sql", string)

MIGRATION_149_EXTENSION_VERSION_SYNC :: #load("migrations/149_extension_version_sync_0_5_9.sql", string)

MIGRATION_150_EXTENSION_VERSION_SYNC :: #load("migrations/150_extension_version_sync_0_5_10.sql", string)

MIGRATION_151_EXTENSION_VERSION_SYNC :: #load("migrations/151_extension_version_sync_0_5_11.sql", string)

MIGRATION_152_EXTENSION_VERSION_SYNC :: #load("migrations/152_extension_version_sync_0_5_12.sql", string)

MIGRATION_153_EXTENSION_VERSION_SYNC :: #load("migrations/153_extension_version_sync_0_5_13.sql", string)

MIGRATION_154_EXTENSION_VERSION_SYNC :: #load("migrations/154_extension_version_sync_0_5_14.sql", string)

MIGRATION_155_EXTENSION_VERSION_SYNC :: #load("migrations/155_extension_version_sync_0_5_15.sql", string)

MIGRATION_156_EXTENSION_VERSION_SYNC :: #load("migrations/156_extension_version_sync_0_5_16.sql", string)

MIGRATION_157_EXTENSION_VERSION_SYNC :: #load("migrations/157_extension_version_sync_0_5_17.sql", string)

MIGRATION_158_EXTENSION_VERSION_SYNC :: #load("migrations/158_extension_version_sync_0_5_18.sql", string)

MIGRATION_159_EXTENSION_VERSION_SYNC :: #load("migrations/159_extension_version_sync_0_5_19.sql", string)

MIGRATION_160_EXTENSION_VERSION_SYNC :: #load("migrations/160_extension_version_sync_0_5_20.sql", string)

MIGRATION_161_EXTENSION_VERSION_SYNC :: #load("migrations/161_extension_version_sync_0_5_21.sql", string)

MIGRATION_162_EXTENSION_VERSION_SYNC :: #load("migrations/162_extension_version_sync_0_5_22.sql", string)

MIGRATION_163_EXTENSION_VERSION_SYNC :: #load("migrations/163_extension_version_sync_0_5_23.sql", string)

MIGRATION_164_EXTENSION_VERSION_SYNC :: #load("migrations/164_extension_version_sync_0_5_24.sql", string)

MIGRATION_165_PROVIDER_EXTENSION_UNINSTALL :: #load("migrations/165_provider_extension_uninstall.sql", string)

MIGRATION_166_EXTENSION_VERSION_SYNC :: #load("migrations/166_extension_version_sync_0_5_25.sql", string)

MIGRATION_167_EXTENSION_VERSION_SYNC :: #load("migrations/167_extension_version_sync_0_5_26.sql", string)

MIGRATION_168_EXTENSION_VERSION_SYNC :: #load("migrations/168_extension_version_sync_0_5_27.sql", string)

MIGRATION_169_PROVIDER_PROFILES :: #load("migrations/169_provider_profiles.sql", string)

MIGRATION_170_EXTENSION_VERSION_SYNC :: #load("migrations/170_extension_version_sync_0_5_28.sql", string)

MIGRATION_171_EXTENSION_VERSION_SYNC :: #load("migrations/171_extension_version_sync_0_5_29.sql", string)

MIGRATION_172_EXTENSION_VERSION_SYNC :: #load("migrations/172_extension_version_sync_0_5_30.sql", string)

MIGRATION_173_EXTENSION_VERSION_SYNC :: #load("migrations/173_extension_version_sync_0_5_31.sql", string)
MIGRATION_175_MCP :: #load("migrations/175_mcp_delegated_credentials.sql", string)
MIGRATION_176_MCP_WRAPS :: #load("migrations/176_mcp_epoch_wraps.sql", string)

MIGRATION_174_EXTENSION_VERSION_SYNC :: #load("migrations/174_extension_version_sync_0_5_32.sql", string)

MIGRATION_178_BRIDGE_SUNSET_RECEIPTS :: #load("migrations/178_bridge_sunset_receipts.sql", string)
MIGRATION_179_MCP_MUTATION_RECEIPTS :: #load("migrations/179_mcp_mutation_receipts.sql", string)
MIGRATION_180_MCP_TASK_CONTRACT :: #load("migrations/180_mcp_task_contract.sql", string)
MIGRATION_181_MCP_RUNTIME_INTENTS :: #load("migrations/181_mcp_runtime_intents.sql", string)
MIGRATION_182_MCP_RESOURCE_PAGES :: #load("migrations/182_mcp_resource_pages.sql", string)

MIGRATION_177_EXTENSION_VERSION_SYNC :: #load("migrations/177_extension_version_sync_0_5_33.sql", string)

MIGRATION_183_MCP_ARTIFACT_PAGES :: #load("migrations/183_mcp_artifact_pages.sql", string)

MIGRATION_184_EXTENSION_VERSION_SYNC :: #load("migrations/184_extension_version_sync_0_5_34.sql", string)

MIGRATION_185_EXTENSION_VERSION_SYNC :: #load("migrations/185_extension_version_sync_0_5_35.sql", string)

MIGRATION_186_EXTENSION_VERSION_SYNC :: #load("migrations/186_extension_version_sync_0_5_36.sql", string)

MIGRATION_187_EXTENSION_VERSION_SYNC :: #load("migrations/187_extension_version_sync_0_5_37.sql", string)

MIGRATION_188_EXTENSION_VERSION_SYNC :: #load("migrations/188_extension_version_sync_0_5_38.sql", string)

MIGRATION_189_EXTENSION_VERSION_SYNC :: #load("migrations/189_extension_version_sync_0_5_39.sql", string)

MIGRATION_190_EXTENSION_VERSION_SYNC :: #load("migrations/190_extension_version_sync_0_5_40.sql", string)

MIGRATION_191_EXTENSION_VERSION_SYNC :: #load("migrations/191_extension_version_sync_0_5_41.sql", string)

MIGRATION_192_EXTENSION_VERSION_SYNC :: #load("migrations/192_extension_version_sync_0_5_42.sql", string)

MIGRATION_193_EXTENSION_VERSION_SYNC :: #load("migrations/193_extension_version_sync_0_5_43.sql", string)

MIGRATION_194_EXTENSION_VERSION_SYNC :: #load("migrations/194_extension_version_sync_0_5_44.sql", string)

MIGRATION_195_EXTENSION_VERSION_SYNC :: #load("migrations/195_extension_version_sync_0_5_45.sql", string)

MIGRATION_203_DURABLE_TASK_CLAIMS :: #load("migrations/203_durable_task_claims.sql", string)
MIGRATION_196_EXTENSION_VERSION_SYNC :: #load("migrations/196_extension_version_sync_0_5_46.sql", string)

MIGRATION_197_AGENT_TOKEN_TOTALS :: #load("migrations/197_agent_token_totals.sql", string)
MIGRATION_198_EXTENSION_USAGE_CAPABILITY :: #load("migrations/198_extension_usage_capability.sql", string)

MIGRATION_199_EXTENSION_VERSION_SYNC :: #load("migrations/199_extension_version_sync_0_5_47.sql", string)

MIGRATION_200_EXTENSION_VERSION_SYNC :: #load("migrations/200_extension_version_sync_0_5_48.sql", string)

MIGRATION_201_EXTENSION_VERSION_SYNC :: #load("migrations/201_extension_version_sync_0_5_49.sql", string)

MIGRATION_202_EXTENSION_VERSION_SYNC :: #load("migrations/202_extension_version_sync_0_5_50.sql", string)

MIGRATION_204_EXTENSION_VERSION_SYNC :: #load("migrations/204_extension_version_sync_0_5_51_durable_1.sql", string)

MIGRATION_205_EXTENSION_VERSION_SYNC :: #load("migrations/205_extension_version_sync_0_5_51.sql", string)

MIGRATION_206_EXTENSION_VERSION_SYNC :: #load("migrations/206_extension_version_sync_0_5_52.sql", string)

MIGRATION_207_EXTENSION_VERSION_SYNC :: #load("migrations/207_extension_version_sync_0_5_53.sql", string)

MIGRATION_208_EXTENSION_VERSION_SYNC :: #load("migrations/208_extension_version_sync_0_5_54.sql", string)

MIGRATION_209_EXTENSION_VERSION_SYNC :: #load("migrations/209_extension_version_sync_0_5_55.sql", string)

MIGRATION_210_EXTENSION_VERSION_SYNC :: #load("migrations/210_extension_version_sync_0_5_56.sql", string)

MIGRATION_211_PROVIDER_TRANSPORT :: #load("migrations/211_provider_transport.sql", string)
MIGRATION_212_EXTENSION_VERSION_SYNC :: #load("migrations/212_extension_version_sync_0_5_57.sql", string)

MIGRATION_213_BOTS :: #load("migrations/213_bots.sql", string)
MIGRATION_214_AGENT_WRITES :: #load("migrations/214_agent_writes.sql", string)
MIGRATION_215_BOTS_WHATSAPP :: #load("migrations/215_bots_whatsapp.sql", string)
MIGRATION_216_BOTS_MEDIA :: #load("migrations/216_bots_media.sql", string)

MIGRATION_217_EXTENSION_VERSION_SYNC :: #load("migrations/217_extension_version_sync_0_5_58.sql", string)

MIGRATION_218_ACP_ADAPTER_INSTALL :: #load("migrations/218_acp_adapter_install.sql", string)

MIGRATION_219_EXTENSION_VERSION_SYNC :: #load("migrations/219_extension_version_sync_0_5_59.sql", string)

MIGRATION_220_EXTENSION_VERSION_SYNC :: #load("migrations/220_extension_version_sync_0_5_60.sql", string)

MIGRATION_221_EXTENSION_VERSION_SYNC :: #load("migrations/221_extension_version_sync_0_5_61.sql", string)

MIGRATION_222_EXTENSION_VERSION_SYNC :: #load("migrations/222_extension_version_sync_0_5_62.sql", string)
MIGRATION_PIPELINE_002_READ_ACK :: #load("migrations/pipeline_002_read_ack.sql", string)
MIGRATION_PIPELINE_001_DELIVERIES :: #load("migrations/pipeline_001_deliveries.sql", string)
MIGRATION_EVENTS_001_OUTBOX :: #load("migrations/events_001_outbox.sql", string)

MIGRATION_EVENTS_005_DELIVERY_RETENTION :: #load("migrations/events_005_delivery_retention.sql", string)
MIGRATION_EVENTS_006_INSTANCE_SUBSCRIPTIONS :: #load("migrations/events_006_instance_subscriptions.sql", string)
MIGRATION_EVENTS_008_STATE_HEADS :: #load("migrations/events_008_state_heads.sql", string)
MIGRATION_EVENTS_007_ENTITY_VERSIONS :: #load("migrations/events_007_entity_versions.sql", string)
MIGRATION_EVENTS_004_DELIVERY :: #load("migrations/events_004_delivery.sql", string)
MIGRATION_EVENTS_003_SUBSCRIPTIONS :: #load("migrations/events_003_subscriptions.sql", string)

MIGRATION_EVENTS_002_TOPICS :: #load("migrations/events_002_topics.sql", string)

MIGRATION_223_EXTENSION_VERSION_SYNC :: #load("migrations/223_extension_version_sync_0_5_63.sql", string)
MIGRATION_BOTS_WEB_004_ACTIVATION :: #load("migrations/bots_web_004_activation.sql", string)
MIGRATION_BOTS_WEB_003_ACTION_REFS :: #load("migrations/bots_web_003_action_refs.sql", string)
MIGRATION_BOTS_WEB_002_ATTACHMENTS :: #load("migrations/bots_web_002_attachments.sql", string)
MIGRATION_BOTS_WEB_001_CHANNEL :: #load("migrations/bots_web_001_channel.sql", string)

MIGRATION_WHATSAPP_001_INVITE_ONLY :: #load("migrations/whatsapp_001_invite_only.sql", string)
// Coordinator idle-stop timers: agent_instances.user_activity_at.
MIGRATION_COORDINATOR_IDLE_001_USER_ACTIVITY :: #load("migrations/coordinator_idle_001_user_activity.sql", string)
// Hub stop reasons surfaced to the UI: agent_instances.stop_reason.
MIGRATION_COORDINATOR_IDLE_002_STOP_REASON :: #load("migrations/coordinator_idle_002_stop_reason.sql", string)

MIGRATION_224_COPILOT_ACP_TRANSPORT :: #load("migrations/224_copilot_acp_transport.sql", string)

MIGRATION_225_EXTENSION_VERSION_SYNC :: #load("migrations/225_extension_version_sync_0_5_64.sql", string)

MIGRATION_226_EXTENSION_VERSION_SYNC :: #load("migrations/226_extension_version_sync_0_5_65.sql", string)

MIGRATION_227_EXTENSION_VERSION_SYNC :: #load("migrations/227_extension_version_sync_0_5_66.sql", string)

MIGRATION_228_EXTENSION_VERSION_SYNC :: #load("migrations/228_extension_version_sync_0_5_67.sql", string)

MIGRATION_229_EXTENSION_VERSION_SYNC :: #load("migrations/229_extension_version_sync_0_5_68.sql", string)

MIGRATION_230_EXTENSION_VERSION_SYNC :: #load("migrations/230_extension_version_sync_0_5_69.sql", string)

MIGRATION_231_EXTENSION_VERSION_SYNC :: #load("migrations/231_extension_version_sync_0_5_70.sql", string)
MIGRATION_232_KIRO_ACP_PROVIDER :: #load("migrations/232_kiro_acp_provider.sql", string)

MIGRATION_233_EXTENSION_VERSION_SYNC :: #load("migrations/233_extension_version_sync_0_5_71.sql", string)

MIGRATION_234_CODEX_ACP_TRANSPORT :: #load("migrations/234_codex_acp_transport.sql", string)

MIGRATION_235_EXTENSION_VERSION_SYNC :: #load("migrations/235_extension_version_sync_0_5_72.sql", string)

MIGRATION_236_EXTENSION_VERSION_SYNC :: #load("migrations/236_extension_version_sync_0_5_73.sql", string)

MIGRATION_AGENTS_001_START_REF :: #load("migrations/agents_001_start_ref.sql", string)

MIGRATION_237_EXTENSION_VERSION_SYNC :: #load("migrations/237_extension_version_sync_0_5_74.sql", string)

MIGRATION_ACTIONS_011_PROMPT_EXPIRY :: #load("migrations/actions_011_prompt_expiry.sql", string)
MIGRATION_ACTIONS_010_AGENT_AUTOMATION_AUDIT :: #load("migrations/actions_010_agent_automation_audit.sql", string)
MIGRATION_ACTIONS_004_BOT_ACTIVITY :: #load("migrations/actions_004_bot_activity.sql", string)
MIGRATION_ACTIONS_009_BATCH_HISTORY :: #load("migrations/actions_009_batch_history.sql", string)
MIGRATION_ACTIONS_008_TARGET_BATCHES :: #load("migrations/actions_008_target_batches.sql", string)
MIGRATION_ACTIONS_005_SETTLE :: #load("migrations/actions_005_settle.sql", string)
MIGRATION_ACTIONS_007_FILTER_TREE :: #load("migrations/actions_007_filter_tree.sql", string)
MIGRATION_ACTIONS_006_TEMPLATE_VARS :: #load("migrations/actions_006_template_vars.sql", string)
MIGRATION_ACTIONS_003_HISTORY_PERFORMANCE :: #load("migrations/actions_003_history_performance.sql", string)
MIGRATION_ACTIONS_002_LOOKUP_INDEXES :: #load("migrations/actions_002_lookup_indexes.sql", string)
MIGRATION_ACP_DELIVERY_001_INPUT_DELIVERIES :: #load("migrations/acp_delivery_001_input_deliveries.sql", string)
MIGRATION_ACTIONS_001_RESET :: #load("migrations/actions_001_reset.sql", string)

MIGRATION_238_EXTENSION_VERSION_SYNC :: #load("migrations/238_extension_version_sync_0_5_75.sql", string)

MIGRATION_239_EXTENSION_VERSION_SYNC :: #load("migrations/239_extension_version_sync_0_5_76.sql", string)

MIGRATION_240_EXTENSION_VERSION_SYNC :: #load("migrations/240_extension_version_sync_0_5_77.sql", string)

MIGRATION_241_EXTENSION_VERSION_SYNC :: #load("migrations/241_extension_version_sync_0_5_78.sql", string)

MIGRATION_242_EXTENSION_VERSION_SYNC :: #load("migrations/242_extension_version_sync_0_5_79.sql", string)

MIGRATION_243_EXTENSION_VERSION_SYNC :: #load("migrations/243_extension_version_sync_0_5_80.sql", string)

MIGRATION_244_EXTENSION_VERSION_SYNC :: #load("migrations/244_extension_version_sync_0_5_81.sql", string)

MIGRATION_245_EXTENSION_VERSION_SYNC :: #load("migrations/245_extension_version_sync_0_5_82.sql", string)

MIGRATION_246_EXTENSION_VERSION_SYNC :: #load("migrations/246_extension_version_sync_0_5_83.sql", string)

MIGRATION_247_EXTENSION_VERSION_SYNC :: #load("migrations/247_extension_version_sync_0_5_84.sql", string)

MIGRATION_248_EXTENSION_VERSION_SYNC :: #load("migrations/248_extension_version_sync_0_5_85.sql", string)

MIGRATION_249_EXTENSION_VERSION_SYNC :: #load("migrations/249_extension_version_sync_0_5_86.sql", string)

MIGRATION_250_EXTENSION_VERSION_SYNC :: #load("migrations/250_extension_version_sync_0_5_87.sql", string)
MIGRATION_251_OPENCODE_ACP_PROVIDER :: #load("migrations/251_opencode_acp_provider.sql", string)

MIGRATION_252_EXTENSION_VERSION_SYNC :: #load("migrations/252_extension_version_sync_0_5_88.sql", string)
MIGRATION_253_SHARED_FLEET_SETTINGS :: #load("migrations/253_shared_fleet_settings.sql", string)
MIGRATION_254_FLEET_APPLICATIONS :: #load("migrations/254_fleet_applications.sql", string)
MIGRATION_257_USER_HOME_LAYOUTS :: #load("migrations/257_user_home_layouts.sql", string)

MIGRATION_255_EXTENSION_VERSION_SYNC :: #load("migrations/255_extension_version_sync_0_5_89.sql", string)

MIGRATION_256_EXTENSION_VERSION_SYNC :: #load("migrations/256_extension_version_sync_0_5_90.sql", string)

MIGRATION_258_EXTENSION_VERSION_SYNC :: #load("migrations/258_extension_version_sync_0_5_91.sql", string)

MIGRATION_259_AGENT_ID_ASSIGNMENT :: #load("migrations/259_agent_id_assignment.sql", string)

MIGRATION_260_DROP_FLEET_ROLES :: #load("migrations/260_drop_fleet_roles.sql", string)

// Applied under the 260 ledger name on a database with owner legacy source
// fences; see owner_legacy_fences_present and the file header.
MIGRATION_260_DROP_FLEET_ROLES_OWNER_LEGACY :: #load("migration_variants/260_drop_fleet_roles_owner_legacy.sql", string)

MIGRATION_261_EXTENSION_VERSION_SYNC :: #load("migrations/261_extension_version_sync_0_5_92.sql", string)

MIGRATION_262_EXTENSION_VERSION_SYNC :: #load("migrations/262_extension_version_sync_0_5_93.sql", string)

MIGRATION_263_TASK_MERGE_PENDING :: #load("migrations/263_task_merge_pending.sql", string)

MIGRATION_264_EXTENSION_VERSION_SYNC :: #load("migrations/264_extension_version_sync_0_5_94.sql", string)

MIGRATION_265_EXTENSION_VERSION_SYNC :: #load("migrations/265_extension_version_sync_0_5_95.sql", string)

MIGRATION_266_INSTANCE_RUNTIME_TRANSPORT_OVERRIDE :: #load("migrations/266_instance_runtime_transport_override.sql", string)

MIGRATION_267_RECONFIGURATION_WAITING_FOR_IDLE :: #load("migrations/267_reconfiguration_waiting_for_idle.sql", string)
MIGRATION_268_BRIDGE_PROVIDER_ACP_RECEIVED_AT :: #load("migrations/268_bridge_provider_acp_received_at.sql", string)
MIGRATION_269_PROFILE_TRANSPORT :: #load("migrations/269_profile_transport.sql", string)

MIGRATION_270_EXTENSION_VERSION_SYNC :: #load("migrations/270_extension_version_sync_0_5_96.sql", string)

migration_order :: [?]string {
	"001_foundation.sql",
	"002_owner_scoped_core.sql",
	"003_device_tokens.sql",
	"004_default_skill_memory.sql",
	"005_agent_to_agent_cross_chain_memory.sql",
	"006_live_agents_skill_memory.sql",
	"007_hide_agent_to_agent_from_user_chat.sql",
	"008_read_inbound_messages_skill_memory.sql",
	"009_artifact_metadata.sql",
	"010_artifact_usage_skill_memory.sql",
	"011_artifact_download_skill_memory.sql",
	"012_task_chains_v2.sql",
	"013_task_workflow_skill_memory.sql",
	"014_task_workflow_skill_comments.sql",
	"015_memory_target_scope.sql",
	"016_memory_workflow_skill_memory.sql",
	"017_chat_message_types.sql",
	"018_coordinator_member_backfill.sql",
	"019_current_task_and_priority.sql",
	"020_title_tracking.sql",
	"021_agent_instance_display_name.sql",
	"022_scheduled_prompts.sql",
	"023_actions.sql",
	"024_push_subscriptions.sql",
	"025_lookup_indexes.sql",
	"026_memory_scope_lists.sql",
	"027_default_coordinator_agent.sql",
	"028_memory_description_and_cleanup.sql",
	"029_search_fts_comments.sql",
	"030_search_fts_all.sql",
	"031_search_fts_messages.sql",
	"032_ai_native_templates.sql",
	"033_default_agents_and_conversation_project.sql",
	"034_cards.sql",
	"035_curator_template.sql",
	"036_action_targets.sql",
	"037_project_state.sql",
	"038_action_instance_strategy.sql",
	"039_shell_jobs.sql",
	"040_artifact_list_indexes.sql",
	"041_shell_sessions.sql",
	"042_pinned_task_chains.sql",
	"043_experiments.sql",
	"043_task_chain_directories.sql",
	"044_issues.sql",
	"044_lsp_servers.sql",
	"045_lsp_server_patterns.sql",
	"046_task_chain_fleets.sql",
	"048_task_subscriptions.sql",
	"048_shell_sessions_kind_and_key.sql",
	"049_shell_sessions_background_and_conversation.sql",
	"050_shell_sessions_kill_intent.sql",
	"051_shell_sessions_run_seq.sql",
	"052_drop_shell_jobs.sql",
	"053_bridge_version_and_updates.sql",
	"054_bridge_telemetry.sql",
	"055_memory_action_expiry.sql",
	"056_bridge_vault_status.sql",
	"057_bridge_tokens.sql",
	"058_provider_catalog.sql",
	"059_bridge_provider_state.sql",
	"060_explicit_provider_models.sql",
	"061_codex_launch_recipe.sql",
	"062_claude_startup_detection.sql",
	"063_claude_login_method_detection.sql",
	"064_codex_trust_detection.sql",
	"065_antigravity_launch_recipe.sql",
	"066_antigravity_trust_detection.sql",
	"067_codex_sandbox_and_models.sql",
	"068_repair_provider_catalog_etag.sql",
	"069_account_billing.sql",
	"070_free_one_bridge.sql",
	"071_codex_folder_access_trust.sql",
	"072_bridge_update_progress.sql",
	"072_instance_reconfiguration.sql",
	"073_claude_current_models.sql",
	"074_reconfiguration_recovery_stop.sql",
	"075_conversation_launch_preferences.sql",
	"076_fleet_bridge_models.sql",
	"077_soloist_agent.sql",
	"078_drop_stale_builtin_template_rows.sql",
	"079_repair_provider_catalog_etag.sql",
	"080_copilot_launch_recipe.sql",
	"081_antigravity_models.sql",
	"082_pi_provider.sql",
	"083_task_chain_search_feed.sql",
	"084_bridge_log_events.sql",
	"085_agent_instance_last_error.sql",
	"086_claude_bypass_permissions_detection.sql",
	"087_attention_cards.sql",
	"088_bridge_enrollment_pending.sql",
	"089_memory_proposer.sql",
	"090_task_v2.sql",
	"091_agent_instance_stopped_by.sql",
	"092_vault_device_directory.sql",
	"093_vault_signed_log.sql",
	"094_vault_hub_blind_pairing.sql",
	"095_vault_pairing_stretch.sql",
	"096_drop_password_vault.sql",
	"097_workflow_runs.sql",
	"098_mixed_work_graph.sql",
	"099_mixed_work_execution.sql",
	"100_vault_pair_hub_origin.sql",
	"101_codex_gpt6_models.sql",
	"102_drop_bridge_enrollments.sql",
	"103_plan_enforcement.sql",
	"104_guard_chat_fts_updates.sql",
	"105_full_scan_indexes.sql",
	"106_agent_extension_events.sql",
	"107_provider_extension.sql",
	"108_agent_permission_mode.sql",
	"109_instance_permission_mode.sql",
	"110_provider_ask_args.sql",
	"111_extension_startup_loading.sql",
	"112_codex_extension.sql",
	"113_antigravity_extension.sql",
	"114_extension_version_sync.sql",
	"115_provider_extension_commands.sql",
	"116_extension_version_sync_0_4_33.sql",
	"117_extension_version_sync_0_4_34.sql",
	"118_extension_version_sync_0_4_35.sql",
	"119_extension_version_sync_0_4_36.sql",
	"120_extension_version_sync_0_4_37.sql",
	"121_extension_version_sync_0_4_38.sql",
	"122_extension_version_sync_0_4_39.sql",
	"123_extension_version_sync_0_4_40.sql",
	"124_extension_version_sync_0_4_41.sql",
	"125_transient_extension_signals.sql",
	"126_action_schedule_revision.sql",
	"127_extension_version_sync_0_4_42.sql",
	"128_extension_version_sync_0_4_43.sql",
	"129_remove_task_verify.sql",
	"130_extension_version_sync_0_4_44.sql",
	"131_fleet_pause.sql",
	"132_extension_version_sync_0_4_45.sql",
	"133_extension_version_sync_0_4_46.sql",
	"native_001_oidc_identities.sql",
	"134_user_sessions.sql",
	"135_clear_user_api_tokens.sql",
	"136_extension_version_sync_0_5_0.sql",
	"137_extension_version_sync_0_5_1.sql",
	"138_bridge_token_rotation_request.sql",
	"139_bridge_token_delivery_and_regrant.sql",
	"140_bridge_tokens_unique_generation.sql",
	"141_extension_version_sync_0_5_2.sql",
	"142_extension_version_sync_0_5_3.sql",
	"143_extension_version_sync_0_5_4.sql",
	"144_extension_version_sync_0_5_5.sql",
	"145_extension_version_sync_0_5_6.sql",
	"146_extension_version_sync_0_5_7.sql",
	"147_extension_version_sync_0_5_8.sql",
	"148_bridge_provider_models.sql",
	"149_extension_version_sync_0_5_9.sql",
	"150_extension_version_sync_0_5_10.sql",
	"151_extension_version_sync_0_5_11.sql",
	"152_extension_version_sync_0_5_12.sql",
	"153_extension_version_sync_0_5_13.sql",
	"154_extension_version_sync_0_5_14.sql",
	"155_extension_version_sync_0_5_15.sql",
	"156_extension_version_sync_0_5_16.sql",
	"157_extension_version_sync_0_5_17.sql",
	"158_extension_version_sync_0_5_18.sql",
	"159_extension_version_sync_0_5_19.sql",
	"160_extension_version_sync_0_5_20.sql",
	"161_extension_version_sync_0_5_21.sql",
	"162_extension_version_sync_0_5_22.sql",
	"163_extension_version_sync_0_5_23.sql",
	"164_extension_version_sync_0_5_24.sql",
	"165_provider_extension_uninstall.sql",
	"166_extension_version_sync_0_5_25.sql",
	"167_extension_version_sync_0_5_26.sql",
	"168_extension_version_sync_0_5_27.sql",
	"169_provider_profiles.sql",
	"170_extension_version_sync_0_5_28.sql",
	"171_extension_version_sync_0_5_29.sql",
	"172_extension_version_sync_0_5_30.sql",
	"173_extension_version_sync_0_5_31.sql",
	"174_extension_version_sync_0_5_32.sql",
	"175_mcp_delegated_credentials.sql",
	"176_mcp_epoch_wraps.sql",
	"177_extension_version_sync_0_5_33.sql",
	"178_bridge_sunset_receipts.sql",
	"179_mcp_mutation_receipts.sql",
	"180_mcp_task_contract.sql",
	"181_mcp_runtime_intents.sql",
	"182_mcp_resource_pages.sql",
	"183_mcp_artifact_pages.sql",
	"184_extension_version_sync_0_5_34.sql",
	"185_extension_version_sync_0_5_35.sql",
	"186_extension_version_sync_0_5_36.sql",
	"187_extension_version_sync_0_5_37.sql",
	"188_extension_version_sync_0_5_38.sql",
	"189_extension_version_sync_0_5_39.sql",
	"190_extension_version_sync_0_5_40.sql",
	"191_extension_version_sync_0_5_41.sql",
	"192_extension_version_sync_0_5_42.sql",
	"193_extension_version_sync_0_5_43.sql",
	"194_extension_version_sync_0_5_44.sql",
	"195_extension_version_sync_0_5_45.sql",
	"196_extension_version_sync_0_5_46.sql",
	"197_agent_token_totals.sql",
	"198_extension_usage_capability.sql",
	"199_extension_version_sync_0_5_47.sql",
	"200_extension_version_sync_0_5_48.sql",
	"201_extension_version_sync_0_5_49.sql",
	"202_extension_version_sync_0_5_50.sql",
	"203_durable_task_claims.sql",
	"204_extension_version_sync_0_5_51_durable_1.sql",
	"205_extension_version_sync_0_5_51.sql",
	"206_extension_version_sync_0_5_52.sql",
	"207_extension_version_sync_0_5_53.sql",
	"208_extension_version_sync_0_5_54.sql",
	"209_extension_version_sync_0_5_55.sql",
	"210_extension_version_sync_0_5_56.sql",
	"211_provider_transport.sql",
	"212_extension_version_sync_0_5_57.sql",
	"213_bots.sql",
	"214_agent_writes.sql",
	"215_bots_whatsapp.sql",
	"216_bots_media.sql",
	"217_extension_version_sync_0_5_58.sql",
	"218_acp_adapter_install.sql",
	"219_extension_version_sync_0_5_59.sql",
	"220_extension_version_sync_0_5_60.sql",
	"221_extension_version_sync_0_5_61.sql",
	"222_extension_version_sync_0_5_62.sql",
	"223_extension_version_sync_0_5_63.sql",
	"events_001_outbox.sql",
	"events_002_topics.sql",
	"events_003_subscriptions.sql",
	"events_004_delivery.sql",
	"events_005_delivery_retention.sql",
	"whatsapp_001_invite_only.sql",
	"224_copilot_acp_transport.sql",
	"225_extension_version_sync_0_5_64.sql",
	"bots_web_001_channel.sql",
	"226_extension_version_sync_0_5_65.sql",
	"bots_web_002_attachments.sql",
	"bots_web_003_action_refs.sql",
	"coordinator_idle_001_user_activity.sql",
	"coordinator_idle_002_stop_reason.sql",
	"227_extension_version_sync_0_5_66.sql",
	"228_extension_version_sync_0_5_67.sql",
	"229_extension_version_sync_0_5_68.sql",
	"230_extension_version_sync_0_5_69.sql",
	"231_extension_version_sync_0_5_70.sql",
	"232_kiro_acp_provider.sql",
	"233_extension_version_sync_0_5_71.sql",
	"234_codex_acp_transport.sql",
	"235_extension_version_sync_0_5_72.sql",
	"236_extension_version_sync_0_5_73.sql",
	"agents_001_start_ref.sql",
	"events_006_instance_subscriptions.sql",
	"events_007_entity_versions.sql",
	"237_extension_version_sync_0_5_74.sql",
	"pipeline_001_deliveries.sql",
	"actions_001_reset.sql",
	"actions_002_lookup_indexes.sql",
	"actions_003_history_performance.sql",
	"actions_004_bot_activity.sql",
	"238_extension_version_sync_0_5_75.sql",
	"239_extension_version_sync_0_5_76.sql",
	"acp_delivery_001_input_deliveries.sql",
	"240_extension_version_sync_0_5_77.sql",
	"pipeline_002_read_ack.sql",
	"actions_005_settle.sql",
	"actions_006_template_vars.sql",
	"241_extension_version_sync_0_5_78.sql",
	"242_extension_version_sync_0_5_79.sql",
	"243_extension_version_sync_0_5_80.sql",
	"actions_008_target_batches.sql",
	"events_008_state_heads.sql",
	"events_009_incremental_inbox.sql",
	"actions_009_batch_history.sql",
	"actions_007_filter_tree.sql",
	"244_extension_version_sync_0_5_81.sql",
	"245_extension_version_sync_0_5_82.sql",
	"246_extension_version_sync_0_5_83.sql",
	"247_extension_version_sync_0_5_84.sql",
	"actions_010_agent_automation_audit.sql",
	"actions_011_prompt_expiry.sql",
	"webhooks_001.sql",
 "webhooks_002_dedupe_header.sql",
	"248_extension_version_sync_0_5_85.sql",
	"249_extension_version_sync_0_5_86.sql",
	"250_extension_version_sync_0_5_87.sql",
	"251_opencode_acp_provider.sql",
	"252_extension_version_sync_0_5_88.sql",
	"253_shared_fleet_settings.sql",
	"254_fleet_applications.sql",
	"255_extension_version_sync_0_5_89.sql",
	"256_extension_version_sync_0_5_90.sql",
	"257_user_home_layouts.sql",
	"258_extension_version_sync_0_5_91.sql",
	"259_agent_id_assignment.sql",
	"260_drop_fleet_roles.sql",
	"261_extension_version_sync_0_5_92.sql",
	"262_extension_version_sync_0_5_93.sql",
	"263_task_merge_pending.sql",
	"264_extension_version_sync_0_5_94.sql",
	"265_extension_version_sync_0_5_95.sql",
	"266_instance_runtime_transport_override.sql",
	"267_reconfiguration_waiting_for_idle.sql",
	"268_bridge_provider_acp_received_at.sql",
	"269_profile_transport.sql",
	"270_extension_version_sync_0_5_96.sql",
	"bots_web_004_activation.sql",
}

// stop_before is a TEST SEAM: when non-empty, the apply loop stops in front of
// that migration and the post-loop upgrade_* twins are skipped, which is how a
// migration test builds the exact pre-migration schema (e.g. the legacy task
// columns) before seeding fixture rows and running the real thing. Production
// callers never set it.
run_migrations :: proc(
	conn: ^Conn,
	migrations_dir := "src/hub/repository/sqlite/migrations",
	stop_before := "",
) -> (
	bool,
	domain.Domain_Error,
) {
	if conn == nil || conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "database connection is not open")
	}
	if !owner_legacy_frozen_view_create(conn) {
		return false, domain.domain_error(.Internal_Error, "failed to prepare the owner legacy frozen chain view")
	}
	defer owner_legacy_frozen_view_drop(conn)
	for name in migration_order {
		if stop_before != "" && name == stop_before do return true, domain.Domain_Error{}
        // 211 is transactional; repair only a committed schema/ledger gap.
        if name=="211_provider_transport.sql" && table_column_exists(conn,"agent_instances","runtime_transport") && sqlite_object_exists(conn,"acp_assistant_turns") && sqlite_object_exists(conn,"provider_transport_update") {
         mark_migration_applied(conn,name)
         continue
        }
		if name == "016_memory_workflow_skill_memory.sql" {
			if !upgrade_memory_target_scope_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory target scope schema upgrade failed")
		}
		// Deployed native 113/115 are immutable historical aliases. Preserve them;
		// acknowledge the namespaced identity only with the entire native schema.
		if name == "native_001_oidc_identities.sql" &&
		   (migration_applied(conn, "113_oidc_identities.sql") ||
		    migration_applied(conn, "115_oidc_identities.sql") ||
		    migration_applied(conn, name) || sqlite_object_exists(conn, "user_external_identities") ||
		    sqlite_object_exists(conn, "vault_request_nonces")) {
			if !native_oidc_schema_complete(conn) {
				return false, domain.domain_error(.Internal_Error, "native OIDC migration schema is incomplete or incompatible; repair before upgrade")
			}
			mark_migration_applied(conn, name)
			continue
		}
        // The profile migration commits atomically. Its final index also lets
        // startup repair a crash between schema commit and ledger insertion.
        if name=="169_provider_profiles.sql" && sqlite_object_exists(conn,"idx_bridge_provider_profiles_driver") {
         mark_migration_applied(conn,name)
         continue
        }
		if migration_applied(conn, name) do continue
		// The reset commits atomically before its ledger entry. Its LAST index
		// plus the absence of the old schema proves the exec-to-mark gap; do
		// not reapply the destructive reset to already committed new rows.
		if name == "actions_001_reset.sql" &&
		   sqlite_object_exists(conn, "action_runs_due") &&
		   !sqlite_object_exists(conn, "action_schedule_revision") &&
		   !sqlite_object_exists(conn, "scheduled_prompts") &&
		   table_column_exists(conn, "actions", "action_id") {
			mark_migration_applied(conn, name)
			continue
		}
		// 215 commits atomically; repair a crash before its ledger insert.
		if name == "215_bots_whatsapp.sql" && sqlite_object_exists(conn, "channel_push_events_pending") {
			mark_migration_applied(conn, name)
			continue
		}
		// Repair a crash after ALTER TABLE but before the migration ledger write.
		if name == "webhooks_002_dedupe_header.sql" && table_column_exists(conn, "event_webhooks", "dedupe_header") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "bots_web_003_action_refs.sql" && table_column_exists(conn, "channel_messages", "action_ids_json") {
			mark_migration_applied(conn, name)
			continue
		}
		// events_006 commits atomically; its lifecycle trigger proves a commit that
		// crashed before its ledger insert.
		if name == "events_006_instance_subscriptions.sql" && sqlite_object_exists(conn, "event_bot_instance_replaced") {
			mark_migration_applied(conn, name)
			continue
		}
		// The message index proves the attachment table rebuild committed atomically.
		if name == "bots_web_002_attachments.sql" && sqlite_object_exists(conn, "channel_attachments_message") {
			mark_migration_applied(conn, name)
			continue
		}
		// The paging index proves the binding constraint upgrade committed atomically.
		if name == "bots_web_001_channel.sql" && sqlite_object_exists(conn, "channel_messages_history_page") {
			mark_migration_applied(conn, name)
			continue
		}
		// 216 commits atomically; its last index lets startup repair a crash before its ledger insert.
		if name == "216_bots_media.sql" && sqlite_object_exists(conn, "channel_attachments_bot") {
			mark_migration_applied(conn, name)
			continue
		}
        // 203 may have committed before its ledger write (or an older build may
        // have applied only the ALTER). Re-run its idempotent data conversion.
        if name == "203_durable_task_claims.sql" && table_column_exists(conn, "task_leases", "phase") {
            remaining, _ := strings.replace_all(MIGRATION_203_DURABLE_TASK_CLAIMS,
                "ALTER TABLE task_leases ADD COLUMN phase TEXT NOT NULL DEFAULT 'active' CHECK (phase IN ('active', 'waiting'));", "", context.temp_allocator)
            if !exec(conn, remaining) do return false, domain.domain_error(.Internal_Error, "durable claim conversion recovery failed")
			mark_migration_applied(conn, name)
			continue
		}

		if name == "003_device_tokens.sql" &&
		   table_column_exists(conn, "user_api_tokens", "created_from") &&
		   table_column_exists(conn, "user_api_tokens", "device_label") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "017_chat_message_types.sql" &&
		   table_column_exists(conn, "chat_messages", "message_type") &&
		   table_column_exists(conn, "chat_messages", "message_status") &&
		   table_column_exists(conn, "chat_messages", "metadata_json") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "019_current_task_and_priority.sql" &&
		   table_column_exists(conn, "agent_instances", "current_task_id") &&
		   table_column_exists(conn, "agent_instances", "current_task_role") &&
		   table_column_exists(conn, "tasks", "priority") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "020_title_tracking.sql" &&
		   table_column_exists(conn, "chat_conversations", "title_source") &&
		   table_column_exists(conn, "task_chains", "title_source") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "021_agent_instance_display_name.sql" &&
		   table_column_exists(conn, "agent_instances", "display_name") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "022_scheduled_prompts.sql" &&
		   table_column_exists(conn, "scheduled_prompts", "id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "023_actions.sql" && table_column_exists(conn, "actions", "cron_expr") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "024_push_subscriptions.sql" &&
		   table_column_exists(conn, "push_subscriptions", "endpoint") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "026_memory_scope_lists.sql" &&
		   table_column_exists(conn, "memories", "agent_ids") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "028_memory_description_and_cleanup.sql" &&
		   table_column_exists(conn, "memories", "description") {
			mark_migration_applied(conn, name)
			continue
		}
		// FTS5 migrations are skipped (marked applied) when FTS5 is unavailable or the
		// vtable already exists, so the append-only ledger stays consistent and
		// non-FTS builds boot on the indexed-LIKE fallback.
		if name == "029_search_fts_comments.sql" &&
		   (!fts5_available(conn) || sqlite_object_exists(conn, "task_comments_fts")) {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "030_search_fts_all.sql" &&
		   (!fts5_available(conn) || sqlite_object_exists(conn, "memories_fts")) {
			mark_migration_applied(conn, name)
			continue
		}
		// 030/031 can be marked applied without creating the chat vtables (non-FTS
		// boot), and a trigger naming a missing vtable fails every base-table UPDATE
		// at compile time, so 104 also requires both vtables to exist.
		if name == "104_guard_chat_fts_updates.sql" &&
		   (!fts5_available(conn) ||
		    !sqlite_object_exists(conn, "chat_messages_fts") ||
		    !sqlite_object_exists(conn, "chat_conversations_fts")) {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "031_search_fts_messages.sql" &&
		   (!fts5_available(conn) || sqlite_object_exists(conn, "chat_messages_fts")) {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "034_cards.sql" && table_column_exists(conn, "cards", "card_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "036_action_targets.sql" &&
		   table_column_exists(conn, "actions", "target_agent_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "037_project_state.sql" && table_column_exists(conn, "projects", "state") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "038_action_instance_strategy.sql" &&
		   table_column_exists(conn, "actions", "instance_strategy") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "039_shell_jobs.sql" && table_column_exists(conn, "shell_jobs", "exec_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "040_artifact_list_indexes.sql" &&
		   sqlite_object_exists(conn, "idx_artifacts_owner_created") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "041_shell_sessions.sql" &&
		   table_column_exists(conn, "shell_sessions", "session_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "042_pinned_task_chains.sql" &&
		   table_column_exists(conn, "task_chains", "is_pinned") &&
		   table_column_exists(conn, "task_chains", "pinned_at") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "043_experiments.sql" && sqlite_object_exists(conn, "experiments") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "044_lsp_servers.sql" && sqlite_object_exists(conn, "lsp_server_configs") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "043_task_chain_directories.sql" &&
		   sqlite_object_exists(conn, "task_chain_directories") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "044_issues.sql" &&
		   sqlite_object_exists(conn, "issues") &&
		   sqlite_object_exists(conn, "issue_comments") &&
		   sqlite_object_exists(conn, "issue_votes") {
			mark_migration_applied(conn, name)
			continue
		}
		if (name == "045_lsp_server_patterns.sql" || name == "046_lsp_server_patterns.sql") &&
		   table_column_exists(conn, "lsp_server_configs", "dir_pattern") {
			mark_migration_applied(conn, name)
			continue
		}
		if (name == "046_task_chain_fleets.sql" || name == "044_task_chain_fleets.sql") &&
		   sqlite_object_exists(conn, "task_chain_fleets") {
			mark_migration_applied(conn, name)
			continue
		}
		// Skip-guard keyed on a NEW index rather than on a column: 048 changes the
		// primary key and the kind vocabulary without adding or removing a column, so
		// table_column_exists cannot tell a migrated table from an unmigrated one.
		//
		// KEYED ON THE LAST OBJECT 048 CREATES, which is shell_sessions_owner_session
		// (048 line 83), NOT the earlier shell_sessions_agent (line 70). run_migrations
		// is not transactional -- there is no BEGIN/COMMIT around the apply loop -- so a
		// failure part-way through 048 leaves whatever it had already created in place.
		// Guarding on an EARLY object would then mark 048 applied while the UNIQUE index
		// shell_sessions_owner_session was missing, and that index is the constraint that
		// makes the owner-scoped by-session-id read single-row by construction rather than
		// by LIMIT 1 choosing arbitrarily between duplicates. Keying on the last object
		// means a partial apply cannot look complete. Same reasoning, same shape, as 050's
		// guard below. sqlite_object_exists queries sqlite_master by name with no type
		// filter, so it matches an index exactly as it matches a table.
		//
		// This is robustness against a FUTURE partial failure, not a live bug: no
		// reachable database today has 048 half-applied.
		if name == "048_shell_sessions_kind_and_key.sql" &&
		   sqlite_object_exists(conn, "shell_sessions_owner_session") {
			mark_migration_applied(conn, name)
			continue
		}
		// 049 only ADDS columns, so the column itself is the honest skip-guard here
		// (unlike 048, which changes the key without changing the column set).
		// ALTER TABLE ADD COLUMN is not idempotent in SQLite -- re-running it is a
		// hard "duplicate column name" error, which would abort startup migrations
		// on any database that reached 049 through the pre-ledger recovery path.
		if name == "049_shell_sessions_background_and_conversation.sql" &&
		   table_column_exists(conn, "shell_sessions", "background") {
			mark_migration_applied(conn, name)
			continue
		}
		// 050 is ALTER TABLE ADD COLUMN too, so it needs a skip guard for the same
		// reason 049 does: SQLite has no IF NOT EXISTS for ADD COLUMN, and a re-run is
		// a hard "duplicate column name" that would abort startup migrations on any
		// database that reached 050 through the pre-ledger recovery path.
		//
		// KEYED ON THE LAST OBJECT 050 CREATES (the index), NOT THE FIRST (the column)
		// — REQ-SHELL-13 N1. 050 creates two objects and run_migrations is not
		// transactional, so a pass that added the column and died before the index
		// leaves a database a column-keyed guard would declare finished, with the replay
		// lookup's index permanently missing. Keying on the LAST object makes the guard
		// unfakeable by a partial apply: it is satisfied only once every object exists.
		//
		// THE PARTIAL APPLY THEN NEEDS ITS OWN BRANCH, and this is the part keying on
		// the last object alone would get wrong. The self-heal twins all run AFTER this
		// loop, so falling through on a half-applied 050 would re-exec the migration
		// file, whose ALTER TABLE ADD COLUMN is a hard "duplicate column name" against
		// the column that is already there — aborting startup on exactly the state the
		// guard exists to catch, with the twin that could have repaired it never
		// reached. So the half-applied case is repaired HERE, by the same per-object
		// twin, before the ledger is marked.
		//
		// Three states, one for each thing that can be true:
		//   both objects  -> nothing to do; mark and skip.
		//   column only   -> partial apply; repair the missing half via the twin.
		//   neither       -> fall through and run the migration file normally.
		if name == "050_shell_sessions_kill_intent.sql" {
			if sqlite_object_exists(conn, "shell_sessions_pending_kill") {
				mark_migration_applied(conn, name)
				continue
			}
			if table_column_exists(conn, "shell_sessions", "kill_requested_at") {
				if !upgrade_shell_sessions_kill_intent_schema(conn) {
					return false, domain.domain_error(
						.Internal_Error,
						"failed to repair a half-applied 050_shell_sessions_kill_intent",
					)
				}
				mark_migration_applied(conn, name)
				continue
			}
		}
		// 051 adds exactly ONE object — the run_seq column — so unlike 050 there is no
		// "last object" distinct from the first and no partial-apply state to repair:
		// the column either exists or the migration never ran. The guard is therefore
		// the column itself, as it is for 049.
		//
		// It still NEEDS a guard for the same reason 049 and 050 do: SQLite has no
		// IF NOT EXISTS for ADD COLUMN, so a re-run on a database that reached 051
		// through the pre-ledger recovery path is a hard "duplicate column name" that
		// would abort startup migrations.
		if name == "051_shell_sessions_run_seq.sql" &&
		   table_column_exists(conn, "shell_sessions", "run_seq") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "053_bridge_version_and_updates.sql" &&
		   table_column_exists(conn, "bridges", "version") &&
		   table_column_exists(conn, "bridges", "update_error") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "054_bridge_telemetry.sql" &&
		   table_column_exists(conn, "bridges", "telemetry_enabled") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "055_memory_action_expiry.sql" &&
		   table_column_exists(conn, "memories", "expires_at") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "056_bridge_vault_status.sql" &&
		   table_column_exists(conn, "bridges", "vault_status") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "089_memory_proposer.sql" &&
		   table_column_exists(conn, "memories", "proposed_in_chain_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "088_bridge_enrollment_pending.sql" &&
		   table_column_exists(conn, "bridges", "enrollment_pending_until") {
			mark_migration_applied(conn, name)
			continue
		}
		// 057 creates a TABLE plus two indexes, all with IF NOT EXISTS, so unlike the
		// ADD COLUMN migrations above it is already idempotent and strictly does not
		// need a guard. It gets one anyway, for the same reason 053-056 have one: a
		// database that reached this schema through the pre-ledger recovery path has
		// the objects but not the ledger row, and marking it applied without
		// re-executing keeps startup migrations off a table that is now on the
		// authentication path. Keyed on the LAST object created by the file (the
		// family index), not the first, so a half-applied file is re-run rather than
		// marked done — the same reasoning as 050's twin.
		// 140's unique index would fail on rows that already break it (only the
		// pre-fix grace race could produce them). Refusing to start over that would
		// be worse than running without the backstop, so log and skip it WITHOUT
		// marking it applied: every start re-checks and installs the index once the
		// data is clean. The atomic re-grant still serializes new rotations.
		if name == "140_bridge_tokens_unique_generation.sql" && bridge_tokens_generation_duplicates(conn) > 0 {
			fmt.eprintfln("hub: bridge_tokens has duplicate (family_id, kind, generation) rows; skipping unique index %s until they are gone", name)
			continue
		}
		if name == "057_bridge_tokens.sql" && sqlite_object_exists(conn, "bridge_tokens_family") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "058_provider_catalog.sql" && sqlite_object_exists(conn, "provider_icons") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "059_bridge_provider_state.sql" &&
		   sqlite_object_exists(conn, "bridge_provider_settings") {
			mark_migration_applied(conn, name)
			continue
		}
		// 090 runs inside its own BEGIN/COMMIT, so it is either fully applied or
		// absent; the guard only has to recognise a database that reached the schema
		// through a pre-ledger path. Keyed on the LAST object the file creates
		// (idx_tasks_chain_state) so nothing short of a complete apply reads as done.
		if name == "090_task_v2.sql" &&
		   sqlite_object_exists(conn, "idx_tasks_chain_state") {
			mark_migration_applied(conn, name)
			continue
		}
		// A database that ran this file under its pre-merge name (088) has the
		// column but not the ledger row for the new name.
		if name == "091_agent_instance_stopped_by.sql" &&
		   table_column_exists(conn, "agent_instances", "stopped_by") {
			mark_migration_applied(conn, name)
			continue
		}
		// Keyed on the LAST object 092 creates.
		if name == "092_vault_device_directory.sql" &&
		   sqlite_object_exists(conn, "vault_directory_resets") {
			mark_migration_applied(conn, name)
			continue
		}
		// 097 commits atomically before its ledger row is written. If the
		// process exits between those writes, its LAST trigger proves that
		// the whole schema exists; preserve any runs already written there.
		if name == "097_workflow_runs.sql" &&
		   sqlite_object_exists(conn, "workflow_runs_no_delete") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "098_mixed_work_graph.sql" &&
		   sqlite_object_exists(conn, "work_scope_decisions_no_delete") {
			mark_migration_applied(conn, name)
			continue
		}
		// 103 commits atomically before its ledger row. Its final column proves
		// completion if the process exits between those writes.
		if name == "103_plan_enforcement.sql" &&
		   table_column_exists(conn, "bridges", "plan_disabled_at") &&
		   table_column_exists(conn, "account_entitlements", "override_shells_enabled") {
			mark_migration_applied(conn, name)
			continue
		}
		// The WhatsApp migration commits atomically before its ledger row; its last column proves completion.
		if name == "whatsapp_001_invite_only.sql" &&
		   table_column_exists(conn, "account_entitlements", "override_whatsapp_enabled") {
			mark_migration_applied(conn, name)
			continue
		}
		// A single ALTER; a database that already has the column needs nothing.
		if name == "coordinator_idle_001_user_activity.sql" && table_column_exists(conn, "agent_instances", "user_activity_at") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "coordinator_idle_002_stop_reason.sql" && table_column_exists(conn, "agent_instances", "stop_reason") {
			mark_migration_applied(conn, name)
			continue
		}
		// 108 is a single ALTER; a database that already has the column needs nothing.
		if name == "108_agent_permission_mode.sql" && table_column_exists(conn, "agents", "permission_mode") {
			mark_migration_applied(conn, name)
			continue
		}
		// 107 commits atomically before its ledger row; its last column proves completion.
		if name == "107_provider_extension.sql" &&
		   table_column_exists(conn, "bridge_provider_status", "extension_checked_at") {
			mark_migration_applied(conn, name)
			continue
		}
		// Keyed on the LAST object 106 creates.
		if name == "106_agent_extension_events.sql" &&
		   sqlite_object_exists(conn, "agent_extension_events_instance_agent") {
			mark_migration_applied(conn, name)
			continue
		}
		// 109 runs inside its own BEGIN/COMMIT; its last statement recreates the
		// commit trigger, so a trigger that mentions permission_mode proves completion.
		if name == "109_instance_permission_mode.sql" &&
		   table_column_exists(conn, "agent_instances", "permission_mode") &&
		   sqlite_trigger_mentions(conn, "instance_reconfiguration_commit", "permission_mode") {
			mark_migration_applied(conn, name)
			continue
		}
		// 266 runs inside its own BEGIN/COMMIT; its last statement recreates the
		// commit trigger, so a trigger that mentions the override proves completion.
		if name == "266_instance_runtime_transport_override.sql" &&
		   table_column_exists(conn, "agent_instances", "runtime_transport_override") &&
		   sqlite_trigger_mentions(conn, "instance_reconfiguration_commit", "runtime_transport_override") {
			mark_migration_applied(conn, name)
			continue
		}
		// 267 rebuilds instance_reconfigurations inside its own BEGIN/COMMIT; the
		// rebuilt table admits waiting_for_idle and its last statement recreates
		// the hold_messages trigger, so both together prove completion.
		if name == "267_reconfiguration_waiting_for_idle.sql" &&
		   sqlite_table_sql_mentions(conn, "instance_reconfigurations", "waiting_for_idle") &&
		   sqlite_object_exists(conn, "instance_reconfiguration_hold_messages") {
			mark_migration_applied(conn, name)
			continue
		}
		// 268 is one atomic ALTER before its ledger row; its column proves completion.
		if name == "268_bridge_provider_acp_received_at.sql" && table_column_exists(conn, "bridge_provider_status", "acp_adapter_received_at") {
			mark_migration_applied(conn, name)
			continue
		}
		// 269 rebuilds bridge_provider_settings inside its own BEGIN/COMMIT; the
		// rebuilt table's named per-profile transport CHECK proves completion.
		if name == "269_profile_transport.sql" && sqlite_table_sql_mentions(conn, "bridge_provider_settings", "profile_transport") {
			mark_migration_applied(conn, name)
			continue
		}
		// 110 commits atomically before its ledger row; its column proves completion.
		if name == "110_provider_ask_args.sql" && table_column_exists(conn, "provider_catalog", "ask_args") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "099_mixed_work_execution.sql" && sqlite_object_exists(conn, "mixed_work_engine_epoch") {
			mark_migration_applied(conn, name)
			continue
		}
		// 095 drops the vault tables on a fresh database (092 is re-run after the loop
		// with the column), and a database that already has the column needs nothing.
		if name == "100_vault_pair_hub_origin.sql" &&
		   (!sqlite_object_exists(conn, "vault_devices") || table_column_exists(conn, "vault_devices", "pair_hub_origin")) {
			mark_migration_applied(conn, name)
			continue
		}
        // Fleet provider/model historically arrive via a post-loop upgrade.
        // Ensure that prerequisite before migrating their default profile IDs.
        if name=="169_provider_profiles.sql" && !upgrade_task_chain_fleets_schema(conn) do return false,domain.domain_error(.Internal_Error,"fleet profile migration prerequisite failed")
		sql := migration_sql(name, migrations_dir)
		// 260 on a database with owner legacy source fences: a fence trigger
		// reads task_leases.review_role, so the variant that keeps that column
		// runs under the same ledger name.
		if name == "260_drop_fleet_roles.sql" && owner_legacy_fences_present(conn) {
			delete(sql)
			sql = strings.clone(MIGRATION_260_DROP_FLEET_ROLES_OWNER_LEGACY)
		}
		if sql == "" {
			return false, domain.domain_error(
				.Internal_Error,
				fmt.tprintf("missing migration %s", name),
			)
		}
		if !exec(conn, sql) {
			if name == "actions_007_filter_tree.sql" || name == "actions_001_reset.sql" || name == "169_provider_profiles.sql" || name == "211_provider_transport.sql" || name == "bots_web_001_channel.sql" || name == "bots_web_002_attachments.sql" || name == "215_bots_whatsapp.sql" || name == "216_bots_media.sql" || name == "218_acp_adapter_install.sql" || name == "events_006_instance_subscriptions.sql" || name == "events_007_entity_versions.sql" || name == "260_drop_fleet_roles.sql" || name == "263_task_merge_pending.sql" || name == "266_instance_runtime_transport_override.sql" || name == "267_reconfiguration_waiting_for_idle.sql" || name == "269_profile_transport.sql" do _ = exec(conn, "ROLLBACK;")
			delete(sql)
			return false, domain.domain_error(
				.Internal_Error,
				fmt.tprintf("migration failed: %s", name),
			)
		}
		mark_migration_applied(conn, name)
		delete(sql)
	}
	if !upgrade_user_api_tokens_schema(conn) do return false, domain.domain_error(.Internal_Error, "user_api_tokens schema upgrade failed")
	if !upgrade_task_comments_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_comments schema upgrade failed")
	if !upgrade_task_chains_v2_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_chains_v2 schema upgrade failed")
	if !upgrade_memory_target_scope_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory target scope schema upgrade failed")
	if !upgrade_memory_scope_lists_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory scope lists schema upgrade failed")
	if !upgrade_chat_message_types_schema(conn) do return false, domain.domain_error(.Internal_Error, "chat message type schema upgrade failed")
	if !upgrade_current_task_and_priority_schema(conn) do return false, domain.domain_error(.Internal_Error, "current task + priority schema upgrade failed")
	if !upgrade_title_tracking_schema(conn) do return false, domain.domain_error(.Internal_Error, "title tracking schema upgrade failed")
	if !upgrade_agent_instance_display_name_schema(conn) do return false, domain.domain_error(.Internal_Error, "agent instance display_name schema upgrade failed")
	if !upgrade_push_subscriptions_schema(conn) do return false, domain.domain_error(.Internal_Error, "push subscriptions schema upgrade failed")
	if !upgrade_memory_description_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory description schema upgrade failed")
	if !upgrade_cards_schema(conn) do return false, domain.domain_error(.Internal_Error, "cards schema upgrade failed")
	if !upgrade_projects_state_schema(conn) do return false, domain.domain_error(.Internal_Error, "projects state schema upgrade failed")
	if !upgrade_artifact_indexes_schema(conn) do return false, domain.domain_error(.Internal_Error, "artifact indexes schema upgrade failed")
	if !upgrade_pinned_task_chains_schema(conn) do return false, domain.domain_error(.Internal_Error, "pinned task chains schema upgrade failed")
	if !upgrade_task_chain_directories_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_chain_directories schema upgrade failed")
	if !upgrade_task_chain_fleets_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_chain_fleets schema upgrade failed")
	if !upgrade_task_bridge_schema(conn) do return false, domain.domain_error(.Internal_Error, "task bridge_id schema upgrade failed")
	if !upgrade_shell_sessions_kind_and_key_schema(conn) do return false, domain.domain_error(.Internal_Error, "shell_sessions kind + key schema upgrade failed")
	if !upgrade_shell_sessions_background_schema(conn) do return false, domain.domain_error(.Internal_Error, "shell_sessions background + conversation schema upgrade failed")
	if !upgrade_shell_sessions_kill_intent_schema(conn) do return false, domain.domain_error(.Internal_Error, "shell_sessions kill intent schema upgrade failed")
	if !upgrade_shell_sessions_run_seq_schema(conn) do return false, domain.domain_error(.Internal_Error, "shell_sessions run_seq schema upgrade failed")
	if !upgrade_bridge_version_and_updates_schema(conn) do return false, domain.domain_error(.Internal_Error, "bridge version and updates schema upgrade failed")
	if !upgrade_bridge_update_progress_schema(conn) do return false, domain.domain_error(.Internal_Error, "bridge update progress schema upgrade failed")
	if !upgrade_memory_action_expiry_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory action expiry schema upgrade failed")
	if !upgrade_task_v2_schema(conn) do return false, domain.domain_error(.Internal_Error, "task v2 schema upgrade failed")
	if !upgrade_vault_directory_schema(conn) do return false, domain.domain_error(.Internal_Error, "vault directory schema upgrade failed")
	return true, domain.Domain_Error{}
}

migration_sql :: proc(name, migrations_dir: string) -> string {
	if name == "270_extension_version_sync_0_5_96.sql" do return strings.clone(MIGRATION_270_EXTENSION_VERSION_SYNC)
	if name == "269_profile_transport.sql" do return strings.clone(MIGRATION_269_PROFILE_TRANSPORT)
	if name == "268_bridge_provider_acp_received_at.sql" do return strings.clone(MIGRATION_268_BRIDGE_PROVIDER_ACP_RECEIVED_AT)
	if name == "267_reconfiguration_waiting_for_idle.sql" do return strings.clone(MIGRATION_267_RECONFIGURATION_WAITING_FOR_IDLE)
	if name == "266_instance_runtime_transport_override.sql" do return strings.clone(MIGRATION_266_INSTANCE_RUNTIME_TRANSPORT_OVERRIDE)
	if name == "265_extension_version_sync_0_5_95.sql" do return strings.clone(MIGRATION_265_EXTENSION_VERSION_SYNC)
	if name == "264_extension_version_sync_0_5_94.sql" do return strings.clone(MIGRATION_264_EXTENSION_VERSION_SYNC)
	if name == "262_extension_version_sync_0_5_93.sql" do return strings.clone(MIGRATION_262_EXTENSION_VERSION_SYNC)
	if name == "263_task_merge_pending.sql" do return strings.clone(MIGRATION_263_TASK_MERGE_PENDING)
	if name == "261_extension_version_sync_0_5_92.sql" do return strings.clone(MIGRATION_261_EXTENSION_VERSION_SYNC)
	if name == "260_drop_fleet_roles.sql" do return strings.clone(MIGRATION_260_DROP_FLEET_ROLES)
	if name == "259_agent_id_assignment.sql" do return strings.clone(MIGRATION_259_AGENT_ID_ASSIGNMENT)
	if name == "258_extension_version_sync_0_5_91.sql" do return strings.clone(MIGRATION_258_EXTENSION_VERSION_SYNC)
	if name == "256_extension_version_sync_0_5_90.sql" do return strings.clone(MIGRATION_256_EXTENSION_VERSION_SYNC)
	if name == "255_extension_version_sync_0_5_89.sql" do return strings.clone(MIGRATION_255_EXTENSION_VERSION_SYNC)
	if name == "252_extension_version_sync_0_5_88.sql" do return strings.clone(MIGRATION_252_EXTENSION_VERSION_SYNC)
	if name == "250_extension_version_sync_0_5_87.sql" do return strings.clone(MIGRATION_250_EXTENSION_VERSION_SYNC)
	if name == "253_shared_fleet_settings.sql" do return strings.clone(MIGRATION_253_SHARED_FLEET_SETTINGS)
	if name == "254_fleet_applications.sql" do return strings.clone(MIGRATION_254_FLEET_APPLICATIONS)
	if name == "257_user_home_layouts.sql" do return strings.clone(MIGRATION_257_USER_HOME_LAYOUTS)
	if name == "251_opencode_acp_provider.sql" do return strings.clone(MIGRATION_251_OPENCODE_ACP_PROVIDER)
	if name == "249_extension_version_sync_0_5_86.sql" do return strings.clone(MIGRATION_249_EXTENSION_VERSION_SYNC)
	if name == "248_extension_version_sync_0_5_85.sql" do return strings.clone(MIGRATION_248_EXTENSION_VERSION_SYNC)
	if name == "247_extension_version_sync_0_5_84.sql" do return strings.clone(MIGRATION_247_EXTENSION_VERSION_SYNC)
	if name == "246_extension_version_sync_0_5_83.sql" do return strings.clone(MIGRATION_246_EXTENSION_VERSION_SYNC)
	if name == "245_extension_version_sync_0_5_82.sql" do return strings.clone(MIGRATION_245_EXTENSION_VERSION_SYNC)
	if name == "244_extension_version_sync_0_5_81.sql" do return strings.clone(MIGRATION_244_EXTENSION_VERSION_SYNC)
	if name == "243_extension_version_sync_0_5_80.sql" do return strings.clone(MIGRATION_243_EXTENSION_VERSION_SYNC)
	if name == "242_extension_version_sync_0_5_79.sql" do return strings.clone(MIGRATION_242_EXTENSION_VERSION_SYNC)
	if name == "241_extension_version_sync_0_5_78.sql" do return strings.clone(MIGRATION_241_EXTENSION_VERSION_SYNC)
	if name == "240_extension_version_sync_0_5_77.sql" do return strings.clone(MIGRATION_240_EXTENSION_VERSION_SYNC)
	if name == "239_extension_version_sync_0_5_76.sql" do return strings.clone(MIGRATION_239_EXTENSION_VERSION_SYNC)
	if name == "238_extension_version_sync_0_5_75.sql" do return strings.clone(MIGRATION_238_EXTENSION_VERSION_SYNC)
 if name == "actions_011_prompt_expiry.sql" do return strings.clone(MIGRATION_ACTIONS_011_PROMPT_EXPIRY)
	if name == "webhooks_002_dedupe_header.sql" do return strings.clone(MIGRATION_WEBHOOKS_002_DEDUPE_HEADER)
	if name == "webhooks_001.sql" do return strings.clone(MIGRATION_WEBHOOKS_001)
	if name == "actions_010_agent_automation_audit.sql" do return strings.clone(MIGRATION_ACTIONS_010_AGENT_AUTOMATION_AUDIT)
	if name == "actions_001_reset.sql" do return strings.clone(MIGRATION_ACTIONS_001_RESET)
 if name == "actions_004_bot_activity.sql" do return strings.clone(MIGRATION_ACTIONS_004_BOT_ACTIVITY)
 if name == "actions_007_filter_tree.sql" do return strings.clone(MIGRATION_ACTIONS_007_FILTER_TREE)
 if name == "actions_006_template_vars.sql" do return strings.clone(MIGRATION_ACTIONS_006_TEMPLATE_VARS)
 if name == "actions_009_batch_history.sql" do return strings.clone(MIGRATION_ACTIONS_009_BATCH_HISTORY)
 if name == "actions_008_target_batches.sql" do return strings.clone(MIGRATION_ACTIONS_008_TARGET_BATCHES)
 if name == "actions_005_settle.sql" do return strings.clone(MIGRATION_ACTIONS_005_SETTLE)
 if name == "actions_003_history_performance.sql" do return strings.clone(MIGRATION_ACTIONS_003_HISTORY_PERFORMANCE)
 if name == "actions_002_lookup_indexes.sql" do return strings.clone(MIGRATION_ACTIONS_002_LOOKUP_INDEXES)
 if name == "acp_delivery_001_input_deliveries.sql" do return strings.clone(MIGRATION_ACP_DELIVERY_001_INPUT_DELIVERIES)
	if name == "237_extension_version_sync_0_5_74.sql" do return strings.clone(MIGRATION_237_EXTENSION_VERSION_SYNC)
 if name == "agents_001_start_ref.sql" do return strings.clone(MIGRATION_AGENTS_001_START_REF)
	if migrations_dir != "" {
		path := strings.concatenate({migrations_dir, "/", name}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.allocator)
		if err == nil {
			return string(data)
		}
	}
	if name == "236_extension_version_sync_0_5_73.sql" do return strings.clone(MIGRATION_236_EXTENSION_VERSION_SYNC)
	if name == "235_extension_version_sync_0_5_72.sql" do return strings.clone(MIGRATION_235_EXTENSION_VERSION_SYNC)
	if name == "234_codex_acp_transport.sql" do return strings.clone(MIGRATION_234_CODEX_ACP_TRANSPORT)
	if name == "233_extension_version_sync_0_5_71.sql" do return strings.clone(MIGRATION_233_EXTENSION_VERSION_SYNC)
	if name == "232_kiro_acp_provider.sql" do return strings.clone(MIGRATION_232_KIRO_ACP_PROVIDER)
	if name == "231_extension_version_sync_0_5_70.sql" do return strings.clone(MIGRATION_231_EXTENSION_VERSION_SYNC)
	if name == "230_extension_version_sync_0_5_69.sql" do return strings.clone(MIGRATION_230_EXTENSION_VERSION_SYNC)
	if name == "229_extension_version_sync_0_5_68.sql" do return strings.clone(MIGRATION_229_EXTENSION_VERSION_SYNC)
	if name == "228_extension_version_sync_0_5_67.sql" do return strings.clone(MIGRATION_228_EXTENSION_VERSION_SYNC)
	if name == "227_extension_version_sync_0_5_66.sql" do return strings.clone(MIGRATION_227_EXTENSION_VERSION_SYNC)
	if name == "226_extension_version_sync_0_5_65.sql" do return strings.clone(MIGRATION_226_EXTENSION_VERSION_SYNC)
	if name == "225_extension_version_sync_0_5_64.sql" do return strings.clone(MIGRATION_225_EXTENSION_VERSION_SYNC)
	if name == "224_copilot_acp_transport.sql" do return strings.clone(MIGRATION_224_COPILOT_ACP_TRANSPORT)
	if name == "223_extension_version_sync_0_5_63.sql" do return strings.clone(MIGRATION_223_EXTENSION_VERSION_SYNC)
	if name == "222_extension_version_sync_0_5_62.sql" do return strings.clone(MIGRATION_222_EXTENSION_VERSION_SYNC)
	if name == "bots_web_004_activation.sql" do return strings.clone(MIGRATION_BOTS_WEB_004_ACTIVATION)
	if name == "bots_web_003_action_refs.sql" do return strings.clone(MIGRATION_BOTS_WEB_003_ACTION_REFS)
	if name == "bots_web_002_attachments.sql" do return strings.clone(MIGRATION_BOTS_WEB_002_ATTACHMENTS)
	if name == "bots_web_001_channel.sql" do return strings.clone(MIGRATION_BOTS_WEB_001_CHANNEL)
	if name == "whatsapp_001_invite_only.sql" do return strings.clone(MIGRATION_WHATSAPP_001_INVITE_ONLY)
	if name == "coordinator_idle_001_user_activity.sql" do return strings.clone(MIGRATION_COORDINATOR_IDLE_001_USER_ACTIVITY)
	if name == "coordinator_idle_002_stop_reason.sql" do return strings.clone(MIGRATION_COORDINATOR_IDLE_002_STOP_REASON)
	if name == "221_extension_version_sync_0_5_61.sql" do return strings.clone(MIGRATION_221_EXTENSION_VERSION_SYNC)
	if name == "events_005_delivery_retention.sql" do return strings.clone(MIGRATION_EVENTS_005_DELIVERY_RETENTION)
	if name == "events_009_incremental_inbox.sql" do return strings.clone(MIGRATION_EVENTS_009_INCREMENTAL_INBOX)
	if name == "events_008_state_heads.sql" do return strings.clone(MIGRATION_EVENTS_008_STATE_HEADS)
 if name == "events_007_entity_versions.sql" do return strings.clone(MIGRATION_EVENTS_007_ENTITY_VERSIONS)
	if name == "events_006_instance_subscriptions.sql" do return strings.clone(MIGRATION_EVENTS_006_INSTANCE_SUBSCRIPTIONS)
	if name == "events_004_delivery.sql" do return strings.clone(MIGRATION_EVENTS_004_DELIVERY)
	if name == "events_003_subscriptions.sql" do return strings.clone(MIGRATION_EVENTS_003_SUBSCRIPTIONS)
	if name == "events_002_topics.sql" do return strings.clone(MIGRATION_EVENTS_002_TOPICS)
	if name == "pipeline_002_read_ack.sql" do return strings.clone(MIGRATION_PIPELINE_002_READ_ACK)
	if name == "pipeline_001_deliveries.sql" do return strings.clone(MIGRATION_PIPELINE_001_DELIVERIES)
	if name == "events_001_outbox.sql" do return strings.clone(MIGRATION_EVENTS_001_OUTBOX)
	if name == "220_extension_version_sync_0_5_60.sql" do return strings.clone(MIGRATION_220_EXTENSION_VERSION_SYNC)
	if name == "219_extension_version_sync_0_5_59.sql" do return strings.clone(MIGRATION_219_EXTENSION_VERSION_SYNC)
	if name == "217_extension_version_sync_0_5_58.sql" do return strings.clone(MIGRATION_217_EXTENSION_VERSION_SYNC)
	if name == "212_extension_version_sync_0_5_57.sql" do return strings.clone(MIGRATION_212_EXTENSION_VERSION_SYNC)
	if name == "211_provider_transport.sql" do return strings.clone(MIGRATION_211_PROVIDER_TRANSPORT)
	if name == "218_acp_adapter_install.sql" do return strings.clone(MIGRATION_218_ACP_ADAPTER_INSTALL)
	if name == "210_extension_version_sync_0_5_56.sql" do return strings.clone(MIGRATION_210_EXTENSION_VERSION_SYNC)
	if name == "216_bots_media.sql" do return strings.clone(MIGRATION_216_BOTS_MEDIA)
	if name == "215_bots_whatsapp.sql" do return strings.clone(MIGRATION_215_BOTS_WHATSAPP)
	if name == "214_agent_writes.sql" do return strings.clone(MIGRATION_214_AGENT_WRITES)
	if name == "213_bots.sql" do return strings.clone(MIGRATION_213_BOTS)
	if name == "209_extension_version_sync_0_5_55.sql" do return strings.clone(MIGRATION_209_EXTENSION_VERSION_SYNC)
	if name == "208_extension_version_sync_0_5_54.sql" do return strings.clone(MIGRATION_208_EXTENSION_VERSION_SYNC)
	if name == "207_extension_version_sync_0_5_53.sql" do return strings.clone(MIGRATION_207_EXTENSION_VERSION_SYNC)
	if name == "206_extension_version_sync_0_5_52.sql" do return strings.clone(MIGRATION_206_EXTENSION_VERSION_SYNC)
	if name == "205_extension_version_sync_0_5_51.sql" do return strings.clone(MIGRATION_205_EXTENSION_VERSION_SYNC)
	if name == "204_extension_version_sync_0_5_51_durable_1.sql" do return strings.clone(MIGRATION_204_EXTENSION_VERSION_SYNC)
	if name == "203_durable_task_claims.sql" do return strings.clone(MIGRATION_203_DURABLE_TASK_CLAIMS)
	if name == "202_extension_version_sync_0_5_50.sql" do return strings.clone(MIGRATION_202_EXTENSION_VERSION_SYNC)
	if name == "201_extension_version_sync_0_5_49.sql" do return strings.clone(MIGRATION_201_EXTENSION_VERSION_SYNC)
	if name == "200_extension_version_sync_0_5_48.sql" do return strings.clone(MIGRATION_200_EXTENSION_VERSION_SYNC)
	if name == "199_extension_version_sync_0_5_47.sql" do return strings.clone(MIGRATION_199_EXTENSION_VERSION_SYNC)
	if name == "198_extension_usage_capability.sql" do return strings.clone(MIGRATION_198_EXTENSION_USAGE_CAPABILITY)
	if name == "197_agent_token_totals.sql" do return strings.clone(MIGRATION_197_AGENT_TOKEN_TOTALS)
	if name == "196_extension_version_sync_0_5_46.sql" do return strings.clone(MIGRATION_196_EXTENSION_VERSION_SYNC)
	if name == "195_extension_version_sync_0_5_45.sql" do return strings.clone(MIGRATION_195_EXTENSION_VERSION_SYNC)
	if name == "194_extension_version_sync_0_5_44.sql" do return strings.clone(MIGRATION_194_EXTENSION_VERSION_SYNC)
	if name == "193_extension_version_sync_0_5_43.sql" do return strings.clone(MIGRATION_193_EXTENSION_VERSION_SYNC)
	if name == "192_extension_version_sync_0_5_42.sql" do return strings.clone(MIGRATION_192_EXTENSION_VERSION_SYNC)
	if name == "191_extension_version_sync_0_5_41.sql" do return strings.clone(MIGRATION_191_EXTENSION_VERSION_SYNC)
	if name == "190_extension_version_sync_0_5_40.sql" do return strings.clone(MIGRATION_190_EXTENSION_VERSION_SYNC)
	if name == "189_extension_version_sync_0_5_39.sql" do return strings.clone(MIGRATION_189_EXTENSION_VERSION_SYNC)
	if name == "188_extension_version_sync_0_5_38.sql" do return strings.clone(MIGRATION_188_EXTENSION_VERSION_SYNC)
	if name == "187_extension_version_sync_0_5_37.sql" do return strings.clone(MIGRATION_187_EXTENSION_VERSION_SYNC)
	if name == "186_extension_version_sync_0_5_36.sql" do return strings.clone(MIGRATION_186_EXTENSION_VERSION_SYNC)
	if name == "185_extension_version_sync_0_5_35.sql" do return strings.clone(MIGRATION_185_EXTENSION_VERSION_SYNC)
	if name == "184_extension_version_sync_0_5_34.sql" do return strings.clone(MIGRATION_184_EXTENSION_VERSION_SYNC)
	if name == "177_extension_version_sync_0_5_33.sql" do return strings.clone(MIGRATION_177_EXTENSION_VERSION_SYNC)
	if name == "178_bridge_sunset_receipts.sql" do return strings.clone(MIGRATION_178_BRIDGE_SUNSET_RECEIPTS)
	if name == "179_mcp_mutation_receipts.sql" do return strings.clone(MIGRATION_179_MCP_MUTATION_RECEIPTS)
	if name == "180_mcp_task_contract.sql" do return strings.clone(MIGRATION_180_MCP_TASK_CONTRACT)
	if name == "181_mcp_runtime_intents.sql" do return strings.clone(MIGRATION_181_MCP_RUNTIME_INTENTS)
	if name == "183_mcp_artifact_pages.sql" do return strings.clone(MIGRATION_183_MCP_ARTIFACT_PAGES)
	if name == "182_mcp_resource_pages.sql" do return strings.clone(MIGRATION_182_MCP_RESOURCE_PAGES)
	if name == "174_extension_version_sync_0_5_32.sql" do return strings.clone(MIGRATION_174_EXTENSION_VERSION_SYNC)
	if name == "173_extension_version_sync_0_5_31.sql" do return strings.clone(MIGRATION_173_EXTENSION_VERSION_SYNC)
	if name == "175_mcp_delegated_credentials.sql" do return strings.clone(MIGRATION_175_MCP)
	if name == "176_mcp_epoch_wraps.sql" do return strings.clone(MIGRATION_176_MCP_WRAPS)
	if name == "172_extension_version_sync_0_5_30.sql" do return strings.clone(MIGRATION_172_EXTENSION_VERSION_SYNC)
	if name == "171_extension_version_sync_0_5_29.sql" do return strings.clone(MIGRATION_171_EXTENSION_VERSION_SYNC)
	if name == "170_extension_version_sync_0_5_28.sql" do return strings.clone(MIGRATION_170_EXTENSION_VERSION_SYNC)
	if name == "168_extension_version_sync_0_5_27.sql" do return strings.clone(MIGRATION_168_EXTENSION_VERSION_SYNC)
	if name == "167_extension_version_sync_0_5_26.sql" do return strings.clone(MIGRATION_167_EXTENSION_VERSION_SYNC)
	if name == "166_extension_version_sync_0_5_25.sql" do return strings.clone(MIGRATION_166_EXTENSION_VERSION_SYNC)
	if name == "165_provider_extension_uninstall.sql" do return strings.clone(MIGRATION_165_PROVIDER_EXTENSION_UNINSTALL)
	if name == "164_extension_version_sync_0_5_24.sql" do return strings.clone(MIGRATION_164_EXTENSION_VERSION_SYNC)
	if name == "163_extension_version_sync_0_5_23.sql" do return strings.clone(MIGRATION_163_EXTENSION_VERSION_SYNC)
	if name == "162_extension_version_sync_0_5_22.sql" do return strings.clone(MIGRATION_162_EXTENSION_VERSION_SYNC)
	if name == "161_extension_version_sync_0_5_21.sql" do return strings.clone(MIGRATION_161_EXTENSION_VERSION_SYNC)
	if name == "160_extension_version_sync_0_5_20.sql" do return strings.clone(MIGRATION_160_EXTENSION_VERSION_SYNC)
	if name == "159_extension_version_sync_0_5_19.sql" do return strings.clone(MIGRATION_159_EXTENSION_VERSION_SYNC)
	if name == "158_extension_version_sync_0_5_18.sql" do return strings.clone(MIGRATION_158_EXTENSION_VERSION_SYNC)
	if name == "157_extension_version_sync_0_5_17.sql" do return strings.clone(MIGRATION_157_EXTENSION_VERSION_SYNC)
	if name == "156_extension_version_sync_0_5_16.sql" do return strings.clone(MIGRATION_156_EXTENSION_VERSION_SYNC)
	if name == "155_extension_version_sync_0_5_15.sql" do return strings.clone(MIGRATION_155_EXTENSION_VERSION_SYNC)
	if name == "154_extension_version_sync_0_5_14.sql" do return strings.clone(MIGRATION_154_EXTENSION_VERSION_SYNC)
	if name == "153_extension_version_sync_0_5_13.sql" do return strings.clone(MIGRATION_153_EXTENSION_VERSION_SYNC)
	if name == "152_extension_version_sync_0_5_12.sql" do return strings.clone(MIGRATION_152_EXTENSION_VERSION_SYNC)
	if name == "151_extension_version_sync_0_5_11.sql" do return strings.clone(MIGRATION_151_EXTENSION_VERSION_SYNC)
	if name == "150_extension_version_sync_0_5_10.sql" do return strings.clone(MIGRATION_150_EXTENSION_VERSION_SYNC)
	if name == "149_extension_version_sync_0_5_9.sql" do return strings.clone(MIGRATION_149_EXTENSION_VERSION_SYNC)
	if name == "169_provider_profiles.sql" do return strings.clone(MIGRATION_169_PROVIDER_PROFILES)
	if name == "148_bridge_provider_models.sql" do return strings.clone(MIGRATION_148_BRIDGE_PROVIDER_MODELS)
	if name == "147_extension_version_sync_0_5_8.sql" do return strings.clone(MIGRATION_147_EXTENSION_VERSION_SYNC)
	if name == "146_extension_version_sync_0_5_7.sql" do return strings.clone(MIGRATION_146_EXTENSION_VERSION_SYNC)
	if name == "145_extension_version_sync_0_5_6.sql" do return strings.clone(MIGRATION_145_EXTENSION_VERSION_SYNC)
	if name == "144_extension_version_sync_0_5_5.sql" do return strings.clone(MIGRATION_144_EXTENSION_VERSION_SYNC)
	if name == "143_extension_version_sync_0_5_4.sql" do return strings.clone(MIGRATION_143_EXTENSION_VERSION_SYNC)
	if name == "142_extension_version_sync_0_5_3.sql" do return strings.clone(MIGRATION_142_EXTENSION_VERSION_SYNC)
	if name == "141_extension_version_sync_0_5_2.sql" do return strings.clone(MIGRATION_141_EXTENSION_VERSION_SYNC)
	if name == "140_bridge_tokens_unique_generation.sql" do return strings.clone(MIGRATION_140_BRIDGE_TOKENS_UNIQUE_GENERATION)
	if name == "139_bridge_token_delivery_and_regrant.sql" do return strings.clone(MIGRATION_139_BRIDGE_TOKEN_DELIVERY_AND_REGRANT)
	if name == "138_bridge_token_rotation_request.sql" do return strings.clone(MIGRATION_138_BRIDGE_TOKEN_ROTATION_REQUEST)
	if name == "137_extension_version_sync_0_5_1.sql" do return strings.clone(MIGRATION_137_EXTENSION_VERSION_SYNC)
	if name == "136_extension_version_sync_0_5_0.sql" do return strings.clone(MIGRATION_136_EXTENSION_VERSION_SYNC)
	if name == "135_clear_user_api_tokens.sql" do return strings.clone(MIGRATION_135_CLEAR_USER_API_TOKENS)
	if name == "134_user_sessions.sql" do return strings.clone(MIGRATION_134_USER_SESSIONS)
	if name == "native_001_oidc_identities.sql" do return strings.clone(MIGRATION_NATIVE_001_OIDC_IDENTITIES)
	if name == "133_extension_version_sync_0_4_46.sql" do return strings.clone(MIGRATION_133_EXTENSION_VERSION_SYNC)
	if name == "132_extension_version_sync_0_4_45.sql" do return strings.clone(MIGRATION_132_EXTENSION_VERSION_SYNC)
	if name == "131_fleet_pause.sql" do return strings.clone(MIGRATION_131_FLEET_PAUSE)
	if name == "130_extension_version_sync_0_4_44.sql" do return strings.clone(MIGRATION_130_EXTENSION_VERSION_SYNC)
	if name == "129_remove_task_verify.sql" do return strings.clone(MIGRATION_129_REMOVE_TASK_VERIFY)
	if name == "128_extension_version_sync_0_4_43.sql" do return strings.clone(MIGRATION_128_EXTENSION_VERSION_SYNC)
	if name == "127_extension_version_sync_0_4_42.sql" do return strings.clone(MIGRATION_127_EXTENSION_VERSION_SYNC)
	if name == "124_extension_version_sync_0_4_41.sql" do return strings.clone(MIGRATION_124_EXTENSION_VERSION_SYNC)
	if name == "123_extension_version_sync_0_4_40.sql" do return strings.clone(MIGRATION_123_EXTENSION_VERSION_SYNC)
	if name == "122_extension_version_sync_0_4_39.sql" do return strings.clone(MIGRATION_122_EXTENSION_VERSION_SYNC)
	if name == "126_action_schedule_revision.sql" do return strings.clone(MIGRATION_126_ACTION_SCHEDULE_REVISION)
	if name == "125_transient_extension_signals.sql" do return strings.clone(MIGRATION_125_TRANSIENT_EXTENSION_SIGNALS)
	if name == "121_extension_version_sync_0_4_38.sql" do return strings.clone(MIGRATION_121_EXTENSION_VERSION_SYNC)
	if name == "120_extension_version_sync_0_4_37.sql" do return strings.clone(MIGRATION_120_EXTENSION_VERSION_SYNC)
	if name == "119_extension_version_sync_0_4_36.sql" do return strings.clone(MIGRATION_119_EXTENSION_VERSION_SYNC)
	if name == "118_extension_version_sync_0_4_35.sql" do return strings.clone(MIGRATION_118_EXTENSION_VERSION_SYNC)
	if name == "117_extension_version_sync_0_4_34.sql" do return strings.clone(MIGRATION_117_EXTENSION_VERSION_SYNC)
	if name == "116_extension_version_sync_0_4_33.sql" do return strings.clone(MIGRATION_116_EXTENSION_VERSION_SYNC)
	if name == "001_foundation.sql" do return strings.clone(MIGRATION_001_FOUNDATION)
	if name == "002_owner_scoped_core.sql" do return strings.clone(MIGRATION_002_OWNER_SCOPED_CORE)
	if name == "003_device_tokens.sql" do return strings.clone(MIGRATION_003_DEVICE_TOKENS)
	if name == "004_default_skill_memory.sql" do return strings.clone(MIGRATION_004_DEFAULT_SKILL_MEMORY)
	if name == "005_agent_to_agent_cross_chain_memory.sql" do return strings.clone(MIGRATION_005_AGENT_TO_AGENT_CROSS_CHAIN_MEMORY)
	if name == "006_live_agents_skill_memory.sql" do return strings.clone(MIGRATION_006_LIVE_AGENTS_SKILL_MEMORY)
	if name == "007_hide_agent_to_agent_from_user_chat.sql" do return strings.clone(MIGRATION_007_HIDE_AGENT_TO_AGENT_FROM_USER_CHAT)
	if name == "008_read_inbound_messages_skill_memory.sql" do return strings.clone(MIGRATION_008_READ_INBOUND_MESSAGES_SKILL_MEMORY)
	if name == "009_artifact_metadata.sql" do return strings.clone(MIGRATION_009_ARTIFACT_METADATA)
	if name == "010_artifact_usage_skill_memory.sql" do return strings.clone(MIGRATION_010_ARTIFACT_USAGE_SKILL_MEMORY)
	if name == "011_artifact_download_skill_memory.sql" do return strings.clone(MIGRATION_011_ARTIFACT_DOWNLOAD_SKILL_MEMORY)
	if name == "012_task_chains_v2.sql" do return strings.clone(MIGRATION_012_TASK_CHAINS_V2)
	if name == "013_task_workflow_skill_memory.sql" do return strings.clone(MIGRATION_013_TASK_WORKFLOW_SKILL_MEMORY)
	if name == "014_task_workflow_skill_comments.sql" do return strings.clone(MIGRATION_014_TASK_WORKFLOW_SKILL_COMMENTS)
	if name == "015_memory_target_scope.sql" do return strings.clone(MIGRATION_015_MEMORY_TARGET_SCOPE)
	if name == "016_memory_workflow_skill_memory.sql" do return strings.clone(MIGRATION_016_MEMORY_WORKFLOW_SKILL_MEMORY)
	if name == "017_chat_message_types.sql" do return strings.clone(MIGRATION_017_CHAT_MESSAGE_TYPES)
	if name == "018_coordinator_member_backfill.sql" do return strings.clone(MIGRATION_018_COORDINATOR_MEMBER_BACKFILL)
	if name == "019_current_task_and_priority.sql" do return strings.clone(MIGRATION_019_CURRENT_TASK_AND_PRIORITY)
	if name == "020_title_tracking.sql" do return strings.clone(MIGRATION_020_TITLE_TRACKING)
	if name == "021_agent_instance_display_name.sql" do return strings.clone(MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME)
	if name == "022_scheduled_prompts.sql" do return strings.clone(MIGRATION_022_SCHEDULED_PROMPTS)
	if name == "023_actions.sql" do return strings.clone(MIGRATION_023_ACTIONS)
	if name == "024_push_subscriptions.sql" do return strings.clone(MIGRATION_024_PUSH_SUBSCRIPTIONS)
	if name == "025_lookup_indexes.sql" do return strings.clone(MIGRATION_025_LOOKUP_INDEXES)
	if name == "026_memory_scope_lists.sql" do return strings.clone(MIGRATION_026_MEMORY_SCOPE_LISTS)
	if name == "027_default_coordinator_agent.sql" do return strings.clone(MIGRATION_027_DEFAULT_COORDINATOR_AGENT)
	if name == "028_memory_description_and_cleanup.sql" do return strings.clone(MIGRATION_028_MEMORY_DESCRIPTION_AND_CLEANUP)
	if name == "029_search_fts_comments.sql" do return strings.clone(MIGRATION_029_SEARCH_FTS_COMMENTS)
	if name == "030_search_fts_all.sql" do return strings.clone(MIGRATION_030_SEARCH_FTS_ALL)
	if name == "031_search_fts_messages.sql" do return strings.clone(MIGRATION_031_SEARCH_FTS_MESSAGES)
	if name == "032_ai_native_templates.sql" do return strings.clone(MIGRATION_032_AI_NATIVE_TEMPLATES)
	if name == "033_default_agents_and_conversation_project.sql" do return strings.clone(MIGRATION_033_DEFAULT_AGENTS_AND_CONVERSATION_PROJECT)
	if name == "034_cards.sql" do return strings.clone(MIGRATION_034_CARDS)
	if name == "035_curator_template.sql" do return strings.clone(MIGRATION_035_CURATOR_TEMPLATE)
	if name == "036_action_targets.sql" do return strings.clone(MIGRATION_036_ACTION_TARGETS)
	if name == "037_project_state.sql" do return strings.clone(MIGRATION_037_PROJECT_STATE)
	if name == "038_action_instance_strategy.sql" do return strings.clone(MIGRATION_038_ACTION_INSTANCE_STRATEGY)
	if name == "039_shell_jobs.sql" do return strings.clone(MIGRATION_039_SHELL_JOBS)
	if name == "040_artifact_list_indexes.sql" do return strings.clone(MIGRATION_040_ARTIFACT_LIST_INDEXES)
	if name == "041_shell_sessions.sql" do return strings.clone(MIGRATION_041_SHELL_SESSIONS)
	if name == "042_pinned_task_chains.sql" do return strings.clone(MIGRATION_042_PINNED_TASK_CHAINS)
	if name == "043_experiments.sql" do return strings.clone(MIGRATION_043_EXPERIMENTS)
	if name == "043_task_chain_directories.sql" do return strings.clone(MIGRATION_043_TASK_CHAIN_DIRECTORIES)
	if name == "044_issues.sql" do return strings.clone(MIGRATION_044_ISSUES)
	if name == "044_lsp_servers.sql" do return strings.clone(MIGRATION_044_LSP_SERVERS)
	if name == "045_lsp_server_patterns.sql" || name == "046_lsp_server_patterns.sql" do return strings.clone(MIGRATION_045_LSP_SERVER_PATTERNS)
	if name == "046_task_chain_fleets.sql" || name == "044_task_chain_fleets.sql" do return strings.clone(MIGRATION_046_TASK_CHAIN_FLEETS)
	if name == "048_task_subscriptions.sql" || name == "049_task_subscriptions.sql" do return strings.clone(MIGRATION_048_TASK_SUBSCRIPTIONS)
	if name == "048_shell_sessions_kind_and_key.sql" do return strings.clone(MIGRATION_048_SHELL_SESSIONS_KIND_AND_KEY)
	if name == "049_shell_sessions_background_and_conversation.sql" do return strings.clone(MIGRATION_049_SHELL_SESSIONS_BACKGROUND_AND_CONVERSATION)
	if name == "050_shell_sessions_kill_intent.sql" do return strings.clone(MIGRATION_050_SHELL_SESSIONS_KILL_INTENT)
	if name == "051_shell_sessions_run_seq.sql" do return strings.clone(MIGRATION_051_SHELL_SESSIONS_RUN_SEQ)
	if name == "052_drop_shell_jobs.sql" do return strings.clone(MIGRATION_052_DROP_SHELL_JOBS)
	if name == "053_bridge_version_and_updates.sql" do return strings.clone(MIGRATION_053_BRIDGE_VERSION_AND_UPDATES)
	if name == "054_bridge_telemetry.sql" do return strings.clone(MIGRATION_054_BRIDGE_TELEMETRY)
	if name == "055_memory_action_expiry.sql" do return strings.clone(MIGRATION_055_MEMORY_ACTION_EXPIRY)
	if name == "056_bridge_vault_status.sql" do return strings.clone(MIGRATION_056_BRIDGE_VAULT_STATUS)
	if name == "057_bridge_tokens.sql" do return strings.clone(MIGRATION_057_BRIDGE_TOKENS)
	if name == "058_provider_catalog.sql" do return strings.clone(MIGRATION_058_PROVIDER_CATALOG)
	if name == "059_bridge_provider_state.sql" do return strings.clone(MIGRATION_059_BRIDGE_PROVIDER_STATE)
	if name == "060_explicit_provider_models.sql" do return strings.clone(MIGRATION_060_EXPLICIT_PROVIDER_MODELS)
	if name == "061_codex_launch_recipe.sql" do return strings.clone(MIGRATION_061_CODEX_LAUNCH_RECIPE)
	if name == "062_claude_startup_detection.sql" do return strings.clone(MIGRATION_062_CLAUDE_STARTUP_DETECTION)
	if name == "063_claude_login_method_detection.sql" do return strings.clone(MIGRATION_063_CLAUDE_LOGIN_METHOD_DETECTION)
	if name == "064_codex_trust_detection.sql" do return strings.clone(MIGRATION_064_CODEX_TRUST_DETECTION)
	if name == "065_antigravity_launch_recipe.sql" do return strings.clone(MIGRATION_065_ANTIGRAVITY_LAUNCH_RECIPE)
	if name == "066_antigravity_trust_detection.sql" do return strings.clone(MIGRATION_066_ANTIGRAVITY_TRUST_DETECTION)
	if name == "067_codex_sandbox_and_models.sql" do return strings.clone(MIGRATION_067_CODEX_SANDBOX_AND_MODELS)
	if name == "070_free_one_bridge.sql" do return strings.clone(MIGRATION_070_FREE_ONE_BRIDGE)
	if name == "082_pi_provider.sql" do return strings.clone(MIGRATION_082_PI_PROVIDER)
	if name == "083_task_chain_search_feed.sql" do return strings.clone(MIGRATION_083_TASK_CHAIN_SEARCH_FEED)
	if name == "084_bridge_log_events.sql" do return strings.clone(MIGRATION_084_BRIDGE_LOG_EVENTS)
	if name == "085_agent_instance_last_error.sql" do return strings.clone(MIGRATION_085_AGENT_INSTANCE_LAST_ERROR)
	if name == "086_claude_bypass_permissions_detection.sql" do return strings.clone(MIGRATION_086_CLAUDE_BYPASS_PERMISSIONS_DETECTION)
	if name == "087_attention_cards.sql" do return strings.clone(MIGRATION_087_ATTENTION_CARDS)
	if name == "088_bridge_enrollment_pending.sql" do return strings.clone(MIGRATION_088_BRIDGE_ENROLLMENT_PENDING)
	if name == "089_memory_proposer.sql" do return strings.clone(MIGRATION_089_MEMORY_PROPOSER)
	if name == "090_task_v2.sql" do return strings.clone(MIGRATION_090_TASK_V2)
	if name == "091_agent_instance_stopped_by.sql" do return strings.clone(MIGRATION_091_AGENT_INSTANCE_STOPPED_BY)
	if name == "092_vault_device_directory.sql" do return strings.clone(MIGRATION_092_VAULT_DEVICE_DIRECTORY)
	if name == "093_vault_signed_log.sql" do return strings.clone(MIGRATION_093_VAULT_SIGNED_LOG)
	if name == "094_vault_hub_blind_pairing.sql" do return strings.clone(MIGRATION_094_VAULT_HUB_BLIND_PAIRING)
	if name == "095_vault_pairing_stretch.sql" do return strings.clone(MIGRATION_095_VAULT_PAIRING_STRETCH)
	if name == "096_drop_password_vault.sql" do return strings.clone(MIGRATION_096_DROP_PASSWORD_VAULT)
	if name == "097_workflow_runs.sql" do return strings.clone(MIGRATION_097_WORKFLOW_RUNS)
	if name == "098_mixed_work_graph.sql" do return strings.clone(MIGRATION_098_MIXED_WORK_GRAPH)
	if name == "099_mixed_work_execution.sql" do return strings.clone(MIGRATION_099_MIXED_WORK_EXECUTION)
	if name == "102_drop_bridge_enrollments.sql" do return strings.clone(MIGRATION_102_DROP_BRIDGE_ENROLLMENTS)
	if name == "103_plan_enforcement.sql" do return strings.clone(MIGRATION_103_PLAN_ENFORCEMENT)
	if name == "104_guard_chat_fts_updates.sql" do return strings.clone(MIGRATION_104_GUARD_CHAT_FTS_UPDATES)
	if name == "105_full_scan_indexes.sql" do return strings.clone(MIGRATION_105_FULL_SCAN_INDEXES)
	if name == "108_agent_permission_mode.sql" do return strings.clone(MIGRATION_108_AGENT_PERMISSION_MODE)
	if name == "107_provider_extension.sql" do return strings.clone(MIGRATION_107_PROVIDER_EXTENSION)
	if name == "106_agent_extension_events.sql" do return strings.clone(MIGRATION_106_AGENT_EXTENSION_EVENTS)
	if name == "109_instance_permission_mode.sql" do return strings.clone(MIGRATION_109_INSTANCE_PERMISSION_MODE)
	if name == "110_provider_ask_args.sql" do return strings.clone(MIGRATION_110_PROVIDER_ASK_ARGS)
	if name == "111_extension_startup_loading.sql" do return strings.clone(MIGRATION_111_EXTENSION_STARTUP_LOADING)
	if name == "112_codex_extension.sql" do return strings.clone(MIGRATION_112_CODEX_EXTENSION)
	if name == "113_antigravity_extension.sql" do return strings.clone(MIGRATION_113_ANTIGRAVITY_EXTENSION)
	if name == "114_extension_version_sync.sql" do return strings.clone(MIGRATION_114_EXTENSION_VERSION_SYNC)
 if name == "115_provider_extension_commands.sql" do return strings.clone(MIGRATION_115_PROVIDER_EXTENSION_COMMANDS)
	if name == "100_vault_pair_hub_origin.sql" do return strings.clone(MIGRATION_100_VAULT_PAIR_HUB_ORIGIN)
	if name == "101_codex_gpt6_models.sql" do return strings.clone(MIGRATION_101_CODEX_GPT6_MODELS)
	if name == "081_antigravity_models.sql" do return strings.clone(MIGRATION_081_ANTIGRAVITY_MODELS)
	if name == "080_copilot_launch_recipe.sql" do return strings.clone(MIGRATION_080_COPILOT_LAUNCH_RECIPE)
	if name == "079_repair_provider_catalog_etag.sql" do return strings.clone(MIGRATION_079_REPAIR_PROVIDER_CATALOG_ETAG)
	if name == "078_drop_stale_builtin_template_rows.sql" do return strings.clone(MIGRATION_078_DROP_STALE_BUILTIN_TEMPLATE_ROWS)
	if name == "077_soloist_agent.sql" do return strings.clone(MIGRATION_077_SOLOIST_AGENT)
	if name == "076_fleet_bridge_models.sql" do return strings.clone(MIGRATION_076_FLEET_BRIDGE_MODELS)
	if name == "075_conversation_launch_preferences.sql" do return strings.clone(MIGRATION_075_CONVERSATION_LAUNCH_PREFERENCES)
	if name == "074_reconfiguration_recovery_stop.sql" do return strings.clone(MIGRATION_074_RECONFIGURATION_RECOVERY_STOP)
	if name == "073_claude_current_models.sql" do return strings.clone(MIGRATION_073_CLAUDE_CURRENT_MODELS)
	if name == "072_instance_reconfiguration.sql" do return strings.clone(MIGRATION_072_INSTANCE_RECONFIGURATION)
	if name == "071_codex_folder_access_trust.sql" do return strings.clone(MIGRATION_071_CODEX_FOLDER_ACCESS_TRUST)
	if name == "072_bridge_update_progress.sql" do return strings.clone(MIGRATION_072_BRIDGE_UPDATE_PROGRESS)
	if name == "069_account_billing.sql" do return strings.clone(MIGRATION_069_ACCOUNT_BILLING)
	if name == "068_repair_provider_catalog_etag.sql" do return strings.clone(MIGRATION_068_REPAIR_PROVIDER_CATALOG_ETAG)
	return ""
}

migration_applied :: proc(conn: ^Conn, version: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf(
		"SELECT 1 FROM schema_migrations WHERE version='%s' LIMIT 1;",
		escape_sql_literal(version),
	)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) == SQLITE_ROW do return true
	// Preserve pre-namespace events ledger identities without replaying CREATE TABLE.
	if version == "events_001_outbox.sql" do return migration_applied(conn, "221_event_outbox.sql")
	if version == "events_002_topics.sql" do return migration_applied(conn, "222_event_topics.sql")
	// Bots shipped on staging before main claimed 210–212. Keep the original
	// ledger identities and skip their renumbered equivalents without replaying SQL.
	if version == "213_bots.sql" do return migration_applied(conn, "209_bots.sql")
	if version == "214_agent_writes.sql" do return migration_applied(conn, "210_agent_writes.sql")
	if version == "215_bots_whatsapp.sql" do return migration_applied(conn, "211_bots_whatsapp.sql")
	if version == "216_bots_media.sql" do return migration_applied(conn, "212_bots_media.sql")
	if version == "046_task_chain_fleets.sql" {
		return migration_applied(conn, "044_task_chain_fleets.sql")
	}
	// The verify removal shipped to some databases as 128 before release 0.4.43
	// took that number, so it was renumbered 129. Such a database already has the
	// removal, and its boot may have consumed the taskv2_boot_regate marker;
	// re-running it would re-create the marker and re-evaluate every in-review
	// gate a second time.
	if version == "129_remove_task_verify.sql" {
		return migration_applied(conn, "128_remove_task_verify.sql")
	}
	// SCHED-0a/0b ran on development databases as 257/258 before release 0.5.91
	// took those numbers, so they were renumbered 259/260. Re-running them would
	// fail (duplicate `paused` column; dropping already-dropped role columns).
	if version == "259_agent_id_assignment.sql" do return migration_applied(conn, "257_agent_id_assignment.sql")
	if version == "260_drop_fleet_roles.sql" do return migration_applied(conn, "258_drop_fleet_roles.sql")
	// The column may already exist (upgrade_task_v2_schema ensures it too). A
	// database that ran this file under its pre-release number (130_fleet_pause.sql,
	// before release 0.4.44 took 130) also has it, so the renumbered file is marked
	// applied there without re-executing; that database still runs 130's sync,
	// because the ledger is keyed by full file name.
	// The column is the whole migration; a database that already has it (an
	// ALTER that ran under another number on a development branch) is applied.
	// Keyed on the LAST column the file adds, so a half-applied file re-runs.
	if version == "139_bridge_token_delivery_and_regrant.sql" {
		return table_column_exists(conn, "bridge_tokens", "regrant_claim")
	}
	if version == "138_bridge_token_rotation_request.sql" {
		return table_column_exists(conn, "bridge_tokens", "rotation_request_hash")
	}
	if version == "131_fleet_pause.sql" {
		// SCHED-0b: 260 drops the column again, so its absence after 260 is not
		// a reason to re-run 131 (that would re-add it).
		return table_column_exists(conn, "task_chain_fleets", "paused_roles_json") || migration_applied(conn, "260_drop_fleet_roles.sql")
	}
	if version == "048_task_subscriptions.sql" || version == "049_task_subscriptions.sql" {
		return sqlite_object_exists(conn, "task_subscriptions")
	}
	if version == "048_shell_sessions_kind_and_key.sql" {
		// The LAST object 048 creates, matching its skip guard above — a partial apply
		// that stopped before the UNIQUE index must not read back as applied.
		return sqlite_object_exists(conn, "shell_sessions_owner_session")
	}
	if version == "049_shell_sessions_background_and_conversation.sql" {
		return table_column_exists(conn, "shell_sessions", "background")
	}
	if version == "050_shell_sessions_kill_intent.sql" {
		// The LAST object 050 creates, matching its skip guard — a partial apply that
		// stopped after the column must not read back as applied.
		return sqlite_object_exists(conn, "shell_sessions_pending_kill")
	}
	if version == "051_shell_sessions_run_seq.sql" {
		// 051's only object, matching its skip guard. Single-object, so unlike 050
		// there is no partial apply this could read back as applied.
		return table_column_exists(conn, "shell_sessions", "run_seq")
	}
	if version == "055_memory_action_expiry.sql" {
		return table_column_exists(conn, "memories", "expires_at")
	}
	return false
}

// owner_legacy_fences_present: the database carries the owner legacy source
// fences (bridge-owned legacy chain export; origin/main has no migration for
// them). Their guard triggers make every row of a chain whose
// owner_legacy_migrations.state is 'frozen' or 'imported' read-only, so a data
// migration must leave those chains' rows alone.
owner_legacy_fences_present :: proc(conn: ^Conn) -> bool {
	return sqlite_object_exists(conn, "owner_legacy_migrations")
}

// owner_legacy_frozen_view_create provides, for the duration of one
// run_migrations, the TEMP view owner_legacy_frozen_chains(chain_id): the
// chains a data migration must not write (see owner_legacy_fences_present).
// Without the fences it is empty, so a migration can always reference it.
// Rebuilt on every run, because the fences can appear between runs.
owner_legacy_frozen_view_create :: proc(conn: ^Conn) -> bool {
	owner_legacy_frozen_view_drop(conn)
	if owner_legacy_fences_present(conn) {
		return exec(conn, "CREATE TEMP VIEW owner_legacy_frozen_chains AS SELECT chain_id FROM main.owner_legacy_migrations WHERE state IN ('frozen', 'imported');")
	}
	return exec(conn, "CREATE TEMP VIEW owner_legacy_frozen_chains AS SELECT '' AS chain_id WHERE 0;")
}

owner_legacy_frozen_view_drop :: proc(conn: ^Conn) {
	_ = exec(conn, "DROP VIEW IF EXISTS temp.owner_legacy_frozen_chains;")
}

mark_migration_applied :: proc(conn: ^Conn, version: string) {
	query := fmt.tprintf(
		"INSERT OR IGNORE INTO schema_migrations (version) VALUES ('%s');",
		escape_sql_literal(version),
	)
	exec(conn, query)
}

upgrade_user_api_tokens_schema :: proc(conn: ^Conn) -> bool {
	// Hub user tokens were removed (135 empties the table; a later release drops
	// it). Tolerate the table being absent.
	if !sqlite_object_exists(conn, "user_api_tokens") do return true
	if !table_column_exists(conn, "user_api_tokens", "label") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN label TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "last_used_at") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN last_used_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "expires_at") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN expires_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "revoked_at") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN revoked_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "user_api_tokens", "created_from") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN created_from TEXT NOT NULL DEFAULT 'operator';") do return false
	if !table_column_exists(conn, "user_api_tokens", "device_label") && !exec(conn, "ALTER TABLE user_api_tokens ADD COLUMN device_label TEXT NOT NULL DEFAULT '';") do return false
	if !exec(conn, "CREATE UNIQUE INDEX IF NOT EXISTS idx_user_api_tokens_token_hash ON user_api_tokens(token_hash);") do return false
	return true
}

upgrade_task_comments_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "task_comments", "author_agent_instance_id") && !exec(conn, "ALTER TABLE task_comments ADD COLUMN author_agent_instance_id TEXT NOT NULL DEFAULT '';") do return false
	return true
}

// fts5_available reports whether the linked SQLite was built with ENABLE_FTS5.
fts5_available :: proc(conn: ^Conn) -> bool {
	if conn == nil || conn.db == nil do return false
	stmt: sqlite3_stmt = nil
	query := "SELECT count(*) FROM pragma_compile_options WHERE compile_options = 'ENABLE_FTS5';"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return false
	return int_v(column_text_unowned(stmt, 0)) > 0
}

// sqlite_object_exists reports whether a table/vtable/trigger of the given name
// exists (sqlite_master lookup). Used to detect the FTS vtable idempotently.
// bridge_tokens_generation_duplicates counts (family_id, kind, generation) groups
// with more than one row; 0 when the table does not exist yet.
bridge_tokens_generation_duplicates :: proc(conn: ^Conn) -> int {
	if conn == nil || conn.db == nil || !sqlite_object_exists(conn, "bridge_tokens") do return 0
	stmt: sqlite3_stmt = nil
	query := "SELECT COUNT(*) FROM (SELECT 1 FROM bridge_tokens GROUP BY family_id, kind, generation HAVING COUNT(*) > 1);"
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return 0
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0
	return int(sqlite3_column_int64(stmt, 0))
}

sqlite_object_exists :: proc(conn: ^Conn, name: string) -> bool {
	if conn == nil || conn.db == nil do return false
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf(
		"SELECT 1 FROM sqlite_master WHERE name='%s' LIMIT 1;",
		escape_sql_literal(name),
	)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	return sqlite3_step(stmt) == SQLITE_ROW
}

// sqlite_trigger_mentions reports whether trigger `name` exists and its SQL
// contains `needle` (a migration that recreates a trigger keys its skip on this).
sqlite_trigger_mentions :: proc(conn: ^Conn, name, needle: string) -> bool {
	if conn == nil || conn.db == nil do return false
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf(
		"SELECT 1 FROM sqlite_master WHERE type='trigger' AND name='%s' AND instr(sql, '%s') > 0 LIMIT 1;",
		escape_sql_literal(name), escape_sql_literal(needle),
	)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	return sqlite3_step(stmt) == SQLITE_ROW
}

// sqlite_table_sql_mentions reports whether table `name` exists and its CREATE
// SQL contains `needle` (a table rebuild keys its skip on a new CHECK value).
sqlite_table_sql_mentions :: proc(conn: ^Conn, name, needle: string) -> bool {
	if conn == nil || conn.db == nil do return false
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf(
		"SELECT 1 FROM sqlite_master WHERE type='table' AND name='%s' AND instr(sql, '%s') > 0 LIMIT 1;",
		escape_sql_literal(name), escape_sql_literal(needle),
	)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	return sqlite3_step(stmt) == SQLITE_ROW
}

table_column_exists :: proc(conn: ^Conn, table_name, column_name: string) -> bool {
	if conn == nil || conn.db == nil do return false
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("PRAGMA table_info(%s);", table_name)
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	for sqlite3_step(stmt) == SQLITE_ROW {
		if column_text_unowned(stmt, 1) == column_name do return true
	}
	return false
}

escape_sql_literal :: proc(value: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for ch in value {
		if ch == '\'' {
			strings.write_string(&builder, "''")
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	return strings.to_string(builder)
}

upgrade_task_chains_v2_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "task_chains", "description") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN description TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "tasks", "description") && !exec(conn, "ALTER TABLE tasks ADD COLUMN description TEXT NOT NULL DEFAULT '';") do return false
	return true
}

upgrade_memory_target_scope_schema :: proc(conn: ^Conn) -> bool {
	// Once migration 025 has converted the memories table to JSON-array list
	// columns (and dropped the scalar scope columns), the legacy scalar backfill
	// must be a no-op — otherwise it would re-create the dropped columns.
	if table_column_exists(conn, "memories", "agent_ids") do return true
	if !table_column_exists(conn, "memories", "project_id") && !exec(conn, "ALTER TABLE memories ADD COLUMN project_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "memories", "template_id") && !exec(conn, "ALTER TABLE memories ADD COLUMN template_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "memories", "bridge_id") && !exec(conn, "ALTER TABLE memories ADD COLUMN bridge_id TEXT NOT NULL DEFAULT '';") do return false
	return true
}

// upgrade_memory_scope_lists_schema is the idempotent end-of-run guard for
// migration 026. When an existing DB still has the scalar scope columns, it adds
// the list columns, backfills each from its scalar (empty -> '[]', else a
// single-element array), and drops the scalars. It is a no-op once agent_ids
// exists. Kept in sync with MIGRATION_026_MEMORY_SCOPE_LISTS.
upgrade_memory_scope_lists_schema :: proc(conn: ^Conn) -> bool {
	if table_column_exists(conn, "memories", "agent_ids") do return true
	if !exec(conn, "ALTER TABLE memories ADD COLUMN agent_ids TEXT NOT NULL DEFAULT '[]';") do return false
	if !exec(conn, "ALTER TABLE memories ADD COLUMN project_ids TEXT NOT NULL DEFAULT '[]';") do return false
	if !exec(conn, "ALTER TABLE memories ADD COLUMN template_ids TEXT NOT NULL DEFAULT '[]';") do return false
	if !exec(conn, "ALTER TABLE memories ADD COLUMN bridge_ids TEXT NOT NULL DEFAULT '[]';") do return false
	if !exec(conn, "UPDATE memories SET agent_ids = CASE WHEN agent_id = '' THEN '[]' ELSE '[\"' || agent_id || '\"]' END, project_ids = CASE WHEN project_id = '' THEN '[]' ELSE '[\"' || project_id || '\"]' END, template_ids = CASE WHEN template_id = '' THEN '[]' ELSE '[\"' || template_id || '\"]' END, bridge_ids = CASE WHEN bridge_id = '' THEN '[]' ELSE '[\"' || bridge_id || '\"]' END;") do return false
	if table_column_exists(conn, "memories", "agent_id") && !exec(conn, "ALTER TABLE memories DROP COLUMN agent_id;") do return false
	if table_column_exists(conn, "memories", "project_id") && !exec(conn, "ALTER TABLE memories DROP COLUMN project_id;") do return false
	if table_column_exists(conn, "memories", "template_id") && !exec(conn, "ALTER TABLE memories DROP COLUMN template_id;") do return false
	if table_column_exists(conn, "memories", "bridge_id") && !exec(conn, "ALTER TABLE memories DROP COLUMN bridge_id;") do return false
	return true
}

upgrade_chat_message_types_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "chat_messages", "message_type") && !exec(conn, "ALTER TABLE chat_messages ADD COLUMN message_type TEXT NOT NULL DEFAULT 'text';") do return false
	if !table_column_exists(conn, "chat_messages", "message_status") && !exec(conn, "ALTER TABLE chat_messages ADD COLUMN message_status TEXT NOT NULL DEFAULT 'complete';") do return false
	if !table_column_exists(conn, "chat_messages", "metadata_json") && !exec(conn, "ALTER TABLE chat_messages ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}';") do return false
	return true
}

upgrade_current_task_and_priority_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "agent_instances", "current_task_id") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN current_task_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "agent_instances", "current_task_role") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN current_task_role TEXT NOT NULL DEFAULT 'none';") do return false
	if !table_column_exists(conn, "tasks", "priority") && !exec(conn, "ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'p2';") do return false
	return true
}

upgrade_title_tracking_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "chat_conversations", "last_activity_at") && !exec(conn, "ALTER TABLE chat_conversations ADD COLUMN last_activity_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "chat_conversations", "last_title_nudge_at") && !exec(conn, "ALTER TABLE chat_conversations ADD COLUMN last_title_nudge_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "chat_conversations", "title_source") && !exec(conn, "ALTER TABLE chat_conversations ADD COLUMN title_source TEXT NOT NULL DEFAULT 'default';") do return false
	if !table_column_exists(conn, "task_chains", "last_activity_at") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN last_activity_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "task_chains", "last_title_nudge_at") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN last_title_nudge_at TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "task_chains", "title_source") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN title_source TEXT NOT NULL DEFAULT 'default';") do return false
	if !exec(conn, "CREATE TABLE IF NOT EXISTS agent_title_counters (agent_id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, counter INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT '');") do return false
	return true
}

upgrade_agent_instance_display_name_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "agent_instances", "display_name") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN display_name TEXT NOT NULL DEFAULT '';") do return false
	return true
}

// upgrade_push_subscriptions_schema idempotently ensures the push_subscriptions
// table, its unique-endpoint index, and the owner-immutable trigger exist. Runs
// on every startup so a DB predating migration 024 self-heals.
upgrade_push_subscriptions_schema :: proc(conn: ^Conn) -> bool {
	return exec(
		conn,
		`CREATE TABLE IF NOT EXISTS push_subscriptions (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  endpoint TEXT NOT NULL,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_push_subscriptions_endpoint ON push_subscriptions(endpoint);
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_owner ON push_subscriptions(owner_user_id);
CREATE TRIGGER IF NOT EXISTS push_subscriptions_owner_immutable BEFORE UPDATE OF owner_user_id ON push_subscriptions BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`,
	)
}

upgrade_memory_description_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "memories", "description") {
		if !exec(conn, "ALTER TABLE memories ADD COLUMN description TEXT NOT NULL DEFAULT '';") do return false
	}
	exec(
		conn,
		"DELETE FROM memories WHERE owner_user_id = 'system' AND (type = 'skill' OR memory_id LIKE 'mem_system_%');",
	)
	return true
}

// upgrade_cards_schema idempotently ensures the cards table, its indexes,
// and the owner-immutable trigger exist (REQ-CARD-1).
upgrade_cards_schema :: proc(conn: ^Conn) -> bool {
	return exec(
		conn,
		`CREATE TABLE IF NOT EXISTS cards (
  card_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  project_id TEXT NOT NULL,
  title TEXT NOT NULL,
  rationale TEXT NOT NULL DEFAULT '',
  scope TEXT NOT NULL DEFAULT 'project',
  provider TEXT NOT NULL DEFAULT '',
  confidence REAL NOT NULL DEFAULT 1.0,
  source_refs_json TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'pending',
  operations_json TEXT NOT NULL DEFAULT '[]',
  guard_json TEXT NOT NULL DEFAULT '{}',
  snooze_until TEXT NOT NULL DEFAULT '',
  ttl_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cards_owner ON cards(owner_user_id);
CREATE INDEX IF NOT EXISTS idx_cards_project ON cards(project_id);
CREATE INDEX IF NOT EXISTS idx_cards_status ON cards(status);
CREATE INDEX IF NOT EXISTS idx_cards_owner_status ON cards(owner_user_id, status);
CREATE TRIGGER IF NOT EXISTS cards_owner_immutable BEFORE UPDATE OF owner_user_id ON cards BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`,
	)
}

// upgrade_projects_state_schema idempotently ensures the projects `state` column
// exists (REQ-PROJ-ARCHIVE-1). Runs on every startup so a DB predating migration
// 037 self-heals, mirroring the agents `state` column.
upgrade_projects_state_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "projects", "state") && !exec(conn, "ALTER TABLE projects ADD COLUMN state TEXT NOT NULL DEFAULT 'active';") do return false
	return true
}

// upgrade_artifact_indexes_schema idempotently ensures the composite indexes
// for the artifacts table exist (REQ-ARTIFACT-DB-INDEXES).
upgrade_artifact_indexes_schema :: proc(conn: ^Conn) -> bool {
	return exec(
		conn,
		`CREATE INDEX IF NOT EXISTS idx_artifacts_owner_project_created ON artifacts(owner_user_id, project_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_instance_created ON artifacts(owner_user_id, agent_instance_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_chain_created ON artifacts(owner_user_id, chain_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_task_created ON artifacts(owner_user_id, task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_created ON artifacts(owner_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_updated ON artifacts(owner_user_id, updated_at DESC);`,
	)
}

// upgrade_pinned_task_chains_schema idempotently ensures the task_chains
// is_pinned and pinned_at columns and index exist (REQ-PIN-DB-SCHEMA).
upgrade_pinned_task_chains_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "task_chains", "is_pinned") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0;") do return false
	if !table_column_exists(conn, "task_chains", "pinned_at") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN pinned_at TEXT NOT NULL DEFAULT '';") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_task_chains_owner_pinned ON task_chains(owner_user_id, is_pinned, pinned_at);") do return false
	return true
}

// upgrade_task_chain_directories_schema idempotently ensures the task_chain_directories
// table and index exist (REQ-BE-TASK-CHAIN-RELEVANT-DIRECTORIES).
upgrade_task_chain_directories_schema :: proc(conn: ^Conn) -> bool {
	return exec(
		conn,
		`CREATE TABLE IF NOT EXISTS task_chain_directories (
  directory_id TEXT PRIMARY KEY,
  chain_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  path TEXT NOT NULL,
  bridge_id TEXT NOT NULL DEFAULT '',
  vcs_kind TEXT NOT NULL DEFAULT '',
  vcs_info_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (chain_id) REFERENCES task_chains(chain_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_task_chain_directories_chain_owner ON task_chain_directories(chain_id, owner_user_id);
CREATE TRIGGER IF NOT EXISTS task_chain_directories_owner_immutable BEFORE UPDATE OF owner_user_id ON task_chain_directories BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`,
	)
}

// upgrade_task_chain_fleets_schema idempotently ensures the task_chain_fleets
// table, provider/model columns, and index exist (REQ-FLEET-SCHEMA-1,
// REQ-FLEET-PT-1).
upgrade_task_chain_fleets_schema :: proc(conn: ^Conn) -> bool {
	if !exec(
		conn,
		`CREATE TABLE IF NOT EXISTS task_chain_fleets (
  task_chain_id TEXT NOT NULL,
  agent_id TEXT NOT NULL,
  capacity INTEGER NOT NULL DEFAULT 1,
  min_warm INTEGER NOT NULL DEFAULT 0,
  idle_ttl_seconds INTEGER NOT NULL DEFAULT 600,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (task_chain_id, agent_id),
  FOREIGN KEY (task_chain_id) REFERENCES task_chains(chain_id) ON DELETE CASCADE
);`,
	) {
		return false
	}
	if !table_column_exists(conn, "task_chain_fleets", "provider") && !exec(conn, "ALTER TABLE task_chain_fleets ADD COLUMN provider TEXT NOT NULL DEFAULT '';") do return false
	if table_column_exists(conn, "task_chain_fleets", "tier") &&
	   !table_column_exists(conn, "task_chain_fleets", "model") {
		if !exec(conn, "ALTER TABLE task_chain_fleets RENAME COLUMN tier TO model;") do return false
	}
	if !table_column_exists(conn, "task_chain_fleets", "model") && !exec(conn, "ALTER TABLE task_chain_fleets ADD COLUMN model TEXT NOT NULL DEFAULT '';") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_task_chain_fleets_chain ON task_chain_fleets(task_chain_id);") do return false
	return true
}

// upgrade_task_bridge_schema idempotently adds tasks.bridge_id (REQ-TB-1): the
// per-task bridge pin deciding which bridge instantiates the task's agent-id
// actors. Empty default = inherit (resolved at promotion time); no backfill.
upgrade_task_bridge_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "tasks", "bridge_id") && !exec(conn, "ALTER TABLE tasks ADD COLUMN bridge_id TEXT NOT NULL DEFAULT '';") do return false
	return true
}

// upgrade_task_v2_schema is 087's twin: it idempotently guarantees every v2
// column exists (a database that reached 087 half-way), then DROPS the legacy
// task-status/actor-ref columns and the votes/subscriptions tables whose data
// 087 has already converted.
//
// THE DROPS ARE TOLERANT. SQLite's DROP COLUMN refuses when the column is
// referenced by an index, trigger or view; on this schema none of them is, but a
// refusal must leave the column in place and log rather than abort startup — the
// engine never reads those columns, so a lingering one is dead weight, not a
// correctness problem. DROP TABLE is unconditional (nothing references them).
upgrade_task_v2_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "tasks", "state") && !exec(conn, "ALTER TABLE tasks ADD COLUMN state TEXT NOT NULL DEFAULT 'backlog';") do return false
	if !table_column_exists(conn, "tasks", "kind") && !exec(conn, "ALTER TABLE tasks ADD COLUMN kind TEXT NOT NULL DEFAULT 'task';") do return false
	if !table_column_exists(conn, "tasks", "attempt_no") && !exec(conn, "ALTER TABLE tasks ADD COLUMN attempt_no INTEGER NOT NULL DEFAULT 0;") do return false
	if !table_column_exists(conn, "tasks", "brief_json") && !exec(conn, "ALTER TABLE tasks ADD COLUMN brief_json TEXT NOT NULL DEFAULT '{}';") do return false
	if !table_column_exists(conn, "tasks", "blocked_on_json") && !exec(conn, "ALTER TABLE tasks ADD COLUMN blocked_on_json TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "tasks", "requires_user_approval") && !exec(conn, "ALTER TABLE tasks ADD COLUMN requires_user_approval INTEGER NOT NULL DEFAULT 0;") do return false
	if !table_column_exists(conn, "tasks", "ready_since") && !exec(conn, "ALTER TABLE tasks ADD COLUMN ready_since TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "tasks", "stage_key") && !exec(conn, "ALTER TABLE tasks ADD COLUMN stage_key TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "tasks", "stage_index") && !exec(conn, "ALTER TABLE tasks ADD COLUMN stage_index INTEGER NOT NULL DEFAULT 0;") do return false
	if !table_column_exists(conn, "tasks", "generated_by_json") && !exec(conn, "ALTER TABLE tasks ADD COLUMN generated_by_json TEXT NOT NULL DEFAULT '';") do return false
	if !sqlite_object_exists(conn, "mixed_work_engine_epoch") && !table_column_exists(conn, "task_chains", "workflow_def_ref") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN workflow_def_ref TEXT NOT NULL DEFAULT '';") do return false
	if !sqlite_object_exists(conn, "mixed_work_engine_epoch") && !table_column_exists(conn, "task_chains", "workflow_snapshot_json") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN workflow_snapshot_json TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "task_chains", "defaults_json") && !exec(conn, "ALTER TABLE task_chains ADD COLUMN defaults_json TEXT NOT NULL DEFAULT '{}';") do return false
	if !table_column_exists(conn, "task_chain_fleets", "bridge_id") && !exec(conn, "ALTER TABLE task_chain_fleets ADD COLUMN bridge_id TEXT NOT NULL DEFAULT '';") do return false
	if !sqlite_object_exists(conn, "mixed_work_engine_epoch") && !exec(conn, "CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_chain_stage ON tasks(chain_id, stage_key, stage_index) WHERE stage_key <> '';") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_tasks_chain_state ON tasks(chain_id, state);") do return false
	// M1 review follow-ups (additive, idempotent): idle_since lets the Idle_TTL
	// timer detect a moved deadline and be rebuilt on boot (S4); extended_at
	// records the one-shot clock-jump extension on the lease row (S5).
	if !table_column_exists(conn, "agent_instances", "idle_since") && !exec(conn, "ALTER TABLE agent_instances ADD COLUMN idle_since TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "task_leases", "extended_at") && !exec(conn, "ALTER TABLE task_leases ADD COLUMN extended_at TEXT NOT NULL DEFAULT '';") do return false
	// Durable summary_overflow episode latch. A chain that already reported an
	// overflow starts inside its episode, so the upgrade does not re-notify it.
	if !table_column_exists(conn, "chain_summaries", "overflow_active") {
		if !exec(conn, "ALTER TABLE chain_summaries ADD COLUMN overflow_active INTEGER NOT NULL DEFAULT 0;") do return false
		if !exec(conn, "UPDATE chain_summaries SET overflow_active = 1 WHERE EXISTS (SELECT 1 FROM task_events e WHERE e.chain_id = chain_summaries.chain_id AND e.owner_user_id = chain_summaries.owner_user_id AND e.kind = 'summary_overflow');") do return false
	}
	// Curated notes stored apart from the rendered body; legacy rows stay
	// curated_stored = 0 until their next rebuild extracts the notes once.
	if !table_column_exists(conn, "chain_summaries", "curated_body") && !exec(conn, "ALTER TABLE chain_summaries ADD COLUMN curated_body TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "chain_summaries", "curated_stored") && !exec(conn, "ALTER TABLE chain_summaries ADD COLUMN curated_stored INTEGER NOT NULL DEFAULT 0;") do return false
	// Legacy drops (tolerant; see the proc comment).
	drop_legacy_column(conn, "tasks", "status")
	drop_legacy_column(conn, "tasks", "assignee_ref_json")
	drop_legacy_column(conn, "tasks", "reviewer_refs_json")
	drop_legacy_column(conn, "task_chains", "default_reviewer_refs_json")
	if !exec(conn, "DROP TABLE IF EXISTS task_votes;") do return false
	if !exec(conn, "DROP TABLE IF EXISTS task_subscriptions;") do return false
	return true
}

// drop_legacy_column drops a column if it still exists, logging (not failing)
// when SQLite refuses. See upgrade_task_v2_schema for why that is acceptable.
drop_legacy_column :: proc(conn: ^Conn, table, column: string) {
	if !table_column_exists(conn, table, column) do return
	stmt := fmt.tprintf("ALTER TABLE %s DROP COLUMN %s;", table, column)
	if !exec(conn, stmt) {
		fmt.eprintfln("[migrations] task v2: could not drop legacy column %s.%s (left in place; the engine never reads it)", table, column)
	}
}

// upgrade_vault_directory_schema is the idempotent self-heal twin of migration 092:
// the file is written with IF NOT EXISTS throughout, so it is simply re-run.
upgrade_vault_directory_schema :: proc(conn: ^Conn) -> bool {
	if !exec(conn, MIGRATION_092_VAULT_DEVICE_DIRECTORY) do return false
	// 100's column on a table 092 created before it existed (CREATE IF NOT EXISTS keeps the old shape).
	if !table_column_exists(conn, "vault_devices", "pair_hub_origin") {
		return exec(conn, MIGRATION_100_VAULT_PAIR_HUB_ORIGIN)
	}
	return true
}



// upgrade_shell_sessions_kind_and_key_schema is the idempotent self-heal twin of
// migration 048, for a database whose ledger says 041 ran but which predates 048
// (or was bootstrapped from a stale embedded copy). It re-runs the migration's
// SQL, which is written to be safe on an already-migrated table: the UPDATEs and
// the DELETE match nothing once the vocabulary is collapsed, and the rebuild is
// skipped entirely when shell_sessions_owner_session already exists.
//
// KEYED ON THE SAME LAST OBJECT as the skip guard, deliberately. This twin is the
// path that REPAIRS a database 048 did not fully reach, so it is the last place that
// should refuse to run because an EARLY object of 048 happens to be present.
upgrade_shell_sessions_kind_and_key_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "shell_sessions") do return true
	if sqlite_object_exists(conn, "shell_sessions_owner_session") do return true
	return exec(conn, MIGRATION_048_SHELL_SESSIONS_KIND_AND_KEY)
}

// upgrade_shell_sessions_background_schema is the idempotent self-heal twin of
// migration 049 (REQ-SHELL-2), for the same class of database 048's twin exists
// for.
//
// It is per-COLUMN rather than one exec of the migration file, because 049 is
// ALTER TABLE ADD COLUMN and SQLite has no IF NOT EXISTS for that: a single
// re-exec is a hard "duplicate column name" error that would fail startup. The
// two columns are also checked independently, so a database that somehow got one
// of them gains the other instead of being stuck.
upgrade_shell_sessions_background_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "shell_sessions") do return true
	if !table_column_exists(conn, "shell_sessions", "background") {
		if !exec(conn, "ALTER TABLE shell_sessions ADD COLUMN background INTEGER NOT NULL DEFAULT 0;") do return false
	}
	if !table_column_exists(conn, "shell_sessions", "conversation_id") {
		if !exec(conn, "ALTER TABLE shell_sessions ADD COLUMN conversation_id TEXT NOT NULL DEFAULT '';") do return false
	}
	return exec(
		conn,
		"CREATE INDEX IF NOT EXISTS shell_sessions_conversation ON shell_sessions(owner_user_id, conversation_id);",
	)
}

// upgrade_shell_sessions_run_seq_schema is the idempotent self-heal twin of
// migration 051 (REQ-SHELL-4), for the same class of database the three twins above
// exist for.
//
// SINGLE-OBJECT, so it is the simplest of the four: 051 adds one column and creates
// no index (run_seq is read from a row already fetched by primary key and is never
// a lookup key — see the migration file), so there is no second half that a
// non-transactional pass could leave missing. The existence check is still required,
// because ALTER TABLE ADD COLUMN is not idempotent in SQLite.
upgrade_shell_sessions_run_seq_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "shell_sessions") do return true
	if table_column_exists(conn, "shell_sessions", "run_seq") do return true
	return exec(conn, "ALTER TABLE shell_sessions ADD COLUMN run_seq INTEGER NOT NULL DEFAULT 0;")
}

// upgrade_shell_sessions_kill_intent_schema is the idempotent self-heal twin of
// migration 050 (REQ-SHELL-3), for the same class of database 048's and 049's
// twins exist for.
//
// PER-OBJECT, and both objects are checked independently — the column AND the
// partial index. 050 creates two objects and run_migrations is not transactional,
// so "the column exists" does not imply "the index exists": a pass that died
// between them leaves exactly that state, and a twin that checked only the column
// would leave the replay lookup without its index forever. Checking each half
// separately means a database that somehow got one gains the other instead of
// being stuck with half a migration.
upgrade_shell_sessions_kill_intent_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "shell_sessions") do return true
	if !table_column_exists(conn, "shell_sessions", "kill_requested_at") {
		if !exec(conn, "ALTER TABLE shell_sessions ADD COLUMN kill_requested_at TEXT NOT NULL DEFAULT '';") do return false
	}
	// CREATE INDEX IF NOT EXISTS is idempotent on its own, unlike ADD COLUMN, so this
	// needs no existence check of its own — it is the statement that repairs the
	// partial-apply case the guards above are keyed on.
	return exec(
		conn,
		"CREATE INDEX IF NOT EXISTS shell_sessions_pending_kill ON shell_sessions(bridge_id) WHERE kill_requested_at != '';",
	)
}

upgrade_bridge_version_and_updates_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "bridges") do return true
	if !table_column_exists(conn, "bridges", "version") && !exec(conn, "ALTER TABLE bridges ADD COLUMN version TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "bridges", "commit_sha") && !exec(conn, "ALTER TABLE bridges ADD COLUMN commit_sha TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "bridges", "build_timestamp") && !exec(conn, "ALTER TABLE bridges ADD COLUMN build_timestamp TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "bridges", "update_status") && !exec(conn, "ALTER TABLE bridges ADD COLUMN update_status TEXT NOT NULL DEFAULT 'idle';") do return false
	if !table_column_exists(conn, "bridges", "update_error") && !exec(conn, "ALTER TABLE bridges ADD COLUMN update_error TEXT NOT NULL DEFAULT '';") do return false
	return true
}

upgrade_bridge_update_progress_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "bridges") do return true
	if !table_column_exists(conn, "bridges", "update_message") && !exec(conn, "ALTER TABLE bridges ADD COLUMN update_message TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "bridges", "update_progress") && !exec(conn, "ALTER TABLE bridges ADD COLUMN update_progress INTEGER NOT NULL DEFAULT 0;") do return false
	return true
}

upgrade_memory_action_expiry_schema :: proc(conn: ^Conn) -> bool {
	if !sqlite_object_exists(conn, "memories") do return true
	if !table_column_exists(conn, "memories", "expires_at") {
		if !exec(conn, "ALTER TABLE memories ADD COLUMN expires_at TEXT NOT NULL DEFAULT '';") do return false
	}
	return true
}

MIGRATION_EVENTS_009_INCREMENTAL_INBOX :: #load("migrations/events_009_incremental_inbox.sql", string)

MIGRATION_WEBHOOKS_001 :: #load("migrations/webhooks_001.sql",string)

MIGRATION_WEBHOOKS_002_DEDUPE_HEADER :: #load("migrations/webhooks_002_dedupe_header.sql",string)
