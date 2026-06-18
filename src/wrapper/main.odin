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
		fmt.println("bc-agent-wrapper", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
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

	window_name := wrapper_window_name(cfg.tmux_window_prefix, agent_instance_id)
	cwd := resolve_working_dir(cfg.working_dir)

	if !handle_existing_agent_window(cfg.tmux_session, window_name) {
		return
	}

	response, health_ok := http.get(cfg.daemon_url, contracts.ROUTE_HEALTH)
	if !health_ok || response.status != 200 {
		fmt.println("daemon is not reachable; start bc-odin-daemon first")
		return
	}

	register_body := register_request_json(agent_class, agent_instance_id, cfg.display_name, requested_agent_token)
	register_response, register_ok := http.post(cfg.daemon_url, contracts.ROUTE_REGISTER, register_body)
	if !register_ok || register_response.status != 200 {
		fmt.println("registration failed")
		if register_ok {
			fmt.println("registration_status", register_response.status)
			fmt.println("registration_response", register_response.body)
		}
		return
	}

	fmt.println("bc-agent-wrapper", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("config", loaded.path)
	fmt.println("daemon_url", cfg.daemon_url)
	fmt.println("agent_class", agent_class)
	fmt.println("agent_instance_id", agent_instance_id)
	fmt.println("selected_agent", selected_agent)
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

	command := build_agent_command(cfg, selected_agent, cfg.daemon_url, registered_instance_id, conversation_id, agent_token)
	launch, launch_ok := tmux.ensure_agent_window(cfg.tmux_session, window_name, cwd, command)
	if !launch_ok {
		fmt.println("failed to launch or find tmux window")
		return
	}
	fmt.println("tmux_pane", launch.pane_id)

	ws_conn, ws_ok := ws.connect(ws_url)
	if ws_ok {
		fmt.println("ws connected", ws_url)
	} else {
		fmt.println("ws connection failed", ws_url)
	}

	heartbeat_loop(cfg.daemon_url, agent_class, registered_instance_id, cfg.display_name, agent_token, launch.pane_id, &ws_conn)
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
				handle_task_event(text, tmux_pane)
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

handle_task_event :: proc(text, tmux_pane: string) {
	task_id := extract_json_string(text, "task_id", "unknown")
	status := extract_json_string(text, "status", "updated")
	line := fmt.tprintf("Task %s %s.", task_id, status)
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
	line := fmt.tprintf("%d User Chat Messages from %s.", pending_count, user_id)
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

	return strings.clone(body[start:start + end])
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
	fmt.println("detached bc-agent-wrapper pid", process.handle)
}

has_flag :: proc(args: []string, flag: string) -> bool {
	for arg in args {
		if arg == flag do return true
	}
	return false
}

print_usage :: proc() {
	fmt.println("bc-agent-wrapper", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("usage: bc-agent-wrapper [--config <path>] [--agent <name>] [--agent-token <token>] [--detach] [--version] [--help] [agent|agent@suffix]")
}

resolve_working_dir :: proc(path: string) -> string {
	absolute, err := os.get_absolute_path(path, context.allocator)
	if err != nil do return path
	return absolute
}

wrapper_window_name :: proc(prefix, agent_instance_id: string) -> string {
	if prefix == "" do return agent_instance_id
	return fmt.aprintf("%s-%s", prefix, agent_instance_id)
}

build_agent_command :: proc(cfg: cfg_lib.Wrapper_Config, selected_agent, daemon_url, agent_instance_id, conversation_id, agent_token: string) -> []string {
	agent_command_name := selected_agent
	if agent_command_name == "" do agent_command_name = command_name_for_agent(cfg.command, cfg.agent_name)
	for agent_cmd in cfg.agent_commands {
		if agent_cmd.name == agent_command_name {
			base := agent_cmd.command
			if len(base) == 0 do base = cfg.command
			count := len(base) + len(agent_cmd.yolo_flags) + len(agent_cmd.prompt_flags)
			if agent_cmd.starter_prompt != "" do count += 1
			result := make([dynamic]string, 0, count)
			append_templated_args(&result, base, daemon_url, agent_instance_id, conversation_id, agent_token)
			append_templated_args(&result, agent_cmd.yolo_flags, daemon_url, agent_instance_id, conversation_id, agent_token)
			append_templated_args(&result, agent_cmd.prompt_flags, daemon_url, agent_instance_id, conversation_id, agent_token)
			if agent_cmd.starter_prompt != "" {
				append(&result, template_string(agent_cmd.starter_prompt, daemon_url, agent_instance_id, conversation_id, agent_token))
			}
			return result[:]
		}
	}
	return template_command(cfg.command, daemon_url, agent_instance_id, conversation_id, agent_token)
}

command_name_for_agent :: proc(command: []string, agent_class: string) -> string {
	if len(command) > 0 do return command[0]
	if strings.has_suffix(agent_class, "-agent") do return agent_class[:len(agent_class) - len("-agent")]
	return agent_class
}

append_templated_args :: proc(result: ^[dynamic]string, args: []string, daemon_url, agent_instance_id, conversation_id, agent_token: string) {
	for arg in args {
		append(result, template_string(arg, daemon_url, agent_instance_id, conversation_id, agent_token))
	}
}

template_command :: proc(command: []string, daemon_url, agent_instance_id, conversation_id, agent_token: string) -> []string {
	result := make([]string, len(command))
	for i in 0..<len(command) {
		result[i] = template_string(command[i], daemon_url, agent_instance_id, conversation_id, agent_token)
	}
	return result
}

template_string :: proc(value, daemon_url, agent_instance_id, conversation_id, agent_token: string) -> string {
	templated := replace_all(value, "{daemon_url}", daemon_url)
	templated = replace_all(templated, "{agent_instance_id}", agent_instance_id)
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
