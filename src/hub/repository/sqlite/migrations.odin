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

MIGRATION_005_AGENT_TO_AGENT_CROSS_CHAIN_MEMORY :: #load("migrations/005_agent_to_agent_cross_chain_memory.sql", string)

MIGRATION_006_LIVE_AGENTS_SKILL_MEMORY :: #load("migrations/006_live_agents_skill_memory.sql", string)

MIGRATION_007_HIDE_AGENT_TO_AGENT_FROM_USER_CHAT :: #load("migrations/007_hide_agent_to_agent_from_user_chat.sql", string)

MIGRATION_008_READ_INBOUND_MESSAGES_SKILL_MEMORY :: #load("migrations/008_read_inbound_messages_skill_memory.sql", string)

MIGRATION_009_ARTIFACT_METADATA :: #load("migrations/009_artifact_metadata.sql", string)

MIGRATION_010_ARTIFACT_USAGE_SKILL_MEMORY :: #load("migrations/010_artifact_usage_skill_memory.sql", string)

MIGRATION_011_ARTIFACT_DOWNLOAD_SKILL_MEMORY :: #load("migrations/011_artifact_download_skill_memory.sql", string)

MIGRATION_012_TASK_CHAINS_V2 :: #load("migrations/012_task_chains_v2.sql", string)

MIGRATION_013_TASK_WORKFLOW_SKILL_MEMORY :: #load("migrations/013_task_workflow_skill_memory.sql", string)

MIGRATION_014_TASK_WORKFLOW_SKILL_COMMENTS :: #load("migrations/014_task_workflow_skill_comments.sql", string)

MIGRATION_015_MEMORY_TARGET_SCOPE :: #load("migrations/015_memory_target_scope.sql", string)

MIGRATION_018_COORDINATOR_MEMBER_BACKFILL :: #load("migrations/018_coordinator_member_backfill.sql", string)

MIGRATION_017_CHAT_MESSAGE_TYPES :: #load("migrations/017_chat_message_types.sql", string)

MIGRATION_016_MEMORY_WORKFLOW_SKILL_MEMORY :: #load("migrations/016_memory_workflow_skill_memory.sql", string)

MIGRATION_019_CURRENT_TASK_AND_PRIORITY :: #load("migrations/019_current_task_and_priority.sql", string)

// MIGRATION_020_TITLE_TRACKING adds per-run auto-title tracking fields to
// conversations and task chains, plus a per-agent monotonic counter table used
// to mint default titles of the form "<agent-name> #<n>". The embedded fallback
// mirrors src/hub/repository/sqlite/migrations/020_title_tracking.sql.
MIGRATION_020_TITLE_TRACKING :: #load("migrations/020_title_tracking.sql", string)

// MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME adds human-readable display_name
// support to agent_instances, defaulting to "<agent-name> #<n>".
MIGRATION_021_AGENT_INSTANCE_DISPLAY_NAME :: #load("migrations/021_agent_instance_display_name.sql", string)

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
MIGRATION_027_DEFAULT_COORDINATOR_AGENT :: #load("migrations/027_default_coordinator_agent.sql", string)

// MIGRATION_028_MEMORY_DESCRIPTION_AND_CLEANUP adds first-class description to
// memories and deletes legacy seeded system memories in favor of static skills.
MIGRATION_028_MEMORY_DESCRIPTION_AND_CLEANUP :: #load("migrations/028_memory_description_and_cleanup.sql", string)

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
MIGRATION_033_DEFAULT_AGENTS_AND_CONVERSATION_PROJECT :: #load("migrations/033_default_agents_and_conversation_project.sql", string)

// MIGRATION_034_CARDS creates the cards table, indexes, and owner-immutable trigger
// for Curator action cards (REQ-CARD-1).
MIGRATION_034_CARDS :: #load("migrations/034_cards.sql", string)

// MIGRATION_035_CURATOR_TEMPLATE seeds the built-in Curator system template
// (tmpl_curator) for activity-driven Action Cards (REQ-AGENT-1).
MIGRATION_035_CURATOR_TEMPLATE :: #load("migrations/035_curator_template.sql", string)

// MIGRATION_036_ACTION_TARGETS adds target_agent_id, target_bridge_id, target_provider,
// target_tier, target_project_id to actions table (REQ-SCHED-1).
MIGRATION_036_ACTION_TARGETS :: #load("migrations/036_action_targets.sql", string)

// MIGRATION_037_PROJECT_STATE adds the soft-archive `state` column to projects
// (mirrors the agents `state` column). Default 'active'; archiving is reversible.
MIGRATION_037_PROJECT_STATE :: #load("migrations/037_project_state.sql", string)

// MIGRATION_038_ACTION_INSTANCE_STRATEGY adds instance_strategy + last_spawned_instance_id
// to actions (REQ-SCHED-2). Defaults keep existing rows on the legacy "reuse" behavior.
MIGRATION_038_ACTION_INSTANCE_STRATEGY :: #load("migrations/038_action_instance_strategy.sql", string)

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

// MIGRATION_045_FIG_PROJECTS adds Fig workspace metadata columns to projects (Cloudtop).
MIGRATION_045_FIG_PROJECTS :: #load("migrations/045_fig_projects.sql", string)

// MIGRATION_046_LSP_SERVER_PATTERNS adds dir_pattern to lsp_server_configs (REQ-LSP-DIR-PAT-1).
MIGRATION_046_LSP_SERVER_PATTERNS :: #load("migrations/046_lsp_server_patterns.sql", string)

migration_order :: [48]string{"001_foundation.sql", "002_owner_scoped_core.sql", "003_device_tokens.sql", "004_default_skill_memory.sql", "005_agent_to_agent_cross_chain_memory.sql", "006_live_agents_skill_memory.sql", "007_hide_agent_to_agent_from_user_chat.sql", "008_read_inbound_messages_skill_memory.sql", "009_artifact_metadata.sql", "010_artifact_usage_skill_memory.sql", "011_artifact_download_skill_memory.sql", "012_task_chains_v2.sql", "013_task_workflow_skill_memory.sql", "014_task_workflow_skill_comments.sql", "015_memory_target_scope.sql", "016_memory_workflow_skill_memory.sql", "017_chat_message_types.sql", "018_coordinator_member_backfill.sql", "019_current_task_and_priority.sql", "020_title_tracking.sql", "021_agent_instance_display_name.sql", "022_scheduled_prompts.sql", "023_actions.sql", "024_push_subscriptions.sql", "025_lookup_indexes.sql", "026_memory_scope_lists.sql", "027_default_coordinator_agent.sql", "028_memory_description_and_cleanup.sql", "029_search_fts_comments.sql", "030_search_fts_all.sql", "031_search_fts_messages.sql", "032_ai_native_templates.sql", "033_default_agents_and_conversation_project.sql", "034_cards.sql", "035_curator_template.sql", "036_action_targets.sql", "037_project_state.sql", "038_action_instance_strategy.sql", "039_shell_jobs.sql", "040_artifact_list_indexes.sql", "041_shell_sessions.sql", "042_pinned_task_chains.sql", "043_experiments.sql", "043_task_chain_directories.sql", "044_issues.sql", "044_lsp_servers.sql", "045_fig_projects.sql", "046_lsp_server_patterns.sql"}

run_migrations :: proc(conn: ^Conn, migrations_dir := "src/hub/repository/sqlite/migrations") -> (bool, domain.Domain_Error) {
	if conn == nil || conn.db == nil {
		return false, domain.domain_error(.Internal_Error, "database connection is not open")
	}
	for name in migration_order {
		if name == "016_memory_workflow_skill_memory.sql" {
			if !upgrade_memory_target_scope_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory target scope schema upgrade failed")
		}
		if migration_applied(conn, name) do continue
		if name == "003_device_tokens.sql" && table_column_exists(conn, "user_api_tokens", "created_from") && table_column_exists(conn, "user_api_tokens", "device_label") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "017_chat_message_types.sql" && table_column_exists(conn, "chat_messages", "message_type") && table_column_exists(conn, "chat_messages", "message_status") && table_column_exists(conn, "chat_messages", "metadata_json") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "019_current_task_and_priority.sql" && table_column_exists(conn, "agent_instances", "current_task_id") && table_column_exists(conn, "agent_instances", "current_task_role") && table_column_exists(conn, "tasks", "priority") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "020_title_tracking.sql" && table_column_exists(conn, "chat_conversations", "title_source") && table_column_exists(conn, "task_chains", "title_source") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "021_agent_instance_display_name.sql" && table_column_exists(conn, "agent_instances", "display_name") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "022_scheduled_prompts.sql" && table_column_exists(conn, "scheduled_prompts", "id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "023_actions.sql" && table_column_exists(conn, "actions", "cron_expr") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "024_push_subscriptions.sql" && table_column_exists(conn, "push_subscriptions", "endpoint") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "026_memory_scope_lists.sql" && table_column_exists(conn, "memories", "agent_ids") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "028_memory_description_and_cleanup.sql" && table_column_exists(conn, "memories", "description") {
			mark_migration_applied(conn, name)
			continue
		}
		// FTS5 migrations are skipped (marked applied) when FTS5 is unavailable or the
		// vtable already exists, so the append-only ledger stays consistent and
		// non-FTS builds boot on the indexed-LIKE fallback.
		if name == "029_search_fts_comments.sql" && (!fts5_available(conn) || sqlite_object_exists(conn, "task_comments_fts")) {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "030_search_fts_all.sql" && (!fts5_available(conn) || sqlite_object_exists(conn, "memories_fts")) {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "031_search_fts_messages.sql" && (!fts5_available(conn) || sqlite_object_exists(conn, "chat_messages_fts")) {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "034_cards.sql" && table_column_exists(conn, "cards", "card_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "036_action_targets.sql" && table_column_exists(conn, "actions", "target_agent_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "037_project_state.sql" && table_column_exists(conn, "projects", "state") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "038_action_instance_strategy.sql" && table_column_exists(conn, "actions", "instance_strategy") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "039_shell_jobs.sql" && table_column_exists(conn, "shell_jobs", "exec_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "040_artifact_list_indexes.sql" && sqlite_object_exists(conn, "idx_artifacts_owner_created") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "041_shell_sessions.sql" && table_column_exists(conn, "shell_sessions", "session_id") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "042_pinned_task_chains.sql" && table_column_exists(conn, "task_chains", "is_pinned") && table_column_exists(conn, "task_chains", "pinned_at") {
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
		if name == "043_task_chain_directories.sql" && sqlite_object_exists(conn, "task_chain_directories") {
			mark_migration_applied(conn, name)
			continue
		}
		if (name == "045_fig_projects.sql" || name == "044_fig_projects.sql" || name == "043_fig_projects.sql" || name == "041_fig_projects.sql" || name == "040_fig_projects.sql" || name == "034_fig_projects.sql" || name == "032_fig_projects.sql" || name == "031_fig_projects.sql" || name == "029_fig_projects.sql" || name == "028_fig_projects.sql" || name == "027_fig_projects.sql") && table_column_exists(conn, "projects", "project_type") && table_column_exists(conn, "projects", "workspace_name") && table_column_exists(conn, "projects", "relative_path") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "044_issues.sql" && sqlite_object_exists(conn, "issues") && sqlite_object_exists(conn, "issue_comments") && sqlite_object_exists(conn, "issue_votes") {
			mark_migration_applied(conn, name)
			continue
		}
		if name == "046_lsp_server_patterns.sql" && table_column_exists(conn, "lsp_server_configs", "dir_pattern") {
			mark_migration_applied(conn, name)
			continue
		}
		sql := migration_sql(name, migrations_dir)
		if sql == "" {
			return false, domain.domain_error(.Internal_Error, fmt.tprintf("missing migration %s", name))
		}
		if !exec(conn, sql) {
			delete(sql)
			return false, domain.domain_error(.Internal_Error, fmt.tprintf("migration failed: %s", name))
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
	if !upgrade_scheduled_prompts_schema(conn) do return false, domain.domain_error(.Internal_Error, "scheduled prompts schema upgrade failed")
	if !upgrade_actions_schema(conn) do return false, domain.domain_error(.Internal_Error, "actions schema upgrade failed")
	if !upgrade_push_subscriptions_schema(conn) do return false, domain.domain_error(.Internal_Error, "push subscriptions schema upgrade failed")
	if !upgrade_memory_description_schema(conn) do return false, domain.domain_error(.Internal_Error, "memory description schema upgrade failed")
	if !upgrade_cards_schema(conn) do return false, domain.domain_error(.Internal_Error, "cards schema upgrade failed")
	if !upgrade_projects_state_schema(conn) do return false, domain.domain_error(.Internal_Error, "projects state schema upgrade failed")
	if !upgrade_fig_projects_schema(conn) do return false, domain.domain_error(.Internal_Error, "fig projects schema upgrade failed")
	if !upgrade_artifact_indexes_schema(conn) do return false, domain.domain_error(.Internal_Error, "artifact indexes schema upgrade failed")
	if !upgrade_pinned_task_chains_schema(conn) do return false, domain.domain_error(.Internal_Error, "pinned task chains schema upgrade failed")
	if !upgrade_task_chain_directories_schema(conn) do return false, domain.domain_error(.Internal_Error, "task_chain_directories schema upgrade failed")
	if !upgrade_lsp_servers_schema(conn) do return false, domain.domain_error(.Internal_Error, "lsp server configs schema upgrade failed")
	return true, domain.Domain_Error{}
}

migration_sql :: proc(name, migrations_dir: string) -> string {
	if migrations_dir != "" {
		path := strings.concatenate({migrations_dir, "/", name}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.allocator)
		if err == nil {
			return string(data)
		}
	}
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
	if name == "045_fig_projects.sql" || name == "044_fig_projects.sql" || name == "043_fig_projects.sql" || name == "041_fig_projects.sql" || name == "040_fig_projects.sql" || name == "034_fig_projects.sql" || name == "032_fig_projects.sql" || name == "031_fig_projects.sql" || name == "029_fig_projects.sql" || name == "028_fig_projects.sql" || name == "027_fig_projects.sql" do return strings.clone(MIGRATION_045_FIG_PROJECTS)
	if name == "046_lsp_server_patterns.sql" do return strings.clone(MIGRATION_046_LSP_SERVER_PATTERNS)
	return ""
}

migration_applied :: proc(conn: ^Conn, version: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("SELECT 1 FROM schema_migrations WHERE version='%s' LIMIT 1;", escape_sql_literal(version))
	if sqlite3_prepare_v2(conn.db, cstring(raw_data(query)), c.int(-1), &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) == SQLITE_ROW do return true
	if version == "045_fig_projects.sql" {
		return migration_applied(conn, "044_fig_projects.sql") || migration_applied(conn, "043_fig_projects.sql") || migration_applied(conn, "041_fig_projects.sql") || migration_applied(conn, "040_fig_projects.sql")
	}
	if version == "044_fig_projects.sql" {
		return migration_applied(conn, "043_fig_projects.sql") || migration_applied(conn, "041_fig_projects.sql") || migration_applied(conn, "040_fig_projects.sql")
	}
	return false
}

mark_migration_applied :: proc(conn: ^Conn, version: string) {
	query := fmt.tprintf("INSERT OR IGNORE INTO schema_migrations (version) VALUES ('%s');", escape_sql_literal(version))
	exec(conn, query)
}

upgrade_user_api_tokens_schema :: proc(conn: ^Conn) -> bool {
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
sqlite_object_exists :: proc(conn: ^Conn, name: string) -> bool {
	if conn == nil || conn.db == nil do return false
	stmt: sqlite3_stmt = nil
	query := fmt.tprintf("SELECT 1 FROM sqlite_master WHERE name='%s' LIMIT 1;", escape_sql_literal(name))
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

upgrade_scheduled_prompts_schema :: proc(conn: ^Conn) -> bool {
	return exec(conn, `CREATE TABLE IF NOT EXISTS scheduled_prompts (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  target_instance_id TEXT NOT NULL,
  prompt_text TEXT NOT NULL,
  target_run_at TEXT NOT NULL,
  interval TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active',
  in_flight INTEGER NOT NULL DEFAULT 0,
  leased_at TEXT NOT NULL DEFAULT '',
  deleted_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_scheduled_prompts_target ON scheduled_prompts(target_instance_id);`)
}

upgrade_actions_schema :: proc(conn: ^Conn) -> bool {
	if !exec(conn, `CREATE TABLE IF NOT EXISTS actions (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL,
  target_instance_id TEXT NOT NULL,
  prompt_text TEXT NOT NULL,
  cron_expr TEXT NOT NULL DEFAULT '',
  timezone TEXT NOT NULL DEFAULT 'UTC',
  blackout_dates TEXT NOT NULL DEFAULT '[]',
  active_from TEXT NOT NULL DEFAULT '',
  active_until TEXT NOT NULL DEFAULT '',
  target_run_at TEXT NOT NULL DEFAULT '',
  interval TEXT NOT NULL DEFAULT '',
  state TEXT NOT NULL DEFAULT 'active',
  in_flight INTEGER NOT NULL DEFAULT 0,
  leased_at TEXT NOT NULL DEFAULT '',
  deleted_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_actions_target ON actions(target_instance_id);
CREATE INDEX IF NOT EXISTS idx_actions_owner_run ON actions(owner_user_id, target_run_at);
CREATE INDEX IF NOT EXISTS idx_actions_due ON actions(target_run_at) WHERE state = 'active' AND in_flight = 0 AND deleted_at = '';
CREATE TRIGGER IF NOT EXISTS actions_owner_immutable BEFORE UPDATE OF owner_user_id ON actions BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`) {
		return false
	}

	if !table_column_exists(conn, "actions", "cron_expr") && !exec(conn, "ALTER TABLE actions ADD COLUMN cron_expr TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "timezone") && !exec(conn, "ALTER TABLE actions ADD COLUMN timezone TEXT NOT NULL DEFAULT 'UTC';") do return false
	if !table_column_exists(conn, "actions", "blackout_dates") && !exec(conn, "ALTER TABLE actions ADD COLUMN blackout_dates TEXT NOT NULL DEFAULT '[]';") do return false
	if !table_column_exists(conn, "actions", "active_from") && !exec(conn, "ALTER TABLE actions ADD COLUMN active_from TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "active_until") && !exec(conn, "ALTER TABLE actions ADD COLUMN active_until TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "target_agent_id") && !exec(conn, "ALTER TABLE actions ADD COLUMN target_agent_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "target_bridge_id") && !exec(conn, "ALTER TABLE actions ADD COLUMN target_bridge_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "target_provider") && !exec(conn, "ALTER TABLE actions ADD COLUMN target_provider TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "target_tier") && !exec(conn, "ALTER TABLE actions ADD COLUMN target_tier TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "target_project_id") && !exec(conn, "ALTER TABLE actions ADD COLUMN target_project_id TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "actions", "instance_strategy") && !exec(conn, "ALTER TABLE actions ADD COLUMN instance_strategy TEXT NOT NULL DEFAULT 'reuse';") do return false
	if !table_column_exists(conn, "actions", "last_spawned_instance_id") && !exec(conn, "ALTER TABLE actions ADD COLUMN last_spawned_instance_id TEXT NOT NULL DEFAULT '';") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_actions_target_agent ON actions(target_agent_id);") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_actions_target_bridge ON actions(target_bridge_id);") do return false

	if table_column_exists(conn, "scheduled_prompts", "id") {
		exec(conn, `INSERT OR IGNORE INTO actions (
  id, owner_user_id, target_instance_id, prompt_text, target_run_at,
  interval, state, in_flight, leased_at, deleted_at, created_at, updated_at
)
SELECT
  id, owner_user_id, target_instance_id, prompt_text, target_run_at,
  interval, state, in_flight, leased_at, deleted_at, created_at, updated_at
FROM scheduled_prompts;`)
	}
	return true
}

// upgrade_push_subscriptions_schema idempotently ensures the push_subscriptions
// table, its unique-endpoint index, and the owner-immutable trigger exist. Runs
// on every startup so a DB predating migration 024 self-heals.
upgrade_push_subscriptions_schema :: proc(conn: ^Conn) -> bool {
	return exec(conn, `CREATE TABLE IF NOT EXISTS push_subscriptions (
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
CREATE TRIGGER IF NOT EXISTS push_subscriptions_owner_immutable BEFORE UPDATE OF owner_user_id ON push_subscriptions BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`)
}

upgrade_memory_description_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "memories", "description") {
		if !exec(conn, "ALTER TABLE memories ADD COLUMN description TEXT NOT NULL DEFAULT '';") do return false
	}
	exec(conn, "DELETE FROM memories WHERE owner_user_id = 'system' AND (type = 'skill' OR memory_id LIKE 'mem_system_%');")
	return true
}

upgrade_fig_projects_schema :: proc(conn: ^Conn) -> bool {
	if !table_column_exists(conn, "projects", "project_type") && !exec(conn, "ALTER TABLE projects ADD COLUMN project_type TEXT NOT NULL DEFAULT 'local';") do return false
	if !table_column_exists(conn, "projects", "workspace_name") && !exec(conn, "ALTER TABLE projects ADD COLUMN workspace_name TEXT NOT NULL DEFAULT '';") do return false
	if !table_column_exists(conn, "projects", "relative_path") && !exec(conn, "ALTER TABLE projects ADD COLUMN relative_path TEXT NOT NULL DEFAULT '';") do return false
	if !exec(conn, "CREATE INDEX IF NOT EXISTS idx_projects_owner_type ON projects(owner_user_id, project_type);") do return false
	return true
}

// upgrade_cards_schema idempotently ensures the cards table, its indexes,
// and the owner-immutable trigger exist (REQ-CARD-1).
upgrade_cards_schema :: proc(conn: ^Conn) -> bool {
	return exec(conn, `CREATE TABLE IF NOT EXISTS cards (
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
CREATE TRIGGER IF NOT EXISTS cards_owner_immutable BEFORE UPDATE OF owner_user_id ON cards BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`)
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
	return exec(conn, `CREATE INDEX IF NOT EXISTS idx_artifacts_owner_project_created ON artifacts(owner_user_id, project_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_instance_created ON artifacts(owner_user_id, agent_instance_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_chain_created ON artifacts(owner_user_id, chain_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_task_created ON artifacts(owner_user_id, task_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_created ON artifacts(owner_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_artifacts_owner_updated ON artifacts(owner_user_id, updated_at DESC);`)
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
	return exec(conn, `CREATE TABLE IF NOT EXISTS task_chain_directories (
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
CREATE TRIGGER IF NOT EXISTS task_chain_directories_owner_immutable BEFORE UPDATE OF owner_user_id ON task_chain_directories BEGIN SELECT RAISE(ABORT, 'owner_user_id is immutable'); END;`)
}

upgrade_lsp_servers_schema :: proc(conn: ^Conn) -> bool {
	if sqlite_object_exists(conn, "lsp_server_configs") && !table_column_exists(conn, "lsp_server_configs", "dir_pattern") {
		if !exec(conn, "ALTER TABLE lsp_server_configs ADD COLUMN dir_pattern TEXT NOT NULL DEFAULT '';") do return false
	}
	return true
}


