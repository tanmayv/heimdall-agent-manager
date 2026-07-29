package main

import "core:c"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import tmux "odin_test:lib/tmux"

Bridge_Runtime_Config :: struct {
	bridge_endpoint: string,
	wrapper_token: string,
	child_agent_token: string,
	agent_instance_id: string,
	working_dir: string,
	provider: string,
	tier: string,
	pane_id: string,
	agent_argv: []string,
	liveness_interval_ms: int,
	activity_interval_ms: int,
}

wrapper_bridge_runtime_main :: proc(args: []string) -> bool {
	cfg := wrapper_bridge_runtime_config_from_args(args)
	if strings.trim_space(cfg.bridge_endpoint) == "" || strings.trim_space(cfg.wrapper_token) == "" || strings.trim_space(cfg.agent_instance_id) == "" || len(cfg.agent_argv) == 0 {
		fmt.eprintln("ham-wrapper bridge-runtime requires --bridge-endpoint, --agent-token, --agent-instance-id, and child command after --")
		return false
	}
	if strings.trim_space(cfg.child_agent_token) == "" do cfg.child_agent_token = cfg.wrapper_token
	if strings.trim_space(cfg.working_dir) == "" do cfg.working_dir = os.get_env_alloc("PWD", context.allocator)
	if strings.trim_space(cfg.pane_id) == "" do cfg.pane_id = os.get_env_alloc("TMUX_PANE", context.allocator)
	_ = os.make_directory_all(cfg.working_dir)
	_ = wrapper_bridge_report_startup(cfg, "starting", "ham-wrapper bridge runtime starting")

	notify_cfg := new(Bridge_Runtime_Config)
	notify_cfg^ = cfg
	thread.run_with_data(rawptr(notify_cfg), wrapper_bridge_notifications_thread)

	child_env := wrapper_bridge_child_env(cfg)
	process, err := os.process_start(os.Process_Desc{command = cfg.agent_argv, working_dir = cfg.working_dir, env = child_env, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if err != nil {
		_ = wrapper_bridge_report_startup(cfg, "startup_failed", "agent process launch failed")
		return false
	}
	_ = wrapper_bridge_report_startup(cfg, "ready", "agent child process launched")
	last_liveness := time.to_unix_nanoseconds(time.now())
	last_activity := last_liveness
	for {
		state, wait_err := os.process_wait(process, 0)
		if wait_err == nil && state.exited {
			_ = wrapper_bridge_local_call(cfg, "wrapper.exited", "{\"reason\":\"child_exited\"}")
			return true
		}
		if strings.trim_space(cfg.pane_id) != "" && !tmux.pane_exists(cfg.pane_id) {
			_ = wrapper_bridge_local_call(cfg, "wrapper.exited", "{\"reason\":\"pane_exited\"}")
			return true
		}
		now := time.to_unix_nanoseconds(time.now())
		if now - last_liveness >= i64(time.Duration(cfg.liveness_interval_ms) * time.Millisecond) {
			_ = wrapper_bridge_local_call(cfg, "wrapper.liveness.ping", "{}")
			last_liveness = now
		}
		if now - last_activity >= i64(time.Duration(cfg.activity_interval_ms) * time.Millisecond) {
			_ = wrapper_bridge_local_call(cfg, "wrapper.activity.report", "{\"status\":\"idle\"}")
			last_activity = now
		}
		time.sleep(250 * time.Millisecond)
	}
}

wrapper_bridge_runtime_config_from_args :: proc(args: []string) -> Bridge_Runtime_Config {
	cfg := Bridge_Runtime_Config{
		bridge_endpoint = option_value(args, "--bridge-endpoint", os.get_env_alloc("HEIMDALL_BRIDGE_ENDPOINT", context.allocator)),
		wrapper_token = option_value(args, "--agent-token", os.get_env_alloc("HEIMDALL_WRAPPER_TOKEN", context.allocator)),
		child_agent_token = option_value(args, "--child-agent-token", os.get_env_alloc("HEIMDALL_AGENT_TOKEN", context.allocator)),
		agent_instance_id = option_value(args, "--agent-instance-id", os.get_env_alloc("HEIMDALL_AGENT_INSTANCE_ID", context.allocator)),
		working_dir = option_value(args, "--run-dir", option_value(args, "--cwd", os.get_env_alloc("PWD", context.allocator))),
		provider = option_value(args, "--provider", ""),
		tier = option_value(args, "--tier", ""),
		pane_id = option_value(args, "--pane-id", os.get_env_alloc("TMUX_PANE", context.allocator)),
		liveness_interval_ms = wrapper_bridge_int_arg(args, "--liveness-interval-ms", 1000),
		activity_interval_ms = wrapper_bridge_int_arg(args, "--activity-interval-ms", 2000),
	}
	if sep := wrapper_bridge_command_separator(args); sep >= 0 && sep + 1 < len(args) {
		cmd := make([dynamic]string)
		for i := sep + 1; i < len(args); i += 1 do append(&cmd, strings.clone(args[i]))
		cfg.agent_argv = cmd[:]
	}
	return cfg
}

wrapper_bridge_command_separator :: proc(args: []string) -> int {
	for arg, i in args { if arg == "--" do return i }
	return -1
}

wrapper_bridge_int_arg :: proc(args: []string, key: string, fallback: int) -> int {
	value := option_value(args, key, "")
	if value == "" do return fallback
	parsed, ok := strconv.parse_int(value)
	if !ok do return fallback
	return int(parsed)
}

wrapper_bridge_child_env :: proc(cfg: Bridge_Runtime_Config) -> []string {
	env, err := os.environ(context.allocator)
	if err != nil do env = make([]string, 0)
	defer {
		for item in env do delete(item)
		delete(env)
	}
	out := make([dynamic]string)
	for item in env {
		if strings.has_prefix(item, "HEIMDALL_BRIDGE_ENDPOINT=") || strings.has_prefix(item, "HEIMDALL_AGENT_TOKEN=") || strings.has_prefix(item, "HEIMDALL_AGENT_INSTANCE_ID=") || strings.has_prefix(item, "HEIMDALL_CTL_BIN=") do continue
		append(&out, strings.clone(item))
	}
	append(&out, strings.concatenate({"HEIMDALL_BRIDGE_ENDPOINT=", cfg.bridge_endpoint}))
	append(&out, strings.concatenate({"HEIMDALL_AGENT_TOKEN=", cfg.child_agent_token}))
	append(&out, strings.concatenate({"HEIMDALL_AGENT_INSTANCE_ID=", cfg.agent_instance_id}))
	append(&out, strings.concatenate({"HEIMDALL_CTL_BIN=", strings.trim_right(cfg.working_dir, "/"), "/.heimdall/bin/ham-ctl"}))
	return out[:]
}

wrapper_bridge_report_startup :: proc(cfg: Bridge_Runtime_Config, phase, detail: string) -> bool {
	b := strings.builder_make()
	strings.write_string(&b, "{\"phase\":\""); json_write_string(&b, phase)
	strings.write_string(&b, "\",\"detail\":\""); json_write_string(&b, detail)
	if strings.trim_space(cfg.pane_id) != "" { strings.write_string(&b, "\",\"pane_id\":\""); json_write_string(&b, cfg.pane_id) }
	strings.write_string(&b, "\"}")
	return wrapper_bridge_local_call(cfg, "wrapper.startup.report", strings.to_string(b))
}

wrapper_bridge_jsonl_request :: proc(token, method, params_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"v\":1,\"id\":\"ham-wrapper-bridge-runtime\",\"token\":\"")
	json_write_string(&b, token)
	strings.write_string(&b, "\",\"method\":\"")
	json_write_string(&b, method)
	strings.write_string(&b, "\",\"params\":")
	if strings.trim_space(params_json) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, params_json) }
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

wrapper_bridge_local_call :: proc(cfg: Bridge_Runtime_Config, method, params_json: string) -> bool {
	request := wrapper_bridge_jsonl_request(cfg.wrapper_token, method, params_json)
	if strings.has_prefix(cfg.bridge_endpoint, "tcp:") do return wrapper_bridge_send_tcp(cfg.bridge_endpoint, request)
	if strings.has_prefix(cfg.bridge_endpoint, "unix:") do return wrapper_bridge_send_unix(cfg.bridge_endpoint, request)
	return false
}

wrapper_bridge_send_tcp :: proc(endpoint, request: string) -> bool {
	parts := strings.split(endpoint, ":")
	defer delete(parts)
	if len(parts) < 3 do return false
	port := wrapper_bridge_int_string(parts[2])
	address := net.IP4_Loopback
	if parsed, ok := net.parse_ip4_address(parts[1]); ok do address = parsed
	conn, err := net.dial_tcp(address, port)
	if err != nil do return false
	defer net.close(conn)
	_, send_err := net.send_tcp(conn, transmute([]byte)request)
	return send_err == nil
}

wrapper_bridge_send_unix :: proc(endpoint, request: string) -> bool {
	path := strings.trim_prefix(endpoint, "unix:")
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	defer posix.close(fd)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD || ODIN_OS == .Haiku { addr.sun_len = c.uchar(size_of(addr)) }
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK do return false
	bytes := transmute([]byte)request
	return posix.send(fd, raw_data(bytes), c.size_t(len(bytes)), {}) >= 0
}

wrapper_bridge_int_string :: proc(value: string) -> int {
	parsed, ok := strconv.parse_int(strings.trim_space(value))
	if !ok do return 0
	return int(parsed)
}

wrapper_bridge_notifications_thread :: proc(data: rawptr) {
	if data == nil do return
	cfg := (^Bridge_Runtime_Config)(data)^
	backoff_ms := 250
	for {
		if strings.trim_space(cfg.pane_id) != "" && !tmux.pane_exists(cfg.pane_id) do return
		connected := wrapper_bridge_notifications_subscribe_loop(cfg)
		if connected { backoff_ms = 250 } else if backoff_ms < 30000 { backoff_ms *= 2 }
		time.sleep(time.Duration(backoff_ms) * time.Millisecond)
	}
}

wrapper_bridge_notifications_subscribe_loop :: proc(cfg: Bridge_Runtime_Config) -> bool {
	request := wrapper_bridge_jsonl_request(cfg.wrapper_token, "wrapper.notifications.subscribe", "{}")
	if strings.has_prefix(cfg.bridge_endpoint, "tcp:") do return wrapper_bridge_subscribe_tcp(cfg, request)
	if strings.has_prefix(cfg.bridge_endpoint, "unix:") do return wrapper_bridge_subscribe_unix(cfg, request)
	return false
}

wrapper_bridge_subscribe_tcp :: proc(cfg: Bridge_Runtime_Config, request: string) -> bool {
	parts := strings.split(cfg.bridge_endpoint, ":")
	defer delete(parts)
	if len(parts) < 3 do return false
	port := wrapper_bridge_int_string(parts[2])
	address := net.IP4_Loopback
	if parsed, ok := net.parse_ip4_address(parts[1]); ok do address = parsed
	conn, err := net.dial_tcp(address, port)
	if err != nil do return false
	defer net.close(conn)
	_, send_err := net.send_tcp(conn, transmute([]byte)request)
	if send_err != nil do return false
	buf: [8192]byte
	pending := ""
	subscribed := false
	for {
		n, recv_err := net.recv_tcp(conn, buf[:])
		if recv_err != nil || n <= 0 do return subscribed
		subscribed = true
		pending = strings.concatenate({pending, string(buf[:n])})
		wrapper_bridge_dispatch_push_lines(cfg, &pending)
	}
}

wrapper_bridge_subscribe_unix :: proc(cfg: Bridge_Runtime_Config, request: string) -> bool {
	path := strings.trim_prefix(cfg.bridge_endpoint, "unix:")
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	defer posix.close(fd)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD || ODIN_OS == .Haiku { addr.sun_len = c.uchar(size_of(addr)) }
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK do return false
	bytes := transmute([]byte)request
	if posix.send(fd, raw_data(bytes), c.size_t(len(bytes)), {}) < 0 do return false
	buf: [8192]byte
	pending := ""
	subscribed := false
	for {
		n := posix.recv(fd, raw_data(buf[:]), c.size_t(len(buf)), {})
		if n <= 0 do return subscribed
		subscribed = true
		pending = strings.concatenate({pending, string(buf[:int(n)])})
		wrapper_bridge_dispatch_push_lines(cfg, &pending)
	}
}

wrapper_bridge_dispatch_push_lines :: proc(cfg: Bridge_Runtime_Config, pending: ^string) {
	for {
		idx := strings.index_byte(pending^, '\n')
		if idx < 0 do return
		line := strings.trim_space((pending^)[:idx])
		pending^ = (pending^)[idx + 1:]
		if line == "" do continue
		if strings.contains(line, "\"push\":\"startup_prompt\"") {
			wrapper_bridge_deliver_startup_prompt(cfg)
			continue
		}
		if strings.contains(line, "\"push\":\"pane_capture_request\"") {
			wrapper_bridge_handle_pane_capture_request(cfg, line)
			continue
		}
		if strings.contains(line, "\"push\":\"agent_message\"") do wrapper_bridge_deliver_message_push(cfg, line)
		if strings.contains(line, "\"push\":\"task_nudge\"") do wrapper_bridge_deliver_task_nudge_push(cfg, line)
	}
}

wrapper_bridge_handle_pane_capture_request :: proc(cfg: Bridge_Runtime_Config, line: string) {
	command_id := extract_json_string(line,"command_id","")
	req_id := extract_json_string(line,"pane_capture_request_id","")
	message_id := extract_json_string(line,"message_id","")
	if extract_json_int(line,"protocol_version",0) != 1 { _ = wrapper_bridge_pane_capture_failure(cfg,command_id,req_id,message_id,"unsupported_capture_agent_pane","The pane capture request protocol is not supported."); return }
	width := wrapper_bridge_clamp_int(extract_json_int(line,"width",80),40,200)
	settle_ms := wrapper_bridge_clamp_int(extract_json_int(line,"settle_ms",3000),500,10000)
	line_limit := wrapper_bridge_clamp_int(extract_json_int(line,"line_limit",120),20,300)
	pane := wrapper_bridge_prompt_pane(cfg)
	if strings.trim_space(pane)=="" || !tmux.pane_exists(pane) { _ = wrapper_bridge_pane_capture_failure(cfg,command_id,req_id,message_id,"pane_not_running","The agent tmux pane is no longer running."); return }
	if !tmux.resize_pane_width(pane,width) { _ = wrapper_bridge_pane_capture_failure(cfg,command_id,req_id,message_id,"resize_failed","The agent pane could not be resized before capture."); return }
	time.sleep(time.Duration(settle_ms) * time.Millisecond)
	output,captured := tmux.capture_pane_text(pane,line_limit)
	if !captured { _ = wrapper_bridge_pane_capture_failure(cfg,command_id,req_id,message_id,"capture_failed","The agent pane could not be captured."); return }
	sanitized,line_count,truncated := wrapper_bridge_sanitize_capture(output,48000)
	b:=strings.builder_make(); strings.write_string(&b,"{\"command_id\":\""); json_write_string(&b,command_id); strings.write_string(&b,"\",\"pane_capture_request_id\":\""); json_write_string(&b,req_id); strings.write_string(&b,"\",\"message_id\":\""); json_write_string(&b,message_id); strings.write_string(&b,"\",\"ok\":true,\"output\":\""); json_write_string(&b,sanitized); strings.write_string(&b,"\",\"width\":"); strings.write_string(&b,fmt.tprintf("%d",width)); strings.write_string(&b,",\"line_count\":"); strings.write_string(&b,fmt.tprintf("%d",line_count)); strings.write_string(&b,",\"truncated\":"); strings.write_string(&b,"true" if truncated else "false"); strings.write_string(&b,"}")
	_ = wrapper_bridge_local_call(cfg,"wrapper.pane_capture.result",strings.to_string(b))
}

wrapper_bridge_pane_capture_failure :: proc(cfg:Bridge_Runtime_Config,command_id,req_id,message_id,error_code,message:string)->bool{ b:=strings.builder_make(); strings.write_string(&b,"{\"command_id\":\""); json_write_string(&b,command_id); strings.write_string(&b,"\",\"pane_capture_request_id\":\""); json_write_string(&b,req_id); strings.write_string(&b,"\",\"message_id\":\""); json_write_string(&b,message_id); strings.write_string(&b,"\",\"ok\":false,\"error_code\":\""); json_write_string(&b,error_code); strings.write_string(&b,"\",\"message\":\""); json_write_string(&b,message); strings.write_string(&b,"\"}"); return wrapper_bridge_local_call(cfg,"wrapper.pane_capture.result",strings.to_string(b)) }

wrapper_bridge_clamp_int :: proc(v,min,max:int)->int{ out:=v; if out<min do out=min; if out>max do out=max; return out }
wrapper_bridge_sanitize_capture :: proc(value:string,max_bytes:int)->(string,int,bool){ b:=strings.builder_make(); line_count:=0; last_newline:=true; truncated:=false; esc:=false; for i:=0; i<len(value); i+=1 { ch:=value[i]; if esc { if ch>='@' && ch<='~' do esc=false; continue }; if ch==0x1b { esc=true; continue }; if ch<32 && ch!='\n' && ch!='\r' && ch!='\t' do continue; if strings.builder_len(b)>=max_bytes { truncated=true; break }; if ch=='\r' do continue; strings.write_byte(&b,ch); if ch=='\n' { line_count+=1; last_newline=true } else { last_newline=false } }; if !last_newline do line_count+=1; return strings.to_string(b),line_count,truncated }

wrapper_bridge_deliver_message_push :: proc(cfg: Bridge_Runtime_Config, line: string) {
	sender := extract_json_string(line, "sender_agent_instance_id", extract_json_string(line, "sender", "user"))
	if strings.trim_space(sender) == "" do sender = "user"
	pane := wrapper_bridge_prompt_pane(cfg)
	if strings.trim_space(pane) == "" do return
	msg := strings.concatenate({"New message from ", sender, " — run './.heimdall/bin/ham-ctl agent chat read' to view."})
	_ = tmux.send_text(pane, msg, true)
}

wrapper_bridge_deliver_task_nudge_push :: proc(cfg: Bridge_Runtime_Config, line: string) {
	task_id := extract_json_string(line, "task_id", "unknown")
	target_role := extract_json_string(line, "target_role", "participant")
	pane := wrapper_bridge_prompt_pane(cfg)
	if strings.trim_space(pane) == "" do return
	msg := strings.concatenate({"Nudge: you have been nudged on ", task_id, " (", target_role, "). Run './.heimdall/bin/ham-ctl tasks list' and complete your assignment."})
	_ = tmux.send_text(pane, msg, true)
}
wrapper_bridge_deliver_startup_prompt :: proc(cfg: Bridge_Runtime_Config) {
	pane := wrapper_bridge_prompt_pane(cfg)
	if strings.trim_space(pane) == "" do return
	msg := "Heimdall is still waiting for startup acknowledgement. If you are ready, run './.heimdall/bin/ham-ctl agent start-success'."
	_ = tmux.send_text(pane, msg, true)
}

wrapper_bridge_prompt_pane :: proc(cfg: Bridge_Runtime_Config) -> string {
	pane := cfg.pane_id
	if strings.trim_space(pane) == "" do pane = os.get_env_alloc("TMUX_PANE", context.allocator)
	return pane
}
