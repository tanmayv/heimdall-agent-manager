package main

import "core:c"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import cfg_lib "odin_test:lib/config"
import tmux "odin_test:lib/tmux"

Bridge_Wrapper_Supervisor_Config :: struct {
	bridge_endpoint: string,
	local_agent_token: string,
	child_agent_token: string,
	agent_instance_id: string,
	working_dir: string,
	tmux_session: string,
	tmux_window: string,
	pane_id: string,
	provider: string,
	tier: string,
	liveness_interval_ms: int,
	activity_interval_ms: int,
}

bridge_wrapper_supervisor_main :: proc(args: []string) -> bool {
	config := bridge_wrapper_supervisor_config_from_args(args)
	if strings.trim_space(config.bridge_endpoint) == "" || strings.trim_space(config.local_agent_token) == "" || strings.trim_space(config.agent_instance_id) == "" {
		fmt.eprintln("bridge wrapper supervisor requires --bridge-endpoint, --agent-token, and --agent-instance-id")
		return false
	}
	if strings.trim_space(config.working_dir) == "" do config.working_dir = bridge_runtime_default_run_dir(config.agent_instance_id)
	if strings.trim_space(config.tmux_session) == "" do config.tmux_session = bridge_runtime_tmux_session()
	if strings.trim_space(config.tmux_window) == "" do config.tmux_window = bridge_runtime_tmux_window(config.agent_instance_id)
	profile, profile_ok := bridge_provider_by_name_or_default(config.provider)
	if !profile_ok || !profile.enabled || len(profile.command) == 0 {
		_ = bridge_wrapper_send_startup(config, "startup_failed", "provider has no runnable command")
		return false
	}
	_ = os.make_directory_all(config.working_dir)
	launch, launch_ok := tmux.ensure_agent_pane_process_window(config.tmux_session, config.tmux_window, config.working_dir, bridge_wrapper_agent_pane_argv(config, profile))
	if !launch_ok || strings.trim_space(launch.pane_id) == "" {
		_ = bridge_wrapper_send_startup(config, "startup_failed", "tmux pane launch failed")
		return false
	}
	config.pane_id = launch.pane_id
	_ = bridge_wrapper_send_startup(config, "starting", "agent pane launched")
	notify_config := new(Bridge_Wrapper_Supervisor_Config)
	notify_config^ = config
	thread.run_with_data(rawptr(notify_config), bridge_wrapper_notifications_subscribe_thread)
	probe := bridge_wrapper_startup_probe(profile.startup_detection, config.pane_id)
	_ = bridge_wrapper_send_startup(config, probe.status, probe.detail)
	if profile.prompt_delivery == "tmux" do bridge_wrapper_deliver_tmux_prompt(config, profile)
	ready_reported := true
	last_liveness := time.to_unix_nanoseconds(time.now())
	last_activity := last_liveness
	for {
		if !tmux.pane_exists(config.pane_id) {
			_ = bridge_wrapper_send_exited(config, "pane_exited")
			return true
		}
		now := time.to_unix_nanoseconds(time.now())
		if !ready_reported {
			_ = bridge_wrapper_send_startup(config, "ready", "agent pane is live")
			ready_reported = true
		}
		if now - last_liveness >= i64(time.Duration(config.liveness_interval_ms) * time.Millisecond) {
			_ = bridge_wrapper_send_liveness(config, 0)
			last_liveness = now
		}
		if now - last_activity >= i64(time.Duration(config.activity_interval_ms) * time.Millisecond) {
			status := "idle"
			source := "pane_alive"
			line_count := 20
			if profile_ok && profile.activity_detection.sample_line_count > 0 do line_count = profile.activity_detection.sample_line_count
			if text, ok := tmux.capture_pane_text(config.pane_id, line_count); ok {
				if strings.trim_space(text) != "" { status = "active"; source = "pane_output" }
			}
			_ = bridge_wrapper_send_activity(config, status, source)
			last_activity = now
		}
		time.sleep(250 * time.Millisecond)
	}
}

bridge_wrapper_supervisor_config_from_args :: proc(args: []string) -> Bridge_Wrapper_Supervisor_Config {
	cfg := Bridge_Wrapper_Supervisor_Config{
		bridge_endpoint = option_value(args, "--bridge-endpoint", os.get_env_alloc("HEIMDALL_BRIDGE_ENDPOINT", context.allocator)),
		local_agent_token = option_value(args, "--agent-token", os.get_env_alloc("HEIMDALL_AGENT_TOKEN", context.allocator)),
		child_agent_token = option_value(args, "--child-agent-token", ""),
		agent_instance_id = option_value(args, "--agent-instance-id", os.get_env_alloc("HEIMDALL_AGENT_INSTANCE_ID", context.allocator)),
		working_dir = option_value(args, "--run-dir", option_value(args, "--cwd", os.get_env_alloc("PWD", context.allocator))),
		tmux_session = option_value(args, "--tmux-session", ""),
		tmux_window = option_value(args, "--tmux-window", ""),
		pane_id = "",
		provider = option_value(args, "--provider", ""),
		tier = option_value(args, "--tier", ""),
		liveness_interval_ms = bridge_wrapper_int_arg(args, "--liveness-interval-ms", 1000),
		activity_interval_ms = bridge_wrapper_int_arg(args, "--activity-interval-ms", 2000),
	}
	if cfg.child_agent_token == "" do cfg.child_agent_token = cfg.local_agent_token
	return cfg
}

Bridge_Wrapper_Probe_Result :: struct { status: string, detail: string }

bridge_wrapper_startup_probe :: proc(cfg: cfg_lib.Startup_Detection_Config, pane_id: string) -> Bridge_Wrapper_Probe_Result {
	if !cfg.enabled do return Bridge_Wrapper_Probe_Result{status = "ready", detail = "startup detection disabled"}
	probe_seconds := cfg.startup_probe_seconds
	if probe_seconds <= 0 do probe_seconds = 20
	interval_ms := cfg.capture_interval_ms
	if interval_ms <= 0 do interval_ms = 500
	deadline := time.to_unix_nanoseconds(time.now()) + i64(time.Duration(probe_seconds) * time.Second)
	last_auto_enter := i64(0)
	for time.to_unix_nanoseconds(time.now()) < deadline {
		if !tmux.pane_exists(pane_id) do return Bridge_Wrapper_Probe_Result{status = "startup_failed", detail = "agent pane exited during startup"}
		pane_text, ok := tmux.capture_pane_text(pane_id, 80)
		if ok {
			if idx := bridge_wrapper_first_pattern(pane_text, cfg.blocked_patterns); idx >= 0 do return Bridge_Wrapper_Probe_Result{status = "startup_blocked", detail = bridge_wrapper_reason(cfg, idx, "startup blocked")}
			now := time.to_unix_nanoseconds(time.now())
			if now - last_auto_enter >= i64(2 * time.Second) {
				if idx := bridge_wrapper_first_pattern(pane_text, cfg.auto_enter_patterns); idx >= 0 {
					if idx < len(cfg.auto_enter_pre_keys) && strings.trim_space(cfg.auto_enter_pre_keys[idx]) != "" {
						_ = tmux.send_text(pane_id, cfg.auto_enter_pre_keys[idx], true)
					} else {
						_ = tmux.send_text(pane_id, "", true)
					}
					last_auto_enter = now
					deadline = now + i64(time.Duration(probe_seconds) * time.Second)
				}
			}
		}
		time.sleep(time.Duration(interval_ms) * time.Millisecond)
	}
	if cfg.startup_unknown_is_blocked do return Bridge_Wrapper_Probe_Result{status = "startup_blocked", detail = "startup readiness unknown"}
	return Bridge_Wrapper_Probe_Result{status = "ready", detail = "startup probe completed"}
}

bridge_wrapper_deliver_tmux_prompt :: proc(config: Bridge_Wrapper_Supervisor_Config, profile: Bridge_Provider_Profile) {
	prompt := bridge_provider_render_starter_prompt(profile.starter_prompt, config.child_agent_token, config.agent_instance_id)
	if strings.trim_space(prompt) == "" do return
	delay := profile.prompt_tmux_delay_ms
	if delay > 0 do time.sleep(time.Duration(delay) * time.Millisecond)
	_ = tmux.send_text(config.pane_id, prompt, profile.prompt_tmux_enter)
}

bridge_wrapper_first_pattern :: proc(text: string, patterns: []string) -> int {
	lower_text := strings.to_lower(text)
	for pattern, i in patterns {
		p := strings.to_lower(strings.trim_space(pattern))
		if p != "" && strings.contains(lower_text, p) do return i
	}
	return -1
}

bridge_wrapper_reason :: proc(cfg: cfg_lib.Startup_Detection_Config, idx: int, fallback: string) -> string {
	if idx >= 0 && idx < len(cfg.sanitized_reason_mapping) && strings.trim_space(cfg.sanitized_reason_mapping[idx]) != "" do return cfg.sanitized_reason_mapping[idx]
	return fallback
}

bridge_wrapper_agent_pane_argv :: proc(config: Bridge_Wrapper_Supervisor_Config, profile: Bridge_Provider_Profile) -> []string {
	out := make([dynamic]string)
	append(&out, "env")
	append(&out, ..bridge_wrapper_child_env(config))
	agent_argv := bridge_runtime_agent_argv_for_profile(profile, config.tier, config.child_agent_token, config.agent_instance_id)
	append(&out, ..agent_argv)
	return out[:]
}

bridge_wrapper_child_env :: proc(config: Bridge_Wrapper_Supervisor_Config) -> []string {
	out := make([dynamic]string)
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
	return bridge_wrapper_local_call(config, "wrapper.startup.report", bridge_wrapper_startup_params(config, phase, detail))
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

bridge_wrapper_startup_params :: proc(config: Bridge_Wrapper_Supervisor_Config, phase, detail: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"phase\":\""); json_write_string(&b, phase)
	strings.write_string(&b, "\",\"detail\":\""); json_write_string(&b, detail)
	if strings.trim_space(config.pane_id) != "" { strings.write_string(&b, "\",\"pane_id\":\""); json_write_string(&b, config.pane_id) }
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

bridge_wrapper_notifications_subscribe_thread :: proc(data: rawptr) {
	if data == nil do return
	config := (^Bridge_Wrapper_Supervisor_Config)(data)^
	bridge_wrapper_notifications_subscribe_loop(config)
}

bridge_wrapper_notifications_subscribe_loop :: proc(config: Bridge_Wrapper_Supervisor_Config) {
	request := bridge_wrapper_jsonl_request(config.local_agent_token, "wrapper.notifications.subscribe", "{}")
	if strings.has_prefix(config.bridge_endpoint, "tcp:") { bridge_wrapper_subscribe_tcp(config, request); return }
	if strings.has_prefix(config.bridge_endpoint, "unix:") { bridge_wrapper_subscribe_unix(config, request); return }
}

bridge_wrapper_subscribe_tcp :: proc(config: Bridge_Wrapper_Supervisor_Config, request: string) {
	parts := strings.split(config.bridge_endpoint, ":")
	defer delete(parts)
	if len(parts) < 3 do return
	port := bridge_wrapper_int_from_string(parts[2])
	address := net.IP4_Loopback
	if parsed, ok := net.parse_ip4_address(parts[1]); ok do address = parsed
	conn, err := net.dial_tcp(address, port)
	if err != nil do return
	defer net.close(conn)
	_, send_err := net.send_tcp(conn, transmute([]byte)request)
	if send_err != nil do return
	buf: [8192]byte
	pending := ""
	for {
		n, recv_err := net.recv_tcp(conn, buf[:])
		if recv_err != nil || n <= 0 do return
		pending = strings.concatenate({pending, string(buf[:n])})
		bridge_wrapper_dispatch_push_lines(config, &pending)
	}
}

bridge_wrapper_subscribe_unix :: proc(config: Bridge_Wrapper_Supervisor_Config, request: string) {
	path := strings.trim_prefix(config.bridge_endpoint, "unix:")
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return
	defer posix.close(fd)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD || ODIN_OS == .Haiku {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK do return
	bytes := transmute([]byte)request
	if posix.send(fd, raw_data(bytes), c.size_t(len(bytes)), {}) < 0 do return
	buf: [8192]byte
	pending := ""
	for {
		n := posix.recv(fd, raw_data(buf[:]), c.size_t(len(buf)), {})
		if n <= 0 do return
		pending = strings.concatenate({pending, string(buf[:int(n)])})
		bridge_wrapper_dispatch_push_lines(config, &pending)
	}
}

bridge_wrapper_dispatch_push_lines :: proc(config: Bridge_Wrapper_Supervisor_Config, pending: ^string) {
	for {
		idx := strings.index_byte(pending^, '\n')
		if idx < 0 do return
		line := strings.trim_space((pending^)[:idx])
		pending^ = (pending^)[idx + 1:]
		if line == "" || !strings.contains(line, "\"push\":\"agent_message\"") do continue
		bridge_wrapper_deliver_message_push(config, line)
	}
}

bridge_wrapper_deliver_message_push :: proc(config: Bridge_Wrapper_Supervisor_Config, line: string) {
	sender := bridge_local_extract_json_string(line, "sender_agent_instance_id", "user")
	if strings.trim_space(sender) == "" do sender = "user"
	msg := strings.concatenate({"New message from ", sender, " — run 'ham-ctl agent chat read' to view."})
	_ = tmux.send_text(config.pane_id, msg, true)
}

bridge_wrapper_int_from_string :: proc(value: string) -> int {
	parsed, ok := strconv_parse_int_bridge_wrapper(value)
	if !ok do return 0
	return parsed
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
