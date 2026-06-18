package main

import "core:fmt"
import "core:net"
import "core:strings"
import "core:thread"
import cfg_lib "odin_test:lib/config"
import mp "odin_test:lib/message_provider"

server_bind_host: string
server_port: int
server_config_path: string
server_data_dir: string
message_provider: mp.Message_Provider

run_server :: proc(cfg: cfg_lib.Config, config_path: string) -> bool {
	server_bind_host = strings.clone(cfg.daemon.bind_host)
	server_port = int(cfg.daemon.port)
	server_config_path = strings.clone(config_path)
	server_data_dir = strings.clone(cfg.daemon.data_dir)

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

	registry_init()
	user_client_registry_init()
	message_provider = mp.new_memory_provider()
	central_hub_init()
	task_store_init(server_data_dir)
	chat_store_init(server_data_dir)
	router_adapter_init(cfg.daemon)
	hub_sync_init()
	message_queue_init()
	message_queue_start_worker()
	hub_sync_start_worker()
	fmt.println("odin-daemon listening", cfg.daemon.bind_host, cfg.daemon.port)
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		thread.run_with_poly_data(client, handle_client)
	}
}

handle_client :: proc(client: net.TCP_Socket) {
	defer net.close(client)

	request, ok := read_http_request(client)
	if !ok do return
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

	if strings.has_prefix(request, "POST /agents/start ") {
		handle_agents_start(client, request_body(request))
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
