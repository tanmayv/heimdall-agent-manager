package main

import "core:c"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import http "odin_test:lib/http_client"

Bridge_Local_Endpoint_Config :: struct {
	// Primary v1 transport is unix:${run_dir}/bridge.sock. The current portable
	// implementation exposes the same JSONL contract over loopback TCP as the
	// fallback while keeping the endpoint descriptor/permission invariant explicit
	// for wrapper launch materialization.
	unix_socket_path: string,
	loopback_host: string,
	loopback_port: u16,
}

Bridge_Local_Relay_Result :: struct {
	status: int,
	body: string,
	ok: bool,
}

Bridge_Wrapper_Push_Conn_Kind :: enum { TCP, Unix }
Bridge_Wrapper_Push_Conn :: struct { agent_instance_id: string, kind: Bridge_Wrapper_Push_Conn_Kind, tcp: net.TCP_Socket, unix: posix.FD }
bridge_wrapper_push_mutex: sync.Mutex
bridge_wrapper_push_conns: [dynamic]Bridge_Wrapper_Push_Conn

bridge_local_endpoint_config_default :: proc(run_dir: string, loopback_port: u16) -> Bridge_Local_Endpoint_Config {
	return Bridge_Local_Endpoint_Config{
		unix_socket_path = strings.concatenate({strings.trim_right(run_dir, "/"), "/bridge.sock"}),
		loopback_host = "127.0.0.1",
		loopback_port = loopback_port,
	}
}

bridge_local_endpoint_env_value :: proc(config: Bridge_Local_Endpoint_Config, prefer_unix := true) -> string {
	if prefer_unix && strings.trim_space(config.unix_socket_path) != "" do return strings.concatenate({"unix:", config.unix_socket_path})
	return fmt.tprintf("tcp:%s:%d", config.loopback_host, config.loopback_port)
}

bridge_local_endpoint_prepare_unix_socket_path :: proc(config: Bridge_Local_Endpoint_Config) -> bool {
	// Unix socket file mode invariant: 0600 owner-only before wrapper/agent env handoff.
	if strings.trim_space(config.unix_socket_path) == "" do return false
	if slash := strings.last_index_byte(config.unix_socket_path, '/'); slash > 0 { _ = os.make_directory_all(config.unix_socket_path[:slash]) }
	return true
}

bridge_local_endpoint_start_unix :: proc(config: Bridge_Local_Endpoint_Config) -> bool {
	if !bridge_local_endpoint_prepare_unix_socket_path(config) do return false
	path := strings.trim_space(config.unix_socket_path)
	if len(path) + 1 > len(posix.sockaddr_un{}.sun_path) do return false
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	success := false
	defer if !success { _ = posix.close(fd) }
	_ = posix.unlink(cstring(raw_data(path)))
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD || ODIN_OS == .Haiku {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK do return false
	_ = posix.chmod(cstring(raw_data(path)), posix.mode_t{.IRUSR, .IWUSR}) // 0600 owner-only local Bridge socket
	if posix.listen(fd, 16) != .OK do return false
	thread.run_with_poly_data(fd, bridge_local_endpoint_accept_unix_loop)
	success = true
	return true
}

bridge_local_endpoint_start_loopback :: proc(config: Bridge_Local_Endpoint_Config) -> bool {
	address := net.IP4_Loopback
	listener, err := net.listen_tcp({address, int(config.loopback_port)})
	if err != nil do return false
	thread.run_with_poly_data(listener, bridge_local_endpoint_accept_loop)
	return true
}

bridge_local_endpoint_accept_unix_loop :: proc(listener: posix.FD) {
	for {
		client := posix.accept(listener, nil, nil)
		if client < 0 do continue
		thread.run_with_poly_data(client, bridge_local_endpoint_unix_client_thread)
	}
}

bridge_local_endpoint_unix_client_thread :: proc(client: posix.FD) {
	registered_instance := ""
	defer {
		if registered_instance != "" do bridge_wrapper_push_drop(registered_instance)
		posix.close(client)
	}
	buf: [8192]byte
	pending := ""
	for {
		n := posix.recv(client, raw_data(buf[:]), c.size_t(len(buf)), {})
		if n <= 0 do return
		pending = strings.concatenate({pending, string(buf[:int(n)])})
		for {
			idx := strings.index_byte(pending, '\n')
			if idx < 0 do break
			line := strings.trim_space(pending[:idx])
			pending = pending[idx + 1:]
			if line == "" do continue
			if inst, sub_ok := bridge_local_subscribe_instance(line); sub_ok { registered_instance = inst; bridge_wrapper_push_register_unix(inst, client) }
			resp := bridge_local_endpoint_handle_jsonl_line(line)
			resp_line := strings.concatenate({resp, "\n"})
			bytes := transmute([]byte)resp_line
			_ = posix.send(client, raw_data(bytes), c.size_t(len(bytes)), {})
		}
	}
}

bridge_local_endpoint_accept_loop :: proc(listener: net.TCP_Socket) {
	for {
		client, _, err := net.accept_tcp(listener)
		if err != nil do continue
		thread.run_with_poly_data(client, bridge_local_endpoint_client_thread)
	}
}

bridge_local_endpoint_client_thread :: proc(client: net.TCP_Socket) {
	registered_instance := ""
	defer {
		if registered_instance != "" do bridge_wrapper_push_drop(registered_instance)
		net.close(client)
	}
	buf: [8192]byte
	pending := ""
	for {
		n, err := net.recv_tcp(client, buf[:])
		if err != nil || n <= 0 do return
		pending = strings.concatenate({pending, string(buf[:n])})
		for {
			idx := strings.index_byte(pending, '\n')
			if idx < 0 do break
			line := strings.trim_space(pending[:idx])
			pending = pending[idx + 1:]
			if line == "" do continue
			if inst, sub_ok := bridge_local_subscribe_instance(line); sub_ok { registered_instance = inst; bridge_wrapper_push_register_tcp(inst, client) }
			resp := bridge_local_endpoint_handle_jsonl_line(line)
			resp_line := strings.concatenate({resp, "\n"})
			_, _ = net.send_tcp(client, transmute([]byte)resp_line)
		}
	}
}

bridge_local_endpoint_handle_jsonl_line :: proc(line: string) -> string {
	request_id := bridge_local_extract_json_string(line, "id", "")
	if bridge_local_extract_json_int(line, "v", 0) != 1 do return bridge_local_response_error(request_id, "bad_version", "local endpoint protocol version must be 1")
	token := bridge_local_extract_json_string(line, "token", "")
	method := bridge_local_extract_json_string(line, "method", "")
	params := bridge_local_extract_json_object(line, "params")
	if bridge_local_spoofable_params(params) do return bridge_local_response_error(request_id, "forbidden", "local callers cannot spoof owner, sender, instance, or Hub credentials")
	rec, ok := bridge_agent_token_verify(token)
	if !ok do return bridge_local_response_error(request_id, "unauthenticated", "local agent token is invalid or rotated")
	if !bridge_local_method_allowed(method, rec.role) do return bridge_local_response_error(request_id, "forbidden", "method is not allowed for this local token role")
	if strings.has_prefix(method, "wrapper.") do return bridge_local_handle_wrapper_method(request_id, method, params, rec)
	if strings.has_prefix(method, "agent.") do return bridge_local_handle_agent_method(request_id, method, params, rec)
	return bridge_local_response_error(request_id, "forbidden", "method is not allowlisted")
}

bridge_local_spoofable_params :: proc(params: string) -> bool {
	blocked := [?]string{"owner_user_id", "sender_agent_instance_id", "agent_instance_id", "hub_url", "Authorization", "authorization", "hub_token", "bridge_token", "token", "access_token"}
	for key in blocked {
		if strings.contains(params, strings.concatenate({"\"", key, "\""})) do return true
	}
	return false
}

bridge_local_subscribe_instance :: proc(line: string) -> (string, bool) {
	if bridge_local_extract_json_string(line, "method", "") != "wrapper.notifications.subscribe" do return "", false
	if bridge_local_extract_json_int(line, "v", 0) != 1 do return "", false
	params := bridge_local_extract_json_object(line, "params")
	if bridge_local_spoofable_params(params) do return "", false
	token := bridge_local_extract_json_string(line, "token", "")
	rec, ok := bridge_agent_token_verify(token)
	if !ok || rec.role != .Wrapper do return "", false
	return rec.agent_instance_id, rec.agent_instance_id != ""
}

bridge_wrapper_push_register_tcp :: proc(instance_id: string, socket: net.TCP_Socket) { bridge_wrapper_push_register(Bridge_Wrapper_Push_Conn{agent_instance_id=strings.clone(instance_id),kind=.TCP,tcp=socket}) }
bridge_wrapper_push_register_unix :: proc(instance_id: string, socket: posix.FD) { bridge_wrapper_push_register(Bridge_Wrapper_Push_Conn{agent_instance_id=strings.clone(instance_id),kind=.Unix,unix=socket}) }
bridge_wrapper_push_register :: proc(conn: Bridge_Wrapper_Push_Conn) {
	if bridge_wrapper_push_conns == nil do bridge_wrapper_push_conns = make([dynamic]Bridge_Wrapper_Push_Conn)
	sync.mutex_lock(&bridge_wrapper_push_mutex)
	defer sync.mutex_unlock(&bridge_wrapper_push_mutex)
	for i in 0..<len(bridge_wrapper_push_conns) { if bridge_wrapper_push_conns[i].agent_instance_id == conn.agent_instance_id { bridge_wrapper_push_conns[i] = conn; return } }
	append(&bridge_wrapper_push_conns, conn)
}
bridge_wrapper_push_drop :: proc(instance_id: string) {
	if bridge_wrapper_push_conns == nil do return
	sync.mutex_lock(&bridge_wrapper_push_mutex)
	defer sync.mutex_unlock(&bridge_wrapper_push_mutex)
	for i in 0..<len(bridge_wrapper_push_conns) { if bridge_wrapper_push_conns[i].agent_instance_id == instance_id { unordered_remove(&bridge_wrapper_push_conns, i); return } }
}
bridge_wrapper_push :: proc(instance_id, json_payload: string) -> bool {
	return bridge_wrapper_push_line(instance_id, strings.concatenate({"{\"push\":\"agent_message\",\"payload\":", json_payload, "}\n"}))
}

bridge_wrapper_push_startup_prompt :: proc(instance_id: string) -> bool {
	return bridge_wrapper_push_line(instance_id, "{\"push\":\"startup_prompt\"}\n")
}

bridge_wrapper_push_line :: proc(instance_id, line: string) -> bool {
	if bridge_wrapper_push_conns == nil do return false
	bytes := transmute([]byte)line
	sync.mutex_lock(&bridge_wrapper_push_mutex)
	defer sync.mutex_unlock(&bridge_wrapper_push_mutex)
	for i in 0..<len(bridge_wrapper_push_conns) {
		if bridge_wrapper_push_conns[i].agent_instance_id != instance_id do continue
		ok := false
		if bridge_wrapper_push_conns[i].kind == .TCP { _, err := net.send_tcp(bridge_wrapper_push_conns[i].tcp, bytes); ok = err == nil } else { ok = posix.send(bridge_wrapper_push_conns[i].unix, raw_data(bytes), c.size_t(len(bytes)), {}) >= 0 }
		if !ok { unordered_remove(&bridge_wrapper_push_conns, i); return false }
		return true
	}
	return false
}

bridge_local_method_allowed :: proc(method: string, role: Bridge_Local_Token_Role) -> bool {
	switch role {
	case .Wrapper:
		return method == "wrapper.startup.report" || method == "wrapper.activity.report" || method == "wrapper.liveness.ping" || method == "wrapper.exited" || method == "wrapper.notifications.subscribe"
	case .Agent:
		return method == "agent.chat.send_to_user" || method == "agent.chat.send_to_agent" || method == "agent.chat.fetch" || method == "agent.chat.read" || method == "agent.agents.live" || method == "agent.tasks.create" || method == "agent.tasks.depend" || method == "agent.tasks.comment" || method == "agent.tasks.status" || method == "agent.tasks.vote" || method == "agent.tasks.nudge" || method == "agent.artifacts.create" || method == "agent.artifacts.list" || method == "agent.artifacts.show" || method == "agent.artifacts.content" || method == "agent.memory.propose" || method == "agent.context.get" || method == "agent.start_success"
	}
	return false
}

bridge_local_handle_wrapper_method :: proc(request_id, method, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if method == "wrapper.startup.report" {
		phase := bridge_local_extract_json_string(params, "phase", "startup_unknown")
		pane_id := bridge_local_extract_json_string(params, "pane_id", "")
		if pane_id != "" do bridge_runtime_update_launch_pane(rec.agent_instance_id, pane_id)
		runtime := "starting"
		// Wrapper "ready" only means the child process was launched. The agent is
		// not running from Heimdall's perspective until explicit start-success.
		if phase == "startup_failed" do runtime = "failed"
		if runtime == "starting" { bridge_runtime_note_wrapper_signal(rec.agent_instance_id, "idle") } else { bridge_runtime_set_status(rec.agent_instance_id, runtime, "idle") }
		return bridge_local_response_data(request_id, "{\"accepted\":true}")
	}
	if method == "wrapper.activity.report" {
		activity := bridge_local_extract_json_string(params, "status", "idle")
		bridge_runtime_note_wrapper_signal(rec.agent_instance_id, activity)
		return bridge_local_response_data(request_id, "{\"accepted\":true}")
	}
	if method == "wrapper.liveness.ping" {
		bridge_runtime_note_wrapper_signal(rec.agent_instance_id, "idle")
		return bridge_local_response_data(request_id, "{\"accepted\":true}")
	}
	if method == "wrapper.exited" {
		bridge_runtime_set_status(rec.agent_instance_id, "stopped", "idle")
		bridge_wrapper_push_drop(rec.agent_instance_id)
		bridge_runtime_remove_launch(rec.agent_instance_id)
		return bridge_local_response_data(request_id, "{\"accepted\":true}")
	}
	if method == "wrapper.notifications.subscribe" {
		// Subscription itself is a live signal. This is the bridge-restart recovery
		// path: a ham-wrapper that outlived the bridge can reconnect with its
		// persisted wrapper token and rehydrate bridge runtime state before the next
		// liveness tick, without implying start-success.
		bridge_runtime_note_wrapper_signal(rec.agent_instance_id, "idle")
		return bridge_local_response_data(request_id, "{\"accepted\":true,\"subscribed\":true}")
	}
	return bridge_local_response_error(request_id, "forbidden", "wrapper method is not allowlisted")
}

bridge_local_handle_agent_method :: proc(request_id, method, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if method == "agent.start_success" {
		// Absolute transition: a valid instance token can mark the agent running from
		// any prior bridge-local state (starting, failed, unreachable, stopped, etc.).
		bridge_runtime_mark_start_success(rec.agent_instance_id)
		if bridge_provider_test_mark_start_success(rec.agent_instance_id) do return bridge_local_response_data(request_id, "{\"accepted\":true,\"provider_test\":true}")
		if strings.has_prefix(rec.agent_instance_id, "inst_ptest_") {
			return bridge_local_response_data(request_id, "{\"accepted\":true,\"provider_test\":true}")
		}
	}
	if strings.trim_space(rec.instance_token) == "" do return bridge_local_response_error(request_id, "unavailable", "Bridge-held instance token is unavailable")
	relay := bridge_local_relay_agent_method(method, params, rec)
	if !relay.ok do return bridge_local_response_error(request_id, "retryable_unavailable", "Hub relay failed")
	if relay.status < 200 || relay.status >= 300 do return bridge_local_response_error(request_id, "hub_error", relay.body)
	if strings.trim_space(relay.body) == "" do return bridge_local_response_data(request_id, "{}")
	return bridge_local_response_data(request_id, relay.body)
}

bridge_local_relay_agent_method :: proc(method, params: string, rec: Bridge_Local_Agent_Token_Record) -> Bridge_Local_Relay_Result {
	path := bridge_local_agent_method_path(method)
	if path == "" do return Bridge_Local_Relay_Result{status = 0, ok = false}
	body := bridge_local_agent_relay_body(method, params, rec.agent_instance_id)
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_config.bridge_token})}, {name = "X-Heimdall-Instance-Token", value = rec.instance_token}}
	resp, ok := http.request_with_headers_timeout("POST", bridge_config.daemon_url, path, body, headers[:], http.DEFAULT_TIMEOUT_MS)
	return Bridge_Local_Relay_Result{status = resp.status, body = resp.body, ok = ok}
}

bridge_local_agent_method_path :: proc(method: string) -> string {
	switch method {
	case "agent.chat.send_to_user": return "/api/v1/agent-actions/chat/send-to-user"
	case "agent.chat.send_to_agent": return "/api/v1/agent-actions/chat/send-to-agent"
	case "agent.chat.fetch": return "/api/v1/agent-actions/chat/fetch"
	case "agent.chat.read": return "/api/v1/agent-actions/chat/read"
	case "agent.agents.live": return "/api/v1/agent-actions/agents/live"
	case "agent.context.get": return "/api/v1/agent-actions/context"
	case "agent.tasks.create": return "/api/v1/agent-actions/tasks/create"
	case "agent.tasks.depend": return "/api/v1/agent-actions/tasks/depend"
	case "agent.tasks.comment": return "/api/v1/agent-actions/tasks/comment"
	case "agent.tasks.status": return "/api/v1/agent-actions/tasks/status"
	case "agent.tasks.vote": return "/api/v1/agent-actions/tasks/vote"
	case "agent.tasks.nudge": return "/api/v1/agent-actions/tasks/nudge"
	case "agent.artifacts.create": return "/api/v1/agent-actions/artifacts/create"
	case "agent.artifacts.list": return "/api/v1/agent-actions/artifacts/list"
	case "agent.artifacts.show": return "/api/v1/agent-actions/artifacts/show"
	case "agent.artifacts.content": return "/api/v1/agent-actions/artifacts/content"
	case "agent.memory.propose": return "/api/v1/agent-actions/memory/propose"
	case "agent.start_success": return "/api/v1/agent-actions/start-success"
	}
	return ""
}

bridge_local_agent_relay_body :: proc(method, params, agent_instance_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"method\":\"")
	bridge_local_write_json_string(&b, method)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	bridge_local_write_json_string(&b, agent_instance_id)
	strings.write_string(&b, "\",\"params\":")
	if strings.trim_space(params) == "" {
		strings.write_string(&b, "{}")
	} else {
		strings.write_string(&b, params)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

bridge_local_response_data :: proc(id, data_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"v\":1,\"id\":\"")
	bridge_local_write_json_string(&b, id)
	strings.write_string(&b, "\",\"ok\":true,\"data\":")
	if strings.trim_space(data_json) == "" {
		strings.write_string(&b, "{}")
	} else {
		strings.write_string(&b, data_json)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

bridge_local_response_error :: proc(id, code, message: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"v\":1,\"id\":\"")
	bridge_local_write_json_string(&b, id)
	strings.write_string(&b, "\",\"ok\":false,\"error\":{\"code\":\"")
	bridge_local_write_json_string(&b, code)
	strings.write_string(&b, "\",\"message\":\"")
	bridge_local_write_json_string(&b, message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_local_extract_json_string :: proc(json, key, fallback: string) -> string {
	start := bridge_local_json_member_value_start(json, key)
	if start < 0 do return fallback
	rest := strings.trim_space(json[start:])
	if len(rest) == 0 || rest[0] != '"' do return fallback
	end := 1
	escaped := false
	for end < len(rest) {
		ch := rest[end]
		if escaped {
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else if ch == '"' {
			return json_unescape(rest[1:end])
		}
		end += 1
	}
	return fallback
}

bridge_local_json_member_value_start :: proc(json, key: string) -> int {
	i := 0
	for i < len(json) {
		if json[i] != '"' { i += 1; continue }
		start := i + 1
		j := start
		escaped := false
		for j < len(json) {
			ch := json[j]
			if escaped { escaped = false; j += 1; continue }
			if ch == '\\' { escaped = true; j += 1; continue }
			if ch == '"' do break
			j += 1
		}
		if j >= len(json) do return -1
		k := j + 1
		for k < len(json) && bridge_local_json_is_ws(json[k]) do k += 1
		if json[start:j] == key && k < len(json) && json[k] == ':' do return k + 1
		i = j + 1
	}
	return -1
}

bridge_local_json_is_ws :: proc(ch: byte) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
}

bridge_local_extract_json_object :: proc(json, key: string) -> string {
	needle := strings.concatenate({"\"", key, "\""})
	idx := strings.index(json, needle)
	if idx < 0 do return "{}"
	rest := json[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return "{}"
	rest = strings.trim_space(rest[colon + 1:])
	if len(rest) == 0 || rest[0] != '{' do return "{}"
	depth := 0
	in_string := false
	escaped := false
	for i in 0..<len(rest) {
		ch := rest[i]
		if in_string {
			if escaped { escaped = false; continue }
			if ch == '\\' { escaped = true; continue }
			if ch == '"' do in_string = false
			continue
		}
		if ch == '"' { in_string = true; continue }
		if ch == '{' do depth += 1
		if ch == '}' {
			depth -= 1
			if depth == 0 do return rest[:i + 1]
		}
	}
	return "{}"
}

bridge_local_extract_json_int :: proc(json, key: string, default: int) -> int {
	needle := strings.concatenate({"\"", key, "\""})
	idx := strings.index(json, needle)
	if idx < 0 do return default
	rest := json[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return default
	rest = strings.trim_space(rest[colon + 1:])
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
	if end == 0 do return default
	value := 0
	for i in 0..<end do value = value * 10 + int(rest[i] - '0')
	return value
}

bridge_local_json_escaped :: proc(value: string) -> string {
	b := strings.builder_make()
	bridge_local_write_json_string(&b, value)
	return strings.to_string(b)
}

bridge_local_write_json_string :: proc(builder: ^strings.Builder, value: string) {
	for i in 0..<len(value) {
		ch := value[i]
		switch ch {
		case '"': strings.write_string(builder, "\\\"")
		case '\\': strings.write_string(builder, "\\\\")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case: strings.write_byte(builder, ch)
		}
	}
}
