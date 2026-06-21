package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:thread"
import "core:sys/posix"
import cfg_lib "odin_test:lib/config"
import mp "odin_test:lib/message_provider"
import memp "odin_test:lib/memory_provider"

server_bind_host: string
server_port: int
server_config_path: string
server_data_dir: string
server_agent_providers: [dynamic]string
server_agent_cmd_configs: [dynamic]cfg_lib.Agent_Command_Config
message_provider: mp.Message_Provider
memory_provider: memp.Memory_Provider

run_server :: proc(cfg: cfg_lib.Config, config_path: string) -> bool {
	server_bind_host = strings.clone(cfg.daemon.bind_host)
	server_port = int(cfg.daemon.port)
	server_config_path = strings.clone(config_path)
	server_data_dir = strings.clone(cfg.daemon.data_dir)
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

	listener, err := net.listen_tcp({address, int(cfg.daemon.port)})
	if err != nil {
		fmt.println("failed to listen", cfg.daemon.bind_host, cfg.daemon.port)
		return false
	}
	defer net.close(listener)
	if !socket_set_close_on_exec(listener) {
		fmt.println("warning: failed to set daemon listener close-on-exec")
	}

	registry_init()
	user_client_registry_init()
	message_provider = mp.new_memory_provider()
	memory_provider = memp.new_local_provider(server_data_dir)
	central_hub_init()
	task_store_init(server_data_dir)
	project_store_init(server_data_dir)
	agent_store_init(server_data_dir)
	chat_store_init(server_data_dir)
	router_adapter_init(cfg.daemon)
	hub_sync_init()
	message_queue_init()
	message_queue_start_worker()
	hub_sync_start_worker()
	task_nudge_scheduler_start(cfg.daemon)
	agent_startup_janitor_start(cfg.daemon)
	test_run_startup_sweep()
	fmt.println("odin-daemon listening", cfg.daemon.bind_host, cfg.daemon.port)
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		if !socket_set_close_on_exec(client) {
			fmt.println("warning: failed to set client socket close-on-exec")
		}
		thread.run_with_poly_data(client, handle_client)
	}
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

	if strings.has_prefix(request, "POST /tasks/participant ") {
		handle_task_participant(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/status ") {
		handle_task_status(client, request_body(request))
		return
	}

	if strings.has_prefix(request, "POST /tasks/review ") {
		handle_task_review(client, request_body(request))
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

	if strings.has_prefix(request, "POST /task-chains/show ") {
		handle_task_chain_show(client, request_body(request))
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

	write_response(client, 404, "Not Found", `{"ok":false,"message":"not found"}`)
}
