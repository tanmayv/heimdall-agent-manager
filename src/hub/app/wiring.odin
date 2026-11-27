package app

import webhooks "odin_test:hub/service/webhooks"

import "core:fmt"
import "core:encoding/json"
import contracts "odin_test:contracts"
import "base:runtime"
import actions_service "odin_test:hub/service/actions"
import eventinbox "odin_test:hub/service/eventinbox"
import eventrelay "odin_test:hub/service/eventrelay"
import delivery "odin_test:hub/service/delivery"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import dbt "odin_test:hub/platform/dbtelemetry"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import mcp_service "odin_test:hub/service/mcp"
import bots_service "odin_test:hub/service/bots"
import channel "odin_test:hub/service/channel"
import agent_service "odin_test:hub/service/agent"
import fleet_application "odin_test:hub/service/fleet_application"
import bridge_service "odin_test:hub/service/bridge"
import bridge_log_service "odin_test:hub/service/bridge_log"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import shell_session_svc "odin_test:hub/service/shell_session"
import content_service "odin_test:hub/service/content"
import device_auth_service "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import project_service "odin_test:hub/service/project"
import placement "odin_test:hub/service/placement"
import provider_service "odin_test:hub/service/provider"
import push_service "odin_test:hub/service/push"
import search_service "odin_test:hub/service/search"
import taskchain_service "odin_test:hub/service/taskchain"
import taskv2 "odin_test:hub/service/taskv2"
import user_service "odin_test:hub/service/user"
import billing_service "odin_test:hub/service/billing"
import vault_directory_service "odin_test:hub/service/vault_directory"
import card_service "odin_test:hub/service/card"
import issue_service "odin_test:hub/service/issue"
import http "odin_test:hub/transport/http"
import platform "odin_test:hub/platform"

App_Graph :: struct {
	actions: actions_service.Service,
 action_router: actions_service.Router,
 action_runtime: actions_service.Runtime,
 placement: placement.Service,
 placement_handlers: http.Placement_Handlers,
	event_relay: eventrelay.Service,
	delivery: ^delivery.Service,
	delivery_commands: project_service.Bridge_Command_Sink,
	sqlite_pipeline_deliveries: sqlite.Pipeline_Delivery_Repo_SQLite,
	event_inbox: eventinbox.Service,
	event_inbox_runtime: eventinbox.Runtime,
	event_inbox_handlers: http.Event_Inbox_Handlers,
	sqlite_event_outbox: sqlite.Event_Outbox_Repo_SQLite,
 sqlite_webhooks: sqlite.Event_Webhook_Repo_SQLite,
 webhooks: webhooks.Service,
 webhook_handlers: http.Event_Webhook_Handlers,
	sqlite_event_subscriptions: sqlite.Event_Subscription_Repo_SQLite,
	mcp_runtime_mutex:sync.Mutex,
	mcp_spike: mcp_service.Store,
	mcp_spike_handlers: http.MCP_Spike_Handlers,
	mcp_repository_impl: sqlite.MCP_Repo_SQLite,
	mcp_repository: iface.MCP_Repository,
	mcp_vault_repo_impl: sqlite.Vault_Directory_Repo_SQLite,
	mcp_vault_repo: iface.Vault_Directory_Repository,
	mcp_vault_view: vault_directory_service.Service,
	mcp_delegation: mcp_service.Delegation_Service,
	mcp_delegation_handlers: http.MCP_Delegation_Handlers,
	mcp_control_handlers: http.MCP_Control_Handlers,
	config: Hub_Config,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	bridge_runtime_registry: project_service.Bridge_Runtime_Registry,
	event_bus: events.User_Event_Bus,
	// attention_events coalesces card writes into attention_changed hints.
	attention_events: events.Attention_Debouncer,
	db: sqlite.Conn,
	oidc_identity_db: sqlite.Conn,
	sqlite_billing: sqlite.Billing_Repo_SQLite,
	billing_repo: iface.Billing_Repository,
	billing: billing_service.Service,
	billing_handlers: http.Billing_Handlers,
	sqlite_users: sqlite.User_Repo_SQLite,
	sqlite_sessions: sqlite.Session_Repo_SQLite,
	session_repo: iface.Session_Repository,
	sqlite_bridges: sqlite.Bridge_Repo_SQLite,
	sqlite_bridge_commit: sqlite.Bridge_Enroll_Commit_Conn,
	sqlite_agents: sqlite.Agent_Repo_SQLite,
	sqlite_projects: sqlite.Project_Repo_SQLite,
	sqlite_content: sqlite.Content_Repo_SQLite,
	sqlite_taskchains: sqlite.Taskchain_Repo_SQLite,
	sqlite_search: sqlite.Search_Repo_SQLite,
	search_skills: []sqlite.Skill_Doc,
	sqlite_actions: sqlite.Action_Repo_SQLite,
	sqlite_push: sqlite.Push_Repo_SQLite,
	sqlite_cards: sqlite.Card_Repo_SQLite,
	sqlite_attention: sqlite.Attention_Repo_SQLite,
	sqlite_issues: sqlite.Issue_Repo_SQLite,
	sqlite_shell_sessions: sqlite.Shell_Session_Repo_SQLite,
	sqlite_experiments: sqlite.Experiment_Repo_SQLite,
	sqlite_agent_writes: sqlite.Agent_Write_Repo_SQLite,
	sqlite_bots: sqlite.Bot_Repo_SQLite,
	sqlite_lsp_server_configs: sqlite.Lsp_Server_Config_Repo_SQLite,
	sqlite_providers: sqlite.Provider_Repo_SQLite,
	sqlite_vault_directory: sqlite.Vault_Directory_Repo_SQLite,
	sqlite_vault_directory_write: sqlite.Vault_Directory_Write_Conn,
	vault_directory_repo: iface.Vault_Directory_Repository,
	sqlite_bridge_logs: sqlite.Bridge_Log_Repo_SQLite,
	bridge_log_repo: iface.Bridge_Log_Repository,
	// bridge_log relay: queue + the one writer thread (started in build_graph,
	// joined in shutdown_graph).
	bridge_logs: bridge_log_service.Service,
	bridge_log_push: bridge_log_service.Push_Client,
	sqlite_uow_factory: sqlite.SQLite_Unit_Of_Work_Factory,
	repos: iface.Repositories,
	uow_factory: iface.Unit_Of_Work_Factory,
	users: user_service.User_Service,
	vault_directory: vault_directory_service.Service,
	bridge_update_catalog: bridge_service.Bridge_Update_Catalog,
	bridges: bridge_service.Bridge_Service,
	agents: agent_service.Agent_Service,
	fleet: fleet_application.Service,
	fleet_handlers: http.Fleet_Handlers,
	bots: bots_service.Bots_Service,
	bots_runtime: bots_service.Bots_Runtime,
	telegram: channel.Telegram_Adapter,
	whatsapp: channel.WhatsApp_Adapter,
	whatsapp_adapter: channel.Channel_Adapter,
	bot_webhook_handlers: http.Bot_Webhook_Handlers,
	channel_adapter: channel.Channel_Adapter,
	bot_handlers: http.Bot_Handlers,
	bot_agent_handlers: http.Bot_Agent_Handlers,
	bot_command_sink: project_service.Bridge_Command_Sink,
	projects: project_service.Project_Service,
	content: content_service.Content_Service,
	taskchains: taskchain_service.Taskchain_Service,
	task_engine: taskv2.Service,
	search: search_service.Search_Service,
	push: push_service.Push_Service,
	auth: auth_service.Auth_Service,
	device_auth_store: device_auth_service.Grant_Store,
	device_auth: device_auth_service.Device_Auth_Service,
	device_auth_handlers: http.Device_Auth_Handlers,
	user_handlers: http.User_Handlers,
	vault_directory_handlers: http.Vault_Directory_Handlers,
	bridge_handlers: http.Bridge_Handlers,
	agent_handlers: http.Agent_Handlers,
	agent_write_handlers: http.Agent_Write_Handlers,
	project_handlers: http.Project_Handlers,
	content_handlers: http.Content_Handlers,
	taskchain_handlers: http.Taskchain_Handlers,
	search_handlers: http.Search_Handlers,
	skills_handlers: http.Skills_Handlers,
	push_handlers: http.Push_Handlers,
	agent_action_handlers: http.Agent_Action_Handlers,
	action_handlers: http.Action_Handlers,
	cards: card_service.Card_Service,
	shell_session_repo: iface.Shell_Session_Repository,
	experiment_repo: iface.Experiment_Repository,
	agent_write_repo: iface.Agent_Write_Repository,
	bot_repo: iface.Bot_Repository,
	lsp_server_config_repo: iface.Lsp_Server_Config_Repository,
	provider_repo: iface.Provider_Repository,
	shell_session_service: shell_session_svc.Shell_Session_Service,
	shell_session_stream_handlers: http.Shell_Session_Stream_Handlers,
	lsp_session_registry:          http.Lsp_Session_Registry,
	lsp_session_stream_handlers:   http.Lsp_Session_Stream_Handlers,
	shell_session_rest_handlers: http.Shell_Session_Rest_Handlers,
	experiment_handlers: http.Experiment_Rest_Handlers,
	lsp_server_config_handlers: http.Lsp_Server_Config_Rest_Handlers,
	provider_handlers: http.Provider_Handlers,
	providers: provider_service.Provider_Service,
	card_handlers: http.Card_Handlers,
	issues: issue_service.Issue_Service,
	issue_handlers: http.Issue_Handlers,
	router: http.Router,
}

// task_engine_on_tasks_changed is the engine → taskchain callback: a task of the
// chain crossed into or out of a terminal state, so the chain's own status may
// need to follow (auto-complete when every task is done; reopen on a reopen).
task_engine_on_tasks_changed :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) {
	graph := (^App_Graph)(ctx)
	if graph == nil do return
	_, _, _ = taskchain_service.sync_chain_status_from_tasks(&graph.taskchains, chain_id, owner)
}

task_engine_on_instance_terminal :: proc(ctx: rawptr, instance_id: string) {
	taskv2.queue_instance_terminal_probe((^taskv2.Service)(ctx), instance_id)
}

task_engine_on_instance_activity :: proc(ctx: rawptr, instance_id, activity_status: string) {
	taskv2.on_instance_activity((^taskv2.Service)(ctx), instance_id, activity_status)
}

task_engine_on_user_activity :: proc(ctx: rawptr, instance_id: string) {
	taskv2.note_user_activity((^taskv2.Service)(ctx), instance_id)
}

task_engine_on_user_stopped :: proc(ctx: rawptr, instance_id: string) {
	taskv2.on_instance_user_stopped((^taskv2.Service)(ctx), instance_id)
}

task_engine_on_start_success :: proc(ctx: rawptr, inst: domain.Agent_Instance) {
	taskv2.on_start_success((^taskv2.Service)(ctx), inst)
}

// task_engine_wake_coordinator (REQ-CIS-2): a [taskv2] notice went to a
// coordinator; start it if it is stopped and not user-stopped, and tell taskv2
// whether to try again. Runs on the taskv2 timer thread, after commit and
// outside every taskv2 lock.
task_engine_wake_coordinator :: proc(ctx: rawptr, owner, instance_id: string, now_ms: i64) -> taskv2.Coordinator_Wake_Reply {
	graph := (^App_Graph)(ctx)
	if graph == nil do return {settled = true}
	_, reply := http.coordinator_wake_after_task_notice(&graph.agent_action_handlers, owner, instance_id, now_ms)
	return reply
}

// task_engine_on_instance_changed runs after a taskv2 commit that rewrote an
// instance's current-task pointer; it re-reads the committed row.
task_engine_on_instance_changed :: proc(ctx: rawptr, instance_id, change: string) {
	graph := (^App_Graph)(ctx)
	if graph == nil do return
	inst, found, _ := iface.agent_get_instance(&graph.repos.agents, instance_id)
	if !found do return
	defer domain.agent_instance_destroy(&inst)
	if change == "created" do http.publish_instance_created(&graph.event_bus, inst)
	else do http.publish_instance_changed(&graph.event_bus, inst, change)
}

// agents_on_reconfiguration_changed publishes the reconfiguration hint and, on
// the advance that committed the destination (agent_instances bridge/provider/
// model/configuration_revision rewritten by trigger), the instance hint too.
agents_on_reconfiguration_changed :: proc(ctx: rawptr, op: domain.Instance_Reconfiguration, change: string, config_committed: bool) {
	graph := (^App_Graph)(ctx)
	if graph == nil do return
	http.publish_reconfiguration_changed(&graph.event_bus, op, change)
	if !config_committed do return
	inst, found, _ := iface.agent_get_instance(&graph.repos.agents, op.agent_instance_id)
	if !found do return
	defer domain.agent_instance_destroy(&inst)
	http.publish_instance_changed(&graph.event_bus, inst, "config_changed")
}

// users_on_agent_seeded announces a canonical agent seeded for an owner.
users_on_agent_seeded :: proc(ctx: rawptr, owner_user_id, agent_id: string) {
	graph := (^App_Graph)(ctx)
	if graph == nil do return
	http.publish_agent_changed(&graph.event_bus, owner_user_id, agent_id, "created")
}

// service_message_created publishes message_created for a chat row a service
// saved outside an HTTP handler (card prompt op after its UoW commit, shell-run
// marker), from the re-read conversation so last_message_at/unread_count are
// the committed values.
service_message_created :: proc(ctx: rawptr, m: domain.Chat_Message) {
	graph := (^App_Graph)(ctx)
	if graph == nil do return
	c, found, _ := iface.content_get_conversation(&graph.repos.content, m.conversation_id)
	if !found do return
	http.publish_chat_message_created(&graph.event_bus, c, m)
}

build_graph :: proc(graph: ^App_Graph, config: Hub_Config) -> (bool, string) {
 webhook_limits:=webhooks.resolve_limits(config.webhook_limits)
 if !webhooks.limits_valid(webhook_limits) do return false,"invalid webhook limits"
 if !actions_service.filter_limits_valid(actions_service.filter_limits(config.action_filter_limits)) do return false,"invalid action filter limits"
 if !actions_service.snapshot_limits_valid(actions_service.snapshot_limits(config.action_snapshot_limits)) do return false,"invalid action snapshot limits"
	if strings.trim_space(config.nats_url) == "" do return false, "--nats-url / HEIMDALL_NATS_URL is required"
	graph.bridge_runtime_registry.limits = project_service.Runtime_Registry_Limits{
		live_bridges = config.runtime_max_live_bridges,
		live_bridges_per_owner = config.runtime_max_live_bridges_per_owner,
		active_instances = config.runtime_max_active_instances,
		active_instances_per_owner = config.runtime_max_active_instances_per_owner,
		terminal_instances_per_bridge = config.runtime_terminal_entries_per_bridge,
		terminal_retention = time.Duration(config.runtime_terminal_retention_seconds) * time.Second,
	}
	if oidc_ok, oidc_err := validate_oidc_config(config); !oidc_ok do return false, oidc_err
	if config.mcp_oauth_spike || config.mcp_oauth_key_file != "" {
		if config.mcp_oauth_spike && config.mcp_oauth_key_file != "" do return false, "choose synthetic MCP probe or delegated OAuth, not both"
		// Reuse the strict HTTPS origin parser, without imposing a distinct host.
		origin, valid, _ := normalize_preview_origin(config.ui_origin, "")
		if !valid || origin == "" do return false, "MCP OAuth probe requires a valid HTTPS ui_origin without a path"
		delete(origin)
		if !web_login_configured(config) do return false, "MCP OAuth probe requires existing OIDC browser login"
	}
	graph.config = config
	graph.clock = platform.real_clock()
	graph.ids = platform.real_id_generator()
	// In-process metrics registry + HTTP/process families. Always on (cheap
	// atomics); only the /metrics listener is gated by config.metrics_addr.
	// DB telemetry mode must be fixed before any family is registered or any
	// handle is opened; an unsupported mode fails boot instead of guessing.
	if ok, message := configure_db_telemetry(config); !ok do return false, message
	init_metrics()
	project_service.fleet_metrics_set_registry(&graph.bridge_runtime_registry)

	db, db_ok, db_err := sqlite.open(config.database_path, .Main)
	if !db_ok do return false, db_err.message
	graph.db = db
	// Billing uses its own transactional connection; tolerate brief writer contention.
	if !sqlite.exec(&graph.db, "PRAGMA busy_timeout = 5000;") do return false, "failed to configure database busy timeout"
	// WAL (persistent, per database file): readers on the other connections no
	// longer block on — or get SQLITE_BUSY from — a committing writer, and a
	// commit is one WAL append instead of journal + db fsyncs. NORMAL is
	// durable across process crashes in WAL mode; only an OS crash can drop
	// the last commits. An in-memory test db reports "memory" and is unaffected.
	if !sqlite.exec(&graph.db, "PRAGMA journal_mode = WAL;") do return false, "failed to enable WAL journal mode"
	if !sqlite.exec(&graph.db, "PRAGMA synchronous = NORMAL;") do return false, "failed to configure database synchronous mode"
	if !sqlite.exec(&graph.db, sqlite.MAIN_CONN_CACHE_SIZE_PRAGMA) do return false, "failed to configure database cache size"

	migrations_ok, migration_err := sqlite.run_migrations(&graph.db, config.migrations_dir)
	if !migrations_ok do return false, migration_err.message
	// DB-backed metric collectors (users/bridges/subscriptions, 60 s cache) use
	// their own read-only connection; tables must exist first.
	_ = db_collectors_attach(config.database_path)

	// Reconcile drifted search (fts5) indexes on boot: a prior bad manual rebuild can
	// leave rows unindexed, which makes the external-content sync triggers' 'delete'
	// op raise SQLITE_CORRUPT and jam every UPDATE to those rows (frozen task status /
	// agent-instance heartbeats). Re-syncing here unsticks affected rows on deploy;
	// it is cheap when healthy (skips non-drifted indexes) and runtime writes also
	// self-heal via step_write_healing. Non-fatal: log and continue on failure.
	if rebuilt, reconcile_ok, reconcile_err := sqlite.repair_fts_indexes(&graph.db, true); !reconcile_ok {
		fmt.printfln("ham-hub FTS reconcile failed (search may be stale until repaired): %s", reconcile_err.message)
	} else if rebuilt > 0 {
		fmt.printfln("ham-hub FTS reconcile: re-synced %d drifted search index(es)", rebuilt)
	}

	if config.paddle_past_due_grace_seconds < 0 do return false, "Paddle grace period must be a nonnegative number of seconds"
	if config.paddle_environment != "sandbox" && config.paddle_environment != "live" do return false, "Paddle environment must be sandbox or live"
	billing_config := billing_service.Config{enforce_plan_limits = config.billing_enforce_plan_limits, hobbyist_price_id = config.paddle_hobbyist_price_id, environment = config.paddle_environment, api_key = config.paddle_api_key, client_token = config.paddle_client_token, webhook_secret = config.paddle_webhook_secret, past_due_grace_seconds = config.paddle_past_due_grace_seconds}
	billing_repo, billing_err := sqlite.new_billing_repository(&graph.sqlite_billing, config.database_path, config.paddle_environment, config.paddle_hobbyist_price_id, config.paddle_api_key != "" || config.paddle_webhook_secret != "")
	if billing_err.code != .None do return false, billing_err.message
	graph.billing_repo = billing_repo
	graph.billing = billing_service.Service{repo = &graph.billing_repo, clock = &graph.clock, config = billing_config}
	graph.billing_handlers = http.Billing_Handlers{auth = &graph.auth, billing = &graph.billing, ui_origin = config.ui_origin}

	graph.repos.webhooks = sqlite.new_event_webhook_repository(&graph.sqlite_webhooks,&graph.db)
 graph.repos.event_outbox = sqlite.new_event_outbox_repository(&graph.sqlite_event_outbox, &graph.db)
	graph.repos.event_subscriptions = sqlite.new_event_subscription_repository(&graph.sqlite_event_subscriptions, &graph.db)
	graph.repos.users = sqlite.new_user_repository(&graph.sqlite_users, &graph.db)
	// External identity claiming is atomic on an isolated connection so its
	// transaction cannot commit or roll back an unrelated repository's writes.
	if oidc_configured(config) && config.database_path != ":memory:" {
		conn, ok, err := sqlite.open(config.database_path)
		if !ok do return false, err.message
		graph.oidc_identity_db = conn
		if !sqlite.exec(&graph.oidc_identity_db, "PRAGMA busy_timeout = 5000;") do return false, "failed to configure the OIDC identity connection"
		graph.sqlite_users.identity_conn = &graph.oidc_identity_db
	}
	graph.repos.bridges = sqlite.new_bridge_repository(&graph.sqlite_bridges, &graph.db)
	// REQ-EA-2: the enrollment commit runs on its own connection (see
	// Bridge_Enroll_Commit_Conn). An in-memory database has no second connection.
	if config.database_path != ":memory:" {
		if ok, err := sqlite.open_bridge_enroll_commit_conn(&graph.sqlite_bridge_commit, config.database_path); !ok do return false, err.message
		graph.sqlite_bridges.commit = &graph.sqlite_bridge_commit
	}
	graph.repos.agents = sqlite.new_agent_repository(&graph.sqlite_agents, &graph.db)
	graph.repos.projects = sqlite.new_project_repository(&graph.sqlite_projects, &graph.db)
	graph.repos.content = sqlite.new_content_repository(&graph.sqlite_content, &graph.db)
	graph.repos.taskchains = sqlite.new_taskchain_repository(&graph.sqlite_taskchains, &graph.db)
	// Inject the compiled-in skills (slug + SKILL.md contents) into the search repo
	// so the skills provider can scan them without the repository importing the
	// agent service (keeps the repository below the service layer).
	graph.search_skills = make([]sqlite.Skill_Doc, len(agent_service.STATIC_SKILLS))
	for skill, i in agent_service.STATIC_SKILLS {
		graph.search_skills[i] = sqlite.Skill_Doc{slug = skill.slug, content = skill.content}
	}
	graph.repos.search = sqlite.new_search_repository(&graph.sqlite_search, &graph.db, graph.search_skills)
	graph.repos.actions = sqlite.new_action_repository(&graph.sqlite_actions, &graph.db)

	graph.repos.push_subscriptions = sqlite.new_push_repository(&graph.sqlite_push, &graph.db)
	graph.repos.cards = sqlite.new_card_repository(&graph.sqlite_cards, &graph.db)
	graph.repos.attention = sqlite.new_attention_repository(&graph.sqlite_attention, &graph.db)
	graph.repos.issues = sqlite.new_issue_repository(&graph.sqlite_issues, &graph.db)
	graph.shell_session_repo = sqlite.new_shell_session_repository(&graph.sqlite_shell_sessions, &graph.db)
	graph.experiment_repo = sqlite.new_experiment_repository(&graph.sqlite_experiments, &graph.db)
	graph.agent_write_repo = sqlite.new_agent_write_repository(&graph.sqlite_agent_writes, &graph.db)
	graph.bot_repo = sqlite.new_bot_repository(&graph.sqlite_bots, &graph.db)
	graph.lsp_server_config_repo = sqlite.new_lsp_server_config_repository(&graph.sqlite_lsp_server_configs, &graph.db)
	graph.bridge_log_repo = sqlite.new_bridge_log_repository(&graph.sqlite_bridge_logs, &graph.db)
	graph.bridge_logs = bridge_log_service.new_service(&graph.bridge_log_repo)
	if strings.trim_space(config.log_push_url) != "" {
		graph.bridge_log_push = bridge_log_service.new_push_client(config.log_push_url)
		bridge_log_service.install_push(&graph.bridge_logs, &graph.bridge_log_push)
	}
	graph.provider_repo = sqlite.new_provider_repository(&graph.sqlite_providers, &graph.db)
	// Passwordless vault directory: writes on their own connection (see
	// Vault_Directory_Write_Conn); an in-memory database has no second connection.
	if config.database_path != ":memory:" {
		if ok, err := sqlite.open_vault_directory_write_conn(&graph.sqlite_vault_directory_write, config.database_path); !ok do return false, err.message
		graph.vault_directory_repo = sqlite.new_vault_directory_repository(&graph.sqlite_vault_directory, &graph.db, &graph.sqlite_vault_directory_write)
	} else {
		graph.vault_directory_repo = sqlite.new_vault_directory_repository(&graph.sqlite_vault_directory, &graph.db)
	}
	graph.vault_directory = vault_directory_service.new_service(&graph.vault_directory_repo, &graph.clock)
	if config.mcp_oauth_key_file != "" {
		if config.database_path == ":memory:" do return false, "delegated MCP OAuth requires a persistent database"
		if ok, err := configure_mcp_delegation(graph); !ok do return false, err
	}
	graph.uow_factory = sqlite.new_unit_of_work_factory(&graph.sqlite_uow_factory, &graph.db, &graph.repos)
	graph.repos.pipeline_deliveries = sqlite.new_pipeline_delivery_repository(&graph.sqlite_pipeline_deliveries, &graph.db)
	sqlite.install_inbox_notifications(&graph.db, &graph.event_inbox, proc(ctx: rawptr) {eventinbox.wake((^eventinbox.Service)(ctx))})
 graph.db.outbox_after_commit_ctx = &graph.event_relay
	graph.db.outbox_after_commit = proc(ctx: rawptr) {eventrelay.wake((^eventrelay.Service)(ctx))}
	graph.users = user_service.new_user_service(&graph.repos.users, &graph.repos.agents, &graph.repos.projects, &graph.clock, &graph.ids)
	graph.users.on_agent_seeded = users_on_agent_seeded
	graph.users.on_agent_seeded_ctx = rawptr(graph)
	bridge_command_sink := bridge_runtime_service.new_bridge_command_sink(&graph.bridge_runtime_registry)
	graph.delivery_commands = bridge_command_sink
	graph.delivery = delivery.new_service(&graph.uow_factory, &graph.repos.bridges, &graph.bridge_runtime_registry, &graph.delivery_commands, &graph.clock, &graph.ids, {url=config.nats_url, creds_file=config.nats_creds_file, ca_file=config.nats_ca_file, timeout_ms=1000})
	graph.bridges = bridge_service.new_bridge_service_with_runtime(&graph.repos.bridges, bridge_command_sink, &graph.clock, &graph.ids)
	// REQ-IMPL-3 / audit F6: revocation must terminate the bridge's LIVE control
	// WebSocket, not merely flip a DB row. The registry owns the socket; the bridge
	// service must not reach into the transport layer, so the teardown is injected
	// as a seam here. Without this line revocation silently degrades to the F6
	// behaviour — the bridge stays connected and fully operational until it next
	// reconnects, which with proactive refresh may be never.
	bridge_service.with_connection_closer(&graph.bridges, bridge_runtime_service.new_bridge_connection_closer(&graph.bridge_runtime_registry))
	graph.bridges.entitlements = billing_service.entitlement_lookup(&graph.billing)
	graph.billing.plan_change_ctx = graph
	graph.billing.on_entitlements = reconcile_bridge_entitlements
	graph.billing.on_plan_change = reconcile_bridge_plans
	if plan_err := reconcile_bridge_plans(graph); plan_err.code != .None {
		fmt.eprintfln("hub: startup bridge plan reconciliation incomplete: %s", plan_err.message)
	}
	graph.bridges.catalog = &graph.bridge_update_catalog
	// HEIMDALL_UPDATE_CATALOG_OFFLINE=1 leaves release_get nil: an offline,
	// manifest-only catalog (HEIMDALL_UPDATE_MANIFEST_PATH), so an isolated hub
	// (the 3-OS lifecycle e2e) offers the build under test instead of whatever
	// release GitHub has promoted.
	if os.get_env("HEIMDALL_UPDATE_CATALOG_OFFLINE", context.temp_allocator) != "1" {
		graph.bridge_update_catalog.release_get = bridge_service.bridge_catalog_http_get
	}
	graph.agents = agent_service.new_agent_service_with_runtime(&graph.repos.agents, &graph.repos.bridges, &graph.repos.projects, &graph.repos.content, &graph.repos.taskchains, bridge_command_sink, &graph.bridge_runtime_registry, &graph.clock, &graph.ids)
	graph.agents.event_bus = &graph.event_bus
	graph.agents.entitlements = billing_service.entitlement_lookup(&graph.billing)
	graph.agents.providers = &graph.provider_repo
	graph.projects = project_service.new_project_service_with_command_sink(&graph.repos.projects, &graph.repos.bridges, bridge_command_sink, &graph.clock, &graph.ids)
	graph.content = content_service.new_content_service_with_runtime(&graph.repos.content, &graph.repos.agents, &graph.repos.bridges, &graph.repos.projects, &graph.repos.taskchains, bridge_command_sink, &graph.clock, &graph.ids)
	graph.content.agent_configuration_service = &graph.agents
	graph.content.title_nudge_cooldown_seconds = config.title_nudge_cooldown_seconds
	graph.taskchains = taskchain_service.new_taskchain_service_with_runtime(&graph.repos.taskchains, &graph.repos.agents, bridge_command_sink, &graph.clock, &graph.ids)
	graph.taskchains.agent_service = &graph.agents
	graph.taskchains.event_bus = &graph.event_bus
	// Task System v2 engine: events + fold + leases + timers + matcher. Every
	// chain/task mutation in the taskchain service funnels into it; it calls back
	// (on_tasks_changed) so the chain auto-completes when its last task is done.
	graph.repos.taskchains.catalog = graph.repos.event_outbox
	graph.task_engine = taskv2.new_service(&graph.repos.taskchains, &graph.repos.agents, &graph.repos.bridges, &graph.clock, &graph.ids)
	graph.task_engine.legacy_event_notices = config.legacy_event_notices
	graph.task_engine.coordinator_idle_completed_seconds = config.coordinator_idle_completed_seconds
	graph.task_engine.coordinator_idle_seconds = config.coordinator_idle_seconds
	// Hub_Config 0 = disabled; the engine reads 0 as "default", < 0 as disabled.
	graph.task_engine.lease_stall_seconds = config.lease_stall_seconds if config.lease_stall_seconds > 0 else -1
	graph.task_engine.content = &graph.repos.content
	graph.content.uow_factory = &graph.uow_factory
	graph.content.vault_directory = &graph.vault_directory_repo
	graph.task_engine.uow_factory = &graph.uow_factory
	graph.task_engine.agent_service = &graph.agents
	graph.task_engine.bridge_command_sink = bridge_command_sink
	graph.task_engine.event_bus = &graph.event_bus
	graph.task_engine.on_tasks_changed = task_engine_on_tasks_changed
	graph.task_engine.on_tasks_changed_ctx = rawptr(graph)
	graph.task_engine.on_instance_changed = task_engine_on_instance_changed
	graph.task_engine.on_instance_changed_ctx = rawptr(graph)
	graph.task_engine.wake_coordinator = task_engine_wake_coordinator
	graph.task_engine.wake_coordinator_ctx = rawptr(graph)
	taskchain_service.set_engine(&graph.taskchains, &graph.task_engine)
	// User chat / action cards / question answers reset the coordinator
	// idle-stop stamp (REQ-CIS-1); the engine arms its timers.
	graph.content.user_activity = content_service.User_Activity_Hook{ctx = rawptr(&graph.task_engine), run = task_engine_on_user_activity}
	taskchain_service.set_uow_factory(&graph.taskchains, &graph.uow_factory)
	// Instance lifecycle → engine: ONE chokepoint for every death path
	// (taskv2.on_instance_terminal), busy/idle activity, and start-success.
	graph.agents.hooks = agent_service.Lifecycle_Hooks{
		ctx              = rawptr(&graph.task_engine),
		on_terminal      = task_engine_on_instance_terminal,
		on_activity      = task_engine_on_instance_activity,
		on_start_success = task_engine_on_start_success,
		launch_context = task_engine_launch_context,
		on_user_stopped  = task_engine_on_user_stopped,
	}
	graph.agents.resource_events = agent_service.Resource_Event_Hooks{
		ctx                        = rawptr(graph),
		on_reconfiguration_changed = agents_on_reconfiguration_changed,
	}
	graph.fleet = fleet_application.Service{settings=agent_service.fleet_service(&graph.agents),agents=&graph.agents,factory=&graph.uow_factory,clock=&graph.clock,ids=&graph.ids,event_ctx=graph,on_changed=fleet_on_changed,authority_ctx=graph,authority_check=fleet_authority_check}
	graph.fleet_handlers = http.Fleet_Handlers{auth=&graph.auth,service=&graph.fleet}
	graph.search = search_service.new_search_service(&graph.repos.search)
	graph.push = push_service.new_push_service(&graph.repos.push_subscriptions, &graph.clock, &graph.ids, push_service.Vapid_Config{
		public_key = config.vapid_public_key,
		private_key = config.vapid_private_key,
		subject = config.vapid_subject,
	})
	graph.auth = auth_service.new_auth_service(auth_service.Auth_Config{
		auto_provision_users = effective_auto_provision_users(config),
	}, &graph.users, &graph.clock, &graph.ids)
	graph.auth.oidc = auth_service.OIDC_Config{issuer = config.oidc_issuer, audience = config.oidc_api_audience, scope = config.oidc_api_scope, allow_insecure_localhost = config.oidc_allow_insecure_localhost, claim_existing_users = config.oidc_claim_existing_users, userinfo_url = config.oidc_userinfo_url, jwks_url = config.oidc_jwks_url}
	// The session store is always wired: the reaper purges expired v2 device-proof
	// nonces through it. Cookie sessions are honoured only with browser login.
	graph.session_repo = sqlite.new_session_repository(&graph.sqlite_sessions, &graph.db)
	graph.auth.sessions = &graph.session_repo
	// Browser login (Hub-side OIDC authorization code + PKCE) and its sessions.
	if web_login_configured(config) {
		client_secret := ""
		if config.oidc_web_client_secret_file != "" {
			secret, secret_ok := read_secret_file(config.oidc_web_client_secret_file)
			if !secret_ok do return false, "could not read oidc_web_client_secret_file (HAM_OIDC_WEB_CLIENT_SECRET_FILE)"
			client_secret = secret
		}
		ttl_hours := config.session_ttl_hours if config.session_ttl_hours > 0 else auth_service.DEFAULT_SESSION_TTL_HOURS
		idle_hours := config.session_idle_hours if config.session_idle_hours > 0 else auth_service.DEFAULT_SESSION_IDLE_HOURS
		graph.auth.web = auth_service.Web_Login_Config{
			enabled = true,
			authorize_url = config.oidc_authorize_url,
			token_url = config.oidc_token_url,
			end_session_url = config.oidc_end_session_url,
			client_id = config.oidc_web_client_id,
			client_secret = client_secret,
			redirect_uri = strings.clone(web_redirect_uri(config)),
			ui_origin = config.ui_origin,
			session_ttl_ms = i64(ttl_hours) * 3_600_000,
			session_idle_ms = i64(min(idle_hours, ttl_hours)) * 3_600_000,
		}
	}
	graph.auth.vault = &graph.vault_directory
	graph.auth.bridges = &graph.bridges
	graph.auth.agents = &graph.agents
	// Bridge-token authorization is ALWAYS enforced; there is nothing to wire.
	//
	// This line used to select the mode with `== "enforce"`, which made
	// enforcement conditional on an exact string match. Every other
	// value — unset, "Enforce", "enforced", "true", a typo — selected the
	// permissive mode silently, with no startup warning. REQ-IMPL-6 removed the
	// mode rather than hardening the comparison: a security control that can be
	// switched off by a misspelling in a config file should not be switchable.
	graph.device_auth_store = device_auth_service.new_grant_store(device_auth_service.Grant_Store_Config{
		verification_uri = config.ui_origin,
		expires_in = config.device_auth_expires_in,
		interval = config.device_auth_interval,
		rate_limit = config.device_auth_rate_limit,
		rate_window = config.device_auth_rate_window,
	})
	graph.device_auth = device_auth_service.new_device_auth_service(&graph.device_auth_store, device_auth_service.real_monotonic_clock(), config.forwarded_for_trusted_cidrs)
	// Wire the REQ-IMPL-2 bridge-credential issuer. Separate seam from the user
	// minter above: a grant that carried a bridge public key mints a per-machine
	// `brg_` identity, never a user token with the machine as a label.
	device_auth_service.with_bridge_token_minter(&graph.device_auth, device_bridge_minter, rawptr(graph))
	graph.users.bridges = &graph.repos.bridges
	graph.user_handlers = http.User_Handlers{home_layouts = &graph.users, launch_preferences = &graph.users, auth = &graph.auth, event_bus = &graph.event_bus, ws_tickets = http.new_user_ws_ticket_store(), forwarded_for_cidrs = config.forwarded_for_trusted_cidrs}
	graph.user_handlers.ws_tickets.auth = &graph.auth
	graph.shell_session_service = shell_session_svc.new_shell_session_service(
		repo                = &graph.shell_session_repo,
		bridge_command_sink = bridge_command_sink,
		event_bus           = &graph.event_bus,
		ids                 = &graph.ids,
		clock               = &graph.clock,
		// Used only to resolve the authenticated conversation binding.
		content             = &graph.content,
	)
	graph.shell_session_service.entitlements = billing_service.entitlement_lookup(&graph.billing)
	shell_session_svc.shell_metrics_set_service(&graph.shell_session_service)
	graph.shell_session_service.live_agents = &graph.agents
	// REQ-SHELL-9 trigger A: a closed chain reaps its servers. Assigned HERE, after the
	// shell-session service is constructed, rather than next to the other two taskchain
	// dependencies at their construction above — graph.taskchains is built before this
	// service exists, so wiring it there would store a pointer to a zero value.
	graph.taskchains.shell_sessions = &graph.shell_session_service
	graph.shell_session_stream_handlers = http.Shell_Session_Stream_Handlers{
		entitlements = billing_service.entitlement_lookup(&graph.billing),
		auth                = &graph.auth,
		ws_tickets          = &graph.user_handlers.ws_tickets,
		bridges             = &graph.bridges,
		shell_sessions      = &graph.shell_session_service,
		shell_repo          = &graph.shell_session_repo,
		bridge_command_sink = bridge_command_sink,
		experiments         = &graph.experiment_repo,
		preview_origin      = config.preview_origin,
		preview_legacy_path = config.preview_legacy_path,
		ui_origin           = config.ui_origin,
		bridge_runtime_registry = &graph.bridge_runtime_registry,
	}
	// REQ-LSP-RLY-1. The registry is plain in-memory state: an LSP session lives
	// exactly as long as its browser socket, so there is no table and nothing to
	// reap on restart.
	graph.lsp_session_stream_handlers = http.Lsp_Session_Stream_Handlers{
		ws_tickets          = &graph.user_handlers.ws_tickets,
		bridges             = &graph.bridges,
		experiments         = &graph.experiment_repo,
		lsp_configs         = &graph.lsp_server_config_repo,
		sessions            = &graph.lsp_session_registry,
		ids                 = &graph.ids,
		bridge_command_sink = bridge_command_sink,
	}
	graph.shell_session_rest_handlers = http.Shell_Session_Rest_Handlers{
		entitlements = billing_service.entitlement_lookup(&graph.billing),
		auth           = &graph.auth,
		shell_sessions = &graph.shell_session_service,
		preview_origin = config.preview_origin,
		ui_origin      = config.ui_origin,
		// REQ-SHELL-10 work item 3: read-only, to derive the bridge-offline session
		// state the serializer reports.
		bridge_runtime_registry = &graph.bridge_runtime_registry,
	}
	graph.bridge_handlers = http.Bridge_Handlers{
		uow_factory = &graph.uow_factory,
		delivery = graph.delivery,
		mcp_control = &graph.mcp_control_handlers,
		entitlements = billing_service.entitlement_lookup(&graph.billing),
		auth = &graph.auth,
		bridges = &graph.bridges,
		agents = &graph.agents,
		content = &graph.content,
		taskchains = &graph.taskchains,
		projects = &graph.projects,
		event_bus = &graph.event_bus,
		bridge_runtime_registry = &graph.bridge_runtime_registry,
		shell_sessions = &graph.shell_session_service,
		lsp_sessions = &graph.lsp_session_registry,
		providers = &graph.providers,
		bridge_logs = &graph.bridge_logs,
		task_engine = &graph.task_engine,
		vault = &graph.vault_directory,
		experiments = &graph.experiment_repo,
	}
	graph.task_engine.vcs_show_file = http.bridge_vcs_show_file_callback
	graph.task_engine.vcs_show_file_ctx = rawptr(&graph.bridge_handlers)
	bridge_log_service.start(&graph.bridge_logs)
	graph.agent_handlers = http.Agent_Handlers{
		agent_writes = &graph.agent_write_repo,
		entitlements = billing_service.entitlement_lookup(&graph.billing),
		launch_preferences = &graph.users,
		auth           = &graph.auth,
		agents         = &graph.agents,
		event_bus      = &graph.event_bus,
		ws_tickets     = &graph.user_handlers.ws_tickets,
		shell_sessions = &graph.shell_session_service,
		experiments    = &graph.experiment_repo,
	}
	graph.agent_write_handlers = http.Agent_Write_Handlers{auth = &graph.auth, writes = &graph.agent_write_repo}
	graph.project_handlers = http.Project_Handlers{agent_writes = &graph.agent_write_repo, auth = &graph.auth, projects = &graph.projects}
	graph.content_handlers = http.Content_Handlers{agent_writes = &graph.agent_write_repo, auth = &graph.auth, agents = &graph.agents, content = &graph.content, event_bus = &graph.event_bus}
	graph.taskchain_handlers = http.Taskchain_Handlers{auth = &graph.auth, taskchains = &graph.taskchains, agents = &graph.agents, content = &graph.content, projects = &graph.projects, event_bus = &graph.event_bus, task_engine = &graph.task_engine, shell_sessions = &graph.shell_session_service}
	graph.search_handlers = http.Search_Handlers{auth = &graph.auth, search = &graph.search}
	graph.skills_handlers = http.Skills_Handlers{auth = &graph.auth}
	graph.push_handlers = http.Push_Handlers{auth = &graph.auth, push = &graph.push, vapid_public_key = config.vapid_public_key}
	graph.device_auth_handlers = http.Device_Auth_Handlers{service = &graph.device_auth, auth = &graph.auth, push = &graph.push, public_app_origin = config.public_app_origin, ui_origin = config.ui_origin, vault = &graph.vault_directory, event_bus = &graph.event_bus, pairing_hub_origins = config.pairing_hub_origin_list, bridges = &graph.bridges}
	graph.vault_directory_handlers = http.Vault_Directory_Handlers{auth = &graph.auth, vault = &graph.vault_directory, device_auth = &graph.device_auth, bridges = &graph.bridges, event_bus = &graph.event_bus, push = &graph.push, public_app_origin = config.public_app_origin}
	graph.agent_action_handlers = http.Agent_Action_Handlers{webhooks = &graph.webhook_handlers, automations = &graph.action_handlers, auth = &graph.auth, agents = &graph.agents, bridges = &graph.bridges, content = &graph.content, taskchains = &graph.taskchains, search = &graph.search, event_bus = &graph.event_bus, push = &graph.push, public_app_origin = config.public_app_origin, task_engine = &graph.task_engine}
	graph.actions = actions_service.Service{
  filter_limits=actions_service.filter_limits(config.action_filter_limits),
  snapshot_limits=actions_service.snapshot_limits(config.action_snapshot_limits),
 webhook_limits=webhook_limits,
 max_per_owner=config.automation_max_per_owner,
		factory=&graph.uow_factory,repos=&graph.repos,placement=&graph.placement,
		experiments=&graph.experiment_repo,clock=&graph.clock,ids=&graph.ids,
		support={ctx=rawptr(&graph.event_relay),get=action_schedule_support},
		target_kinds=make([]string,3,runtime.heap_allocator()),
	}
	graph.actions.target_kinds[0]="agent"
	graph.actions.target_kinds[1]="instance"
	graph.actions.target_kinds[2]="bot"
	graph.action_router=actions_service.Router{
 factory=&graph.uow_factory,experiments=&graph.experiment_repo,placement=&graph.placement,
 clock=&graph.clock,ids=&graph.ids,support=graph.actions.support,
 message_created={ctx=graph,created=service_message_created},
 agents={ctx=graph,find=action_agent_find,create=action_agent_create,stop=action_agent_stop,instance=action_agent_instance,persist_prompt=action_persist_prompt,retire_prompt=action_retire_prompt},
 pipeline={ctx=graph.delivery,route=action_route_delivery,expire=action_expire_delivery,unread=action_unread_delivery},
 }
 graph.content.messages_read={ctx=graph.delivery,read=delivery_messages_read}
 delivery.register_sink(graph.delivery,{kind="prompt",ctx=&graph.action_router,on_final=actions_service.on_delivery_final,replace=actions_service.on_delivery_replace})
 graph.webhooks = webhooks.Service{factory=graph.actions.factory,clock=&graph.clock,limits=webhook_limits,experiments=&graph.experiment_repo}
 graph.webhook_handlers = http.Event_Webhook_Handlers{actions=&graph.action_handlers,service=&graph.webhooks,trusted_cidrs=config.forwarded_for_trusted_cidrs}
 graph.action_handlers = http.Action_Handlers{auth=&graph.auth,service=&graph.actions,router=&graph.action_router,experiments=&graph.experiment_repo}
	graph.issues = issue_service.new_issue_service(&graph.repos.issues, &graph.clock, &graph.ids)
	graph.cards = card_service.new_card_service(
		&graph.repos.cards,
		&graph.repos.projects,
		&graph.taskchains,
		&graph.content,
		&graph.projects,
		&graph.agents,
		&graph.uow_factory,
		&graph.clock,
		&graph.ids,
		&graph.issues,
	)
	// Attention deck: the card projector keeps task-validation and actionable
	// message cards in step with their sources (write-through), so wire it into
	// the services that own those sources.
	card_service.init_attention(&graph.cards, &graph.repos.attention)
	taskchain_service.set_attention_notifier(&graph.taskchains, &graph.cards.attention_notifier)
	// The task engine re-projects the attention card of every task an event touched.
	graph.task_engine.attention = &graph.cards.attention_notifier
	content_service.set_attention_notifier(&graph.content, &graph.cards.attention_notifier)
	events.init_attention_debouncer(&graph.attention_events, &graph.event_bus)
	// Agent blockers change the 'Needs you' deck too (kind agent_blocker).
	graph.agents.blockers.attention = &graph.attention_events
	graph.cards.card_changed = card_service.Card_Changed_Hook{ctx = rawptr(&graph.attention_events), changed = attention_card_changed}
	graph.cards.message_created = content_service.Message_Created_Hook{ctx = rawptr(graph), created = service_message_created}
	graph.experiment_handlers = http.Experiment_Rest_Handlers{auth = &graph.auth, repo = &graph.experiment_repo, clock = &graph.clock}
	graph.lsp_server_config_handlers = http.Lsp_Server_Config_Rest_Handlers{auth = &graph.auth, repo = &graph.lsp_server_config_repo, clock = &graph.clock, ids = &graph.ids}
	graph.providers = provider_service.new_provider_service(&graph.provider_repo)
	graph.providers.uow_factory = &graph.uow_factory
	graph.providers.bridges = &graph.repos.bridges
	graph.bot_command_sink = bridge_command_sink
	graph.placement=placement.new_service(&graph.repos.bridges,&graph.repos.agents,&graph.providers,&graph.bridge_runtime_registry,billing_service.entitlement_lookup(&graph.billing))
 graph.placement_handlers={auth=&graph.auth,placement=&graph.placement}
	graph.bots = bots_service.Bots_Service{placement=&graph.placement,ui_origin = config.ui_origin, repo = &graph.bot_repo, uow_factory = &graph.uow_factory, event_bus = &graph.event_bus, experiments = &graph.experiment_repo, entitlements = billing_service.entitlement_lookup(&graph.billing), agents = &graph.agents, providers = &graph.providers, bridges = &graph.repos.bridges, registry = &graph.bridge_runtime_registry, command_sink = &graph.bot_command_sink, adapter = nil, clock = &graph.clock, ids = &graph.ids, timers = config.bot_timers}
	if config.telegram_bot_token != "" {
		graph.telegram = channel.Telegram_Adapter{token = config.telegram_bot_token, api_base = config.telegram_api_base}
		graph.channel_adapter = channel.telegram_adapter(&graph.telegram)
		graph.bots.adapter = &graph.channel_adapter
	}
	configured, problem := app_whatsapp_config_state(config)
	if problem != "" do fmt.eprintln(problem)
	if configured {
		graph.whatsapp = channel.WhatsApp_Adapter{access_token = config.whatsapp_access_token, app_secret = config.whatsapp_app_secret,
			verify_token = config.whatsapp_verify_token, phone_number_id = config.whatsapp_phone_number_id,
			business_account_id = config.whatsapp_business_account_id, api_base = config.whatsapp_api_base}
		graph.whatsapp_adapter = channel.whatsapp_adapter(&graph.whatsapp)
		graph.bots.whatsapp = &graph.whatsapp_adapter
		fmt.printf("bots: whatsapp configured phone_number_id=%s\n", config.whatsapp_phone_number_id)
	}
	graph.bot_webhook_handlers = http.Bot_Webhook_Handlers{bots = &graph.bots, runtime = &graph.bots_runtime, trusted_cidrs = config.forwarded_for_trusted_cidrs}
	graph.bots_runtime = bots_service.Bots_Runtime{service = &graph.bots, telegram_bot_token = config.telegram_bot_token, supervisor_tick = bots_service.bots_supervisor_tick}
	graph.experiment_handlers.on_changed = bots_service.bots_on_experiment_changed
	graph.experiment_handlers.on_changed_ctx = &graph.bots_runtime
	graph.bots.boot_unix_ms, _ = platform.rfc3339_to_unix_ms(platform.clock_now(&graph.clock))
	graph.bridge_handlers.bots = &graph.bots
	graph.event_inbox = eventinbox.Service{
 reconcile_interval = time.Duration(config.event_inbox_reconcile_seconds)*time.Second,
		factory = &graph.uow_factory, ids = &graph.ids,
		notice_ctx = graph, notice = event_inbox_notice,
		options = {url = config.nats_url, creds_file = config.nats_creds_file, ca_file = config.nats_ca_file, timeout_ms = 1000},
	}
	graph.mcp_control_handlers.inbox = &graph.event_inbox
	graph.user_handlers.catalog = &graph.event_inbox
	graph.event_inbox_handlers = http.Event_Inbox_Handlers{agent_actions = &graph.agent_action_handlers, inbox = &graph.event_inbox}
	graph.bot_agent_handlers = http.Bot_Agent_Handlers{agent_actions = &graph.agent_action_handlers, bots = &graph.bots, experiments = &graph.experiment_repo}
	graph.bot_handlers = http.Bot_Handlers{auth = &graph.auth, bots = &graph.bots, experiments = &graph.experiment_repo, content = &graph.repos.content, cards = &graph.repos.cards}
	graph.bridges.provider_repo = graph.providers.repo
	graph.provider_handlers = http.Provider_Handlers{auth = &graph.auth, providers = &graph.providers, bridges = &graph.bridges, bridge_runtime_registry = &graph.bridge_runtime_registry, clock = &graph.clock, ids = &graph.ids, agents = &graph.agents, event_bus = &graph.event_bus}
	graph.agent_action_handlers.providers = &graph.providers
	graph.card_handlers = http.Card_Handlers{auth = &graph.auth, cards = &graph.cards, clock = &graph.clock}
	graph.issue_handlers = http.Issue_Handlers{auth = &graph.auth, issues = &graph.issues, clock = &graph.clock}
	graph.agent_action_handlers.cards = &graph.cards
	graph.router = http.new_router()
	if config.mcp_oauth_spike {
		mcp_service.init(&graph.mcp_spike)
		graph.mcp_spike_handlers = {auth = &graph.auth, store = &graph.mcp_spike, origin = strings.trim_right(config.ui_origin, "/")}
	}
	register_routes(graph)
	// Log the Web Push send status ONCE at startup. Never log the private key.
	// When unconfigured, subscription endpoints still work; only sending is off.
	if vapid_is_configured(config) {
		fmt.println("ham-hub web push enabled (VAPID public key configured)")
	} else {
		fmt.println("ham-hub web push send disabled (no VAPID keypair configured); subscription endpoints remain active")
	}
	graph.event_relay.published_ctx = &graph.event_inbox
	graph.event_relay.published = proc(ctx: rawptr, subject: string) {
		eventinbox.published((^eventinbox.Service)(ctx), subject)
	}
	eventinbox.start(&graph.event_inbox_runtime, &graph.event_inbox)
	eventrelay.start(&graph.event_relay, &graph.uow_factory, {url = config.nats_url, creds_file = config.nats_creds_file, ca_file = config.nats_ca_file, timeout_ms = 1000})
	if !delivery.start(graph.delivery) do return false, "failed to start delivery pipeline"
 if !actions_service.start(&graph.action_runtime,&graph.actions,graph.action_router,{nats_url=config.nats_url,creds_file=config.nats_creds_file,ca_file=config.nats_ca_file,max_deliver=int(graph.event_inbox.max_deliver)}) do return false,"failed to start actions runtime"
	return true, ""
}

shutdown_graph :: proc(graph: ^App_Graph) {
	eventrelay.stop(&graph.event_relay)
	eventinbox.stop(&graph.event_inbox_runtime)
	eventinbox.counters_destroy(&graph.event_inbox)
	actions_service.stop(&graph.action_runtime)
	delivery.stop(graph.delivery)
	graph.delivery = nil
	bots_service.bots_runtime_stop(&graph.bots_runtime)
	delete(graph.actions.target_kinds,runtime.heap_allocator())
	placement.service_destroy(&graph.placement)
	bots_service.bots_service_destroy(&graph.bots)
	channel.telegram_destroy(&graph.telegram)
	channel.whatsapp_destroy(&graph.whatsapp)
	http.event_webhook_limiter_destroy(&graph.webhook_handlers.limiter)
 http.webhook_rate_destroy(&graph.bot_webhook_handlers.limiter)
	bridge_service.bridge_update_catalog_destroy(&graph.bridge_update_catalog)
	db_collectors_detach()
	// Join the bridge_log writer (final drain) while the DB is still open.
	bridge_log_service.service_free(&graph.bridge_logs)
	bridge_runtime_service.runtime_command_cache_destroy(&graph.bridge_runtime_registry)
	http.secure_form_routing_destroy(&graph.bridge_handlers.secure_forms)
	http.stream_routing_destroy(&graph.bridge_handlers)
	http.router_free(&graph.router)
	http.user_ws_ticket_store_free(&graph.user_handlers.ws_tickets)
	shell_session_svc.shell_metrics_detach_service(&graph.shell_session_service)
	shell_session_svc.shell_session_service_free(&graph.shell_session_service)
	agent_service.tool_live_destroy(&graph.agents.tool_live)
	device_auth_service.grant_store_free(&graph.device_auth_store)
	billing_service.service_free(&graph.billing)
	sqlite.close_billing_repository(&graph.sqlite_billing)
	sqlite.close(&graph.sqlite_bridge_commit.conn)
	if graph.config.mcp_oauth_spike || graph.config.mcp_oauth_key_file != "" do mcp_service.free(&graph.mcp_spike)
	free_mcp_delegation(graph)
	auth_service.oidc_free(&graph.auth)
	sqlite.close(&graph.oidc_identity_db)
	vault_directory_service.service_free(&graph.vault_directory)
	sqlite.close(&graph.sqlite_vault_directory_write.conn)
	sqlite.close(&graph.db)
}

register_routes :: proc(graph: ^App_Graph) {
	if graph.config.mcp_oauth_spike {
		http.mcp_spike_register_routes(&graph.router, &graph.mcp_spike_handlers)
	}
	if graph.config.mcp_oauth_key_file != "" do http.mcp_delegation_register_routes(&graph.router, &graph.mcp_delegation_handlers)
	if graph.config.mcp_oauth_key_file != "" do http.mcp_control_register_routes(&graph.router, &graph.mcp_control_handlers)
	http.router_add(&graph.router, "GET", "/api/v1/account/billing", rawptr(&graph.billing_handlers), http.account_billing_handler)
	http.router_add(&graph.router, "POST", "/api/v1/account/billing/checkout", rawptr(&graph.billing_handlers), http.account_checkout_handler)
	http.router_add(&graph.router, "POST", "/api/v1/account/billing/portal", rawptr(&graph.billing_handlers), http.account_portal_handler)
	http.router_add(&graph.router, "POST", "/api/v1/billing/paddle/webhook", rawptr(&graph.billing_handlers), http.paddle_webhook_handler)
	http.router_add(&graph.router, "GET", "/api/v1/health", rawptr(graph), health_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/authorize", rawptr(&graph.device_auth_handlers), http.device_authorize_handler)
	http.router_add(&graph.router, "GET", "/api/v1/device", rawptr(&graph.device_auth_handlers), http.device_page_handler)
	http.router_add(&graph.router, "GET", "/api/v1/device/add", rawptr(&graph.device_auth_handlers), http.device_add_redirect_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/verify", rawptr(&graph.device_auth_handlers), http.device_verify_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/pair-salts", rawptr(&graph.device_auth_handlers), http.device_pair_salts_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/approve", rawptr(&graph.device_auth_handlers), http.device_approve_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/token", rawptr(&graph.device_auth_handlers), http.device_token_handler)
	// REQ-IMPL-3: credential rotation. Authenticated by the `hbf_` refresh token
	// itself — no user session, and an `hba_` access token is refused — so it is
	// registered next to the flow that issued the credential rather than under
	// /api/v1/bridges, whose routes are user-session scoped. Handled by
	// bridge_handlers because the credential is bridge-service state, not grant state.
	http.router_add(&graph.router, "POST", "/api/v1/device/bridge-refresh", rawptr(&graph.bridge_handlers), http.bridge_refresh_handler)
	http.router_add(&graph.router, "GET", "/api/v1/auth/config", rawptr(&graph.user_handlers), http.auth_config_handler)
	http.router_add(&graph.router, "GET", "/api/v1/auth/login", rawptr(&graph.user_handlers), http.auth_login_handler)
	http.router_add(&graph.router, "GET", "/api/v1/auth/callback", rawptr(&graph.user_handlers), http.auth_callback_handler)
	http.router_add(&graph.router, "GET", "/api/v1/auth/sessions", rawptr(&graph.user_handlers), http.auth_sessions_handler)
	http.router_add(&graph.router, "POST", "/api/v1/auth/switch", rawptr(&graph.user_handlers), http.auth_switch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/auth/logout", rawptr(&graph.user_handlers), http.auth_logout_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me", rawptr(&graph.user_handlers), http.me_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/logout-url", rawptr(&graph.user_handlers), http.logout_url_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/agent-writes", rawptr(&graph.agent_write_handlers), http.list_agent_writes_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/experiments", rawptr(&graph.experiment_handlers), http.experiment_list_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/me/experiments/*", rawptr(&graph.experiment_handlers), http.experiment_set_handler)
	http.router_add(&graph.router, "GET", "/api/v1/providers", rawptr(&graph.provider_handlers), http.provider_catalog_list_handler)
	http.router_add(&graph.router, "GET", "/api/v1/providers/*/icon", rawptr(&graph.provider_handlers), http.provider_icon_handler)
 for route in ([]struct{method,path:string}{{"GET","/api/v1/bridges/*/provider-profiles"},{"PUT","/api/v1/bridges/*/provider-profiles/*"},{"DELETE","/api/v1/bridges/*/provider-profiles/*"},{"POST","/api/v1/bridges/*/provider-profiles/*/get"},{"POST","/api/v1/bridges/*/provider-profiles/*/reset"}}) {
 http.router_add(&graph.router,route.method,route.path,rawptr(&graph.provider_handlers),http.bridge_provider_profiles_handler)
 }
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/provider-status", rawptr(&graph.provider_handlers), http.bridge_provider_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/providers/discover", rawptr(&graph.provider_handlers), http.bridge_provider_discover_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/providers/*/extension-install", rawptr(&graph.provider_handlers), http.bridge_provider_extension_install_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/providers/*/acp-adapter", rawptr(&graph.provider_handlers), http.bridge_provider_acp_adapter_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/providers/*/extension-install/*", rawptr(&graph.provider_handlers), http.bridge_provider_extension_command_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/providers/*/extension-uninstall", rawptr(&graph.provider_handlers), http.bridge_provider_extension_uninstall_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/providers/*/extension-uninstall/*", rawptr(&graph.provider_handlers), http.bridge_provider_extension_command_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/bridges/*/providers/*", rawptr(&graph.provider_handlers), http.bridge_provider_enable_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/provider-tests", rawptr(&graph.provider_handlers), http.provider_test_start_handler)
	http.router_add(&graph.router, "GET", "/api/v1/provider-tests/*", rawptr(&graph.provider_handlers), http.provider_test_get_handler)
	http.router_add(&graph.router, "POST", "/api/v1/provider-tests/*/validate", rawptr(&graph.provider_handlers), http.provider_test_validate_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/provider-tests/*", rawptr(&graph.provider_handlers), http.provider_test_cancel_handler)
	// Passwordless vault device directory (plan §2 P2). Literal paths before wildcards.
	http.router_add(&graph.router, "GET", "/api/v1/vault/directory", rawptr(&graph.vault_directory_handlers), http.vault_directory_get_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/directory/genesis", rawptr(&graph.vault_directory_handlers), http.vault_genesis_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/directory/reset", rawptr(&graph.vault_directory_handlers), http.vault_reset_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/directory/reset/cancel", rawptr(&graph.vault_directory_handlers), http.vault_reset_cancel_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/directory/rotate", rawptr(&graph.vault_directory_handlers), http.vault_rotate_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/devices/register", rawptr(&graph.vault_directory_handlers), http.vault_register_handler)
	http.router_add(&graph.router, "GET", "/api/v1/vault/devices/self", rawptr(&graph.vault_directory_handlers), http.vault_self_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/devices/recovery", rawptr(&graph.vault_directory_handlers), http.vault_recovery_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/devices/*/approve", rawptr(&graph.vault_directory_handlers), http.vault_approve_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/devices/*/revoke", rawptr(&graph.vault_directory_handlers), http.vault_revoke_handler)
	http.router_add(&graph.router, "POST", "/api/v1/vault/devices/*/deny", rawptr(&graph.vault_directory_handlers), http.vault_deny_handler)
	// LSP server config CRUD (REQ-LSP-CFG-1). The /resolve literal route must be
	// registered before the /* wildcard so first-match-wins selects it correctly.
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/lsp-servers", rawptr(&graph.lsp_server_config_handlers), http.lsp_server_config_create_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/lsp-servers", rawptr(&graph.lsp_server_config_handlers), http.lsp_server_config_list_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/launch-defaults", rawptr(&graph.fleet_handlers), http.fleet_settings_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/agent-overrides", rawptr(&graph.fleet_handlers), http.fleet_settings_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/fleet/apply", rawptr(&graph.fleet_handlers), http.fleet_apply_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/fleet/preview", rawptr(&graph.fleet_handlers), http.fleet_preview_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/fleet/applications/*", rawptr(&graph.fleet_handlers), http.fleet_application_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/fleet/applications/*/retry", rawptr(&graph.fleet_handlers), http.fleet_retry_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/lsp-servers/resolve", rawptr(&graph.lsp_server_config_handlers), http.lsp_server_config_resolve_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/lsp-servers/*", rawptr(&graph.lsp_server_config_handlers), http.lsp_server_config_get_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/bridges/*/lsp-servers/*", rawptr(&graph.lsp_server_config_handlers), http.lsp_server_config_delete_handler)
	http.router_add(&graph.router, "POST", "/api/v1/me/ws-ticket", rawptr(&graph.user_handlers), http.issue_user_ws_ticket_handler)
	http.router_add(&graph.router, "GET", "/api/v1/push/vapid-public-key", rawptr(&graph.push_handlers), http.vapid_public_key_handler)
	http.router_add(&graph.router, "POST", "/api/v1/me/push-subscriptions", rawptr(&graph.push_handlers), http.create_push_subscription_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/me/push-subscriptions", rawptr(&graph.push_handlers), http.delete_push_subscription_handler)
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/user-ws", rawptr(&graph.user_handlers), http.user_ws_upgrade_handler)
	http.router_add(&graph.router, "GET", "/api/v1/search", rawptr(&graph.search_handlers), http.search_handler)
	http.router_add(&graph.router, "GET", "/api/v1/skills/*", rawptr(&graph.skills_handlers), http.skill_detail_handler)
	http.router_add(&graph.router, "GET", "/api/v1/memories", rawptr(&graph.content_handlers), http.list_memories_handler)
	http.router_add(&graph.router, "POST", "/api/v1/memories", rawptr(&graph.content_handlers), http.create_memory_handler)
	http.router_add(&graph.router, "GET", "/api/v1/memories/*", rawptr(&graph.content_handlers), http.memory_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/memories/*", rawptr(&graph.content_handlers), http.patch_memory_handler)
	http.router_add(&graph.router, "POST", "/api/v1/memories/*/*", rawptr(&graph.content_handlers), http.memory_action_handler)
	http.router_add(&graph.router, "GET", "/api/v1/chats", rawptr(&graph.content_handlers), http.list_chats_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats", rawptr(&graph.content_handlers), http.create_chat_handler)
	// Registered BEFORE the /chats/* wildcards so the literal "by-instance"
	// segment wins over "/chats/*/..." patterns (first-match-wins, equal segment
	// count). Resolves the single conversation for an agent instance id.
	http.router_add(&graph.router, "GET", "/api/v1/chats/by-instance/*", rawptr(&graph.content_handlers), http.get_chat_by_instance_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/chats/*", rawptr(&graph.content_handlers), http.patch_chat_handler)
	http.router_add(&graph.router, "GET", "/api/v1/chats/*/messages", rawptr(&graph.content_handlers), http.list_chat_messages_handler)
	http.router_add(&graph.router, "GET", "/api/v1/chats/*/messages/*", rawptr(&graph.content_handlers), http.get_conversation_message_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats/*/messages", rawptr(&graph.content_handlers), http.send_chat_message_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats/*/messages/*/answers", rawptr(&graph.content_handlers), http.answer_chat_questions_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats/*/pane-capture", rawptr(&graph.content_handlers), http.pane_capture_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats/*/read", rawptr(&graph.content_handlers), http.read_chat_handler)
	http.router_add(&graph.router, "GET", "/api/v1/chats/*/send-now", rawptr(&graph.content_handlers), http.get_send_now_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats/*/send-now", rawptr(&graph.content_handlers), http.send_now_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts", rawptr(&graph.content_handlers), http.list_artifacts_handler)
	http.router_add(&graph.router, "POST", "/api/v1/artifacts", rawptr(&graph.content_handlers), http.create_artifact_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts/*/content", rawptr(&graph.content_handlers), http.artifact_content_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts/*/download", rawptr(&graph.content_handlers), http.artifact_download_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts/*", rawptr(&graph.content_handlers), http.artifact_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/artifacts/*", rawptr(&graph.content_handlers), http.patch_artifact_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/artifacts/*", rawptr(&graph.content_handlers), http.delete_artifact_handler)
	http.router_add(&graph.router, "GET", "/api/v1/templates", rawptr(&graph.content_handlers), http.list_templates_handler)
	http.router_add(&graph.router, "POST", "/api/v1/templates", rawptr(&graph.content_handlers), http.create_template_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/templates/*", rawptr(&graph.content_handlers), http.update_template_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/templates/*", rawptr(&graph.content_handlers), http.delete_template_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances", rawptr(&graph.agent_handlers), http.list_agent_instances_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances", rawptr(&graph.agent_handlers), http.create_agent_instance_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/pane", rawptr(&graph.agent_handlers), http.get_agent_instance_pane_handler)
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/agent-instances/*/stream", rawptr(&graph.agent_handlers), http.agent_instance_stream_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/input", rawptr(&graph.agent_handlers), http.agent_instance_input_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/resize", rawptr(&graph.agent_handlers), http.agent_instance_resize_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/reconfigurations/retry", rawptr(&graph.agent_handlers), http.retry_instance_reconfiguration_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/reconfigurations", rawptr(&graph.agent_handlers), http.create_instance_reconfiguration_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/reconfigurations", rawptr(&graph.agent_handlers), http.list_instance_reconfigurations_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/extension/events", rawptr(&graph.agent_handlers), http.agent_instance_extension_events_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/extension/subagents", rawptr(&graph.agent_handlers), http.agent_instance_extension_subagents_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/extension/files", rawptr(&graph.agent_handlers), http.agent_instance_extension_files_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/blockers", rawptr(&graph.agent_handlers), http.agent_instance_blockers_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/blockers/*/resolve", rawptr(&graph.agent_handlers), http.agent_instance_blocker_resolve_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*", rawptr(&graph.agent_handlers), http.agent_instance_detail_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/start", rawptr(&graph.agent_handlers), http.start_agent_instance_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/restart", rawptr(&graph.agent_handlers), http.restart_agent_instance_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/stop", rawptr(&graph.agent_handlers), http.stop_agent_instance_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/fs", rawptr(&graph.bridge_handlers), http.list_instance_dir_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*/fs/file", rawptr(&graph.bridge_handlers), http.read_instance_file_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/conversation-launch", rawptr(&graph.user_handlers), http.get_conversation_launch_preferences_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/home-layout", rawptr(&graph.user_handlers), http.home_layout_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/me/home-layout", rawptr(&graph.user_handlers), http.home_layout_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/me/conversation-launch", rawptr(&graph.user_handlers), http.patch_conversation_launch_preferences_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/agents/*/favorite", rawptr(&graph.user_handlers), http.set_agent_favorite_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agents", rawptr(&graph.agent_handlers), http.list_agents_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agents", rawptr(&graph.agent_handlers), http.create_agent_handler)
	// Registered BEFORE the /agents/* wildcard so the literal "live" tree endpoint
	// (project -> live-chains -> agents) is not swallowed by agent_detail_handler.
	http.router_add(&graph.router, "GET", "/api/v1/agents/live", rawptr(&graph.taskchain_handlers), http.agents_live_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bots/me", rawptr(&graph.bot_handlers), http.bot_me_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bots/me", rawptr(&graph.bot_handlers), http.bot_me_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/bots/me", rawptr(&graph.bot_handlers), http.bot_me_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bots/me/placement", rawptr(&graph.bot_handlers), http.bot_placement_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/bots/me/placement", rawptr(&graph.bot_handlers), http.bot_placement_handler)
	http.router_add(&graph.router,"GET","/api/v1/placement/candidates",rawptr(&graph.placement_handlers),http.placement_candidates_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bots/me/placement/options", rawptr(&graph.bot_handlers), http.bot_placement_options_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bots/me/deliveries", rawptr(&graph.bot_handlers), http.bot_deliveries_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bots/me/channels/telegram/pairing", rawptr(&graph.bot_handlers), http.bot_pairing_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/bots/me/channels/telegram", rawptr(&graph.bot_handlers), http.bot_disconnect_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bots/me/channels/whatsapp/pairing", rawptr(&graph.bot_handlers), http.bot_whatsapp_pairing_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/bots/me/channels/whatsapp", rawptr(&graph.bot_handlers), http.bot_whatsapp_disconnect_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bots/me/channels/telegram/messages", rawptr(&graph.bot_handlers), http.bot_messages_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bots/me/channels/web/messages", rawptr(&graph.bot_handlers), http.bot_web_messages_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bots/me/messages", rawptr(&graph.bot_handlers), http.bot_unified_messages_handler)
	http.router_add(&graph.router, "GET", "/api/v1/channels/whatsapp/webhook", rawptr(&graph.bot_webhook_handlers), http.whatsapp_webhook_handler)
	http.router_add(&graph.router, "POST", "/api/v1/channels/whatsapp/webhook", rawptr(&graph.bot_webhook_handlers), http.whatsapp_webhook_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/channel/media/fetch", rawptr(&graph.bot_agent_handlers), http.bot_agent_media_fetch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/channel/media/stored", rawptr(&graph.bot_agent_handlers), http.bot_agent_media_stored_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/channel/media/plan", rawptr(&graph.bot_agent_handlers), http.bot_agent_media_plan_handler)
	http.router_add(&graph.router, "GET", "/api/v1/events/metrics", rawptr(&graph.event_inbox_handlers), http.event_metrics_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/events/next", rawptr(&graph.event_inbox_handlers), http.event_next_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/events/ack", rawptr(&graph.event_inbox_handlers), http.event_ack_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/events/watch", rawptr(&graph.event_inbox_handlers), http.event_watch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/events/unwatch", rawptr(&graph.event_inbox_handlers), http.event_unwatch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/events/subscriptions", rawptr(&graph.event_inbox_handlers), http.event_subscriptions_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/channel/read", rawptr(&graph.bot_agent_handlers), http.bot_agent_channel_read_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/channel/send", rawptr(&graph.bot_agent_handlers), http.bot_agent_channel_send_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/channel/history", rawptr(&graph.bot_agent_handlers), http.bot_agent_channel_history_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agents/*", rawptr(&graph.agent_handlers), http.agent_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/agents/*", rawptr(&graph.agent_handlers), http.update_agent_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agents/*/archive", rawptr(&graph.agent_handlers), http.archive_agent_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agents/*/unarchive", rawptr(&graph.agent_handlers), http.unarchive_agent_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agents/*/bridge-support", rawptr(&graph.agent_handlers), http.list_agent_support_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/agents/*/bridge-support", rawptr(&graph.agent_handlers), http.put_agent_support_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/agents/*/bridge-support/*", rawptr(&graph.agent_handlers), http.patch_agent_support_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/agents/*/bridge-support/*", rawptr(&graph.agent_handlers), http.delete_agent_support_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects", rawptr(&graph.project_handlers), http.list_projects_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects", rawptr(&graph.project_handlers), http.create_project_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*", rawptr(&graph.project_handlers), http.project_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/projects/*", rawptr(&graph.project_handlers), http.update_project_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/archive", rawptr(&graph.project_handlers), http.archive_project_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/unarchive", rawptr(&graph.project_handlers), http.unarchive_project_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/projects/*/bridge-paths/*", rawptr(&graph.project_handlers), http.put_project_bridge_path_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/projects/*/bridge-paths/*", rawptr(&graph.project_handlers), http.delete_project_bridge_path_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/bridge-paths/*/validate", rawptr(&graph.project_handlers), http.validate_project_bridge_path_handler)
	// Project-scoped filesystem browser (resolves project -> bridge+root, relays fs_* WS commands).
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/fs", rawptr(&graph.bridge_handlers), http.list_project_dir_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/fs/quick-open", rawptr(&graph.bridge_handlers), http.quick_open_project_fs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/fs/search", rawptr(&graph.bridge_handlers), http.search_project_fs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/fs/file", rawptr(&graph.bridge_handlers), http.read_project_file_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/fs/file", rawptr(&graph.bridge_handlers), http.create_project_file_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/projects/*/fs/file", rawptr(&graph.bridge_handlers), http.write_project_file_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/projects/*/fs/files", rawptr(&graph.bridge_handlers), http.batch_write_project_files_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/fs/dir", rawptr(&graph.bridge_handlers), http.create_project_dir_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/fs/move", rawptr(&graph.bridge_handlers), http.move_project_path_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/projects/*/fs", rawptr(&graph.bridge_handlers), http.delete_project_path_handler)

	// Project-scoped VCS relay (resolves project -> bridge+root, relays vcs_* WS commands).
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/capabilities", rawptr(&graph.bridge_handlers), http.project_handle_vcs_capabilities)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/status", rawptr(&graph.bridge_handlers), http.project_handle_vcs_status)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/files", rawptr(&graph.bridge_handlers), http.project_handle_vcs_files)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/diff", rawptr(&graph.bridge_handlers), http.project_handle_vcs_diff)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/log", rawptr(&graph.bridge_handlers), http.project_handle_vcs_log)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/commit-diff", rawptr(&graph.bridge_handlers), http.project_handle_vcs_commit_diff)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/vcs/workspaces", rawptr(&graph.bridge_handlers), http.project_handle_vcs_workspaces)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/stage", rawptr(&graph.bridge_handlers), http.project_handle_vcs_stage)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/unstage", rawptr(&graph.bridge_handlers), http.project_handle_vcs_unstage)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/revert", rawptr(&graph.bridge_handlers), http.project_handle_vcs_revert)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/save-file", rawptr(&graph.bridge_handlers), http.project_handle_vcs_save_file)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/commit", rawptr(&graph.bridge_handlers), http.project_handle_vcs_commit)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/upload", rawptr(&graph.bridge_handlers), http.project_handle_vcs_upload)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/vcs/sync", rawptr(&graph.bridge_handlers), http.project_handle_vcs_sync)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains", rawptr(&graph.taskchain_handlers), http.list_task_chains_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/task-chain-search/documents", rawptr(&graph.taskchain_handlers), http.task_chain_search_documents_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains", rawptr(&graph.taskchain_handlers), http.create_task_chain_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/search/relay", rawptr(&graph.bridge_handlers), http.task_chain_search_relay_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*", rawptr(&graph.taskchain_handlers), http.task_chain_detail_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/summary", rawptr(&graph.taskchain_handlers), http.get_task_chain_summary_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/token-usage", rawptr(&graph.taskchain_handlers), http.task_chain_token_usage_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/conversation", rawptr(&graph.taskchain_handlers), http.get_task_chain_conversation_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/task-chains/*/summary", rawptr(&graph.taskchain_handlers), http.put_task_chain_summary_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/propose", rawptr(&graph.taskchain_handlers), http.propose_task_chain_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/proposal/decide", rawptr(&graph.taskchain_handlers), http.decide_task_chain_proposal_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/publish", rawptr(&graph.taskchain_handlers), http.publish_task_chain_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/complete", rawptr(&graph.taskchain_handlers), http.complete_task_chain_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/pin", rawptr(&graph.taskchain_handlers), http.pin_task_chain_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks", rawptr(&graph.taskchain_handlers), http.list_tasks_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks", rawptr(&graph.taskchain_handlers), http.create_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/publish", rawptr(&graph.taskchain_handlers), http.publish_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/review", rawptr(&graph.taskchain_handlers), http.user_review_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/reopen", rawptr(&graph.taskchain_handlers), http.reopen_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/answer", rawptr(&graph.taskchain_handlers), http.answer_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/hold", rawptr(&graph.taskchain_handlers), http.hold_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/release", rawptr(&graph.taskchain_handlers), http.hold_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/cancel", rawptr(&graph.taskchain_handlers), http.task_cancel_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/recheck", rawptr(&graph.taskchain_handlers), http.recheck_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/tasks/*/recheck", rawptr(&graph.taskchain_handlers), http.recheck_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/tasks/*/placement-recovery", rawptr(&graph.taskchain_handlers), http.recover_task_placement_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/placement-recovery", rawptr(&graph.taskchain_handlers), http.recover_task_placement_handler)
	http.router_add(&graph.router, "POST", "/api/v1/cards/*/placement-recovery", rawptr(&graph.card_handlers), http.recover_card_placement_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/fetch", rawptr(&graph.taskchain_handlers), http.fetch_task_ref_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/readiness", rawptr(&graph.taskchain_handlers), http.task_readiness_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/events", rawptr(&graph.taskchain_handlers), http.list_task_events_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/attempts/*/facets/*", rawptr(&graph.taskchain_handlers), http.get_task_facet_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/task-chains/*", rawptr(&graph.taskchain_handlers), http.patch_task_chain_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/members", rawptr(&graph.taskchain_handlers), http.list_chain_members_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/members", rawptr(&graph.taskchain_handlers), http.add_chain_member_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/task-chains/*/members/*", rawptr(&graph.taskchain_handlers), http.remove_chain_member_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories", rawptr(&graph.taskchain_handlers), http.list_chain_directories_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/directories", rawptr(&graph.taskchain_handlers), http.add_chain_directory_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*", rawptr(&graph.taskchain_handlers), http.get_chain_directory_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/task-chains/*/directories/*", rawptr(&graph.taskchain_handlers), http.patch_chain_directory_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/task-chains/*/directories/*", rawptr(&graph.taskchain_handlers), http.remove_chain_directory_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/fleets", rawptr(&graph.taskchain_handlers), http.list_chain_fleets_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/task-chains/*/fleets/*", rawptr(&graph.taskchain_handlers), http.upsert_chain_fleet_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/task-chains/*/fleets/*", rawptr(&graph.taskchain_handlers), http.delete_chain_fleet_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/fleets/*/pause", rawptr(&graph.taskchain_handlers), http.pause_chain_fleet_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/fleets/*/resume", rawptr(&graph.taskchain_handlers), http.pause_chain_fleet_handler)
	// Task chain directory filesystem browser (resolves chain+directory -> bridge+path, relays fs_* WS commands).
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/fs", rawptr(&graph.bridge_handlers), http.list_chain_directory_fs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/fs/quick-open", rawptr(&graph.bridge_handlers), http.quick_open_chain_directory_fs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/fs/search", rawptr(&graph.bridge_handlers), http.search_chain_directory_fs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/fs/file", rawptr(&graph.bridge_handlers), http.read_chain_directory_file_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/directories/*/fs/file", rawptr(&graph.bridge_handlers), http.create_chain_directory_file_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/task-chains/*/directories/*/fs/file", rawptr(&graph.bridge_handlers), http.write_chain_directory_file_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/task-chains/*/directories/*/fs/files", rawptr(&graph.bridge_handlers), http.batch_write_chain_directory_files_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/directories/*/fs/dir", rawptr(&graph.bridge_handlers), http.create_chain_directory_dir_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/directories/*/fs/move", rawptr(&graph.bridge_handlers), http.move_chain_directory_path_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/task-chains/*/directories/*/fs", rawptr(&graph.bridge_handlers), http.delete_chain_directory_path_handler)
	// Task chain directory VCS relay (resolves chain+directory -> bridge+path, relays vcs_* WS commands).
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/capabilities", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_capabilities)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/status", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_status)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/files", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_files)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/diff", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_diff)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/log", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_log)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/commit-diff", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_commit_diff)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/directories/*/vcs/workspaces", rawptr(&graph.bridge_handlers), http.chain_directory_handle_vcs_workspaces)
	http.router_add(&graph.router, "GET", "/api/v1/workflows/templates", rawptr(&graph.taskchain_handlers), http.workflow_templates_handler)
	http.router_add(&graph.router, "GET", "/api/v1/workflows/definitions", rawptr(&graph.taskchain_handlers), http.workflow_list_definitions_handler)
	http.router_add(&graph.router, "POST", "/api/v1/workflows/definitions", rawptr(&graph.taskchain_handlers), http.workflow_define_handler)
	http.router_add(&graph.router, "POST", "/api/v1/workflows/define", rawptr(&graph.taskchain_handlers), http.workflow_define_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/work/complete", rawptr(&graph.agent_action_handlers), http.agent_action_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/work/scope", rawptr(&graph.agent_action_handlers), http.agent_action_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/work/remove-dependency", rawptr(&graph.agent_action_handlers), http.agent_action_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/work/depend", rawptr(&graph.agent_action_handlers), http.agent_action_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/work/graph", rawptr(&graph.agent_action_handlers), http.agent_action_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/work/complete", rawptr(&graph.taskchain_handlers), http.mixed_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/work/scope", rawptr(&graph.taskchain_handlers), http.mixed_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/work/remove-dependency", rawptr(&graph.taskchain_handlers), http.mixed_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/work/depend", rawptr(&graph.taskchain_handlers), http.mixed_work_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/work/graph", rawptr(&graph.taskchain_handlers), http.mixed_work_handler)
	http.router_add(&graph.router, "POST", "/api/v1/workflow-runs/*/cancel", rawptr(&graph.taskchain_handlers), http.workflow_cancel_handler)
	http.router_add(&graph.router, "POST", "/api/v1/workflow-runs/*/retry", rawptr(&graph.taskchain_handlers), http.workflow_retry_handler)
	http.router_add(&graph.router, "GET", "/api/v1/workflow-runs/*/executions", rawptr(&graph.taskchain_handlers), http.workflow_history_handler)
	http.router_add(&graph.router, "GET", "/api/v1/workflow-runs/*/output", rawptr(&graph.taskchain_handlers), http.workflow_output_handler)
	http.router_add(&graph.router, "GET", "/api/v1/workflow-runs/*", rawptr(&graph.taskchain_handlers), http.workflow_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/workflow-runs", rawptr(&graph.taskchain_handlers), http.workflow_run_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/workflow-runs", rawptr(&graph.taskchain_handlers), http.workflow_runs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*", rawptr(&graph.taskchain_handlers), http.get_task_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/task-chains/*/tasks/*", rawptr(&graph.taskchain_handlers), http.patch_task_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/comments", rawptr(&graph.taskchain_handlers), http.list_task_comments_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/comments", rawptr(&graph.taskchain_handlers), http.create_task_comment_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/send-to-user", rawptr(&graph.agent_action_handlers), http.agent_action_chat_send_to_user_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/send-to-agent", rawptr(&graph.agent_action_handlers), http.agent_action_chat_send_to_agent_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/previous-context", rawptr(&graph.agent_action_handlers), http.agent_action_chat_previous_context_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/fetch", rawptr(&graph.agent_action_handlers), http.agent_action_chat_fetch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/read", rawptr(&graph.agent_action_handlers), http.agent_action_chat_read_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/assistant-message", rawptr(&graph.agent_action_handlers), http.agent_action_chat_assistant_message_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/input-state", rawptr(&graph.agent_action_handlers), http.agent_action_chat_input_state_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/conversation/set-title", rawptr(&graph.agent_action_handlers), http.agent_action_conversation_set_title_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/set-title", rawptr(&graph.agent_action_handlers), http.agent_action_chain_set_title_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/set-description", rawptr(&graph.agent_action_handlers), http.agent_action_chain_set_description_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/set-status", rawptr(&graph.agent_action_handlers), http.agent_action_chain_set_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/update", rawptr(&graph.agent_action_handlers), http.agent_action_chain_update_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/show", rawptr(&graph.agent_action_handlers), http.agent_action_chain_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/summary", rawptr(&graph.agent_action_handlers), http.agent_action_chain_summary_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/summary/set", rawptr(&graph.agent_action_handlers), http.agent_action_chain_summary_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/summary/get", rawptr(&graph.agent_action_handlers), http.agent_action_chain_summary_get_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chain/propose", rawptr(&graph.agent_action_handlers), http.agent_action_chain_propose_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/templates", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_templates_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/list", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/define", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_define_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/run", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_run_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/runs", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_runs_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/history", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_history_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/status", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/output", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_output_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/retry", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_retry_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/workflow/cancel", rawptr(&graph.agent_action_handlers), http.agent_action_workflow_cancel_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/agents/live", rawptr(&graph.agent_action_handlers), http.agent_action_agents_live_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/context", rawptr(&graph.agent_action_handlers), http.agent_action_context_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/list", rawptr(&graph.agent_action_handlers), http.agent_action_task_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/show", rawptr(&graph.agent_action_handlers), http.agent_action_task_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/comments", rawptr(&graph.agent_action_handlers), http.agent_action_task_comments_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/create", rawptr(&graph.agent_action_handlers), http.agent_action_task_create_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/update", rawptr(&graph.agent_action_handlers), http.agent_action_task_update_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/depend", rawptr(&graph.agent_action_handlers), http.agent_action_task_depend_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/comment", rawptr(&graph.agent_action_handlers), http.agent_action_task_comment_handler)
    http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/transfer", rawptr(&graph.agent_action_handlers), http.agent_action_lease_claim_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/claim", rawptr(&graph.agent_action_handlers), http.agent_action_lease_claim_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/next", rawptr(&graph.agent_action_handlers), http.agent_action_lease_next_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/heartbeat", rawptr(&graph.agent_action_handlers), http.agent_action_lease_heartbeat_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/submit", rawptr(&graph.agent_action_handlers), http.agent_action_lease_submit_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/handoff", rawptr(&graph.agent_action_handlers), http.agent_action_lease_handoff_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/switch", rawptr(&graph.agent_action_handlers), http.agent_action_lease_switch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/lease/block", rawptr(&graph.agent_action_handlers), http.agent_action_lease_block_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/review/post", rawptr(&graph.agent_action_handlers), http.agent_action_review_post_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/task/fetch", rawptr(&graph.agent_action_handlers), http.agent_action_task_fetch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/task/readiness", rawptr(&graph.agent_action_handlers), http.agent_action_task_readiness_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/create", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_create_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/list", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/show", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/content", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_content_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/search", rawptr(&graph.agent_action_handlers), http.agent_action_search_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/memory/propose", rawptr(&graph.agent_action_handlers), http.agent_action_memory_propose_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/memory/list", rawptr(&graph.agent_action_handlers), http.agent_action_memory_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/memory/show", rawptr(&graph.agent_action_handlers), http.agent_action_memory_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/memory/content", rawptr(&graph.agent_action_handlers), http.agent_action_memory_content_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/cards/create", rawptr(&graph.agent_action_handlers), http.agent_action_card_create_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/cards/list", rawptr(&graph.agent_action_handlers), http.agent_action_card_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/cards/show", rawptr(&graph.agent_action_handlers), http.agent_action_card_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/cards/discard", rawptr(&graph.agent_action_handlers), http.agent_action_card_discard_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/cards/accept", rawptr(&graph.agent_action_handlers), http.agent_action_card_accept_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/start-success", rawptr(&graph.agent_action_handlers), http.agent_action_start_success_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/extension-events", rawptr(&graph.agent_action_handlers), http.agent_action_extension_events_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tool-activity", rawptr(&graph.agent_action_handlers), http.agent_action_tool_activity_handler)
	// REQ-ENROLL-9: the four pre-shared-token enrollment routes are GONE —
	// POST/GET /api/v1/bridge-enrollments, DELETE /api/v1/bridge-enrollments/*
	// (enrollment-token minting, listing and revocation) and
	// POST /api/v1/bridges/enroll (the token-for-credential exchange).
	// Enrollment is browser-approved only; see the /api/v1/device/* routes.
	http.router_add_secure_forms(&graph.router, &graph.bridge_handlers)
	http.router_add_streams(&graph.router, &graph.bridge_handlers, &graph.user_handlers.ws_tickets)
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/bridge-ws", rawptr(&graph.bridge_handlers), http.bridge_ws_upgrade_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/agent-instances/*/bootstrap", rawptr(&graph.bridge_handlers), http.bridge_instance_bootstrap_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridge/agent-instances/*/start-begin", rawptr(&graph.bridge_handlers), http.bridge_instance_start_begin_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/agents/*/bootstrap-manifest", rawptr(&graph.bridge_handlers), http.bridge_agent_manifest_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/blobs/*", rawptr(&graph.bridge_handlers), http.bridge_blob_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridge/blobs", rawptr(&graph.bridge_handlers), http.bridge_blobs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges", rawptr(&graph.bridge_handlers), http.list_bridges_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/shells/*/input", rawptr(&graph.bridge_handlers), http.bridge_shell_input_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/shells/*/resize", rawptr(&graph.bridge_handlers), http.bridge_shell_resize_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/session-projects", rawptr(&graph.bridge_handlers), http.list_bridge_session_projects_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/fs", rawptr(&graph.bridge_handlers), http.list_bridge_dir_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/fs/stat", rawptr(&graph.bridge_handlers), http.stat_bridge_path_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/fs/file", rawptr(&graph.bridge_handlers), http.read_bridge_file_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/fs/mkdir", rawptr(&graph.bridge_handlers), http.mkdir_bridge_path_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*", rawptr(&graph.bridge_handlers), http.bridge_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/bridges/*", rawptr(&graph.bridge_handlers), http.rename_bridge_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/revoke", rawptr(&graph.bridge_handlers), http.revoke_bridge_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridge/self/revoke", rawptr(&graph.bridge_handlers), http.bridge_self_revoke_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/update", rawptr(&graph.bridge_handlers), http.bridge_update_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/update-catalog", rawptr(&graph.bridge_handlers), http.bridge_auto_update_catalog_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/auto-update", rawptr(&graph.bridge_handlers), http.bridge_auto_update_config_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/bridges/*/auto-update", rawptr(&graph.bridge_handlers), http.bridge_auto_update_config_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/context-windows", rawptr(&graph.bridge_handlers), http.bridge_context_windows_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/bridges/*/context-windows", rawptr(&graph.bridge_handlers), http.bridge_context_windows_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/bridges/*/context-windows", rawptr(&graph.bridge_handlers), http.bridge_context_windows_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/uninstall", rawptr(&graph.bridge_handlers), http.bridge_uninstall_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/unseal", rawptr(&graph.bridge_handlers), http.bridge_unseal_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/public-key", rawptr(&graph.bridge_handlers), http.bridge_public_key_handler)
	// REQ-EA: pending-enrollment status for the approval page, and operator cancel.
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/enrollment", rawptr(&graph.bridge_handlers), http.bridge_enrollment_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/enrollment/cancel", rawptr(&graph.bridge_handlers), http.bridge_enrollment_cancel_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/events", rawptr(&graph.bridge_handlers), http.bridge_events_list_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/bridges/*/events", rawptr(&graph.bridge_handlers), http.bridge_events_purge_handler)
	// Actions API
	http.router_add(&graph.router,"POST","/api/v1/hooks/*",rawptr(&graph.webhook_handlers),http.event_webhook_receive_handler)
 http.router_add(&graph.router,"POST","/api/v1/hooks/*/*",rawptr(&graph.webhook_handlers),http.event_webhook_receive_handler)
 http.router_add(&graph.router,"GET","/api/v1/webhooks",rawptr(&graph.webhook_handlers),http.event_webhook_crud_handler)
 http.router_add(&graph.router,"POST","/api/v1/webhooks",rawptr(&graph.webhook_handlers),http.event_webhook_crud_handler)
 http.router_add(&graph.router,"GET","/api/v1/webhooks/*",rawptr(&graph.webhook_handlers),http.event_webhook_crud_handler)
 http.router_add(&graph.router,"PATCH","/api/v1/webhooks/*",rawptr(&graph.webhook_handlers),http.event_webhook_crud_handler)
 http.router_add(&graph.router,"DELETE","/api/v1/webhooks/*",rawptr(&graph.webhook_handlers),http.event_webhook_crud_handler)
 http.router_add(&graph.router,"POST","/api/v1/webhooks/*/rotate",rawptr(&graph.webhook_handlers),http.event_webhook_crud_handler)
 http.router_add(&graph.router, "GET", "/api/v1/actions", rawptr(&graph.action_handlers), http.list_actions_handler)
	http.router_add(&graph.router, "POST", "/api/v1/actions", rawptr(&graph.action_handlers), http.create_action_handler)
	http.router_add(&graph.router, "GET", "/api/v1/actions/trigger-types", rawptr(&graph.action_handlers), http.action_trigger_types_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/webhooks/create", rawptr(&graph.agent_action_handlers), http.agent_webhook_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/webhooks/update", rawptr(&graph.agent_action_handlers), http.agent_webhook_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/webhooks/list", rawptr(&graph.agent_action_handlers), http.agent_webhook_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/webhooks/show", rawptr(&graph.agent_action_handlers), http.agent_webhook_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/webhooks/rotate", rawptr(&graph.agent_action_handlers), http.agent_webhook_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/webhooks/enable", rawptr(&graph.agent_action_handlers), http.agent_webhook_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/webhooks/disable", rawptr(&graph.agent_action_handlers), http.agent_webhook_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/webhooks/delete", rawptr(&graph.agent_action_handlers), http.agent_webhook_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/webhooks/test", rawptr(&graph.agent_action_handlers), http.agent_webhook_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/list", rawptr(&graph.agent_action_handlers), http.agent_automation_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/create", rawptr(&graph.agent_action_handlers), http.agent_automation_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/show", rawptr(&graph.agent_action_handlers), http.agent_automation_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/update", rawptr(&graph.agent_action_handlers), http.agent_automation_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/delete", rawptr(&graph.agent_action_handlers), http.agent_automation_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/runs", rawptr(&graph.agent_action_handlers), http.agent_automation_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/trigger-types", rawptr(&graph.agent_action_handlers), http.agent_automation_handler)
 http.router_add(&graph.router, "POST", "/api/v1/agent-actions/automations/filter-test", rawptr(&graph.agent_action_handlers), http.agent_automation_handler)
 http.router_add(&graph.router, "POST", "/api/v1/actions/filter-test", rawptr(&graph.action_handlers), http.action_filter_test_handler)
	http.router_add(&graph.router, "POST", "/api/v1/actions/*/enable", rawptr(&graph.action_handlers), http.enable_action_handler)
	http.router_add(&graph.router, "POST", "/api/v1/actions/*/disable", rawptr(&graph.action_handlers), http.disable_action_handler)
	http.router_add(&graph.router,"GET","/api/v1/actions/*/runs",rawptr(&graph.action_handlers),http.list_action_runs_handler)
	http.router_add(&graph.router, "GET", "/api/v1/actions/*", rawptr(&graph.action_handlers), http.get_action_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/actions/*", rawptr(&graph.action_handlers), http.patch_action_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/actions/*", rawptr(&graph.action_handlers), http.delete_action_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridge/bot-attempts/*/switch", rawptr(&graph.bridge_handlers), http.bot_bridge_switch_handler)

	// Cards API
	http.router_add(&graph.router, "GET", "/api/v1/attention", rawptr(&graph.card_handlers), http.attention_handler)
	http.router_add(&graph.router, "GET", "/api/v1/attention/summary", rawptr(&graph.card_handlers), http.attention_summary_handler)
	http.router_add(&graph.router, "GET", "/api/v1/cards", rawptr(&graph.card_handlers), http.list_cards_handler)
	http.router_add(&graph.router, "POST", "/api/v1/cards", rawptr(&graph.card_handlers), http.create_card_handler)
	http.router_add(&graph.router, "GET", "/api/v1/cards/*", rawptr(&graph.card_handlers), http.get_card_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/cards/*", rawptr(&graph.card_handlers), http.patch_card_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/cards/*", rawptr(&graph.card_handlers), http.delete_card_handler)
	http.router_add(&graph.router, "POST", "/api/v1/cards/*/*", rawptr(&graph.card_handlers), http.card_action_handler)

	// Issues API
	http.router_add(&graph.router, "GET", "/api/v1/issues", rawptr(&graph.issue_handlers), http.list_issues_handler)
	http.router_add(&graph.router, "POST", "/api/v1/issues", rawptr(&graph.issue_handlers), http.create_issue_handler)
	http.router_add(&graph.router, "GET", "/api/v1/issues/*", rawptr(&graph.issue_handlers), http.get_issue_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/issues/*", rawptr(&graph.issue_handlers), http.patch_issue_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/issues/*", rawptr(&graph.issue_handlers), http.delete_issue_handler)
	http.router_add(&graph.router, "GET", "/api/v1/issues/*/comments", rawptr(&graph.issue_handlers), http.list_issue_comments_handler)
	http.router_add(&graph.router, "POST", "/api/v1/issues/*/comments", rawptr(&graph.issue_handlers), http.create_issue_comment_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/issues/*/comments/*", rawptr(&graph.issue_handlers), http.delete_issue_comment_handler)
	http.router_add(&graph.router, "GET", "/api/v1/issues/*/votes", rawptr(&graph.issue_handlers), http.list_issue_votes_handler)
	http.router_add(&graph.router, "POST", "/api/v1/issues/*/vote", rawptr(&graph.issue_handlers), http.vote_issue_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/issues/*/vote", rawptr(&graph.issue_handlers), http.unvote_issue_handler)
	http.router_add(&graph.router, "POST", "/api/v1/issues/*/unvote", rawptr(&graph.issue_handlers), http.unvote_issue_handler)

	// Shell session WS stream + HTTP input/resize fallback (T7).
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/tool-activity/stream", rawptr(&graph.agent_handlers), http.tool_stream_handler)
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/shells/*/stream", rawptr(&graph.shell_session_stream_handlers), http.shell_session_stream_handler)
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/lsp/*/stream", rawptr(&graph.lsp_session_stream_handlers), http.lsp_session_stream_handler)
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/input", rawptr(&graph.shell_session_stream_handlers), http.shell_session_input_handler)
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/resize", rawptr(&graph.shell_session_stream_handlers), http.shell_session_resize_handler)
	// Preview tunnel proxy (T8) — raw-socket route: handler owns the socket for all
	// request methods (plain HTTP and future WebSocket upgrade via XM-2).
	http.router_add_raw_upgrade(&graph.router, "ANY", "/api/v1/preview/**", rawptr(&graph.shell_session_stream_handlers), http.shell_session_preview_proxy_handler)
	http.router_add(&graph.router, "GET", http.PREVIEW_AUTH_START_PATH, rawptr(&graph.shell_session_stream_handlers), http.preview_auth_start_handler)
	// Shell session REST API (T5).
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/shells", rawptr(&graph.shell_session_rest_handlers), http.shell_session_create_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/shells", rawptr(&graph.shell_session_rest_handlers), http.shell_session_list_by_bridge_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*/shells", rawptr(&graph.shell_session_rest_handlers), http.shell_session_list_by_project_handler)
	http.router_add(&graph.router, "GET", "/api/v1/shells", rawptr(&graph.shell_session_rest_handlers), http.shell_session_list_handler)
	http.router_add(&graph.router, "GET", "/api/v1/shells/*", rawptr(&graph.shell_session_rest_handlers), http.shell_session_get_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/shells/*", rawptr(&graph.shell_session_rest_handlers), http.shell_session_kill_handler)
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/signal", rawptr(&graph.shell_session_rest_handlers), http.shell_session_signal_handler)
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/restart", rawptr(&graph.shell_session_rest_handlers), http.shell_session_restart_handler)
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/port", rawptr(&graph.shell_session_rest_handlers), http.shell_session_set_port_handler)
	// REQ-SHELL-2 §3: convert a live FOREGROUND run to background at runtime. The
	// control REQ-SHELL-6 builds in the UI calls this; it is also the shape the
	// agent-liveness hook uses, so both go through one transition.
	http.router_add(&graph.router, "POST", "/api/v1/shells/*/background", rawptr(&graph.shell_session_rest_handlers), http.shell_session_background_handler)
	http.router_add(&graph.router, "GET", "/api/v1/shells/*/log", rawptr(&graph.shell_session_rest_handlers), http.shell_session_log_handler)
	http.router_add(&graph.router, "GET", "/api/v1/shells/*/capture", rawptr(&graph.shell_session_rest_handlers), http.shell_session_capture_handler)
	http.router_add(&graph.router, "GET", "/api/v1/shells/*/pane", rawptr(&graph.shell_session_rest_handlers), http.shell_session_pane_handler)
}

health_handler :: proc(ctx: rawptr, req: http.Request) -> http.Response {
	graph := (^App_Graph)(ctx)
	server_time := platform.clock_now(&graph.clock)
	status, backlog := eventrelay.health(&graph.event_relay)

	payload := struct {
		ok: bool,
		version: int,
		events: struct { status: string, outbox_backlog: i64 },
	}{ok = true, version = 1, events = {status = status, outbox_backlog = backlog}}
	return http.respond_success_typed(payload, req.request_id, server_time)
}

// device_bridge_minter is the REQ-IMPL-2 bridge-credential issuer wired into
// approve. It mints a `brg_` row and a credential that resolves to exactly that one bridge, so
// verify_bridge_token / resolve_bridge_instance_auth give per-machine scoping.
// Returns (plaintext_token, bridge_id, ok).
device_bridge_minter :: proc(graph_ptr: rawptr, req: device_auth_service.Bridge_Mint_Request) -> (device_auth_service.Bridge_Mint_Result, bool) {
	graph := (^App_Graph)(graph_ptr)
	// Passwordless vault gate (plan §2 P2): a bridge enrolls only into an existing
	// vault directory, and only with an approving device's signed `approve`
	// statement naming the bridge's persistent identity key. Validated BEFORE the
	// credential is minted; committed (versioned CAS) right after, and a failed
	// commit cancels the still-pending enrollment so no unattested bridge remains.
	if !req.vault_approval.present {
		return device_auth_service.Bridge_Mint_Result{
			error = domain.domain_error(.Validation_Failed, "approving a bridge requires a signed vault_approval from an approved device"),
		}, false
	}
	approval_in := vault_directory_service.Bridge_Approval_Input{
		user_id = req.owner_user_id,
		expected_version = req.vault_approval.expected_version,
		statement = req.vault_approval.statement,
		signature = req.vault_approval.signature,
		bridge_identity_public_key = req.bridge_identity_public_key,
	}
	vault_device, check_err := vault_directory_service.check_bridge_approval(&graph.vault_directory, approval_in)
	if check_err.code != .None do return device_auth_service.Bridge_Mint_Result{error = check_err}, false
	result, ok, mint_err := bridge_service.enroll_bridge_from_device_grant(&graph.bridges, bridge_service.Device_Enroll_Input{
		owner_user_id = req.owner_user_id, // bound from Auth_Context by approve()
		bridge_public_key = req.bridge_public_key,
		bridge_key_fingerprint = req.bridge_key_fingerprint,
		os_user = req.os_user,
		machine_hostname = req.device_label,
		machine_os = req.os,
		bridge_version = req.app_version,
		new_bridge_label = req.new_bridge_label,
		// REQ-BE-3: the approver's "reuse this bridge" choice. Empty mints a new
		// bridge; non-empty attaches, and the bridge service re-checks that the
		// approver owns the target and that it is neither revoked nor pending.
		target_bridge_id = req.target_bridge_id,
		// The setup wizard's "register new and sunset one": retired in the same
		// repository transaction that creates the new row; restored by any rollback of
		// this pending enrollment (below, cancel, committed:false, the sweep), and
		// final only once the bridge commits its vault key.
		sunset_bridge_id = req.sunset_bridge_id,
		// REQ-EA-1: the enrollment stays pending until the vault key is delivered.
		pending = true,
	})
	if !ok {
		// Pass ownership/target refusals through (e.g. an attach target that is not
		// the approver's): they are the approver's to see, not an internal fault.
		if mint_err.code == .Not_Found || mint_err.code == .Validation_Failed || mint_err.code == .Plan_Limit_Reached {
			return device_auth_service.Bridge_Mint_Result{error = mint_err}, false
		}
		return device_auth_service.Bridge_Mint_Result{}, false
	}
	if _, commit_err := vault_directory_service.commit_bridge_approval(&graph.vault_directory, approval_in, vault_device, result.bridge.bridge_id); commit_err.code != .None {
		// Roll back exactly the family just minted. cancel_pending_enrollment would pick
		// the bridge's newest enroll family, which for an attach refused because another
		// attach is already pending could be THAT attach's family (same-second tie).
		// The same rollback restores a bridge this enrollment sunset (from the durable
		// receipt), in the transaction that deletes the new row.
		_, _, _ = bridge_service.rollback_pending_enrollment(&graph.bridges, result.bridge.bridge_id, result.family_id)
		return device_auth_service.Bridge_Mint_Result{error = commit_err}, false
	}
	// REQ-IMPL-3: enroll_bridge_from_device_grant returns an EXPIRING PAIR
	// (`hba_` + `hbf_`), so the approval hands both halves to the grant and the
	// bridge receives them together on its single-use poll.
	return device_auth_service.Bridge_Mint_Result{
		access_token = result.bridge_token,
		refresh_token = result.refresh_token,
		bridge_id = result.bridge.bridge_id,
		expires_in = result.expires_in,
		refresh_expires_in = result.refresh_expires_in,
		vault_delivery_expected = true,
	}, true
}

// attention_card_changed adapts the card service's change hook to the
// debounced attention_changed event (one hint per owner per 500ms).
attention_card_changed :: proc(ctx: rawptr, owner_user_id: string, kind: string) {
	events.attention_debouncer_note((^events.Attention_Debouncer)(ctx), owner_user_id, kind)
}

// configure_db_telemetry applies Hub_Config's DB telemetry settings
// (HEIMDALL_DB_TELEMETRY / _SLOW_MS / _SAMPLE_N). Default: basic.
configure_db_telemetry :: proc(config: Hub_Config) -> (bool, string) {
	mode, ok, message := dbt.parse_mode(config.db_telemetry)
	if !ok do return false, message
	dbt.set_mode(mode)
	if config.db_slow_ms >= 0 do dbt.slow_config.slow_ms = i64(config.db_slow_ms)
	if config.db_sample_n >= 0 do dbt.slow_config.sample_n = i64(config.db_sample_n)
	return true, ""
}

// read_secret_file reads a secret from a file (trailing whitespace trimmed). The
// contents are never logged.
read_secret_file :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return "", false
	secret := strings.clone(strings.trim_space(string(data)))
	delete(data)
	return secret, secret != ""
}

// The inbox observes pending messages; delivery stays on the existing bridge
// notice and guarded agent start paths, always outside a SQLite transaction.
event_inbox_notice :: proc(
	ctx: rawptr,
	owner, instance: string,
	target: domain.Event_Notice_Target,
	count: int,
	wake: bool,
) -> bool {
	graph := (^App_Graph)(ctx)
	// Only the subscription's own instance is ever notified (REQ-EVP-4a).
	if target.instance_id != instance do return false
	inst, found, _ := iface.agent_get_instance(&graph.repos.agents, target.instance_id)
	defer domain.agent_instance_destroy(&inst)
	if !found || string(inst.owner_user_id) != owner || inst.stopped_by != "" do return false
	if wake {
		if inst.runtime_status != "stopped" do return false
		guard := Event_Inbox_Wake_Guard {
			graph       = graph,
			owner       = owner,
			instance_id = inst.agent_instance_id,
		}
		_, started, _ := agent_service.start_instance(
			&graph.agents,
			{kind = .Internal_User, user_id = owner},
			inst.agent_instance_id,
			&guard,
			event_inbox_wake_guard,
		)
		return started
	}
	if (inst.runtime_status != "running" && inst.runtime_status != "idle") || inst.activity_status != "idle" do return false
	id := platform.generate_id(&graph.ids, "cmd_events_")
	if id == "" do return false
	// ID generator returns temporary allocator storage.
	line := fmt.tprintf("[events] %d new event(s) — run ham-ctl events next", count)
	body := taskv2.agent_notice_command_json(id, inst.agent_instance_id, "", "events", line)
	defer delete(body)
	accepted, _ := project_service.bridge_command_send_runtime(
		graph.agents.bridge_command_sink,
		{bridge_id = inst.bridge_id, command_id = id, body_json = body},
	)
	return accepted
}

// start_instance invokes this while holding reconfiguration_mutex, the same
// mutex as stop_instance. An automatic event wake must never clear a user stop
// that arrived after the inbox's earlier snapshot.
Event_Inbox_Wake_Guard :: struct {
	graph:              ^App_Graph,
	owner, instance_id: string,
}
event_inbox_wake_guard :: proc(ctx: rawptr) -> domain.Domain_Error {
	guard := (^Event_Inbox_Wake_Guard)(ctx)
	inst, found, err := iface.agent_get_instance(&guard.graph.repos.agents, guard.instance_id)
	defer domain.agent_instance_destroy(&inst)
	if err.code != .None do return err
	if !found || string(inst.owner_user_id) != guard.owner do return domain.domain_error(.Not_Found, "event wake instance no longer belongs to subscriber")
	if inst.stopped_by != "" || inst.runtime_status != "stopped" do return domain.domain_error(.Conflict, "event wake requires a stopped instance without an explicit stop")
	return {}
}

action_schedule_support :: proc(ctx:rawptr) -> int {
	return int(eventrelay.schedule_support((^eventrelay.Service)(ctx)))
}


action_agent_find :: proc(ctx:rawptr,owner,agent_id,project_id,prefer_instance:string,c:placement.Candidate)->(string,string,bool) {
 graph:=(^App_Graph)(ctx)
 context.allocator=context.temp_allocator
 auth:=contracts.Auth_Context{kind=.Internal_User,user_id=owner}
 rows,err:=agent_service.list_action_instances(&graph.agents,auth,agent_id,c.bridge_id)
 if err.code!=.None do return "","",false
 chosen:domain.Agent_Instance
 found:=false
 for inst in rows {
  if string(inst.project_id)!=project_id || (c.provider!=placement.ANY && inst.provider!=c.provider) || (c.model!=placement.ANY && inst.model!=c.model && inst.model!=c.resolved_model) do continue
  if !found || inst.created_at>chosen.created_at || (inst.created_at==chosen.created_at && inst.agent_instance_id>chosen.agent_instance_id) {
   chosen=inst; found=true
  }
  if inst.agent_instance_id==prefer_instance {chosen=inst;found=true;break}
 }
 if !found do return "","",false
 conversation,exists,e:=content_service.get_action_conversation(&graph.content,auth,chosen.agent_instance_id)
 if !exists || e.code!=.None do return "","",false
 return chosen.agent_instance_id,conversation.conversation_id,true
}
action_agent_create :: proc(ctx:rawptr,owner,agent_id,project_id:string,c:placement.Candidate)->(string,string,domain.Domain_Error) {
 graph:=(^App_Graph)(ctx)
 context.allocator=context.temp_allocator
 inst,ok,err:=agent_service.create_instance_stopped(&graph.agents,{kind=.Internal_User,user_id=owner},
  {fleet_scope="excluded",agent_id=agent_id,project_id=domain.Project_ID(project_id),bridge_id=c.bridge_id,provider=c.provider,provider_profile=c.provider_profile,model=c.model})
 if !ok {
  if err.code==.None do err=domain.domain_error(.Internal_Error,"instance creation refused")
  return "","",err
 }
 return inst.agent_instance_id,inst.conversation_id,{}
}
action_agent_stop :: proc(ctx:rawptr,owner,instance_id:string) {
 graph:=(^App_Graph)(ctx)
 context.allocator=context.temp_allocator
 row,ok,err:=agent_service.stop_instance_confirmed(&graph.agents,{kind=.Internal_User,user_id=owner},instance_id,{reason="action_fresh_per_run"})
 defer domain.agent_instance_destroy(&row)
 if !ok do fmt.eprintf("action stop %s: %s\n",instance_id,err.message)
}
action_agent_instance :: proc(ctx:rawptr,owner,instance_id:string)->(string,string,string,bool) {
 graph:=(^App_Graph)(ctx)
 context.allocator=context.temp_allocator
 auth:=contracts.Auth_Context{kind=.Internal_User,user_id=owner}
 inst,found,err:=agent_service.get_instance(&graph.agents,auth,instance_id)
 if !found || err.code!=.None do return "","","",false
 conversation,exists,e:=content_service.get_action_conversation(&graph.content,auth,instance_id)
 if !exists || e.code!=.None do return "","","",false
 return inst.agent_id,inst.bridge_id,conversation.conversation_id,true
}
action_persist_prompt :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,conversation_id,body,metadata_json:string)->(string,domain.Domain_Error) {
 graph:=(^App_Graph)(ctx)
 context.allocator=context.temp_allocator
 message,ok,err:=content_service.persist_user_message(&graph.content,{kind=.Internal_User,user_id=owner},conversation_id,
  {body=body,message_type="action",metadata_json=metadata_json})
 if !ok && err.code==.None do return "",domain.domain_error(.Internal_Error,"prompt storage refused")
 return message.message_id,err
}
action_retire_prompt :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,message_id,moved_to_instance_id:string)->domain.Domain_Error {
 graph:=(^App_Graph)(ctx)
 context.allocator=context.temp_allocator
 repo:=&uow.repos.content
 message,found,err:=iface.content_get_message(repo,message_id)
 if err.code!=.None do return err
 if !found || string(message.owner_user_id)!=owner do return domain.domain_error(.Not_Found,"prompt not found")
 value:json.Value
 if json.unmarshal(transmute([]u8)message.metadata_json,&value,allocator=context.temp_allocator)!=nil do return domain.domain_error(.Internal_Error,"invalid prompt metadata")
 metadata,valid:=value.(json.Object)
 if !valid do return domain.domain_error(.Internal_Error,"invalid prompt metadata")
 metadata["moved_to_instance_id"]=moved_to_instance_id
 encoded,e:=json.marshal(metadata,allocator=context.temp_allocator)
 if e!=nil do return domain.domain_error(.Internal_Error,"cannot encode moved prompt")
 _,updated,update_err:=iface.content_update_message(repo,domain.User_ID(owner),message.conversation_id,message_id,message.body,message.message_status,string(encoded))
 if update_err.code!=.None do return update_err
 if !updated do return domain.domain_error(.Conflict,"prompt metadata not updated")
 ids:=[1]string{message_id}
 _,mark_err:=iface.content_mark_messages_read(repo,domain.User_ID(owner),ids[:],platform.clock_now(&graph.clock))
 return mark_err
}
action_route_delivery :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,input:delivery.Route_Input)->(string,domain.Domain_Error) {
 return delivery.route((^delivery.Service)(ctx),uow,input)
}
action_expire_delivery :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,id:string)->(bool,domain.Domain_Error) {
 return delivery.expire((^delivery.Service)(ctx),uow,id)
}

action_unread_delivery :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner,id:string)->domain.Domain_Error {
 return delivery.on_unread((^delivery.Service)(ctx),uow,owner,id)
}
delivery_messages_read :: proc(ctx:rawptr,uow:^iface.Unit_Of_Work,owner:domain.User_ID,ids:[]string)->domain.Domain_Error {
 return delivery.on_messages_read((^delivery.Service)(ctx),uow,owner,ids)
}
