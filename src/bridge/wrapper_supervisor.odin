package main

import "core:c"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

Bridge_Wrapper_Supervisor_Config :: struct {
	bridge_endpoint: string,
	local_agent_token: string,
	child_agent_token: string,
	agent_instance_id: string,
	working_dir: string,
	agent_command: string,
	liveness_interval_ms: int,
	activity_interval_ms: int,
}

bridge_wrapper_supervisor_main :: proc(args: []string) -> bool {
	config := bridge_wrapper_supervisor_config_from_args(args)
	if strings.trim_space(config.bridge_endpoint) == "" || strings.trim_space(config.local_agent_token) == "" || strings.trim_space(config.agent_instance_id) == "" || strings.trim_space(config.agent_command) == "" {
		fmt.eprintln("bridge wrapper supervisor requires HEIMDALL_BRIDGE_ENDPOINT, HEIMDALL_AGENT_TOKEN, HEIMDALL_AGENT_INSTANCE_ID, and --agent-command")
		return false
	}
	_ = bridge_wrapper_send_startup(config, "starting", "launching agent command")
	env := bridge_wrapper_child_env(config)
	process, err := os.process_start(os.Process_Desc{command = []string{"sh", "-c", config.agent_command}, working_dir = config.working_dir, env = env})
	if err != nil {
		_ = bridge_wrapper_send_startup(config, "startup_failed", "agent command failed to start")
		return false
	}
	_ = bridge_wrapper_send_startup(config, "ready", "agent command started")
	last_liveness := time.to_unix_nanoseconds(time.now())
	last_activity := last_liveness
	for {
		state, wait_err := os.process_wait(process, 0)
		if wait_err == nil {
			_ = state
			_ = bridge_wrapper_send_exited(config, "process_exited")
			return true
		}
		now := time.to_unix_nanoseconds(time.now())
		if now - last_liveness >= i64(time.Duration(config.liveness_interval_ms) * time.Millisecond) {
			_ = bridge_wrapper_send_liveness(config, process.pid)
			last_liveness = now
		}
		if now - last_activity >= i64(time.Duration(config.activity_interval_ms) * time.Millisecond) {
			_ = bridge_wrapper_send_activity(config, "active", "process_alive")
			last_activity = now
		}
		time.sleep(100 * time.Millisecond)
	}
}

bridge_wrapper_supervisor_config_from_args :: proc(args: []string) -> Bridge_Wrapper_Supervisor_Config {
	cfg := Bridge_Wrapper_Supervisor_Config{
		bridge_endpoint = option_value(args, "--bridge-endpoint", os.get_env_alloc("HEIMDALL_BRIDGE_ENDPOINT", context.allocator)),
		local_agent_token = option_value(args, "--agent-token", os.get_env_alloc("HEIMDALL_AGENT_TOKEN", context.allocator)),
		child_agent_token = option_value(args, "--child-agent-token", ""),
		agent_instance_id = option_value(args, "--agent-instance-id", os.get_env_alloc("HEIMDALL_AGENT_INSTANCE_ID", context.allocator)),
		working_dir = option_value(args, "--cwd", os.get_env_alloc("PWD", context.allocator)),
		agent_command = option_value(args, "--agent-command", ""),
		liveness_interval_ms = bridge_wrapper_int_arg(args, "--liveness-interval-ms", 1000),
		activity_interval_ms = bridge_wrapper_int_arg(args, "--activity-interval-ms", 2000),
	}
	if cfg.child_agent_token == "" do cfg.child_agent_token = cfg.local_agent_token
	return cfg
}

bridge_wrapper_child_env :: proc(config: Bridge_Wrapper_Supervisor_Config) -> []string {
	// Deliberately sanitized: never inherit parent Hub/daemon/Bridge credential
	// variables; only a small tool/runtime allowlist plus local endpoint env.
	out := make([dynamic]string)
	bridge_wrapper_append_parent_env_if_present(&out, "PATH")
	bridge_wrapper_append_parent_env_if_present(&out, "HOME")
	bridge_wrapper_append_parent_env_if_present(&out, "USER")
	bridge_wrapper_append_parent_env_if_present(&out, "LOGNAME")
	bridge_wrapper_append_parent_env_if_present(&out, "SHELL")
	bridge_wrapper_append_parent_env_if_present(&out, "TERM")
	bridge_wrapper_append_parent_env_if_present(&out, "TMPDIR")
	bridge_wrapper_append_parent_env_if_present(&out, "LANG")
	bridge_wrapper_append_parent_env_if_present(&out, "LC_ALL")
	append(&out, strings.concatenate({"HEIMDALL_BRIDGE_ENDPOINT=", config.bridge_endpoint}))
	append(&out, strings.concatenate({"HEIMDALL_AGENT_TOKEN=", config.child_agent_token}))
	append(&out, strings.concatenate({"HEIMDALL_AGENT_INSTANCE_ID=", config.agent_instance_id}))
	return out[:]
}

bridge_wrapper_append_parent_env_if_present :: proc(out: ^[dynamic]string, key: string) {
	if !bridge_wrapper_env_key_allowed(key) do return
	value := os.get_env_alloc(key, context.allocator)
	defer delete(value)
	if value == "" do return
	append(out, strings.concatenate({key, "=", value}))
}

bridge_wrapper_env_key_allowed :: proc(key: string) -> bool {
	switch key {
	case "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TMPDIR", "TMP", "TEMP", "PWD", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR", "NIX_SSL_CERT_FILE":
		return true
	}
	if strings.has_prefix(key, "LC_") do return true
	return false
}

bridge_wrapper_send_startup :: proc(config: Bridge_Wrapper_Supervisor_Config, phase, detail: string) -> bool {
	return bridge_wrapper_local_call(config, "wrapper.startup.report", bridge_wrapper_startup_params(phase, detail))
}

bridge_wrapper_send_activity :: proc(config: Bridge_Wrapper_Supervisor_Config, status, source: string) -> bool {
	b := strings.builder_make()
	strings.write_string(&b, "{\"status\":\""); json_write_string(&b, status)
	strings.write_string(&b, "\",\"source\":\""); json_write_string(&b, source)
	strings.write_string(&b, "\"}")
	return bridge_wrapper_local_call(config, "wrapper.activity.report", strings.to_string(b))
}

bridge_wrapper_send_liveness :: proc(config: Bridge_Wrapper_Supervisor_Config, pid: int) -> bool {
	return bridge_wrapper_local_call(config, "wrapper.liveness.ping", fmt.tprintf("{\"pane_alive\":true,\"pid\":%d}", pid))
}

bridge_wrapper_send_exited :: proc(config: Bridge_Wrapper_Supervisor_Config, reason: string) -> bool {
	b := strings.builder_make()
	strings.write_string(&b, "{\"reason\":\""); json_write_string(&b, reason)
	strings.write_string(&b, "\"}")
	return bridge_wrapper_local_call(config, "wrapper.exited", strings.to_string(b))
}

bridge_wrapper_startup_params :: proc(phase, detail: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"phase\":\""); json_write_string(&b, phase)
	strings.write_string(&b, "\",\"detail\":\""); json_write_string(&b, detail)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_wrapper_local_call :: proc(config: Bridge_Wrapper_Supervisor_Config, method, params_json: string) -> bool {
	request := bridge_wrapper_jsonl_request(config.local_agent_token, method, params_json)
	if strings.has_prefix(config.bridge_endpoint, "tcp:") do return bridge_wrapper_send_tcp(config.bridge_endpoint, request)
	if strings.has_prefix(config.bridge_endpoint, "unix:") do return bridge_wrapper_send_unix(config.bridge_endpoint, request)
	return false
}

bridge_wrapper_jsonl_request :: proc(token, method, params_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"v\":1,\"id\":\"wrapper-supervisor\",\"token\":\"")
	json_write_string(&b, token)
	strings.write_string(&b, "\",\"method\":\"")
	json_write_string(&b, method)
	strings.write_string(&b, "\",\"params\":")
	if strings.trim_space(params_json) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, params_json) }
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

bridge_wrapper_send_tcp :: proc(endpoint, line: string) -> bool {
	parts := strings.split(endpoint, ":")
	defer delete(parts)
	if len(parts) != 3 do return false
	port_i, port_ok := strconv_parse_int_bridge_wrapper(parts[2])
	if !port_ok do return false
	address := net.IP4_Loopback
	if parsed, ok := net.parse_ip4_address(parts[1]); ok do address = parsed
	socket, err := net.dial_tcp(address, int(port_i))
	if err != nil do return false
	defer net.close(socket)
	_, send_err := net.send_tcp(socket, transmute([]byte)line)
	if send_err != nil do return false
	buf: [1024]byte
	_, _ = net.recv_tcp(socket, buf[:])
	return true
}

bridge_wrapper_send_unix :: proc(endpoint, line: string) -> bool {
	path := strings.trim_prefix(endpoint, "unix:")
	if strings.trim_space(path) == "" || len(path) + 1 > len(posix.sockaddr_un{}.sun_path) do return false
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	defer posix.close(fd)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD || ODIN_OS == .Haiku {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK do return false
	bytes := transmute([]byte)line
	if posix.send(fd, raw_data(bytes), c.size_t(len(bytes)), {}) < 0 do return false
	buf: [1024]byte
	_ = posix.recv(fd, raw_data(buf[:]), c.size_t(len(buf)), {})
	return true
}

bridge_wrapper_int_arg :: proc(args: []string, name: string, fallback: int) -> int {
	value := option_value(args, name, "")
	if value == "" do return fallback
	parsed, ok := strconv_parse_int_bridge_wrapper(value)
	if !ok do return fallback
	return int(parsed)
}

strconv_parse_int_bridge_wrapper :: proc(value: string) -> (int, bool) {
	result := 0
	if value == "" do return 0, false
	for ch in value {
		if ch < '0' || ch > '9' do return 0, false
		result = result * 10 + int(ch - '0')
	}
	return result, true
}
