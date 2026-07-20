package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:thread"
import "core:time"
import "core:sys/posix"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import mp "odin_test:lib/message_provider"

server_bind_host: string
server_port: int
server_config_path: string
server_data_dir: string
server_daemon_id: string
server_wrapper_bin: string
server_bridge_url: string
server_bridge_token_configured: bool
server_agent_providers: [dynamic]string
server_agent_cmd_configs: [dynamic]cfg_lib.Agent_Command_Config
message_provider: mp.Message_Provider
server_config: cfg_lib.Config

run_server :: proc(cfg: cfg_lib.Config, config_path: string) -> bool {
	server_config = cfg
	server_bind_host = strings.clone(cfg.daemon.bind_host)
	server_port = int(cfg.daemon.port)
	server_config_path = strings.clone(config_path)
	expanded_data_dir := expand_home(cfg.daemon.data_dir)
	server_data_dir = strings.clone(expanded_data_dir)
	server_daemon_id = strings.clone(cfg.daemon.daemon_id)
	if server_daemon_id == "" do server_daemon_id = "local-daemon"
	server_wrapper_bin = strings.clone(cfg.daemon.wrapper_bin)
	server_bridge_url = strings.clone(cfg.daemon.bridge_url)
	server_bridge_token_configured = strings.trim_space(cfg.daemon.bridge_token) != ""
	if strings.trim_space(server_bridge_url) == "" {
		fmt.println("federation bridge disabled: no daemon.bridge_url configured; running local-only")
	} else {
		fmt.println("federation bridge configured", server_bridge_url)
	}
	server_agent_providers = make([dynamic]string)
	server_agent_cmd_configs = make([dynamic]cfg_lib.Agent_Command_Config)
	for provider in cfg.wrapper.agent_commands {
		if provider.name != "" {
			append(&server_agent_providers, strings.clone(provider.name))
			append(&server_agent_cmd_configs, provider)
		}
	}
	if len(server_agent_providers) == 0 && cfg.wrapper.default_agent != "" do append(&server_agent_providers, strings.clone(cfg.wrapper.default_agent))
	if len(server_agent_providers) == 0 && cfg.wrapper.agent_name != "" do append(&server_agent_providers, strings.clone(cfg.wrapper.agent_name))

	address := net.IP4_Loopback
	if cfg.daemon.bind_host != "127.0.0.1" {
		if parsed, ok := net.parse_ip4_address(cfg.daemon.bind_host); ok {
			address = parsed
		}
	}

	// Initialize all subsystems BEFORE binding the listen socket so the kernel
	// can't accept SYNs that we'd then ignore for tens of seconds while stores
	// replay events on cold start.
	init_t0 := time.tick_now()
	time_step :: proc(name: string, prev: ^time.Tick) {
		now := time.tick_now()
		dt_ms := time.duration_milliseconds(time.tick_diff(prev^, now))
		fmt.printf("init %s %.1fms\n", name, dt_ms)
		prev^ = now
	}
	step := init_t0
	registry_init(); time_step("registry_init", &step)
	agent_runtime_tracker_init(); time_step("agent_runtime_tracker_init", &step)
	user_client_registry_init(); time_step("user_client_registry_init", &step)
	message_provider = mp.new_memory_provider(); time_step("message_provider", &step)
	if !memory_db_init(server_data_dir) {
		fmt.println("WARNING: memory_db_init failed, memories will not persist across daemon restarts")
	}
	time_step("memory_db_init", &step)
	central_hub_init(); time_step("central_hub_init", &step)
	task_store_init(server_data_dir)
	task_store_recover_stuck_system_chains()
	time_step("task_store_init", &step)
	project_store_init(server_data_dir); time_step("project_store_init", &step)
	agent_store_init(server_data_dir); time_step("agent_store_init", &step)
	peer_link_store_init(server_data_dir); time_step("peer_link_store_init", &step)
	chat_store_init(server_data_dir); time_step("chat_store_init", &step)
	if !vcs_db_init(server_data_dir) { fmt.println("WARNING: vcs_db_init failed, workspaces will not persist") }
	time_step("vcs_db_init", &step)
	if !artifact_db_init(server_data_dir) {
		fmt.println("WARNING: artifact_db_init failed, artifact metadata will not persist")
	}
	time_step("artifact_db_init", &step)
	if !artifact_storage_init(server_data_dir, cfg.daemon.artifact_blob_dir) {
		fmt.println("WARNING: artifact_storage_init failed, artifact blobs may be unavailable")
	}
	time_step("artifact_storage_init", &step)
	if !auth_db_init(server_data_dir) {
		fmt.println("WARNING: auth_db_init failed, tokens will not persist across daemon restarts")
	}
	time_step("auth_db_init", &step)

	if !user_pref_db_init(server_data_dir) {
		fmt.println("WARNING: user_pref_db_init failed, preferences will not persist across daemon restarts")
	}
	time_step("user_pref_db_init", &step)

	if !audit_db_init(server_data_dir) {
		fmt.println("WARNING: audit_db_init failed, cognitive audits will not persist across daemon restarts")
	}
	time_step("audit_db_init", &step)
	router_adapter_init(cfg.daemon); time_step("router_adapter_init", &step)
	_ = task_runtime_reconcile_all_active("startup_replay", "normal"); time_step("task_runtime_reconcile_all_active", &step)
	hub_sync_init(); time_step("hub_sync_init", &step)
	message_queue_init(); time_step("message_queue_init", &step)
	message_queue_start_worker(); time_step("message_queue_start_worker", &step)
	hub_sync_start_worker(); time_step("hub_sync_start_worker", &step)
	task_nudge_scheduler_start(cfg.daemon); time_step("task_nudge_scheduler_start", &step)
	agent_startup_janitor_start(cfg.daemon); time_step("agent_startup_janitor_start", &step)
	test_run_startup_sweep(); time_step("test_run_startup_sweep", &step)
	backup_scheduler_start(); time_step("backup_scheduler_start", &step)
	total_ms := time.duration_milliseconds(time.tick_diff(init_t0, time.tick_now()))
	fmt.printf("init TOTAL %.1fms\n", total_ms)

	listener, err := net.listen_tcp({address, int(cfg.daemon.port)})
	if err != nil {
		fmt.println("failed to listen", cfg.daemon.bind_host, cfg.daemon.port)
		return false
	}
	defer net.close(listener)
	if !socket_set_close_on_exec(listener) {
		fmt.println("warning: failed to set daemon listener close-on-exec")
	}
	fmt.println("odin-daemon listening", cfg.daemon.bind_host, cfg.daemon.port)
	_ = guide_service_start(cfg.guide_agent, "daemon_startup")
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		if !socket_set_close_on_exec(client) {
			fmt.println("warning: failed to set client socket close-on-exec")
		}
		thread.run_with_poly_data(client, handle_client)
	}
}

daemon_info_json :: proc() -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"daemon_id":"`)
	json_write_string(&builder, server_daemon_id)
	strings.write_string(&builder, `","version":"`)
	json_write_string(&builder, contracts.APP_VERSION)
	strings.write_string(&builder, `","protocol_version":`)
	strings.write_string(&builder, fmt.tprintf("%d", contracts.PROTOCOL_VERSION))
	strings.write_string(&builder, `}`)
	return strings.to_string(builder)
}

http_method_target :: proc(request: string) -> (string, string) {
	line_end := strings.index(request, "\r\n")
	if line_end < 0 do return "", ""
	line := request[:line_end]
	parts := strings.split(line, " ")
	defer delete(parts)
	if len(parts) < 2 do return "", ""
	return parts[0], parts[1]
}

path_without_query :: proc(target: string) -> string {
	if idx := strings.index_byte(target, '?'); idx >= 0 do return target[:idx]
	return target
}

query_value :: proc(target, name: string) -> string {
	if idx := strings.index_byte(target, '?'); idx >= 0 do return query_param_value(target[idx + 1:], name)
	return ""
}

socket_set_close_on_exec :: proc(socket: net.TCP_Socket) -> bool {
	flags := posix.fcntl(posix.FD(socket), .GETFD, 0)
	if flags < 0 do return false
	return posix.fcntl(posix.FD(socket), .SETFD, flags | posix.FD_CLOEXEC) != -1
}

handle_client :: proc(client: net.TCP_Socket) {
	defer net.close(client)

	request, ok := read_http_request(client)
	if !ok do return
	if strings.has_prefix(request, "OPTIONS ") {
		write_response(client, 200, "OK", `{}`)
		return
	}

	ctx := parse_route_context(request)
	defer route_context_free(&ctx)

	telemetry: Request_Telemetry
	telemetry.method = ctx.method
	telemetry.path = ctx.path
	telemetry.start_tick = time.tick_now()

	if ctx.method == "POST" || ctx.method == "PUT" || ctx.method == "PATCH" {
		telemetry.params = request_body(request)
	} else {
		telemetry.params = ctx.query
	}

	current_telemetry = &telemetry
	defer current_telemetry = nil

	if handle_rest_route(client, request, &ctx) {
		return
	}

	if strings.has_prefix(request, "GET /daemon/info ") {
		write_response(client, 200, "OK", daemon_info_json())
		return
	}

	if strings.has_prefix(request, "GET /health ") {
		write_response(client, 200, "OK", `{"ok":true,"protocol_version":1}`)
		return
	}

	if strings.has_prefix(request, "GET /ws/") {
		handle_ws(client, request)
		return
	}

	if strings.has_prefix(request, "GET /user-ws/") {
		handle_user_ws(client, request)
		return
	}

	if strings.has_prefix(request, "POST /register ") {
		handle_register(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /heartbeat ") {
		handle_heartbeat(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /startup ") {
		handle_startup_report(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /user-client/register ") {
		handle_user_client_register(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /user-client/heartbeat ") {
		handle_user_client_heartbeat(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /users/presence ") {
		handle_user_presence(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /user-rpc ") {
		handle_user_rpc(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agent-rpc ") {
		handle_agent_rpc(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /chat/") || strings.has_prefix(request, "GET /chat/") {
		if handle_chat_request(client, request) do return
	}

	if strings.has_prefix(request, "GET /agents/templates ") {
		handle_agents_templates(client)
		return
	}

	if strings.has_prefix(request, "POST /agents/templates/create ") || strings.has_prefix(request, "POST /agents/templates/update ") {
		handle_agent_template_create_update(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/templates/show ") {
		handle_agent_template_show(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/templates/archive ") || strings.has_prefix(request, "POST /agents/templates/delete ") {
		handle_agent_template_archive(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "GET /agents/providers ") || strings.has_prefix(request, "POST /agents/providers ") {
		handle_agents_providers(client)
		return
	}

	if strings.has_prefix(request, "GET /agents ") || strings.has_prefix(request, "GET /agents?") {
		handle_agents_list(client, request)
		return
	}

	if strings.has_prefix(request, "POST /agents/test-connectivity ") {
		handle_agents_test_connectivity(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/associate ") {
		handle_agents_associate(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/disassociate ") {
		handle_agents_disassociate(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/create ") {
		handle_agent_instance_create(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/show ") {
		handle_agent_instance_show(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/update ") {
		handle_agent_instance_update(client, request_body(request))
		return
	}

	// Durable identity create/edit (agent_id defaults), no concrete instance required.
	if strings.has_prefix(request, "POST /agent-ids/create ") {
		handle_agent_id_create(client, request_body(request))
		return
	}
	if strings.has_prefix(request, "POST /agent-ids/update ") {
		handle_agent_id_update(client, request_body(request))
		return
	}
	if strings.has_prefix(request, "POST /agent-ids/delete ") || strings.has_prefix(request, "POST /agent-ids/archive ") {
		handle_agent_id_delete(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/archive ") || strings.has_prefix(request, "POST /agents/delete ") || strings.has_prefix(request, "POST /agents/remove ") {
		handle_agent_instance_archive(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/start ") {
		handle_agents_start(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/stop-done ") {
		handle_agents_stop_done(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /agents/stop ") {
		handle_agents_stop(client, request_body(request), request)
		return
	}

	if strings.has_prefix(request, "POST /agents/test-launch ") {
		handle_agents_test_launch(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "GET /agents/test-status") {
		handle_agents_test_status(client, request)
		return
	}

	if strings.has_prefix(request, "GET /agents/test-history") {
		handle_agents_test_history(client)
		return
	}

	if strings.has_prefix(request, "POST /router/envelope ") {
		handle_router_envelope_ingress(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /hub/append ") {
		handle_hub_append(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /hub/poll ") {
		handle_hub_poll(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /hub/ack ") {
		handle_hub_ack(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /hub/presence ") {
		handle_hub_presence(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /memory/propose/new ") {
		handle_memory_propose(client, request_body(request), "new")
		return
	}

	if strings.has_prefix(request, "POST /memory/propose/edit ") {
		handle_memory_propose(client, request_body(request), "edit")
		return
	}

	if strings.has_prefix(request, "POST /memory/propose/archive ") {
		handle_memory_propose(client, request_body(request), "archive")
		return
	}

	if strings.has_prefix(request, "POST /memory/propose/rollback ") {
		handle_memory_propose(client, request_body(request), "rollback")
		return
	}

	if strings.has_prefix(request, "POST /memory/decide ") {
		handle_memory_decide(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /memory/list ") {
		handle_memory_list(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /memory/applicable ") {
		handle_memory_applicable(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /memory/show ") {
		handle_memory_show(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /memory/history ") {
		handle_memory_history(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /projects/create ") {
		handle_project_create(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /projects/update ") {
		handle_project_update(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /projects/delete ") {
		handle_project_delete(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /projects/list ") {
		handle_project_list(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /projects/show ") {
		handle_project_show(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/create ") {
		handle_task_create(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/comment ") {
		handle_task_comment(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/assign ") {
		handle_task_assign(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/participant/remove ") {
		handle_task_participant_remove(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/participant ") {
		handle_task_participant(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/status ") {
		handle_task_status(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/update ") {
		handle_task_update(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/delete ") {
		handle_task_delete(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/done ") {
		handle_task_done(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/blocked ") {
		handle_task_blocked(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/later ") {
		handle_task_later(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/vote ") {
		handle_task_review_vote(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/comment-resolve ") {
		handle_task_comment_resolve(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/comments ") {
		handle_task_comments(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/nudge ") {
		handle_task_nudge(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/list ") {
		handle_task_list_authed(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/next ") {
		handle_task_next(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/show ") {
		handle_task_show(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/log ") {
		handle_task_log(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /task-chains/create ") {
		handle_task_chain_create(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /task-chains/retry-archives ") {
		handle_task_archive_retry(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /task-chains/update ") {
		handle_task_chain_update(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /task-chains/status ") {
		handle_task_chain_status(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /task-chains/complete ") {
		handle_task_chain_complete(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /task-chains/evaluate ") {
		handle_task_chain_evaluate(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /task-chains/activate ") {
		handle_task_chain_activate(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /task-chains/show ") {
		handle_task_chain_show(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /workspace/show ") { handle_workspace_show(client, request_body(request)); return }
	if strings.has_prefix(request, "POST /workspace/diff ") { handle_workspace_diff(client, request_body(request)); return }
	if strings.has_prefix(request, "POST /workspace/refresh ") { handle_workspace_refresh(client, request_body(request)); return }
	if strings.has_prefix(request, "POST /workspace/pull-base ") { handle_workspace_pull_base(client, request_body(request)); return }
	if strings.has_prefix(request, "POST /workspace/merge-preview ") { handle_workspace_merge_preview(client, request_body(request)); return }
	if strings.has_prefix(request, "POST /workspace/merge ") { handle_workspace_merge(client, request_body(request)); return }
	if strings.has_prefix(request, "POST /workspace/archive ") { handle_workspace_archive(client, request_body(request)); return }

	if strings.has_prefix(request, "POST /backup/trigger ") {
		handle_backup_trigger(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /backups/list ") {
		handle_backup_list(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /backup/restore ") {
		handle_backup_restore(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "GET /tasks ") {
		handle_task_list(client)
		return
	}

	if strings.has_prefix(request, "GET /clients ") {
		write_response(client, 200, "OK", registry_list_json())
		return
	}

	if strings.has_prefix(request, "GET /attention ") || strings.has_prefix(request, "GET /attention?") {
		handle_attention(client, request)
		return
	}

	if handle_workspace_request(client, request) do return

	write_response(client, 404, "Not Found", `{"ok":false,"message":"not found"}`)
}
