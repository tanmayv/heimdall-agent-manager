package app

import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import content_service "odin_test:hub/service/content"
import device_auth_service "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"
import events "odin_test:hub/service/events"
import project_service "odin_test:hub/service/project"
import search_service "odin_test:hub/service/search"
import taskchain_service "odin_test:hub/service/taskchain"
import user_service "odin_test:hub/service/user"
import http "odin_test:hub/transport/http"
import platform "odin_test:hub/platform"

App_Graph :: struct {
	config: Hub_Config,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	bridge_runtime_registry: project_service.Bridge_Runtime_Registry,
	event_bus: events.User_Event_Bus,
	db: sqlite.Conn,
	sqlite_users: sqlite.User_Repo_SQLite,
	sqlite_bridges: sqlite.Bridge_Repo_SQLite,
	sqlite_agents: sqlite.Agent_Repo_SQLite,
	sqlite_projects: sqlite.Project_Repo_SQLite,
	sqlite_content: sqlite.Content_Repo_SQLite,
	sqlite_taskchains: sqlite.Taskchain_Repo_SQLite,
	sqlite_search: sqlite.Search_Repo_SQLite,
	sqlite_uow_factory: sqlite.SQLite_Unit_Of_Work_Factory,
	repos: iface.Repositories,
	uow_factory: iface.Unit_Of_Work_Factory,
	users: user_service.User_Service,
	bridges: bridge_service.Bridge_Service,
	agents: agent_service.Agent_Service,
	projects: project_service.Project_Service,
	content: content_service.Content_Service,
	taskchains: taskchain_service.Taskchain_Service,
	search: search_service.Search_Service,
	auth: auth_service.Auth_Service,
	device_auth_store: device_auth_service.Grant_Store,
	device_auth: device_auth_service.Device_Auth_Service,
	device_auth_handlers: http.Device_Auth_Handlers,
	user_handlers: http.User_Handlers,
	bridge_handlers: http.Bridge_Handlers,
	agent_handlers: http.Agent_Handlers,
	project_handlers: http.Project_Handlers,
	content_handlers: http.Content_Handlers,
	taskchain_handlers: http.Taskchain_Handlers,
	search_handlers: http.Search_Handlers,
	agent_action_handlers: http.Agent_Action_Handlers,
	router: http.Router,
}

build_graph :: proc(graph: ^App_Graph, config: Hub_Config) -> (bool, string) {
	graph.config = config
	graph.clock = platform.real_clock()
	graph.ids = platform.real_id_generator()

	db, db_ok, db_err := sqlite.open(config.database_path)
	if !db_ok do return false, db_err.message
	graph.db = db

	migrations_ok, migration_err := sqlite.run_migrations(&graph.db, config.migrations_dir)
	if !migrations_ok do return false, migration_err.message

	graph.repos.users = sqlite.new_user_repository(&graph.sqlite_users, &graph.db)
	graph.repos.bridges = sqlite.new_bridge_repository(&graph.sqlite_bridges, &graph.db)
	graph.repos.agents = sqlite.new_agent_repository(&graph.sqlite_agents, &graph.db)
	graph.repos.projects = sqlite.new_project_repository(&graph.sqlite_projects, &graph.db)
	graph.repos.content = sqlite.new_content_repository(&graph.sqlite_content, &graph.db)
	graph.repos.taskchains = sqlite.new_taskchain_repository(&graph.sqlite_taskchains, &graph.db)
	graph.repos.search = sqlite.new_search_repository(&graph.sqlite_search, &graph.db)
	graph.uow_factory = sqlite.new_unit_of_work_factory(&graph.sqlite_uow_factory, &graph.db, &graph.repos)
	graph.users = user_service.new_user_service(&graph.repos.users, &graph.clock, &graph.ids)
	graph.bridges = bridge_service.new_bridge_service(&graph.repos.bridges, &graph.clock, &graph.ids)
	bridge_command_sink := bridge_runtime_service.new_bridge_command_sink(&graph.bridge_runtime_registry)
	graph.agents = agent_service.new_agent_service_with_runtime(&graph.repos.agents, &graph.repos.bridges, &graph.repos.projects, &graph.repos.content, &graph.repos.taskchains, bridge_command_sink, &graph.bridge_runtime_registry, &graph.clock, &graph.ids)
	graph.projects = project_service.new_project_service_with_command_sink(&graph.repos.projects, &graph.repos.bridges, bridge_command_sink, &graph.clock, &graph.ids)
	graph.content = content_service.new_content_service_with_runtime(&graph.repos.content, &graph.repos.agents, &graph.repos.projects, &graph.repos.taskchains, bridge_command_sink, &graph.clock, &graph.ids)
	graph.taskchains = taskchain_service.new_taskchain_service(&graph.repos.taskchains, &graph.repos.agents, &graph.clock, &graph.ids)
	graph.search = search_service.new_search_service(&graph.repos.search)
	graph.auth = auth_service.new_auth_service_with_tokens(auth_service.Trusted_Proxy_Config{
		username_header = config.username_header,
		display_name_header = config.display_name_header,
		email_header = config.email_header,
		trusted_proxy_cidrs = config.trusted_proxy_cidrs,
		auto_provision_users = config.auto_provision_users,
		login_url = config.login_url,
		logout_url = config.logout_url,
	}, &graph.users, &graph.repos.users, &graph.clock, &graph.ids)
	graph.device_auth_store = device_auth_service.new_grant_store(device_auth_service.Grant_Store_Config{
		verification_uri = config.device_auth_verification_uri,
		expires_in = config.device_auth_expires_in,
		interval = config.device_auth_interval,
		rate_limit = config.device_auth_rate_limit,
		rate_window = config.device_auth_rate_window,
	})
	graph.device_auth = device_auth_service.new_device_auth_service(&graph.device_auth_store, device_auth_service.real_monotonic_clock(), config.trusted_proxy_cidrs)
	// Wire the device-flow token issuer (ELDA-4). The minter captures the graph
	// so approve() can pre-mint a no-revoke, no-cap device token on the bound
	// owner and the grant holds the plaintext for the first poll.
	device_auth_service.with_token_minter(&graph.device_auth, device_minter, rawptr(graph))
	graph.user_handlers = http.User_Handlers{auth = &graph.auth, event_bus = &graph.event_bus, ws_tickets = http.new_user_ws_ticket_store()}
	graph.bridge_handlers = http.Bridge_Handlers{auth = &graph.auth, bridges = &graph.bridges, agents = &graph.agents, event_bus = &graph.event_bus, bridge_runtime_registry = &graph.bridge_runtime_registry}
	graph.agent_handlers = http.Agent_Handlers{auth = &graph.auth, agents = &graph.agents, event_bus = &graph.event_bus}
	graph.project_handlers = http.Project_Handlers{auth = &graph.auth, projects = &graph.projects}
	graph.content_handlers = http.Content_Handlers{auth = &graph.auth, agents = &graph.agents, content = &graph.content}
	graph.taskchain_handlers = http.Taskchain_Handlers{auth = &graph.auth, taskchains = &graph.taskchains, agents = &graph.agents}
	graph.search_handlers = http.Search_Handlers{auth = &graph.auth, search = &graph.search}
	graph.device_auth_handlers = http.Device_Auth_Handlers{service = &graph.device_auth, auth = &graph.auth}
	graph.agent_action_handlers = http.Agent_Action_Handlers{agents = &graph.agents, bridges = &graph.bridges, content = &graph.content, taskchains = &graph.taskchains}
	graph.router = http.new_router()
	register_routes(graph)
	return true, ""
}

shutdown_graph :: proc(graph: ^App_Graph) {
	http.router_free(&graph.router)
	http.user_ws_ticket_store_free(&graph.user_handlers.ws_tickets)
	device_auth_service.grant_store_free(&graph.device_auth_store)
	sqlite.close(&graph.db)
}

register_routes :: proc(graph: ^App_Graph) {
	http.router_add(&graph.router, "GET", "/api/v1/health", rawptr(graph), health_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/authorize", rawptr(&graph.device_auth_handlers), http.device_authorize_handler)
	http.router_add(&graph.router, "GET", "/api/v1/device", rawptr(&graph.device_auth_handlers), http.device_page_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/verify", rawptr(&graph.device_auth_handlers), http.device_verify_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/approve", rawptr(&graph.device_auth_handlers), http.device_approve_handler)
	http.router_add(&graph.router, "POST", "/api/v1/device/token", rawptr(&graph.device_auth_handlers), http.device_token_handler)
	http.router_add(&graph.router, "GET", "/api/v1/auth/config", rawptr(&graph.user_handlers), http.auth_config_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me", rawptr(&graph.user_handlers), http.me_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/logout-url", rawptr(&graph.user_handlers), http.logout_url_handler)
	http.router_add(&graph.router, "GET", "/api/v1/me/tokens", rawptr(&graph.user_handlers), http.list_my_tokens_handler)
	http.router_add(&graph.router, "POST", "/api/v1/me/tokens", rawptr(&graph.user_handlers), http.issue_my_token_handler)
	http.router_add(&graph.router, "POST", "/api/v1/me/tokens/*/revoke", rawptr(&graph.user_handlers), http.revoke_my_token_handler)
	http.router_add(&graph.router, "POST", "/api/v1/me/ws-ticket", rawptr(&graph.user_handlers), http.issue_user_ws_ticket_handler)
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/user-ws", rawptr(&graph.user_handlers), http.user_ws_upgrade_handler)
	http.router_add(&graph.router, "GET", "/api/v1/search", rawptr(&graph.search_handlers), http.search_handler)
	http.router_add(&graph.router, "GET", "/api/v1/memories", rawptr(&graph.content_handlers), http.list_memories_handler)
	http.router_add(&graph.router, "POST", "/api/v1/memories", rawptr(&graph.content_handlers), http.create_memory_handler)
	http.router_add(&graph.router, "GET", "/api/v1/memories/*", rawptr(&graph.content_handlers), http.memory_detail_handler)
	http.router_add(&graph.router, "POST", "/api/v1/memories/*/*", rawptr(&graph.content_handlers), http.memory_action_handler)
	http.router_add(&graph.router, "GET", "/api/v1/chats", rawptr(&graph.content_handlers), http.list_chats_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats", rawptr(&graph.content_handlers), http.create_chat_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/chats/*", rawptr(&graph.content_handlers), http.patch_chat_handler)
	http.router_add(&graph.router, "GET", "/api/v1/chats/*/messages", rawptr(&graph.content_handlers), http.list_chat_messages_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats/*/messages", rawptr(&graph.content_handlers), http.send_chat_message_handler)
	http.router_add(&graph.router, "POST", "/api/v1/chats/*/read", rawptr(&graph.content_handlers), http.read_chat_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts", rawptr(&graph.content_handlers), http.list_artifacts_handler)
	http.router_add(&graph.router, "POST", "/api/v1/artifacts", rawptr(&graph.content_handlers), http.create_artifact_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts/*/content", rawptr(&graph.content_handlers), http.artifact_content_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts/*/download", rawptr(&graph.content_handlers), http.artifact_download_handler)
	http.router_add(&graph.router, "GET", "/api/v1/artifacts/*", rawptr(&graph.content_handlers), http.artifact_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/artifacts/*", rawptr(&graph.content_handlers), http.patch_artifact_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/artifacts/*", rawptr(&graph.content_handlers), http.delete_artifact_handler)
	http.router_add(&graph.router, "GET", "/api/v1/templates", rawptr(&graph.content_handlers), http.list_templates_handler)
	http.router_add(&graph.router, "POST", "/api/v1/templates", rawptr(&graph.content_handlers), http.create_template_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances", rawptr(&graph.agent_handlers), http.list_agent_instances_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances", rawptr(&graph.agent_handlers), http.create_agent_instance_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agent-instances/*", rawptr(&graph.agent_handlers), http.agent_instance_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/agent-instances/*", rawptr(&graph.agent_handlers), http.patch_agent_instance_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/restart", rawptr(&graph.agent_handlers), http.restart_agent_instance_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-instances/*/stop", rawptr(&graph.agent_handlers), http.stop_agent_instance_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agents", rawptr(&graph.agent_handlers), http.list_agents_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agents", rawptr(&graph.agent_handlers), http.create_agent_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agents/*", rawptr(&graph.agent_handlers), http.agent_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/agents/*", rawptr(&graph.agent_handlers), http.update_agent_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agents/*/archive", rawptr(&graph.agent_handlers), http.archive_agent_handler)
	http.router_add(&graph.router, "GET", "/api/v1/agents/*/bridge-support", rawptr(&graph.agent_handlers), http.list_agent_support_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/agents/*/bridge-support", rawptr(&graph.agent_handlers), http.put_agent_support_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/agents/*/bridge-support/*", rawptr(&graph.agent_handlers), http.patch_agent_support_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/agents/*/bridge-support/*", rawptr(&graph.agent_handlers), http.delete_agent_support_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects", rawptr(&graph.project_handlers), http.list_projects_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects", rawptr(&graph.project_handlers), http.create_project_handler)
	http.router_add(&graph.router, "GET", "/api/v1/projects/*", rawptr(&graph.project_handlers), http.project_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/projects/*", rawptr(&graph.project_handlers), http.update_project_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/projects/*/bridge-paths/*", rawptr(&graph.project_handlers), http.put_project_bridge_path_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/projects/*/bridge-paths/*", rawptr(&graph.project_handlers), http.delete_project_bridge_path_handler)
	http.router_add(&graph.router, "POST", "/api/v1/projects/*/bridge-paths/*/validate", rawptr(&graph.project_handlers), http.validate_project_bridge_path_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains", rawptr(&graph.taskchain_handlers), http.list_task_chains_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains", rawptr(&graph.taskchain_handlers), http.create_task_chain_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*", rawptr(&graph.taskchain_handlers), http.task_chain_detail_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/publish", rawptr(&graph.taskchain_handlers), http.publish_task_chain_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/complete", rawptr(&graph.taskchain_handlers), http.complete_task_chain_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks", rawptr(&graph.taskchain_handlers), http.list_tasks_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks", rawptr(&graph.taskchain_handlers), http.create_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/publish", rawptr(&graph.taskchain_handlers), http.publish_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/status", rawptr(&graph.taskchain_handlers), http.change_task_status_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/task-chains/*", rawptr(&graph.taskchain_handlers), http.patch_task_chain_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/members", rawptr(&graph.taskchain_handlers), http.list_chain_members_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/members", rawptr(&graph.taskchain_handlers), http.add_chain_member_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/task-chains/*/members/*", rawptr(&graph.taskchain_handlers), http.remove_chain_member_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/task-chains/*/tasks/*", rawptr(&graph.taskchain_handlers), http.patch_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/cancel", rawptr(&graph.taskchain_handlers), http.cancel_task_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/comments", rawptr(&graph.taskchain_handlers), http.list_task_comments_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/comments", rawptr(&graph.taskchain_handlers), http.create_task_comment_handler)
	http.router_add(&graph.router, "GET", "/api/v1/task-chains/*/tasks/*/votes", rawptr(&graph.taskchain_handlers), http.list_task_votes_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/vote", rawptr(&graph.taskchain_handlers), http.vote_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/task-chains/*/tasks/*/nudge", rawptr(&graph.taskchain_handlers), http.nudge_task_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/send-to-user", rawptr(&graph.agent_action_handlers), http.agent_action_chat_send_to_user_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/send-to-agent", rawptr(&graph.agent_action_handlers), http.agent_action_chat_send_to_agent_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/fetch", rawptr(&graph.agent_action_handlers), http.agent_action_chat_fetch_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/chat/read", rawptr(&graph.agent_action_handlers), http.agent_action_chat_read_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/agents/live", rawptr(&graph.agent_action_handlers), http.agent_action_agents_live_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/context", rawptr(&graph.agent_action_handlers), http.agent_action_context_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/create", rawptr(&graph.agent_action_handlers), http.agent_action_task_create_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/depend", rawptr(&graph.agent_action_handlers), http.agent_action_task_depend_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/comment", rawptr(&graph.agent_action_handlers), http.agent_action_task_comment_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/status", rawptr(&graph.agent_action_handlers), http.agent_action_task_status_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/vote", rawptr(&graph.agent_action_handlers), http.agent_action_task_vote_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/tasks/nudge", rawptr(&graph.agent_action_handlers), http.agent_action_task_nudge_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/create", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_create_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/list", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_list_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/show", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_show_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/artifacts/content", rawptr(&graph.agent_action_handlers), http.agent_action_artifact_content_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/memory/propose", rawptr(&graph.agent_action_handlers), http.agent_action_memory_propose_handler)
	http.router_add(&graph.router, "POST", "/api/v1/agent-actions/start-success", rawptr(&graph.agent_action_handlers), http.agent_action_start_success_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridge-enrollments", rawptr(&graph.bridge_handlers), http.create_bridge_enrollment_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge-enrollments", rawptr(&graph.bridge_handlers), http.list_bridge_enrollments_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/bridge-enrollments/*", rawptr(&graph.bridge_handlers), http.revoke_bridge_enrollment_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/enroll", rawptr(&graph.bridge_handlers), http.enroll_bridge_handler)
	http.router_add_upgrade(&graph.router, "GET", "/api/v1/bridge-ws", rawptr(&graph.bridge_handlers), http.bridge_ws_upgrade_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridge/agent-instances/*/bootstrap", rawptr(&graph.bridge_handlers), http.bridge_instance_bootstrap_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges", rawptr(&graph.bridge_handlers), http.list_bridges_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*/providers", rawptr(&graph.bridge_handlers), http.list_bridge_providers_handler)
	http.router_add(&graph.router, "PUT", "/api/v1/bridges/*/providers/*", rawptr(&graph.bridge_handlers), http.put_bridge_provider_handler)
	http.router_add(&graph.router, "DELETE", "/api/v1/bridges/*/providers/*", rawptr(&graph.bridge_handlers), http.delete_bridge_provider_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/providers/*/test", rawptr(&graph.bridge_handlers), http.test_bridge_provider_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/provider-defaults", rawptr(&graph.bridge_handlers), http.set_bridge_provider_defaults_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/providers/refresh", rawptr(&graph.bridge_handlers), http.refresh_bridge_providers_handler)
	http.router_add(&graph.router, "GET", "/api/v1/bridges/*", rawptr(&graph.bridge_handlers), http.bridge_detail_handler)
	http.router_add(&graph.router, "PATCH", "/api/v1/bridges/*", rawptr(&graph.bridge_handlers), http.rename_bridge_handler)
	http.router_add(&graph.router, "POST", "/api/v1/bridges/*/revoke", rawptr(&graph.bridge_handlers), http.revoke_bridge_handler)
}

health_handler :: proc(ctx: rawptr, req: http.Request) -> http.Response {
	graph := (^App_Graph)(ctx)
	server_time := platform.clock_now(&graph.clock)
	return http.respond_success("{\"ok\":true,\"version\":1}", req.request_id, server_time)
}

// device_minter is the task-3 token issuer wired into approve (ELDA-4). It
// issues a user API token via the device-authorization path (no revoke, no cap,
// created_from='device_authorization') and returns the plaintext + token_id so
// the grant can hand it out on the first successful /device/token poll.
device_minter :: proc(graph_ptr: rawptr, user_id, client, device_label: string) -> (string, string, bool) {
	graph := (^App_Graph)(graph_ptr)
	token, plaintext, ok, _ := auth_service.issue_device_authorization_token(&graph.auth, domain.User_ID(user_id), device_label)
	return plaintext, token.token_id, ok
}
