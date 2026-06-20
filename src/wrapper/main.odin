package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import http "odin_test:lib/http_client"
import tmux "odin_test:lib/tmux"
import ws "odin_test:lib/ws"

main :: proc() {
	if has_flag(os.args, "--version") {
		fmt.println("ham-wrapper", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
		return
	}
	if has_flag(os.args, "--help") || has_flag(os.args, "-h") {
		print_usage()
		return
	}

	if has_flag(os.args, "--detach") {
		start_detached(os.args)
		return
	}

	config_path := cfg_lib.config_path_from_args(os.args)
	loaded, ok := cfg_lib.load(config_path)
	if !ok {
		fmt.println("failed to load config", config_path)
		return
	}

	cfg := loaded.config.wrapper
	selected_agent := option_value(os.args, "--agent", cfg.default_agent)
	if selected_agent == "" do selected_agent = cfg.agent_name
	requested_agent_token := option_value(os.args, "--agent-token", "")
	raw_agent_identity := agent_identity_from_args(os.args, cfg.agent_name)
	agent_class, agent_instance_id, identity_ok := parse_agent_identity(raw_agent_identity)
	if !identity_ok {
		fmt.println("invalid agent identity; use class or class@suffix with only letters, numbers, and dash in each part")
		return
	}

	agent_cmd, agent_cmd_ok := selected_agent_command(cfg, selected_agent)
	window_name := wrapper_window_name(cfg.tmux_window_prefix, agent_instance_id)
	cwd := resolve_agent_run_dir(cfg, agent_cmd, agent_cmd_ok, selected_agent, agent_instance_id)

	if !handle_existing_agent_window(cfg.tmux_session, window_name) {
		return
	}

	display_name := option_value(os.args, "--display-name", template_display_name(cfg.display_name, agent_class, agent_instance_id, selected_agent))

	response, health_ok := http.get(cfg.daemon_url, contracts.ROUTE_HEALTH)
	if !health_ok || response.status != 200 {
		fmt.println("daemon is not reachable; start ham-daemon first")
		return
	}

	register_body := register_request_json(agent_class, agent_instance_id, display_name, requested_agent_token)
	register_response, register_ok := http.post(cfg.daemon_url, contracts.ROUTE_REGISTER, register_body)
	if !register_ok || register_response.status != 200 {
		fmt.println("registration failed")
		if register_ok {
			fmt.println("registration_status", register_response.status)
			fmt.println("registration_response", register_response.body)
		}
		return
	}

	fmt.println("ham-wrapper", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("config", loaded.path)
	fmt.println("daemon_url", cfg.daemon_url)
	fmt.println("agent_class", agent_class)
	fmt.println("agent_instance_id", agent_instance_id)
	fmt.println("selected_agent", selected_agent)
	fmt.println("display_name", display_name)
	fmt.println("daemon_health", response.body)
	fmt.println("registered", register_response.body)

	registered_instance_id := extract_json_string(register_response.body, "agent_instance_id", "")
	conversation_id := extract_json_string(register_response.body, "conversation_id", "")
	ws_url := extract_json_string(register_response.body, "ws_url", "")
	agent_token := extract_json_string(register_response.body, "agent_token", "")
	if registered_instance_id == "" {
		fmt.println("registration response missing agent_instance_id")
		return
	}
	if ws_url == "" {
		fmt.println("registration response missing ws_url")
		return
	}

	fmt.println("starting tmux agent")
	fmt.println("tmux_session", cfg.tmux_session)
	fmt.println("tmux_window", window_name)
	fmt.println("working_dir", cwd)

	if agent_cmd_ok && agent_cmd.bootstrap_enabled {
		generate_bootstrap_files(cwd, cfg, agent_cmd, selected_agent, registered_instance_id, display_name, cfg.daemon_url, agent_token)
	}

	command := build_agent_command(cfg, selected_agent, cfg.daemon_url, registered_instance_id, display_name, conversation_id, agent_token)
	launch, launch_ok := tmux.ensure_agent_window(cfg.tmux_session, window_name, cwd, command)
	if !launch_ok {
		fmt.println("failed to launch or find tmux window")
		return
	}
	fmt.println("tmux_pane", launch.pane_id)
	if agent_cmd_ok {
		report_startup_status(cfg.daemon_url, registered_instance_id, "starting", "launch", "Agent process launched in tmux", selected_agent, cwd, launch.pane_id)
		result := startup_probe_agent(agent_cmd.startup_detection, launch.pane_id)
		if result.status != "disabled" {
			fmt.println("startup_status", result.status)
			if result.reason_code != "" do fmt.println("startup_reason_code", result.reason_code)
			if result.safe_diagnostic != "" do fmt.println("startup_diagnostic", result.safe_diagnostic)
			report_startup_status(cfg.daemon_url, registered_instance_id, result.status, result.reason_code, result.safe_diagnostic, selected_agent, cwd, launch.pane_id)
		}
	}

	ws_conn, ws_ok := ws.connect(ws_url)
	if ws_ok {
		fmt.println("ws connected", ws_url)
	} else {
		fmt.println("ws connection failed", ws_url)
	}

	heartbeat_loop(cfg.daemon_url, agent_class, registered_instance_id, display_name, agent_token, launch.pane_id, &ws_conn)
}

Startup_Probe_Result :: struct {
	status: string,
	reason_code: string,
	safe_diagnostic: string,
}

startup_probe_agent :: proc(cfg: cfg_lib.Startup_Detection_Config, pane_id: string) -> Startup_Probe_Result {
	if !cfg.enabled do return Startup_Probe_Result{status = "disabled"}
	if pane_id == "" do return Startup_Probe_Result{status = "startup_failed", reason_code = "missing_pane", safe_diagnostic = "tmux pane was not available for startup detection"}

	probe_seconds := cfg.startup_probe_seconds
	if probe_seconds <= 0 do probe_seconds = 15
	interval_ms := cfg.capture_interval_ms
	if interval_ms <= 0 do interval_ms = 500
	deadline := time.to_unix_nanoseconds(time.now()) + i64(probe_seconds) * i64(time.Second)
	probe_sent := false
	echo_seen := cfg.probe_prompt == "" || !cfg.probe_expect_echo

	for time.to_unix_nanoseconds(time.now()) <= deadline {
		if !tmux.pane_exists(pane_id) do return Startup_Probe_Result{status = "startup_failed", reason_code = "pane_exited", safe_diagnostic = "tmux pane exited during startup detection"}
		if cfg.probe_prompt != "" && !probe_sent {
			_ = tmux.send_line(pane_id, cfg.probe_prompt)
			probe_sent = true
		}
		pane_text, ok := tmux.capture_pane_text(pane_id, 80)
		if !ok do return Startup_Probe_Result{status = "startup_failed", reason_code = "capture_failed", safe_diagnostic = "tmux pane capture failed during startup detection"}
		if cfg.probe_expect_echo && cfg.probe_prompt != "" && strings.index(pane_text, cfg.probe_prompt) >= 0 do echo_seen = true
		if idx := first_matching_pattern(pane_text, cfg.blocked_patterns); idx >= 0 {
			return Startup_Probe_Result{status = "startup_blocked", reason_code = startup_reason_code("blocked", idx, cfg.blocked_patterns[idx]), safe_diagnostic = startup_safe_diagnostic(cfg, idx, "Startup blocked by configured provider prompt")}
		}
		if echo_seen {
			if idx := first_matching_pattern(pane_text, cfg.ready_patterns); idx >= 0 {
				return Startup_Probe_Result{status = "ready", reason_code = startup_reason_code("ready", idx, cfg.ready_patterns[idx]), safe_diagnostic = "Startup ready pattern matched"}
			}
		}
		time.sleep(time.Duration(interval_ms) * time.Millisecond)
	}

	if cfg.probe_expect_echo && cfg.probe_prompt != "" && !echo_seen {
		return Startup_Probe_Result{status = "startup_unknown", reason_code = "probe_echo_missing", safe_diagnostic = "Startup probe echo was not observed"}
	}
	status := "startup_unknown"
	if cfg.startup_unknown_is_blocked do status = "startup_blocked"
	return Startup_Probe_Result{status = status, reason_code = "no_pattern_matched", safe_diagnostic = "No configured startup pattern matched before timeout"}
}

first_matching_pattern :: proc(text: string, patterns: []string) -> int {
	for pattern, i in patterns {
		if pattern == "" do continue
		if strings.index(text, pattern) >= 0 do return i
	}
	return -1
}

startup_reason_code :: proc(prefix: string, idx: int, pattern: string) -> string {
	code := strings.builder_make()
	strings.write_string(&code, prefix)
	strings.write_string(&code, "_")
	strings.write_string(&code, fmt.tprintf("%d", idx))
	for ch in pattern {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9':
			strings.write_rune(&code, ch)
		case ' ', '-', '_':
			strings.write_string(&code, "_")
		case:
		}
	}
	return strings.to_string(code)
}

startup_safe_diagnostic :: proc(cfg: cfg_lib.Startup_Detection_Config, idx: int, fallback: string) -> string {
	if idx >= 0 && idx < len(cfg.sanitized_reason_mapping) {
		entry := cfg.sanitized_reason_mapping[idx]
		if eq := strings.index_byte(entry, '='); eq >= 0 && eq < len(entry) - 1 do return entry[eq + 1:]
		if entry != "" do return entry
	}
	return fallback
}

report_startup_status :: proc(daemon_url, agent_instance_id, status, reason_code, safe_diagnostic, provider_profile, run_dir, tmux_pane: string) {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"agent_instance_id":"`); json_write_string(&builder, agent_instance_id)
	strings.write_string(&builder, `","startup_status":"`); json_write_string(&builder, status)
	strings.write_string(&builder, `","reason_code":"`); json_write_string(&builder, reason_code)
	strings.write_string(&builder, `","safe_diagnostic":"`); json_write_string(&builder, safe_diagnostic)
	strings.write_string(&builder, `","provider_profile":"`); json_write_string(&builder, provider_profile)
	strings.write_string(&builder, `","run_dir":"`); json_write_string(&builder, run_dir)
	strings.write_string(&builder, `","tmux_pane":"`); json_write_string(&builder, tmux_pane)
	strings.write_string(&builder, `"}`)
	_, _ = http.post(daemon_url, "/startup", strings.to_string(builder))
}

handle_existing_agent_window :: proc(tmux_session, window_name: string) -> bool {
	existing_pane := tmux.pane_for_window(tmux_session, window_name)
	if existing_pane == "" do return true

	fmt.println("agent tmux window already exists")
	fmt.println("tmux_session", tmux_session)
	fmt.println("tmux_window", window_name)
	fmt.println("tmux_target", fmt.tprintf("%s:%s", tmux_session, window_name))
	fmt.println("tmux_pane", existing_pane)
	fmt.println("close_command", fmt.tprintf("tmux kill-window -t '%s:%s'", tmux_session, window_name))
	fmt.print("Close existing tmux window and continue? [y/N]: ")

	if !read_yes_from_stdin() {
		fmt.println("not closing existing window; aborting before registration")
		return false
	}

	if !tmux.kill_window(tmux_session, window_name) {
		fmt.println("failed to close existing tmux window; aborting before registration")
		return false
	}

	fmt.println("closed existing tmux window; continuing")
	return true
}

read_yes_from_stdin :: proc() -> bool {
	buf: [16]byte
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n == 0 do return false
	answer := strings.trim_space(string(buf[:n]))
	return answer == "y" || answer == "Y" || answer == "yes" || answer == "YES"
}

heartbeat_loop :: proc(daemon_url, agent_class, agent_instance_id, display_name, agent_token, tmux_pane: string, ws_conn: ^ws.Connection) {
	fmt.println("heartbeat started", agent_instance_id)
	failed_heartbeats := 0
	for {
		if !tmux.pane_exists(tmux_pane) {
			fmt.println("agent tmux pane missing; stopping wrapper", tmux_pane)
			return
		}

		body := heartbeat_request_json(agent_instance_id, tmux_pane)
		response, ok := http.post(daemon_url, contracts.ROUTE_HEARTBEAT, body)
		if ok && response.status == 200 {
			failed_heartbeats = 0
			fmt.println("heartbeat ok", agent_instance_id)
		} else {
			failed_heartbeats += 1
			fmt.println("heartbeat failed", agent_instance_id)
		}

		if failed_heartbeats >= 3 {
			fmt.println("heartbeat failed repeatedly; re-registering", agent_instance_id)
			if new_ws_url, reconnected := reregister_and_reconnect_ws(daemon_url, agent_class, agent_instance_id, display_name, agent_token, ws_conn); reconnected {
				fmt.println("reconnected", agent_instance_id, new_ws_url)
				failed_heartbeats = 0
			} else {
				fmt.println("reconnect attempt failed", agent_instance_id)
			}
		}

		if text, got_message := ws.poll_text(ws_conn); got_message {
			if strings.index(text, `"type":"duplicate_check"`) >= 0 {
				// internal control message; do not surface as an agent message
			} else if strings.index(text, `"type":"message_event"`) >= 0 {
				fmt.println("message event", text)
				handle_message_event(text, tmux_pane)
			} else if strings.index(text, `"type":"task_event"`) >= 0 {
				fmt.println("task event", text)
				handle_task_event(text, tmux_pane, agent_instance_id)
			} else if strings.index(text, `"type":"memory_event"`) >= 0 {
				fmt.println("memory event", text)
				handle_memory_event(text, tmux_pane, agent_instance_id)
			} else if strings.index(text, `"type":"user_chat_event"`) >= 0 {
				fmt.println("user chat event", text)
				handle_user_chat_event(text, tmux_pane)
			} else {
				fmt.println("ws message", text)
			}
		}
		time.sleep(5 * time.Second)
	}
}

handle_message_event :: proc(text, tmux_pane: string) {
	if strings.index(text, `"event":"messages_available"`) < 0 do return

	pending_count := extract_json_int(text, "pending_count", 1)
	from_agent_instance_id := extract_json_string(text, "from_agent_instance_id", "unknown")
	if pending_count <= 0 do pending_count = 1

	line := fmt.tprintf("%d Unread Messages from %s.", pending_count, from_agent_instance_id)
	if tmux.send_line(tmux_pane, line) {
		fmt.println("notified agent pane", line)
	} else {
		fmt.println("failed to notify agent pane", line)
	}
}

handle_task_event :: proc(text, tmux_pane, agent_instance_id: string) {
	task_id := extract_json_string(text, "task_id", "unknown")
	status := extract_json_string(text, "status", "updated")
	changed_by := extract_json_string(text, "changed_by", "unknown")
	if changed_by == agent_instance_id {
		fmt.println("suppressed self-authored task event", task_id, status, changed_by)
		return
	}
	body := extract_json_string(text, "body", "")
	line := ""
	if body != "" {
		line = fmt.tprintf("Task %s %s by %s: %s", task_id, status, changed_by, body)
	} else {
		line = fmt.tprintf("Task %s %s by %s.", task_id, status, changed_by)
	}
	escape_prefix := strings.index(text, `"send_escape_prefix":true`) >= 0 || strings.index(body, "delivery=escape_prefixed_pane_or_ws") >= 0
	if tmux.send_line_with_escape(tmux_pane, line, escape_prefix) {
		fmt.println("notified agent pane", line)
	} else {
		fmt.println("failed to notify agent pane", line)
	}
}

handle_memory_event :: proc(text, tmux_pane, agent_instance_id: string) {
	changed_by := extract_json_string(text, "changed_by", "unknown")
	if changed_by == agent_instance_id {
		fmt.println("suppressed self-authored memory event", extract_json_string(text, "memory_id", ""), changed_by)
		return
	}
	event := extract_json_string(text, "event", "memory_updated")
	memory_id := extract_json_string(text, "memory_id", "unknown")
	proposal_id := extract_json_string(text, "proposal_id", "")
	subject_agent := extract_json_string(text, "subject_agent", "")
	status := extract_json_string(text, "status", "")
	line := fmt.tprintf("Memory %s %s by %s for %s (%s). Fetch details with: ./bin/ham-ctl --config ./config.toml memory show --token <your token> --memory-id %s", memory_id, event, changed_by, subject_agent, status, memory_id)
	if proposal_id != "" && (status == "pending" || strings.index(event, "Proposed") >= 0) {
		line = fmt.tprintf("Memory proposal %s %s by %s for %s. Review with: ./bin/ham-ctl --config ./config.toml memory history --token <your token> --memory-id %s", proposal_id, event, changed_by, subject_agent, memory_id)
	}
	if tmux.send_line(tmux_pane, line) {
		fmt.println("notified agent pane", line)
	} else {
		fmt.println("failed to notify agent pane", line)
	}
}

handle_user_chat_event :: proc(text, tmux_pane: string) {
	user_id := extract_json_string(text, "user_id", "unknown")
	pending_count := extract_json_int(text, "pending_count", 1)
	if pending_count <= 0 do pending_count = 1
	line := fmt.tprintf("%d User Chat Messages from %s. Read with: ./bin/ham-ctl --config ./config.toml chat fetch-user --token <your token> --user-id %s", pending_count, user_id, user_id)
	if tmux.send_line(tmux_pane, line) {
		fmt.println("notified agent pane", line)
	} else {
		fmt.println("failed to notify agent pane", line)
	}
}

reregister_and_reconnect_ws :: proc(daemon_url, agent_class, agent_instance_id, display_name, agent_token: string, ws_conn: ^ws.Connection) -> (string, bool) {
	response, health_ok := http.get(daemon_url, contracts.ROUTE_HEALTH)
	if !health_ok || response.status != 200 do return "", false

	register_body := register_request_json(agent_class, agent_instance_id, display_name, agent_token)
	register_response, register_ok := http.post(daemon_url, contracts.ROUTE_REGISTER, register_body)
	if !register_ok || register_response.status != 200 {
		if register_ok {
			fmt.println("re-registration failed", register_response.status, register_response.body)
		}
		return "", false
	}

	new_ws_url := extract_json_string(register_response.body, "ws_url", "")
	if new_ws_url == "" do return "", false

	ws.close(ws_conn)
	new_conn, ws_ok := ws.connect(new_ws_url)
	if !ws_ok do return new_ws_url, false
	ws_conn^ = new_conn
	return new_ws_url, true
}

heartbeat_request_json :: proc(agent_instance_id, tmux_pane: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"agent_instance_id\":\"")
	strings.write_string(&builder, agent_instance_id)
	strings.write_string(&builder, "\",\"tmux_pane\":\"")
	strings.write_string(&builder, tmux_pane)
	strings.write_string(&builder, "\"}")
	return strings.to_string(builder)
}

extract_json_string :: proc(body, key, fallback: string) -> string {
	pattern := fmt.tprintf("\"%s\":\"", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback

	start := idx + len(pattern)
	end := strings.index_byte(body[start:], '"')
	if end < 0 do return fallback

	return json_unescape(body[start:start + end])
}

json_unescape :: proc(value: string) -> string {
	builder := strings.builder_make()
	escaped := false
	for ch in value {
		if escaped {
			switch ch {
			case 'n': strings.write_rune(&builder, '\n')
			case 'r': strings.write_rune(&builder, '\r')
			case 't': strings.write_rune(&builder, '\t')
			case '"': strings.write_rune(&builder, '"')
			case '\\': strings.write_rune(&builder, '\\')
			case: strings.write_rune(&builder, ch)
			}
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	if escaped do strings.write_rune(&builder, '\\')
	return strings.to_string(builder)
}

json_write_string :: proc(builder: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(builder, "\\\\")
		case '"': strings.write_string(builder, "\\\"")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case: strings.write_rune(builder, ch)
		}
	}
}

extract_json_int :: proc(body, key: string, fallback: int) -> int {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	end := start
	for end < len(body) {
		ch := body[end]
		if ch < '0' || ch > '9' do break
		end += 1
	}
	if end == start do return fallback
	parsed, ok := strconv.parse_int(body[start:end])
	if !ok do return fallback
	return int(parsed)
}

start_detached :: proc(args: []string) {
	child_args := make([dynamic]string)
	append(&child_args, args[0])
	for i := 1; i < len(args); i += 1 {
		if args[i] == "--detach" do continue
		append(&child_args, args[i])
	}

	process, err := os.process_start(os.Process_Desc{command = child_args[:]})
	if err != nil {
		fmt.println("failed to detach wrapper")
		return
	}
	fmt.println("detached ham-wrapper pid", process.handle)
}

has_flag :: proc(args: []string, flag: string) -> bool {
	for arg in args {
		if arg == flag do return true
	}
	return false
}

print_usage :: proc() {
	fmt.println("ham-wrapper", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("usage: ham-wrapper [--config <path>] [--agent <name>] [--agent-token <token>] [--detach] [--version] [--help] [agent|agent@suffix]")
}

resolve_working_dir :: proc(path: string) -> string {
	expanded := cfg_lib.expand_home(path)
	absolute, err := os.get_absolute_path(expanded, context.allocator)
	if err != nil do return expanded
	return absolute
}

selected_agent_command :: proc(cfg: cfg_lib.Wrapper_Config, selected_agent: string) -> (cfg_lib.Agent_Command_Config, bool) {
	name := selected_agent
	if name == "" do name = command_name_for_agent(cfg.command, cfg.agent_name)
	for agent_cmd in cfg.agent_commands {
		if agent_cmd.name == name do return agent_cmd, true
	}
	return cfg_lib.Agent_Command_Config{}, false
}

resolve_agent_run_dir :: proc(cfg: cfg_lib.Wrapper_Config, agent_cmd: cfg_lib.Agent_Command_Config, agent_cmd_ok: bool, selected_agent, agent_instance_id: string) -> string {
	if agent_cmd_ok && agent_cmd.run_dir != "" {
		cwd := resolve_working_dir(agent_cmd.run_dir)
		_ = os.make_directory_all(cwd)
		return cwd
	}

	root := cfg.agent_run_dir
	if agent_cmd_ok && agent_cmd.agent_run_dir != "" do root = agent_cmd.agent_run_dir
	if root == "" do return resolve_working_dir(cfg.working_dir)

	project := cfg.project
	if agent_cmd_ok && agent_cmd.project != "" do project = agent_cmd.project
	if project == "" do project = "default"

	agent_name := agent_instance_id
	if agent_name == "" do agent_name = selected_agent
	if agent_name == "" do agent_name = cfg.agent_name

	base := resolve_working_dir(root)
	cwd := join_path3(base, safe_slug(project), safe_slug(agent_name))
	_ = os.make_directory_all(cwd)
	return cwd
}

join_path3 :: proc(a, b, c: string) -> string {
	sep := "/"
	left := a
	if strings.has_suffix(left, "/") do sep = ""
	return strings.concatenate({left, sep, b, "/", c})
}

safe_slug :: proc(value: string) -> string {
	builder := strings.builder_make()
	last_dash := false
	for i in 0..<len(value) {
		ch := value[i]
		valid := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')
		if valid {
			strings.write_byte(&builder, ch)
			last_dash = false
		} else if !last_dash {
			strings.write_byte(&builder, '-')
			last_dash = true
		}
	}
	slug := strings.to_string(builder)
	slug = strings.trim(slug, "-")
	if slug == "" do return "unnamed"
	if slug == "." || slug == ".." do return "unnamed"
	return slug
}

BOOTSTRAP_HEADER :: "<!-- HEIMDALL-MANAGED-BOOTSTRAP v1: safe to overwrite -->"
BOOTSTRAP_MANIFEST :: ".heimdall-bootstrap-manifest"

generate_bootstrap_files :: proc(cwd: string, cfg: cfg_lib.Wrapper_Config, agent_cmd: cfg_lib.Agent_Command_Config, selected_agent, agent_instance_id, display_name, daemon_url, agent_token: string) {
	profile := bootstrap_profile(agent_cmd, selected_agent)
	files := agent_cmd.bootstrap_files
	if len(files) == 0 {
		files = default_bootstrap_files(profile)
	}
	cleanup_removed_bootstrap_files(cwd, files)
	memory_templates := agent_cmd.memory_templates
	if len(memory_templates) == 0 do memory_templates = cfg.memory_templates
	memory_context := active_memory_bootstrap(daemon_url, agent_token, agent_instance_id, memory_templates)
	project_context := project_bootstrap_context(daemon_url, agent_token, cfg, agent_cmd)
	for file_name in files {
		if !safe_relative_path(file_name) do continue
		path := join_path(cwd, file_name)
		if !can_write_managed_file(path) do continue
		content := bootstrap_file_content(file_name, profile, agent_cmd.bootstrap_sections, selected_agent, agent_instance_id, display_name, daemon_url, memory_context, project_context)
		write_managed_file(path, content)
	}
	write_manifest(cwd, files)
}

cleanup_removed_bootstrap_files :: proc(cwd: string, files: []string) {
	manifest_path := join_path(cwd, BOOTSTRAP_MANIFEST)
	data, err := os.read_entire_file(manifest_path, context.allocator)
	if err != nil do return
	lines := strings.split(string(data), "\n")
	for line in lines {
		name := strings.trim_space(line)
		if name == "" || name == BOOTSTRAP_HEADER do continue
		if !safe_relative_path(name) do continue
		keep := false
		for file_name in files {
			if file_name == name { keep = true; break }
		}
		if keep do continue
		path := join_path(cwd, name)
		if file_has_managed_header(path) {
			_ = os.remove(path)
		}
	}
}

write_manifest :: proc(cwd: string, files: []string) {
	builder := strings.builder_make()
	strings.write_string(&builder, BOOTSTRAP_HEADER); strings.write_string(&builder, "\n")
	for file_name in files {
		if safe_relative_path(file_name) {
			strings.write_string(&builder, file_name); strings.write_string(&builder, "\n")
		}
	}
	write_managed_file(join_path(cwd, BOOTSTRAP_MANIFEST), strings.to_string(builder))
}

can_write_managed_file :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return true
	return strings.has_prefix(string(data), BOOTSTRAP_HEADER)
}

file_has_managed_header :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	return strings.has_prefix(string(data), BOOTSTRAP_HEADER)
}

write_managed_file :: proc(path, content: string) {
	parent := parent_dir(path)
	if parent != "" do _ = os.make_directory_all(parent)
	tmp := strings.concatenate({path, ".tmp"})
	if os.write_entire_file(tmp, content) == nil {
		_ = os.rename(tmp, path)
	}
}

bootstrap_file_content :: proc(file_name, profile: string, sections: []string, selected_agent, agent_instance_id, display_name, daemon_url, memory_context, project_context: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, BOOTSTRAP_HEADER); strings.write_string(&builder, "\n")
	strings.write_string(&builder, bootstrap_title(file_name, profile)); strings.write_string(&builder, "\n\n")
	if bootstrap_section_enabled(sections, "identity") {
		strings.write_string(&builder, "- Display name: "); strings.write_string(&builder, display_name); strings.write_string(&builder, "\n")
		strings.write_string(&builder, "- Agent instance: "); strings.write_string(&builder, agent_instance_id); strings.write_string(&builder, "\n")
		strings.write_string(&builder, "- Provider/profile: "); strings.write_string(&builder, selected_agent); strings.write_string(&builder, " / "); strings.write_string(&builder, profile); strings.write_string(&builder, "\n")
		strings.write_string(&builder, "- Daemon URL: "); strings.write_string(&builder, daemon_url); strings.write_string(&builder, "\n")
		strings.write_string(&builder, "- This file is generated by Heimdall and is overwritten on agent start. Unmanaged files are preserved.\n")
	}
	if bootstrap_section_enabled(sections, "guidance") do strings.write_string(&builder, bootstrap_profile_guidance(profile, file_name))
	if bootstrap_section_enabled(sections, "project") && project_context != "" do strings.write_string(&builder, project_context)
	if bootstrap_section_enabled(sections, "memory") && memory_context != "" do strings.write_string(&builder, memory_context)
	return strings.to_string(builder)
}

bootstrap_profile :: proc(agent_cmd: cfg_lib.Agent_Command_Config, selected_agent: string) -> string {
	if agent_cmd.bootstrap_profile != "" do return agent_cmd.bootstrap_profile
	name := selected_agent
	if name == "" do name = agent_cmd.name
	if name == "claude" || strings.has_prefix(name, "claude-") do return "claude"
	if name == "codex" || strings.has_prefix(name, "codex-") do return "codex"
	return "pi"
}

default_bootstrap_files :: proc(profile: string) -> []string {
	files := make([]string, 1)
	if profile == "claude" {
		files[0] = "CLAUDE.md"
	} else {
		files[0] = "AGENTS.md"
	}
	return files
}

bootstrap_title :: proc(file_name, profile: string) -> string {
	if strings.has_suffix(file_name, "CLAUDE.md") || profile == "claude" do return "# Claude bootstrap for Heimdall AI Manager"
	if profile == "codex" do return "# Codex AGENTS.md bootstrap for Heimdall AI Manager"
	return "# Agent bootstrap for Heimdall AI Manager"
}

bootstrap_profile_guidance :: proc(profile, file_name: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "\n# Heimdall Tooling\n")
	strings.write_string(&builder, "- Use repo-local `./bin/ham-ctl --config ./config.toml ...` for Heimdall task, chat, project, and memory workflows when available.\n")
	strings.write_string(&builder, "- Track non-trivial/verifiable work in Heimdall tasks; keep status current and request review when complete.\n")
	if profile == "claude" {
		strings.write_string(&builder, "- Claude profile: this generated `CLAUDE.md` is the primary local instruction file. Keep tool/reference notes concise and fetch details through Heimdall CLI/RPC when needed.\n")
	} else if profile == "codex" {
		strings.write_string(&builder, "- Codex profile: this generated `AGENTS.md` follows repository-agent instruction conventions. Prefer scoped, auditable edits and run relevant validation before handoff.\n")
	} else {
		strings.write_string(&builder, "- Pi profile: this generated `AGENTS.md` is the primary run-directory instruction file. Read inbox/task state before beginning new work.\n")
	}
	return strings.to_string(builder)
}

bootstrap_section_enabled :: proc(sections: []string, section: string) -> bool {
	if len(sections) == 0 do return true
	for item in sections {
		if item == section || item == "all" do return true
	}
	return false
}

project_bootstrap_context :: proc(daemon_url, agent_token: string, cfg: cfg_lib.Wrapper_Config, agent_cmd: cfg_lib.Agent_Command_Config) -> string {
	project_id := agent_cmd.project
	if project_id == "" do project_id = cfg.project
	if project_id == "" do return ""
	request := strings.builder_make()
	strings.write_string(&request, `{"agent_token":"`); json_write_string(&request, agent_token)
	strings.write_string(&request, `","project_id":"`); json_write_string(&request, project_id)
	strings.write_string(&request, `"}`)
	response, ok := http.post(daemon_url, "/projects/show", strings.to_string(request))
	if ok && response.status == 200 {
		formatted := format_project_bootstrap(response.body)
		if formatted != "" do return formatted
	}
	builder := strings.builder_make()
	strings.write_string(&builder, "\n\n# Project Context\n")
	strings.write_string(&builder, "Configured project: "); strings.write_string(&builder, project_id); strings.write_string(&builder, "\n")
	strings.write_string(&builder, "Project anchors are optional context only; do not infer source cwd from them unless explicitly instructed.\n")
	return strings.to_string(builder)
}

format_project_bootstrap :: proc(body: string) -> string {
	start := strings.index(body, `"project":`)
	if start < 0 do return ""
	obj_start_rel := strings.index(body[start:], `{`)
	if obj_start_rel < 0 do return ""
	obj_start := start + obj_start_rel
	obj_end := json_object_end(body, obj_start)
	if obj_end <= obj_start do return ""
	object := body[obj_start:obj_end]
	project_id := extract_json_string(object, "project_id", "")
	name := extract_json_string(object, "name", "")
	description := extract_json_string(object, "description", "")
	builder := strings.builder_make()
	strings.write_string(&builder, "\n\n# Project Context\n")
	if name != "" { strings.write_string(&builder, "Project: "); strings.write_string(&builder, name); strings.write_string(&builder, "\n") }
	if project_id != "" { strings.write_string(&builder, "Project ID: "); strings.write_string(&builder, project_id); strings.write_string(&builder, "\n") }
	if description != "" { strings.write_string(&builder, "Description: "); strings.write_string(&builder, description); strings.write_string(&builder, "\n") }
	strings.write_string(&builder, "Anchors are loose metadata only; do not over-interpret them as mandatory cwd/git/agent links.\n")
	idx := 0
	wrote_anchors := false
	for {
		start_rel := strings.index(object[idx:], `{"type":"`)
		if start_rel < 0 do break
		anchor_start := idx + start_rel
		anchor_end := json_object_end(object, anchor_start)
		if anchor_end <= anchor_start do break
		anchor := object[anchor_start:anchor_end]
		if !wrote_anchors { strings.write_string(&builder, "Anchors:\n"); wrote_anchors = true }
		strings.write_string(&builder, "- "); strings.write_string(&builder, extract_json_string(anchor, "type", "anchor")); strings.write_string(&builder, ": "); strings.write_string(&builder, extract_json_string(anchor, "value", ""))
		note := extract_json_string(anchor, "note", "")
		if note != "" { strings.write_string(&builder, " — "); strings.write_string(&builder, note) }
		strings.write_string(&builder, "\n")
		idx = anchor_end
	}
	return strings.to_string(builder)
}

safe_relative_path :: proc(path: string) -> bool {
	if path == "" do return false
	if strings.has_prefix(path, "/") do return false
	parts := strings.split(path, "/")
	for part in parts {
		if part == "" || part == "." || part == ".." do return false
	}
	return true
}

join_path :: proc(a, b: string) -> string {
	if strings.has_suffix(a, "/") do return strings.concatenate({a, b})
	return strings.concatenate({a, "/", b})
}

parent_dir :: proc(path: string) -> string {
	last := -1
	for i in 0..<len(path) {
		if path[i] == '/' do last = i
	}
	if last <= 0 do return ""
	return path[:last]
}

wrapper_window_name :: proc(prefix, agent_instance_id: string) -> string {
	if prefix == "" do return agent_instance_id
	return fmt.aprintf("%s-%s", prefix, agent_instance_id)
}

template_display_name :: proc(display_name, agent_class, agent_instance_id, selected_agent: string) -> string {
	if display_name == "" do return agent_instance_id
	templated := replace_all(display_name, "{agent_class}", agent_class)
	templated = replace_all(templated, "{agent}", selected_agent)
	templated = replace_all(templated, "{agent_instance_id}", agent_instance_id)
	templated = replace_all(templated, "{instance}", agent_instance_id)
	return templated
}

build_agent_command :: proc(cfg: cfg_lib.Wrapper_Config, selected_agent, daemon_url, agent_instance_id, display_name, conversation_id, agent_token: string) -> []string {
	agent_command_name := selected_agent
	if agent_command_name == "" do agent_command_name = command_name_for_agent(cfg.command, cfg.agent_name)
	for agent_cmd in cfg.agent_commands {
		if agent_cmd.name == agent_command_name {
			base := agent_cmd.command
			if len(base) == 0 do base = cfg.command
			count := len(base) + len(agent_cmd.yolo_flags) + len(agent_cmd.prompt_flags)
			if agent_cmd.starter_prompt != "" do count += 1
			result := make([dynamic]string, 0, count)
			append_templated_args(&result, base, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
			append_templated_args(&result, agent_cmd.yolo_flags, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
			append_templated_args(&result, agent_cmd.prompt_flags, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
			if agent_cmd.starter_prompt != "" {
				prompt := template_string(agent_cmd.starter_prompt, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
				templates := agent_cmd.memory_templates
				if len(templates) == 0 do templates = cfg.memory_templates
				prompt = strings.concatenate({prompt, memory_cli_guidance(agent_token), active_memory_bootstrap(daemon_url, agent_token, agent_instance_id, templates)})
				append(&result, prompt)
			}
			return result[:]
		}
	}
	return template_command(cfg.command, daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
}

memory_cli_guidance :: proc(agent_token: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "\n\n# Memory CLI\n")
	strings.write_string(&builder, "Use repo-local ./bin/ham-ctl memory commands with your token for durable memory proposals and review. Approved active memory is what affects runtime behavior; pending, rejected, and archived proposals do not. Template memories are reusable starter memory for configured agents/roles and follow the same propose/approve/version/archive/rollback lifecycle. Proposal reason/evidence are proposal-only review metadata and should not be copied into runtime memory bodies. Skill memories must use structured body text with at least name: and description:.\n")
	strings.write_string(&builder, "Examples: ./bin/ham-ctl --config ./config.toml memory propose new --token "); strings.write_string(&builder, agent_token); strings.write_string(&builder, " --subject-agent <agent> --type fact|habit|episode|expertise|skill|template --title <title> --body <body> --reason <why> --evidence <task-or-source>; ./bin/ham-ctl --config ./config.toml memory propose edit --token "); strings.write_string(&builder, agent_token); strings.write_string(&builder, " --memory-id <id> --expected-version <n> --title <title> --body <body> --reason <why> --evidence <source>; ./bin/ham-ctl --config ./config.toml memory propose archive --token "); strings.write_string(&builder, agent_token); strings.write_string(&builder, " --memory-id <id> --expected-version <n> --reason <why> --evidence <source>; ./bin/ham-ctl --config ./config.toml memory propose rollback --token "); strings.write_string(&builder, agent_token); strings.write_string(&builder, " --memory-id <id> --expected-version <n> --reason <why> --evidence <source>.\n")
	strings.write_string(&builder, "Review/query: ./bin/ham-ctl --config ./config.toml memory decide --token "); strings.write_string(&builder, agent_token); strings.write_string(&builder, " --proposal-id <proposal_id> --decision approve|reject; ./bin/ham-ctl --config ./config.toml memory list --token "); strings.write_string(&builder, agent_token); strings.write_string(&builder, " --status active|pending|archived|rejected|all; ./bin/ham-ctl --config ./config.toml memory show --token "); strings.write_string(&builder, agent_token); strings.write_string(&builder, " --memory-id <id>; ./bin/ham-ctl --config ./config.toml memory history --token "); strings.write_string(&builder, agent_token); strings.write_string(&builder, " --memory-id <id>.\n")
	return strings.to_string(builder)
}

active_memory_bootstrap :: proc(daemon_url, agent_token, agent_instance_id: string, memory_templates: []string) -> string {
	builder := strings.builder_make()
	if len(memory_templates) > 0 {
		all_request := strings.builder_make()
		strings.write_string(&all_request, `{"agent_token":"`); json_write_string(&all_request, agent_token)
		strings.write_string(&all_request, `","action":"memory_list","status":"active"}`)
		all_response, all_ok := http.post(daemon_url, contracts.ROUTE_AGENT_RPC, strings.to_string(all_request))
		if all_ok && all_response.status == 200 {
			strings.write_string(&builder, format_active_memory_bootstrap(all_response.body, memory_templates, true))
		}
	}
	request := strings.builder_make()
	strings.write_string(&request, `{"agent_token":"`); json_write_string(&request, agent_token)
	strings.write_string(&request, `","action":"memory_list","subject_agent":"`); json_write_string(&request, agent_instance_id)
	strings.write_string(&request, `","status":"active"}`)
	response, ok := http.post(daemon_url, contracts.ROUTE_AGENT_RPC, strings.to_string(request))
	if ok && response.status == 200 do strings.write_string(&builder, format_active_memory_bootstrap(response.body, nil, false))
	return strings.to_string(builder)
}

format_active_memory_bootstrap :: proc(body: string, memory_templates: []string, templates_only: bool) -> string {
	builder := strings.builder_make()
	wrote_header := false
	wrote_skills := false
	idx := 0
	for {
		start_rel := strings.index(body[idx:], `{"memory_id":"`)
		if start_rel < 0 do break
		start := idx + start_rel
		end := json_object_end(body, start)
		if end <= start do break
		object := body[start:end]
		status := extract_json_string(object, "status", "")
		type_text := extract_json_string(object, "type", "fact")
		if status == "active" && (!templates_only || (type_text == "template" && memory_template_matches(object, memory_templates))) {
			if !wrote_header {
				if templates_only {
					strings.write_string(&builder, "\n\n# Active Approved Memory Templates\nOnly configured, approved active template memories are included here; pending, rejected, and archived templates are excluded.\n")
				} else {
					strings.write_string(&builder, "\n\n# Active Approved Memory\nOnly active approved memory is included here; pending, rejected, and archived proposals are excluded.\n")
				}
				wrote_header = true
			}
			title := extract_json_string(object, "title", "")
			memory_body := extract_json_string(object, "body", "")
			if type_text == "skill" {
				if !wrote_skills {
					strings.write_string(&builder, "\n## Skills\n")
					wrote_skills = true
				}
				strings.write_string(&builder, "\n### "); strings.write_string(&builder, title); strings.write_string(&builder, "\n")
				strings.write_string(&builder, memory_body); strings.write_string(&builder, "\n")
			} else {
				strings.write_string(&builder, "\n- "); strings.write_string(&builder, type_text); strings.write_string(&builder, ": ")
				if title != "" { strings.write_string(&builder, title); strings.write_string(&builder, " — ") }
				strings.write_string(&builder, memory_body); strings.write_string(&builder, "\n")
			}
		}
		idx = end
	}
	if !wrote_header do return ""
	return strings.to_string(builder)
}

memory_template_matches :: proc(object: string, memory_templates: []string) -> bool {
	memory_id := extract_json_string(object, "memory_id", "")
	title := extract_json_string(object, "title", "")
	scope := extract_json_string(object, "scope", "")
	for item in memory_templates {
		if item == memory_id || item == title || item == scope do return true
	}
	return false
}

json_object_end :: proc(body: string, start: int) -> int {
	depth := 0
	in_string := false
	escaped := false
	for i := start; i < len(body); i += 1 {
		ch := body[i]
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
			if depth == 0 do return i + 1
		}
	}
	return -1
}

command_name_for_agent :: proc(command: []string, agent_class: string) -> string {
	if len(command) > 0 do return command[0]
	if strings.has_suffix(agent_class, "-agent") do return agent_class[:len(agent_class) - len("-agent")]
	return agent_class
}

append_templated_args :: proc(result: ^[dynamic]string, args: []string, daemon_url, agent_instance_id, display_name, conversation_id, agent_token: string) {
	for arg in args {
		append(result, template_string(arg, daemon_url, agent_instance_id, display_name, conversation_id, agent_token))
	}
}

template_command :: proc(command: []string, daemon_url, agent_instance_id, display_name, conversation_id, agent_token: string) -> []string {
	result := make([]string, len(command))
	for i in 0..<len(command) {
		result[i] = template_string(command[i], daemon_url, agent_instance_id, display_name, conversation_id, agent_token)
	}
	return result
}

template_string :: proc(value, daemon_url, agent_instance_id, display_name, conversation_id, agent_token: string) -> string {
	templated := replace_all(value, "{daemon_url}", daemon_url)
	templated = replace_all(templated, "{agent_instance_id}", agent_instance_id)
	templated = replace_all(templated, "{display_name}", display_name)
	templated = replace_all(templated, "{instance}", agent_instance_id)
	templated = replace_all(templated, "{conversation_id}", conversation_id)
	templated = replace_all(templated, "{agent_token}", agent_token)
	templated = replace_all(templated, "{token}", agent_token)
	return templated
}

replace_all :: proc(value, needle, replacement: string) -> string {
	if needle == "" do return strings.clone(value)
	builder := strings.builder_make()
	start := 0
	for {
		idx := strings.index(value[start:], needle)
		if idx < 0 do break
		strings.write_string(&builder, value[start:start + idx])
		strings.write_string(&builder, replacement)
		start = start + idx + len(needle)
	}
	strings.write_string(&builder, value[start:])
	return strings.to_string(builder)
}

register_request_json :: proc(agent_class, agent_instance_id, display_name: string, agent_token := "") -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"protocol_version\":1")
	strings.write_string(&builder, ",\"agent_class\":\"")
	strings.write_string(&builder, agent_class)
	strings.write_string(&builder, "\",\"agent_instance_id\":\"")
	strings.write_string(&builder, agent_instance_id)
	strings.write_string(&builder, "\",\"display_name\":\"")
	strings.write_string(&builder, display_name)
	if agent_token != "" {
		strings.write_string(&builder, "\",\"agent_token\":\"")
		strings.write_string(&builder, agent_token)
	}
	strings.write_string(&builder, "\"}")
	return strings.to_string(builder)
}

parse_agent_identity :: proc(raw: string) -> (agent_class: string, agent_instance_id: string, ok: bool) {
	at := strings.index_byte(raw, '@')
	class := raw
	suffix := "default"
	if at >= 0 {
		class = raw[:at]
		suffix = raw[at + 1:]
	}

	if !valid_agent_id_part(class) || !valid_agent_id_part(suffix) {
		return "", "", false
	}

	return strings.clone(class), fmt.aprintf("%s@%s", class, suffix), true
}

valid_agent_id_part :: proc(id: string) -> bool {
	if len(id) == 0 do return false
	for ch in id {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-':
			continue
		case:
			return false
		}
	}
	return true
}

option_value :: proc(args: []string, name, fallback: string) -> string {
	for i := 0; i + 1 < len(args); i += 1 {
		if args[i] == name do return args[i + 1]
	}
	return fallback
}

agent_identity_from_args :: proc(args: []string, fallback: string) -> string {
	for i := 1; i < len(args); i += 1 {
		if args[i] == cfg_lib.CONFIG_PATH_FLAG || args[i] == "--agent" || args[i] == "--agent-token" {
			i += 1
			continue
		}
		if args[i] == "--detach" do continue
		return args[i]
	}
	return fallback
}
