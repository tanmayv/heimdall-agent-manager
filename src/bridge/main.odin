package main

import "core:crypto/legacy/sha1"
import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import http "odin_test:lib/http_client"
import ws "odin_test:lib/ws"

Bridge_Config :: struct {
	bind_host: string,
	port: u16,
	daemon_url: string,
	daemon_id: string,
	bridge_token: string,
	peers: [dynamic]cfg_lib.Peer_Config,
	peer_auth_token: string,
	chunk_bytes: int,
}

Bridge_Peer_Link_State :: struct {
	name: string,
	daemon_id: contracts.Daemon_ID,
	endpoint: string,
	status: contracts.Bridge_Reachability_Status,
	active_sessions: int,
	has_socket: bool,
	ws_socket: net.TCP_Socket,
	last_seen_unix_ms: i64,
	last_error: string,
}

Chunk_Reassembly :: struct {
	stream_id: contracts.Bridge_Stream_ID,
	chunk_id: string,
	original_kind: string,
	idempotency_key: string,
	total_bytes: int,
	chunk_count: int,
	received_chunks: int,
	received_bytes: int,
	fragments: []string,
	created_unix_ms: i64,
}

Bridge_Pending_Response :: struct {
	stream_id: string,
	status_code: int,
	status_text: string,
	body: string,
	done: bool,
}

Bridge_Transit_Frame :: struct {
	peer_name: string,
	frame_text: string,
	created_unix_ms: i64,
}

Bridge_Chunk_Ack :: struct {
	chunk_id: string,
	chunk_index: int,
	accepted: bool,
	created_unix_ms: i64,
}

Bridge_WS_Request_Job :: struct {
	socket: net.TCP_Socket,
	text: string,
}

bridge_config: Bridge_Config
bridge_peer_states: [dynamic]Bridge_Peer_Link_State
bridge_state_mutex: sync.Mutex
bridge_ws_send_mutex: sync.Mutex
bridge_pending_responses: [dynamic]Bridge_Pending_Response
bridge_transit_queue: [dynamic]Bridge_Transit_Frame
bridge_reassemblies: [dynamic]Chunk_Reassembly
bridge_chunk_acks: [dynamic]Bridge_Chunk_Ack
bridge_sequence: i64

main :: proc() {
	if has_flag(os.args, "--version") {
		fmt.println("ham-bridge", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION, "bridge", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION, "ws", contracts.BRIDGE_WS_FRAME_VERSION)
		return
	}
	if has_flag(os.args, "--help") || has_flag(os.args, "-h") {
		print_usage()
		return
	}

	bridge_config = bridge_config_from_args(os.args)
	bridge_runtime_init()
	if bridge_config.chunk_bytes <= 0 do bridge_config.chunk_bytes = contracts.BRIDGE_WS_DEFAULT_CHUNK_BYTES
	bridge_peer_state_init(bridge_config.peers[:])
	if len(bridge_config.peers) > 0 do thread.run(bridge_dialer_worker)
	_ = run_bridge_server(bridge_config)
}

print_usage :: proc() {
	fmt.println("ham-bridge", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("usage: ham-bridge [--config <path>] [--bind-host 127.0.0.1] [--port 49323] [--daemon-url URL] [--daemon-id ID] [--bridge-token TOKEN] [--peer-ws ws://host:port/bridge-ws]... [--peer-auth-token TOKEN] [--chunk-bytes N]")
	fmt.println("loopback routes:", contracts.ROUTE_BRIDGE_HEALTH, contracts.ROUTE_BRIDGE_SEND, contracts.ROUTE_BRIDGE_REQUEST, contracts.ROUTE_BRIDGE_REACHABLE)
	fmt.println("bridge websocket route:", contracts.ROUTE_BRIDGE_WS)
}

bridge_config_from_args :: proc(args: []string) -> Bridge_Config {
	cfg := Bridge_Config{
		bind_host = "127.0.0.1",
		port = 49323,
		daemon_url = "http://127.0.0.1:49322",
		daemon_id = "local-daemon",
		bridge_token = "",
		peers = make([dynamic]cfg_lib.Peer_Config),
		peer_auth_token = "",
		chunk_bytes = contracts.BRIDGE_WS_DEFAULT_CHUNK_BYTES,
	}

	config_path := cfg_lib.config_path_from_args(args)
	if loaded, ok := cfg_lib.load(config_path); ok {
		cfg.daemon_url = loaded.config.wrapper.daemon_url
		cfg.daemon_id = loaded.config.daemon.daemon_id
		cfg.bridge_token = loaded.config.daemon.bridge_token
		for peer in loaded.config.bridge.peers {
			if strings.trim_space(peer.name) == "" || strings.trim_space(peer.endpoint) == "" || strings.trim_space(peer.token) == "" do continue
			append(&cfg.peers, cfg_lib.Peer_Config{name = strings.clone(peer.name), endpoint = strings.clone(peer.endpoint), token = strings.clone(peer.token)})
		}
	}

	cfg.bind_host = option_value(args, "--bind-host", cfg.bind_host)
	cfg.daemon_url = option_value(args, "--daemon-url", cfg.daemon_url)
	cfg.daemon_id = option_value(args, "--daemon-id", cfg.daemon_id)
	cfg.bridge_token = option_value(args, "--bridge-token", cfg.bridge_token)
	cfg.peer_auth_token = option_value(args, "--peer-auth-token", cfg.peer_auth_token)
	if port_s := option_value(args, "--port", ""); port_s != "" {
		if port_i, ok := strconv.parse_int(port_s); ok do cfg.port = u16(port_i)
	}
	if chunk_s := option_value(args, "--chunk-bytes", ""); chunk_s != "" {
		if chunk_i, ok := strconv.parse_int(chunk_s); ok do cfg.chunk_bytes = int(chunk_i)
	}
	for i in 0..<len(args) {
		if args[i] == "--peer-ws" && i + 1 < len(args) {
			append(&cfg.peers, cfg_lib.Peer_Config{name = fmt.tprintf("cli-peer-%d", len(cfg.peers) + 1), endpoint = strings.clone(args[i + 1]), token = strings.clone(cfg.peer_auth_token)})
		}
	}
	return cfg
}

bridge_runtime_init :: proc() {
	bridge_state_mutex = sync.Mutex{}
	bridge_ws_send_mutex = sync.Mutex{}
	bridge_pending_responses = make([dynamic]Bridge_Pending_Response)
	bridge_transit_queue = make([dynamic]Bridge_Transit_Frame)
	bridge_reassemblies = make([dynamic]Chunk_Reassembly)
	bridge_chunk_acks = make([dynamic]Bridge_Chunk_Ack)
	bridge_sequence = 0
}

bridge_next_id :: proc(prefix: string) -> string {
	bridge_sequence += 1
	return fmt.tprintf("%s_%d_%d", prefix, bridge_now_unix_ms(), bridge_sequence)
}

bridge_peer_state_init :: proc(peers: []cfg_lib.Peer_Config) {
	bridge_peer_states = make([dynamic]Bridge_Peer_Link_State)
	for peer in peers {
		name := strings.trim_space(peer.name)
		if name == "" do name = fmt.tprintf("peer-%d", len(bridge_peer_states) + 1)
		append(&bridge_peer_states, Bridge_Peer_Link_State{
			name = strings.clone(name),
			daemon_id = contracts.Daemon_ID(strings.clone(name)),
			endpoint = strings.clone(peer.endpoint),
			status = .Unreachable,
			last_seen_unix_ms = 0,
			last_error = "",
		})
	}
}

bridge_peer_state_set :: proc(name: string, status: contracts.Bridge_Reachability_Status, err: string) {
	for i in 0..<len(bridge_peer_states) {
		if bridge_peer_states[i].name != name do continue
		if bridge_peer_states[i].active_sessions > 0 && status == .Unreachable {
			bridge_peer_states[i].last_error = strings.clone(err)
			return
		}
		bridge_peer_states[i].status = status
		if status == .Linked do bridge_peer_states[i].last_seen_unix_ms = bridge_now_unix_ms()
		bridge_peer_states[i].last_error = strings.clone(err)
		return
	}
}

bridge_peer_state_connected :: proc(name: string, socket: net.TCP_Socket) {
	changed := false
	sync.mutex_lock(&bridge_state_mutex)
	for i in 0..<len(bridge_peer_states) {
		if bridge_peer_states[i].name != name do continue
		old_status := bridge_peer_states[i].status
		bridge_peer_states[i].active_sessions += 1
		bridge_peer_states[i].has_socket = true
		bridge_peer_states[i].ws_socket = socket
		bridge_peer_states[i].status = .Linked
		bridge_peer_states[i].last_seen_unix_ms = bridge_now_unix_ms()
		bridge_peer_states[i].last_error = ""
		changed = old_status != .Linked
		break
	}
	sync.mutex_unlock(&bridge_state_mutex)
	if changed do thread.run(bridge_reachability_push_to_daemon)
}

bridge_peer_state_disconnected :: proc(name, err: string, socket: net.TCP_Socket) {
	changed := false
	sync.mutex_lock(&bridge_state_mutex)
	for i in 0..<len(bridge_peer_states) {
		if bridge_peer_states[i].name != name do continue
		old_status := bridge_peer_states[i].status
		if bridge_peer_states[i].active_sessions > 0 do bridge_peer_states[i].active_sessions -= 1
		if bridge_peer_states[i].has_socket && bridge_peer_states[i].ws_socket == socket {
			bridge_peer_states[i].has_socket = false
		}
		if bridge_peer_states[i].active_sessions == 0 {
			bridge_peer_states[i].status = .Unreachable
			bridge_peer_states[i].last_error = strings.clone(err)
		}
		changed = old_status != bridge_peer_states[i].status
		break
	}
	sync.mutex_unlock(&bridge_state_mutex)
	if changed do thread.run(bridge_reachability_push_to_daemon)
}

bridge_peer_ws_url :: proc(endpoint: string) -> string {
	trimmed := strings.trim_space(endpoint)
	for len(trimmed) > 1 && strings.has_suffix(trimmed, "/") do trimmed = trimmed[:len(trimmed) - 1]
	if strings.has_prefix(trimmed, "ws://") || strings.has_prefix(trimmed, "wss://") {
		if strings.has_suffix(trimmed, contracts.ROUTE_BRIDGE_WS) do return strings.clone(trimmed)
		return strings.concatenate({trimmed, contracts.ROUTE_BRIDGE_WS})
	}
	if strings.has_prefix(trimmed, "http://") {
		return strings.concatenate({"ws://", trimmed[len("http://"):], contracts.ROUTE_BRIDGE_WS})
	}
	if strings.has_prefix(trimmed, "https://") {
		return strings.concatenate({"wss://", trimmed[len("https://"):], contracts.ROUTE_BRIDGE_WS})
	}
	return strings.clone(trimmed)
}

run_bridge_server :: proc(cfg: Bridge_Config) -> bool {
	address := net.IP4_Loopback
	if cfg.bind_host != "127.0.0.1" {
		if parsed, ok := net.parse_ip4_address(cfg.bind_host); ok do address = parsed
	}
	listener, err := net.listen_tcp({address, int(cfg.port)})
	if err != nil {
		fmt.println("failed to listen", cfg.bind_host, cfg.port)
		return false
	}
	defer net.close(listener)
	fmt.println("ham-bridge listening", cfg.bind_host, cfg.port, "daemon_url", cfg.daemon_url)
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		thread.run_with_poly_data(client, handle_bridge_client)
	}
}

handle_bridge_client :: proc(client: net.TCP_Socket) {
	defer net.close(client)
	request, ok := read_http_request(client)
	if !ok do return
	method, route := request_method_route(request)
	if method == "OPTIONS" {
		write_response(client, 200, "OK", `{}`)
		return
	}
	if !contracts.bridge_route_supported(.Bridge, method, route) {
		write_response(client, 404, "Not Found", bridge_unsupported_route_json(method, route))
		return
	}
	if route == contracts.ROUTE_BRIDGE_WS {
		handle_bridge_ws(client, request)
		return
	}
	if !bridge_loopback_authorized(request) {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"bridge loopback unauthorized"}`)
		return
	}
	switch route {
	case contracts.ROUTE_BRIDGE_HEALTH:
		write_response(client, 200, "OK", bridge_health_json())
	case contracts.ROUTE_BRIDGE_SEND:
		bridge_handle_send(client, request_body(request))
	case contracts.ROUTE_BRIDGE_REQUEST:
		bridge_handle_request(client, request_body(request))
	case contracts.ROUTE_BRIDGE_REACHABLE:
		write_response(client, 200, "OK", bridge_reachable_json())
	case:
		write_response(client, 404, "Not Found", bridge_unsupported_route_json(method, route))
	}
}

bridge_loopback_authorized :: proc(request: string) -> bool {
	if strings.trim_space(bridge_config.bridge_token) == "" do return true
	auth := extract_header(request, contracts.BRIDGE_LOOPBACK_AUTH_HEADER)
	return auth == strings.concatenate({contracts.BRIDGE_AUTH_BEARER_PREFIX, bridge_config.bridge_token})
}

bridge_peer_ws_authorize :: proc(request: string) -> (peer_name: string, ok: bool) {
	auth := extract_header(request, contracts.BRIDGE_WS_AUTH_HEADER)
	if strings.has_prefix(auth, contracts.BRIDGE_AUTH_BEARER_PREFIX) {
		presented := strings.trim_space(auth[len(contracts.BRIDGE_AUTH_BEARER_PREFIX):])
		if presented != "" {
			for peer in bridge_config.peers {
				if strings.trim_space(peer.token) == presented do return strings.trim_space(peer.name), true
			}
			if strings.trim_space(bridge_config.peer_auth_token) == presented do return "", true
		}
	}
	// Empty peer credentials are allowed only for local smoke/development configs.
	if strings.trim_space(bridge_config.peer_auth_token) != "" do return "", false
	for peer in bridge_config.peers {
		if strings.trim_space(peer.token) != "" do return "", false
	}
	return "", true
}

bridge_health_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"ws_frame_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"self_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","bridge_id":"ham-bridge","chunk_bytes":`)
	strings.write_string(&b, fmt.tprintf("%d", bridge_config.chunk_bytes))
	strings.write_string(&b, `,"large_payload_target_bytes":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_LARGE_PAYLOAD_TARGET_BYTES))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

bridge_send_stub_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"acceptance":"`); json_write_string(&b, contracts.bridge_send_acceptance_wire(.Rejected))
	strings.write_string(&b, `","error_code":"`); json_write_string(&b, contracts.BRIDGE_ERROR_NOT_IMPLEMENTED)
	strings.write_string(&b, `","message":"bridge send transport scaffold only; async transit queue arrives in a later task"}`)
	return strings.to_string(b)
}

bridge_request_stub_json :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"result_kind":"`); json_write_string(&b, contracts.BRIDGE_RESULT_UNSUPPORTED_SCAFFOLD)
	strings.write_string(&b, `","status_code":501,"status_text":"Not Implemented","error_code":"`); json_write_string(&b, contracts.BRIDGE_ERROR_NOT_IMPLEMENTED)
	strings.write_string(&b, `","message":"bridge request transport scaffold only"}`)
	return strings.to_string(b)
}

bridge_peer_name_for_daemon :: proc(dest_daemon_id: string) -> string {
	trimmed := strings.trim_space(dest_daemon_id)
	for state in bridge_peer_states {
		if string(state.daemon_id) == trimmed || state.name == trimmed do return state.name
	}
	return trimmed
}

bridge_send_accepted_json :: proc(idempotency_key: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"acceptance":"`); json_write_string(&b, contracts.bridge_send_acceptance_wire(.Accepted_Queued))
	strings.write_string(&b, `","bridge_message_id":"`); json_write_string(&b, bridge_next_id("bridge_msg"))
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","message":"accepted by bridge transport"}`)
	return strings.to_string(b)
}

bridge_send_backpressure_json :: proc(idempotency_key, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"acceptance":"`); json_write_string(&b, contracts.bridge_send_acceptance_wire(.Backpressure))
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","error_code":"backpressure","message":"`); json_write_string(&b, message)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

bridge_send_unreachable_json :: proc(idempotency_key: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"acceptance":"`); json_write_string(&b, contracts.bridge_send_acceptance_wire(.Destination_Unreachable))
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","error_code":"unreachable","message":"peer websocket unavailable"}`)
	return strings.to_string(b)
}

bridge_request_transport_error_json :: proc(status_code: int, status_text, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"result_kind":"`); json_write_string(&b, contracts.BRIDGE_RESULT_TRANSPORT_ERROR)
	strings.write_string(&b, `","status_code":`); strings.write_string(&b, fmt.tprintf("%d", status_code))
	strings.write_string(&b, `,"status_text":"`); json_write_string(&b, status_text)
	strings.write_string(&b, `","error_code":"transport_error","message":"`); json_write_string(&b, message)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

bridge_request_response_json :: proc(resp: Bridge_Pending_Response) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"result_kind":"`); json_write_string(&b, contracts.BRIDGE_RESULT_DESTINATION_DAEMON_HTTP_RESPONSE)
	strings.write_string(&b, `","status_code":`); strings.write_string(&b, fmt.tprintf("%d", resp.status_code))
	strings.write_string(&b, `,"status_text":"`); json_write_string(&b, resp.status_text)
	strings.write_string(&b, `","body":"`); json_write_string(&b, resp.body)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

bridge_ws_push_json :: proc(dest, route_kind, idempotency_key, payload: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"version":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"kind":"`); json_write_string(&b, contracts.BRIDGE_WS_FRAME_KIND_PUSH)
	strings.write_string(&b, `","frame_id":"`); json_write_string(&b, bridge_next_id("frame"))
	strings.write_string(&b, `","stream_id":"`); json_write_string(&b, bridge_next_id("push"))
	strings.write_string(&b, `","src_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","dest_daemon_id":"`); json_write_string(&b, dest)
	strings.write_string(&b, `","route_kind":"`); json_write_string(&b, route_kind)
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","payload":"`); json_write_string(&b, payload)
	strings.write_string(&b, `","ttl":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_DEFAULT_ENVELOPE_TTL))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

bridge_ws_request_json :: proc(stream_id, dest, method, path, idempotency_key, body: string, timeout_ms: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"version":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"kind":"`); json_write_string(&b, contracts.BRIDGE_WS_FRAME_KIND_REQUEST)
	strings.write_string(&b, `","frame_id":"`); json_write_string(&b, bridge_next_id("frame"))
	strings.write_string(&b, `","stream_id":"`); json_write_string(&b, stream_id)
	strings.write_string(&b, `","src_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","dest_daemon_id":"`); json_write_string(&b, dest)
	strings.write_string(&b, `","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","method":"`); json_write_string(&b, method)
	strings.write_string(&b, `","path":"`); json_write_string(&b, path)
	strings.write_string(&b, `","body":"`); json_write_string(&b, body)
	strings.write_string(&b, `","timeout_ms":`); strings.write_string(&b, fmt.tprintf("%d", timeout_ms))
	strings.write_string(&b, `,"ttl":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_DEFAULT_ENVELOPE_TTL))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

bridge_handle_send :: proc(client: net.TCP_Socket, body: string) {
	dest := extract_json_string(body, "dest_daemon_id", extract_json_string(body, "dest_daemon", ""))
	route_kind := extract_json_string(body, "route_kind", extract_json_string(body, "kind", contracts.BRIDGE_SEND_ROUTE_FEDERATION_INBOX))
	idempotency_key := extract_json_string(body, "idempotency_key", "")
	payload := extract_json_string(body, "payload", "")
	peer_name := bridge_peer_name_for_daemon(dest)
	if !bridge_peer_known(peer_name) {
		write_response(client, 503, "Service Unavailable", bridge_send_unreachable_json(idempotency_key))
		return
	}
	frame := bridge_ws_push_json(dest, route_kind, idempotency_key, payload)
	if accepted, reason := bridge_peer_send_or_queue(peer_name, frame); accepted {
		write_response(client, 202, "Accepted", bridge_send_accepted_json(idempotency_key))
		return
	} else if reason == "backpressure" {
		write_response(client, 429, "Too Many Requests", bridge_send_backpressure_json(idempotency_key, "bridge transit queue full"))
		return
	}
	write_response(client, 503, "Service Unavailable", bridge_send_unreachable_json(idempotency_key))
}

bridge_handle_request :: proc(client: net.TCP_Socket, body: string) {
	dest := extract_json_string(body, "dest_daemon_id", extract_json_string(body, "dest_daemon", ""))
	method := extract_json_string(body, "method", contracts.BRIDGE_HTTP_METHOD_GET)
	path := extract_json_string(body, "path", "")
	idempotency_key := extract_json_string(body, "idempotency_key", "")
	request_body_value := extract_json_string(body, "body", "")
	timeout_ms := extract_json_int(body, "timeout_ms", contracts.BRIDGE_DEFAULT_REQUEST_TIMEOUT_MS)
	if timeout_ms <= 0 do timeout_ms = contracts.BRIDGE_DEFAULT_REQUEST_TIMEOUT_MS
	peer_name := bridge_peer_name_for_daemon(dest)
	if !bridge_peer_known(peer_name) {
		write_response(client, 503, "Service Unavailable", bridge_request_transport_error_json(503, "Service Unavailable", "peer not configured"))
		return
	}
	stream_id := bridge_next_id("stream")
	bridge_pending_response_add(stream_id)
	frame := bridge_ws_request_json(stream_id, dest, method, path, idempotency_key, request_body_value, timeout_ms)
	if !bridge_peer_send_text(peer_name, frame) {
		bridge_pending_response_remove(stream_id)
		write_response(client, 503, "Service Unavailable", bridge_request_transport_error_json(503, "Service Unavailable", "peer websocket unavailable"))
		return
	}
	if resp, ok := bridge_pending_response_wait(stream_id, timeout_ms); ok {
		write_response(client, resp.status_code, resp.status_text, bridge_request_response_json(resp))
		return
	}
	write_response(client, 504, "Gateway Timeout", bridge_request_transport_error_json(504, "Gateway Timeout", "bridge request timed out"))
}

bridge_peer_known :: proc(peer_name: string) -> bool {
	sync.mutex_lock(&bridge_state_mutex)
	defer sync.mutex_unlock(&bridge_state_mutex)
	for state in bridge_peer_states {
		if state.name == peer_name do return true
	}
	return false
}

bridge_peer_send_text :: proc(peer_name, frame_text: string) -> bool {
	sync.mutex_lock(&bridge_state_mutex)
	socket: net.TCP_Socket
	found := false
	for state in bridge_peer_states {
		if state.name == peer_name && state.has_socket && state.status == .Linked {
			socket = state.ws_socket
			found = true
			break
		}
	}
	sync.mutex_unlock(&bridge_state_mutex)
	if !found do return false
	return bridge_ws_send_frame(socket, frame_text)
}

bridge_transit_queue_bytes_locked :: proc() -> int {
	total := 0
	for item in bridge_transit_queue do total += len(item.frame_text)
	return total
}

bridge_transit_queue_prune_locked :: proc() {
	now := bridge_now_unix_ms()
	for i := len(bridge_transit_queue) - 1; i >= 0; i -= 1 {
		if now - bridge_transit_queue[i].created_unix_ms > i64(contracts.BRIDGE_WS_TRANSIT_QUEUE_TTL_MS) {
			ordered_remove(&bridge_transit_queue, i)
		}
	}
}

bridge_transit_queue_can_accept_locked :: proc(frame_text: string) -> bool {
	bridge_transit_queue_prune_locked()
	if len(bridge_transit_queue) >= contracts.BRIDGE_WS_MAX_TRANSIT_QUEUE_FRAMES do return false
	if bridge_transit_queue_bytes_locked() + len(frame_text) > contracts.BRIDGE_WS_MAX_TRANSIT_QUEUE_BYTES do return false
	return true
}

bridge_peer_send_or_queue :: proc(peer_name, frame_text: string) -> (bool, string) {
	if !bridge_peer_known(peer_name) do return false, "unknown"
	if bridge_peer_send_text(peer_name, frame_text) do return true, "sent"
	sync.mutex_lock(&bridge_state_mutex)
	defer sync.mutex_unlock(&bridge_state_mutex)
	if !bridge_transit_queue_can_accept_locked(frame_text) do return false, "backpressure"
	append(&bridge_transit_queue, Bridge_Transit_Frame{peer_name = strings.clone(peer_name), frame_text = strings.clone(frame_text), created_unix_ms = bridge_now_unix_ms()})
	return true, "queued"
}

bridge_flush_transit_queue :: proc(peer_name: string) {
	for {
		frame := ""
		idx := -1
		sync.mutex_lock(&bridge_state_mutex)
		for item, i in bridge_transit_queue {
			if item.peer_name == peer_name {
				idx = i
				frame = strings.clone(item.frame_text)
				break
			}
		}
		if idx >= 0 {
			ordered_remove(&bridge_transit_queue, idx)
		}
		sync.mutex_unlock(&bridge_state_mutex)
		if idx < 0 do return
		if !bridge_peer_send_text(peer_name, frame) {
			sync.mutex_lock(&bridge_state_mutex)
			if bridge_transit_queue_can_accept_locked(frame) {
				append(&bridge_transit_queue, Bridge_Transit_Frame{peer_name = strings.clone(peer_name), frame_text = strings.clone(frame), created_unix_ms = bridge_now_unix_ms()})
			}
			sync.mutex_unlock(&bridge_state_mutex)
			return
		}
	}
}

bridge_pending_response_add :: proc(stream_id: string) {
	sync.mutex_lock(&bridge_state_mutex)
	append(&bridge_pending_responses, Bridge_Pending_Response{stream_id = strings.clone(stream_id)})
	sync.mutex_unlock(&bridge_state_mutex)
}

bridge_pending_response_store :: proc(stream_id: string, status_code: int, status_text, body: string) {
	sync.mutex_lock(&bridge_state_mutex)
	defer sync.mutex_unlock(&bridge_state_mutex)
	for i in 0..<len(bridge_pending_responses) {
		if bridge_pending_responses[i].stream_id != stream_id do continue
		bridge_pending_responses[i].status_code = status_code
		bridge_pending_responses[i].status_text = strings.clone(status_text)
		bridge_pending_responses[i].body = strings.clone(body)
		bridge_pending_responses[i].done = true
		return
	}
}

bridge_pending_response_wait :: proc(stream_id: string, timeout_ms: int) -> (Bridge_Pending_Response, bool) {
	start := bridge_now_unix_ms()
	for bridge_now_unix_ms() - start < i64(timeout_ms) {
		sync.mutex_lock(&bridge_state_mutex)
		for i in 0..<len(bridge_pending_responses) {
			if bridge_pending_responses[i].stream_id == stream_id && bridge_pending_responses[i].done {
				resp := bridge_pending_responses[i]
				ordered_remove(&bridge_pending_responses, i)
				sync.mutex_unlock(&bridge_state_mutex)
				return resp, true
			}
		}
		sync.mutex_unlock(&bridge_state_mutex)
		time.sleep(10 * time.Millisecond)
	}
	bridge_pending_response_remove(stream_id)
	return Bridge_Pending_Response{}, false
}

bridge_pending_response_remove :: proc(stream_id: string) {
	sync.mutex_lock(&bridge_state_mutex)
	defer sync.mutex_unlock(&bridge_state_mutex)
	for i in 0..<len(bridge_pending_responses) {
		if bridge_pending_responses[i].stream_id == stream_id {
			ordered_remove(&bridge_pending_responses, i)
			return
		}
	}
}

bridge_reachable_json :: proc() -> string {
	return bridge_reachable_json_with_change(false)
}

bridge_reachability_update_json :: proc() -> string {
	return bridge_reachable_json_with_change(true)
}

bridge_reachable_json_with_change :: proc(include_changed: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"contract_version":`)
	strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_LOOPBACK_CONTRACT_VERSION))
	strings.write_string(&b, `,"self_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","reachable":[`)
	sync.mutex_lock(&bridge_state_mutex)
	for state, i in bridge_peer_states {
		if i > 0 do strings.write_string(&b, `,`)
		strings.write_string(&b, `{"daemon_id":"`); json_write_string(&b, string(state.daemon_id))
		strings.write_string(&b, `","reach":"direct","next_hop_daemon_id":"`); json_write_string(&b, string(state.daemon_id))
		strings.write_string(&b, `","hops":1,"status":"`); json_write_string(&b, bridge_reachability_status_wire(state.status))
		strings.write_string(&b, `","via":[],"last_seen_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", state.last_seen_unix_ms))
		strings.write_string(&b, `}`)
	}
	sync.mutex_unlock(&bridge_state_mutex)
	strings.write_string(&b, `]`)
	if include_changed {
		strings.write_string(&b, `,"changed_unix_ms":`)
		strings.write_string(&b, fmt.tprintf("%d", bridge_now_unix_ms()))
	}
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

bridge_reachability_push_to_daemon :: proc() {
	if strings.trim_space(bridge_config.daemon_url) == "" do return
	_, _ = http.request_with_headers_timeout(contracts.BRIDGE_HTTP_METHOD_POST, bridge_config.daemon_url, contracts.ROUTE_FEDERATION_REACHABILITY, bridge_reachability_update_json(), bridge_daemon_headers(bridge_config.daemon_id), contracts.BRIDGE_DEFAULT_REQUEST_TIMEOUT_MS)
}

bridge_reachability_status_wire :: proc(status: contracts.Bridge_Reachability_Status) -> string {
	switch status {
	case .Linked:
		return contracts.BRIDGE_REACHABILITY_STATUS_LINKED
	case .Unreachable:
		return contracts.BRIDGE_REACHABILITY_STATUS_UNREACHABLE
	}
	return contracts.BRIDGE_REACHABILITY_STATUS_UNREACHABLE
}

bridge_unsupported_route_json :: proc(method, route: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":false,"error_code":"`)
	json_write_string(&b, contracts.BRIDGE_ERROR_UNSUPPORTED_ROUTE)
	strings.write_string(&b, `","message":"unsupported bridge route","method":"`)
	json_write_string(&b, method)
	strings.write_string(&b, `","route":"`)
	json_write_string(&b, route)
	strings.write_string(&b, `"}`)
	return strings.to_string(b)
}

handle_bridge_ws :: proc(client: net.TCP_Socket, request: string) {
	peer_name, auth_ok := bridge_peer_ws_authorize(request)
	if !auth_ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"bridge websocket unauthorized"}`)
		return
	}
	key := extract_header(request, "Sec-WebSocket-Key")
	if key == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"missing websocket key"}`)
		return
	}
	write_ws_upgrade(client, ws_accept_key(key))
	if peer_name != "" {
		bridge_peer_state_connected(peer_name, client)
		bridge_flush_transit_queue(peer_name)
	}
	fmt.println("bridge ws accepted", peer_name)
	bridge_ws_read_loop(client)
	if peer_name != "" do bridge_peer_state_disconnected(peer_name, "accepted_ws_disconnected", client)
}

bridge_ws_read_loop :: proc(client: net.TCP_Socket) {
	buf: [131072]byte
	pending := make([dynamic]byte)
	_ = net.set_option(client, .Receive_Timeout, 1 * time.Second)
	last_rx_ms := bridge_now_unix_ms()
	last_keepalive_ms := bridge_now_unix_ms()
	for {
		n, err := net.recv_tcp(client, buf[:])
		if err != nil {
			if err == .Would_Block {
				now := bridge_now_unix_ms()
				if now - last_keepalive_ms >= i64(contracts.BRIDGE_WS_HEARTBEAT_INTERVAL_MS) {
					_ = write_ws_text(client, bridge_ws_keepalive_json())
					last_keepalive_ms = now
				}
				if now - last_rx_ms > i64(contracts.BRIDGE_WS_HEARTBEAT_TIMEOUT_MS) {
					fmt.println("bridge ws heartbeat timeout")
					return
				}
				continue
			}
			fmt.println("bridge ws disconnected")
			return
		}
		if n == 0 {
			fmt.println("bridge ws disconnected")
			return
		}
		last_rx_ms = bridge_now_unix_ms()
		append(&pending, ..buf[:n])
		pos := 0
		for pos + 2 <= len(pending) {
			opcode := pending[pos] & 0x0f
			masked := (pending[pos + 1] & 0x80) != 0
			payload_len := int(pending[pos + 1] & 0x7f)
			offset := pos + 2
			if payload_len == 126 {
				if pos + 4 > len(pending) do break
				payload_len = int(pending[pos + 2]) << 8 | int(pending[pos + 3])
				offset = pos + 4
			} else if payload_len == 127 {
				_ = write_ws_text(client, bridge_ws_error_json("", contracts.BRIDGE_WS_ERROR_MALFORMED_FRAME, "large unchunked websocket frame header not accepted", true))
				return
			}
			mask_key: [4]byte
			if masked {
				if len(pending) < offset + 4 do break
				mask_key = {pending[offset], pending[offset+1], pending[offset+2], pending[offset+3]}
				offset += 4
			}
			frame_end := offset + payload_len
			if frame_end > len(pending) do break
			if opcode == 0x8 do return
			if opcode == 0x1 && payload_len > 0 {
				payload := make([]byte, payload_len)
				copy(payload, pending[offset:frame_end])
				if masked {
					for i in 0..<payload_len {
						payload[i] = payload[i] ~ mask_key[i % 4]
					}
				}
				bridge_ws_handle_text(client, string(payload))
			}
			pos = frame_end
		}
		if pos > 0 {
			remaining := make([dynamic]byte)
			if pos < len(pending) do append(&remaining, ..pending[pos:])
			pending = remaining
		}
	}
}

bridge_ws_handle_text :: proc(client: net.TCP_Socket, text: string) {
	version := extract_json_int(text, "version", contracts.BRIDGE_WS_FRAME_VERSION)
	stream_id := extract_json_string(text, "stream_id", "")
	if !contracts.bridge_ws_frame_version_supported(version) {
		_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_UNSUPPORTED_VERSION, contracts.BRIDGE_WS_UNSUPPORTED_VERSION_POLICY, true))
		return
	}
	kind := extract_json_string(text, "kind", "")
	if !contracts.bridge_ws_frame_supported(.Bridge, kind) {
		_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_UNKNOWN_KIND, contracts.BRIDGE_WS_UNKNOWN_KIND_POLICY, false))
		return
	}
	if kind == contracts.BRIDGE_WS_FRAME_KIND_CHUNK {
		bridge_ws_handle_chunk_skeleton(client, text)
		return
	}
	if kind == contracts.BRIDGE_WS_FRAME_KIND_KEEPALIVE {
		_ = write_ws_text(client, bridge_ws_keepalive_json())
		return
	}
	if kind == contracts.BRIDGE_WS_FRAME_KIND_RESPONSE {
		bridge_ws_handle_response(text)
		return
	}
	if kind == contracts.BRIDGE_WS_FRAME_KIND_PUSH {
		bridge_ws_handle_push(client, text)
		return
	}
	if kind == contracts.BRIDGE_WS_FRAME_KIND_REQUEST {
		thread.run_with_poly_data(Bridge_WS_Request_Job{socket = client, text = strings.clone(text)}, bridge_ws_request_worker)
		return
	}
	if kind == contracts.BRIDGE_WS_FRAME_KIND_CHUNK_ACK {
		bridge_ws_handle_chunk_ack(text)
		return
	}
	_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_SCAFFOLD_ONLY, "bridge websocket frame not implemented", false))
}

bridge_ws_handle_chunk_ack :: proc(text: string) {
	chunk_id := extract_json_string(text, "chunk_id", "")
	chunk_index := extract_json_int(text, "chunk_index", -1)
	if chunk_id == "" || chunk_index < 0 do return
	sync.mutex_lock(&bridge_state_mutex)
	accepted := strings.contains(text, `"accepted":true`)
	append(&bridge_chunk_acks, Bridge_Chunk_Ack{chunk_id = strings.clone(chunk_id), chunk_index = chunk_index, accepted = accepted, created_unix_ms = bridge_now_unix_ms()})
	if len(bridge_chunk_acks) > contracts.BRIDGE_WS_MAX_TRANSIT_QUEUE_FRAMES {
		ordered_remove(&bridge_chunk_acks, 0)
	}
	sync.mutex_unlock(&bridge_state_mutex)
}

bridge_ws_handle_response :: proc(text: string) {
	response_class := extract_json_string(text, "response_class", "")
	if response_class == contracts.BRIDGE_WS_RESPONSE_CLASS_DESTINATION_ACK || response_class == contracts.BRIDGE_WS_RESPONSE_CLASS_TRANSPORT_ACCEPT {
		bridge_ws_handle_delivery_ack(text)
		return
	}
	stream_id := extract_json_string(text, "stream_id", "")
	status_code := extract_json_int(text, "status_code", 502)
	status_text := extract_json_string(text, "status_text", "Bad Gateway")
	body := extract_json_string(text, "body", "")
	bridge_pending_response_store(stream_id, status_code, status_text, body)
}

bridge_ws_handle_delivery_ack :: proc(text: string) {
	body := extract_json_string(text, "body", "")
	if body == "" do return
	_, ok := http.request_with_headers_timeout(contracts.BRIDGE_HTTP_METHOD_POST, bridge_config.daemon_url, contracts.ROUTE_FEDERATION_CALLBACK, body, bridge_daemon_headers(extract_json_string(text, "src_daemon_id", "")), contracts.BRIDGE_DEFAULT_REQUEST_TIMEOUT_MS)
	_ = ok
}

bridge_ws_handle_push :: proc(client: net.TCP_Socket, text: string) {
	route_kind := extract_json_string(text, "route_kind", contracts.BRIDGE_SEND_ROUTE_FEDERATION_INBOX)
	payload := extract_json_string(text, "payload", "")
	path := contracts.ROUTE_FEDERATION_INBOX
	if route_kind == contracts.BRIDGE_SEND_ROUTE_FEDERATION_CALLBACK do path = contracts.ROUTE_FEDERATION_CALLBACK
	resp, ok := http.request_with_headers_timeout(contracts.BRIDGE_HTTP_METHOD_POST, bridge_config.daemon_url, path, payload, bridge_daemon_headers(extract_json_string(text, "src_daemon_id", "")), contracts.BRIDGE_DEFAULT_REQUEST_TIMEOUT_MS)
	stream_id := extract_json_string(text, "stream_id", "")
	if !ok || resp.status < 200 || resp.status >= 300 {
		_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_DESTINATION_DAEMON, "local daemon push delivery failed", false))
		return
	}
	_ = bridge_ws_send_frame(client, bridge_ws_delivery_ack_json(stream_id, route_kind, extract_json_string(text, "idempotency_key", "")))
}

bridge_ws_request_worker :: proc(job: Bridge_WS_Request_Job) {
	bridge_ws_handle_request_frame(job.socket, job.text)
}

bridge_ws_handle_request_frame :: proc(client: net.TCP_Socket, text: string) {
	stream_id := extract_json_string(text, "stream_id", "")
	method := extract_json_string(text, "method", contracts.BRIDGE_HTTP_METHOD_GET)
	path := extract_json_string(text, "path", "")
	body := extract_json_string(text, "body", "")
	timeout_ms := extract_json_int(text, "timeout_ms", contracts.BRIDGE_DEFAULT_REQUEST_TIMEOUT_MS)
	resp, ok := http.request_with_headers_timeout(method, bridge_config.daemon_url, path, body, bridge_daemon_headers(extract_json_string(text, "src_daemon_id", "")), timeout_ms)
	if !ok {
		_ = bridge_ws_send_frame(client, bridge_ws_response_json(stream_id, 502, "Bad Gateway", `{"ok":false,"message":"local daemon unavailable"}`))
		return
	}
	_ = bridge_ws_send_frame(client, bridge_ws_response_json(stream_id, resp.status, bridge_status_text(resp.status), resp.body))
}

bridge_daemon_headers :: proc(src_daemon_id: string) -> []http.Header {
	headers := make([dynamic]http.Header)
	if strings.trim_space(bridge_config.bridge_token) != "" {
		append(&headers, http.Header{name = contracts.BRIDGE_LOOPBACK_AUTH_HEADER, value = strings.concatenate({contracts.BRIDGE_AUTH_BEARER_PREFIX, bridge_config.bridge_token})})
	}
	if strings.trim_space(src_daemon_id) != "" {
		append(&headers, http.Header{name = contracts.BRIDGE_SOURCE_DAEMON_HEADER, value = src_daemon_id})
	}
	return headers[:]
}

bridge_ws_delivery_ack_json :: proc(stream_id, route_kind, idempotency_key: string) -> string {
	ack_route_kind := "inbox"
	if route_kind == contracts.BRIDGE_SEND_ROUTE_FEDERATION_CALLBACK do ack_route_kind = "callback"
	ack_id := fmt.tprintf("delivery_ack:%s", idempotency_key)
	ack_body_b := strings.builder_make()
	strings.write_string(&ack_body_b, `{"kind":"delivery_ack","idempotency_key":"`); json_write_string(&ack_body_b, ack_id)
	strings.write_string(&ack_body_b, `","ack_route_kind":"`); json_write_string(&ack_body_b, ack_route_kind)
	strings.write_string(&ack_body_b, `","ack_idempotency_key":"`); json_write_string(&ack_body_b, idempotency_key)
	strings.write_string(&ack_body_b, `"}`)
	ack_body := strings.to_string(ack_body_b)
	b := strings.builder_make()
	strings.write_string(&b, `{"version":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"kind":"`); json_write_string(&b, contracts.BRIDGE_WS_FRAME_KIND_RESPONSE)
	strings.write_string(&b, `","frame_id":"`); json_write_string(&b, bridge_next_id("frame"))
	strings.write_string(&b, `","stream_id":"`); json_write_string(&b, stream_id)
	strings.write_string(&b, `","src_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","dest_daemon_id":"","idempotency_key":"`); json_write_string(&b, idempotency_key)
	strings.write_string(&b, `","response_class":"`); json_write_string(&b, contracts.BRIDGE_WS_RESPONSE_CLASS_DESTINATION_ACK)
	strings.write_string(&b, `","status_code":200,"status_text":"OK","body":"`); json_write_string(&b, ack_body)
	strings.write_string(&b, `","end_stream":true}`)
	return strings.to_string(b)
}

bridge_ws_response_json :: proc(stream_id: string, status_code: int, status_text, body: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"version":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"kind":"`); json_write_string(&b, contracts.BRIDGE_WS_FRAME_KIND_RESPONSE)
	strings.write_string(&b, `","frame_id":"`); json_write_string(&b, bridge_next_id("frame"))
	strings.write_string(&b, `","stream_id":"`); json_write_string(&b, stream_id)
	strings.write_string(&b, `","src_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","dest_daemon_id":"","idempotency_key":"","response_class":"`); json_write_string(&b, contracts.BRIDGE_WS_RESPONSE_CLASS_DAEMON_HTTP)
	strings.write_string(&b, `","status_code":`); strings.write_string(&b, fmt.tprintf("%d", status_code))
	strings.write_string(&b, `,"status_text":"`); json_write_string(&b, status_text)
	strings.write_string(&b, `","body":"`); json_write_string(&b, body)
	strings.write_string(&b, `","end_stream":true}`)
	return strings.to_string(b)
}

bridge_status_text :: proc(status_code: int) -> string {
	switch status_code {
	case 200, 201, 202:
		return "OK"
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 500:
		return "Internal Server Error"
	case 501:
		return "Not Implemented"
	case 502:
		return "Bad Gateway"
	case 503:
		return "Service Unavailable"
	case 504:
		return "Gateway Timeout"
	}
	return "OK"
}

bridge_ws_handle_chunk_skeleton :: proc(client: net.TCP_Socket, text: string) {
	stream_id := extract_json_string(text, "stream_id", "")
	chunk_id := extract_json_string(text, "chunk_id", "")
	chunk_index := extract_json_int(text, "chunk_index", -1)
	chunk_count := extract_json_int(text, "chunk_count", 0)
	total_bytes := extract_json_int(text, "total_bytes", 0)
	fragment_b64 := extract_json_string(text, "payload_fragment", "")
	if chunk_id == "" || chunk_index < 0 || chunk_count <= 0 || chunk_index >= chunk_count || total_bytes <= 0 || fragment_b64 == "" {
		_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_MALFORMED_FRAME, "invalid chunk metadata", false))
		return
	}
	if chunk_count > contracts.BRIDGE_WS_MAX_CHUNK_COUNT || chunk_count > total_bytes {
		_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_MALFORMED_FRAME, "impossible chunk metadata", false))
		return
	}
	if total_bytes > contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES {
		_ = write_ws_text(client, bridge_ws_error_json(stream_id, "backpressure", "chunk reassembly byte limit exceeded", true))
		return
	}
	decoded, err := base64.decode(fragment_b64)
	if err != nil || len(decoded) == 0 {
		_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_MALFORMED_FRAME, "invalid chunk payload", false))
		return
	}
	decoded_text := string(decoded)
	if len(decoded_text) > total_bytes {
		_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_MALFORMED_FRAME, "chunk exceeds declared total bytes", false))
		return
	}
	completed := ""
	sync.mutex_lock(&bridge_state_mutex)
	idx := -1
	for item, i in bridge_reassemblies {
		if item.chunk_id == chunk_id {
			idx = i
			break
		}
	}
	if idx < 0 {
		if len(bridge_reassemblies) >= contracts.BRIDGE_WS_MAX_REASSEMBLIES {
			sync.mutex_unlock(&bridge_state_mutex)
			_ = write_ws_text(client, bridge_ws_error_json(stream_id, "backpressure", "too many active chunk reassemblies", false))
			return
		}
		append(&bridge_reassemblies, Chunk_Reassembly{
			stream_id = contracts.Bridge_Stream_ID(strings.clone(stream_id)),
			chunk_id = strings.clone(chunk_id),
			original_kind = strings.clone(extract_json_string(text, "original_kind", "")),
			idempotency_key = strings.clone(extract_json_string(text, "idempotency_key", "")),
			total_bytes = total_bytes,
			chunk_count = chunk_count,
			received_chunks = 0,
			received_bytes = 0,
			fragments = make([]string, chunk_count),
			created_unix_ms = bridge_now_unix_ms(),
		})
		idx = len(bridge_reassemblies) - 1
	}
	if bridge_reassemblies[idx].chunk_count != chunk_count || bridge_reassemblies[idx].total_bytes != total_bytes {
		sync.mutex_unlock(&bridge_state_mutex)
		_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_MALFORMED_FRAME, "conflicting chunk metadata", false))
		return
	}
	if bridge_reassemblies[idx].fragments[chunk_index] == "" {
		if bridge_reassemblies[idx].received_bytes + len(decoded_text) > bridge_reassemblies[idx].total_bytes {
			sync.mutex_unlock(&bridge_state_mutex)
			_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_MALFORMED_FRAME, "chunks exceed declared total bytes", false))
			return
		}
		bridge_reassemblies[idx].fragments[chunk_index] = strings.clone(decoded_text)
		bridge_reassemblies[idx].received_chunks += 1
		bridge_reassemblies[idx].received_bytes += len(decoded_text)
	}
	if bridge_reassemblies[idx].received_chunks == bridge_reassemblies[idx].chunk_count {
		if bridge_reassemblies[idx].received_bytes != bridge_reassemblies[idx].total_bytes {
			sync.mutex_unlock(&bridge_state_mutex)
			_ = write_ws_text(client, bridge_ws_error_json(stream_id, contracts.BRIDGE_WS_ERROR_MALFORMED_FRAME, "chunk total byte mismatch", false))
			return
		}
		b := strings.builder_make()
		for frag in bridge_reassemblies[idx].fragments {
			strings.write_string(&b, frag)
		}
		completed = strings.to_string(b)
		ordered_remove(&bridge_reassemblies, idx)
	}
	sync.mutex_unlock(&bridge_state_mutex)
	_ = write_ws_text(client, bridge_ws_chunk_ack_json(stream_id, chunk_id, chunk_index, chunk_count))
	if completed != "" {
		bridge_ws_handle_text(client, completed)
	}
}

bridge_ws_keepalive_json :: proc() -> string {
	now := bridge_now_unix_ms()
	b := strings.builder_make()
	strings.write_string(&b, `{"version":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"kind":"`); json_write_string(&b, contracts.BRIDGE_WS_FRAME_KIND_KEEPALIVE)
	strings.write_string(&b, `","frame_id":"bridge-keepalive","stream_id":"","src_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","sent_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", now))
	strings.write_string(&b, `,"observed_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", now))
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

bridge_ws_error_json :: proc(stream_id, code, message: string, terminal: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"version":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"kind":"`); json_write_string(&b, contracts.BRIDGE_WS_FRAME_KIND_ERROR)
	strings.write_string(&b, `","frame_id":"bridge-error","stream_id":"`); json_write_string(&b, stream_id)
	strings.write_string(&b, `","src_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","dest_daemon_id":"","error_code":"`); json_write_string(&b, code)
	strings.write_string(&b, `","message":"`); json_write_string(&b, message)
	strings.write_string(&b, `","terminal":`); strings.write_string(&b, "true" if terminal else "false")
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

bridge_ws_chunk_ack_json :: proc(stream_id, chunk_id: string, chunk_index, chunk_count: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"version":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"kind":"`); json_write_string(&b, contracts.BRIDGE_WS_FRAME_KIND_CHUNK_ACK)
	strings.write_string(&b, `","frame_id":"bridge-chunk-ack","stream_id":"`); json_write_string(&b, stream_id)
	strings.write_string(&b, `","src_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","dest_daemon_id":"","chunk_id":"`); json_write_string(&b, chunk_id)
	strings.write_string(&b, `","chunk_index":`); strings.write_string(&b, fmt.tprintf("%d", chunk_index))
	strings.write_string(&b, `,"chunk_count":`); strings.write_string(&b, fmt.tprintf("%d", chunk_count))
	strings.write_string(&b, `,"accepted":true}`)
	return strings.to_string(b)
}

bridge_dialer_worker :: proc() {
	backoff_ms := contracts.BRIDGE_WS_RECONNECT_BACKOFF_MIN_MS
	for {
		for peer in bridge_config.peers {
			peer_name := strings.trim_space(peer.name)
			peer_url := bridge_peer_ws_url(peer.endpoint)
			peer_token := strings.trim_space(peer.token)
			if peer_token == "" do peer_token = strings.trim_space(bridge_config.peer_auth_token)
			fmt.println("bridge ws dial begin", peer_name, peer_url)
			conn, ok := ws.connect_with_bearer(peer_url, peer_token)
			if !ok {
				bridge_peer_state_set(peer_name, .Unreachable, "dial_failed")
				fmt.println("bridge ws dial failed", peer_name, "backoff_ms", backoff_ms)
				continue
			}
			bridge_peer_state_connected(peer_name, conn.socket)
			bridge_flush_transit_queue(peer_name)
			fmt.println("bridge ws linked", peer_name)
			backoff_ms = contracts.BRIDGE_WS_RECONNECT_BACKOFF_MIN_MS
			last_keepalive_ms := bridge_now_unix_ms() - i64(contracts.BRIDGE_WS_HEARTBEAT_INTERVAL_MS)
			last_rx_ms := bridge_now_unix_ms()
			for conn.connected {
				now := bridge_now_unix_ms()
				if now - last_keepalive_ms >= i64(contracts.BRIDGE_WS_HEARTBEAT_INTERVAL_MS) {
					_ = write_ws_text(conn.socket, bridge_ws_keepalive_json())
					last_keepalive_ms = now
				}
				for {
					if text, got := ws.poll_text(&conn); got {
						last_rx_ms = bridge_now_unix_ms()
						bridge_ws_handle_text(conn.socket, text)
						continue
					}
					break
				}
				if bridge_now_unix_ms() - last_rx_ms > i64(contracts.BRIDGE_WS_HEARTBEAT_TIMEOUT_MS) {
					fmt.println("bridge ws heartbeat timeout", peer_name)
					conn.connected = false
					break
				}
				time.sleep(10 * time.Millisecond)
			}
			ws.close(&conn)
			bridge_peer_state_disconnected(peer_name, "dialed_ws_disconnected", conn.socket)
			fmt.println("bridge ws unlinked", peer_name)
		}
		jitter_ms := int(bridge_now_unix_ms() % i64(contracts.BRIDGE_WS_RECONNECT_JITTER_MS))
		time.sleep(time.Duration(backoff_ms + jitter_ms) * time.Millisecond)
		backoff_ms *= 2
		if backoff_ms > contracts.BRIDGE_WS_RECONNECT_BACKOFF_MAX_MS do backoff_ms = contracts.BRIDGE_WS_RECONNECT_BACKOFF_MAX_MS
	}
}

bridge_payload_needs_chunking :: proc(payload: []byte) -> bool {
	return len(payload) > bridge_config.chunk_bytes
}

bridge_ws_chunk_count :: proc(total_bytes, chunk_bytes: int) -> int {
	if total_bytes <= 0 do return 0
	effective_chunk_bytes := chunk_bytes
	if effective_chunk_bytes <= 0 do effective_chunk_bytes = contracts.BRIDGE_WS_DEFAULT_CHUNK_BYTES
	return (total_bytes + effective_chunk_bytes - 1) / effective_chunk_bytes
}

read_http_request :: proc(client: net.TCP_Socket) -> (string, bool) {
	buf: [4096]byte
	n, recv_err := net.recv_tcp(client, buf[:])
	if recv_err != nil || n <= 0 do return "", false
	request := strings.clone(string(buf[:n]))
	for !http_request_complete(request) {
		m, err := net.recv_tcp(client, buf[:])
		if err != nil || m <= 0 do break
		request = strings.concatenate({request, string(buf[:m])})
	}
	return request, true
}

http_request_complete :: proc(request: string) -> bool {
	head_end := strings.index(request, "\r\n\r\n")
	if head_end < 0 do return false
	content_length := request_content_length(request)
	if content_length <= 0 do return true
	body_len := len(request) - (head_end + 4)
	return body_len >= content_length
}

request_body :: proc(request: string) -> string {
	if idx := strings.index(request, "\r\n\r\n"); idx >= 0 do return request[idx + 4:]
	return ""
}

request_content_length :: proc(request: string) -> int {
	value := extract_header(request, "Content-Length")
	if value == "" do value = extract_header(request, "content-length")
	if value == "" do return 0
	if parsed, ok := strconv.parse_int(value); ok do return int(parsed)
	return 0
}

extract_header :: proc(request, name: string) -> string {
	pattern := fmt.tprintf("%s:", name)
	idx := strings.index(request, pattern)
	if idx < 0 do return ""
	start := idx + len(pattern)
	end := strings.index(request[start:], "\r\n")
	if end < 0 do return ""
	return strings.trim_space(request[start:start + end])
}

bridge_tcp_send_all :: proc(client: net.TCP_Socket, data: []byte) -> bool {
	sent_total := 0
	for sent_total < len(data) {
		sent, err := net.send_tcp(client, data[sent_total:])
		if err != nil || sent <= 0 do return false
		sent_total += sent
	}
	return true
}

write_response :: proc(client: net.TCP_Socket, status: int, status_text, body: string) {
	builder := strings.builder_make()
	strings.write_string(&builder, fmt.tprintf("HTTP/1.1 %d %s\r\n", status, status_text))
	strings.write_string(&builder, "Content-Type: application/json\r\n")
	strings.write_string(&builder, fmt.tprintf("Content-Length: %d\r\n", len(body)))
	strings.write_string(&builder, "Access-Control-Allow-Origin: *\r\n")
	strings.write_string(&builder, "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n")
	strings.write_string(&builder, "Access-Control-Allow-Headers: Content-Type, Authorization\r\n")
	strings.write_string(&builder, "Connection: close\r\n\r\n")
	header_bytes := transmute([]byte)strings.to_string(builder)
	if !bridge_tcp_send_all(client, header_bytes) do return
	if len(body) > 0 do _ = bridge_tcp_send_all(client, transmute([]byte)body)
}

write_ws_upgrade :: proc(client: net.TCP_Socket, accept_key: string) {
	response := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept_key)
	net.send_tcp(client, transmute([]byte)response)
}

ws_accept_key :: proc(key: string) -> string {
	GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	combined := fmt.tprintf("%s%s", key, GUID)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)combined)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:])
}

bridge_chunk_ack_seen :: proc(chunk_id: string, chunk_index: int) -> bool {
	sync.mutex_lock(&bridge_state_mutex)
	defer sync.mutex_unlock(&bridge_state_mutex)
	for ack, i in bridge_chunk_acks {
		if ack.chunk_id == chunk_id && ack.chunk_index == chunk_index && ack.accepted {
			ordered_remove(&bridge_chunk_acks, i)
			return true
		}
	}
	return false
}

bridge_wait_for_chunk_ack :: proc(chunk_id: string, chunk_index: int, timeout_ms: int) -> bool {
	start := bridge_now_unix_ms()
	for bridge_now_unix_ms() - start < i64(timeout_ms) {
		if bridge_chunk_ack_seen(chunk_id, chunk_index) do return true
		time.sleep(25 * time.Millisecond)
	}
	return false
}

bridge_ws_send_frame :: proc(socket: net.TCP_Socket, frame_text: string) -> bool {
	max_payload := bridge_config.chunk_bytes
	// Keep chunk wrapper frames below the simple WS reader/writer's 4 KiB frame
	// buffer while still supporting arbitrarily large opaque loopback bodies.
	if max_payload <= 0 || max_payload > contracts.BRIDGE_WS_MAX_CHUNK_PAYLOAD_BYTES do max_payload = contracts.BRIDGE_WS_MAX_CHUNK_PAYLOAD_BYTES
	if len(frame_text) <= max_payload do return write_ws_text(socket, frame_text)
	chunk_count := bridge_ws_chunk_count(len(frame_text), max_payload)
	chunk_id := bridge_next_id("chunk")
	for i := 0; i < chunk_count; i += 1 {
		start := i * max_payload
		end := start + max_payload
		if end > len(frame_text) do end = len(frame_text)
		fragment := base64.encode(transmute([]byte)frame_text[start:end])
		chunk_frame := bridge_ws_chunk_json(chunk_id, i, chunk_count, len(frame_text), fragment)
		acked := false
		for attempt := 0; attempt < contracts.BRIDGE_WS_CHUNK_MAX_SEND_ATTEMPTS; attempt += 1 {
			if write_ws_text(socket, chunk_frame) {
				if bridge_wait_for_chunk_ack(chunk_id, i, contracts.BRIDGE_WS_CHUNK_ACK_TIMEOUT_MS) {
					acked = true
					break
				}
			} else {
				time.sleep(50 * time.Millisecond)
			}
		}
		if !acked do return false
	}
	return true
}

bridge_ws_chunk_json :: proc(chunk_id: string, chunk_index, chunk_count, total_bytes: int, fragment: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"version":`); strings.write_string(&b, fmt.tprintf("%d", contracts.BRIDGE_WS_FRAME_VERSION))
	strings.write_string(&b, `,"kind":"`); json_write_string(&b, contracts.BRIDGE_WS_FRAME_KIND_CHUNK)
	strings.write_string(&b, `","frame_id":"`); json_write_string(&b, bridge_next_id("frame"))
	strings.write_string(&b, `","stream_id":"`); json_write_string(&b, chunk_id)
	strings.write_string(&b, `","src_daemon_id":"`); json_write_string(&b, bridge_config.daemon_id)
	strings.write_string(&b, `","dest_daemon_id":"","original_kind":"frame","idempotency_key":"","chunk_id":"`); json_write_string(&b, chunk_id)
	strings.write_string(&b, `","chunk_index":`); strings.write_string(&b, fmt.tprintf("%d", chunk_index))
	strings.write_string(&b, `,"chunk_count":`); strings.write_string(&b, fmt.tprintf("%d", chunk_count))
	strings.write_string(&b, `,"total_bytes":`); strings.write_string(&b, fmt.tprintf("%d", total_bytes))
	strings.write_string(&b, `,"payload_fragment":"`); json_write_string(&b, fragment)
	strings.write_string(&b, `","end_stream":`); strings.write_string(&b, "true" if chunk_index + 1 == chunk_count else "false")
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

write_ws_text :: proc(socket: net.TCP_Socket, text: string) -> bool {
	if len(text) > 65535 do return false
	sync.mutex_lock(&bridge_ws_send_mutex)
	defer sync.mutex_unlock(&bridge_ws_send_mutex)
	header_len := 2
	if len(text) > 125 do header_len = 4
	frame := make([]byte, header_len + len(text))
	frame[0] = 0x81
	if len(text) <= 125 {
		frame[1] = byte(len(text))
	} else {
		frame[1] = 126
		frame[2] = byte((len(text) >> 8) & 0xff)
		frame[3] = byte(len(text) & 0xff)
	}
	copy(frame[header_len:], transmute([]byte)text)
	return bridge_tcp_send_all(socket, frame)
}

json_write_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(builder, "\\\\")
		case '"': strings.write_string(builder, "\\\"")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case:
			if ch < 32 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", ch))
			} else {
				strings.write_rune(builder, ch)
			}
		}
	}
}

extract_json_string :: proc(body, key, fallback: string) -> string {
	pattern := fmt.tprintf("\"%s\":\"", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	end := start
	escaped := false
	for end < len(body) {
		ch := body[end]
		if escaped {
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else if ch == '"' {
			return json_unescape(body[start:end])
		}
		end += 1
	}
	return fallback
}

json_unescape :: proc(value: string) -> string {
	builder := strings.builder_make()
	i := 0
	for i < len(value) {
		ch := value[i]
		if ch == '\\' {
			if i + 1 < len(value) {
				next_ch := value[i + 1]
				switch next_ch {
				case 'n': strings.write_byte(&builder, '\n')
				case 'r': strings.write_byte(&builder, '\r')
				case 't': strings.write_byte(&builder, '\t')
				case '"': strings.write_byte(&builder, '"')
				case '\\': strings.write_byte(&builder, '\\')
				case 'u':
					if i + 5 < len(value) {
						hex_str := value[i + 2 : i + 6]
						val, ok := strconv.parse_int(hex_str, 16)
						if ok {
							strings.write_rune(&builder, rune(val))
							i += 6
							continue
						}
					}
					strings.write_byte(&builder, 'u')
				case:
					strings.write_byte(&builder, next_ch)
				}
				i += 2
			} else {
				strings.write_byte(&builder, '\\')
				i += 1
			}
		} else {
			strings.write_byte(&builder, ch)
			i += 1
		}
	}
	return strings.to_string(builder)
}

extract_json_int :: proc(body, key: string, fallback: int) -> int {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	for start < len(body) && (body[start] == ' ' || body[start] == '\n' || body[start] == '\r' || body[start] == '\t') do start += 1
	end := start
	for end < len(body) && ((body[end] >= '0' && body[end] <= '9') || body[end] == '-') do end += 1
	if end <= start do return fallback
	if parsed, ok := strconv.parse_int(body[start:end]); ok do return int(parsed)
	return fallback
}

option_value :: proc(args: []string, name, fallback: string) -> string {
	for i in 0..<len(args) {
		if args[i] == name && i + 1 < len(args) do return args[i + 1]
	}
	return fallback
}

request_method_route :: proc(request: string) -> (method: string, route: string) {
	first_space := strings.index_byte(request, ' ')
	if first_space < 0 do return "", ""
	method = request[:first_space]
	path_start := first_space + 1
	path_end_rel := strings.index_byte(request[path_start:], ' ')
	if path_end_rel < 0 do return method, ""
	path := request[path_start:path_start + path_end_rel]
	if q := strings.index_byte(path, '?'); q >= 0 do path = path[:q]
	return method, path
}

has_flag :: proc(args: []string, flag: string) -> bool {
	for arg in args {
		if arg == flag do return true
	}
	return false
}

bridge_now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}
