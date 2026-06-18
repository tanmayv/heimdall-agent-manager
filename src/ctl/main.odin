package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:time"
import "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import http "odin_test:lib/http_client"

main :: proc() {
	if has_flag(os.args, "--version") {
		fmt.println("bc-odinctl", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
		return
	}
	if has_flag(os.args, "--help") || has_flag(os.args, "-h") {
		print_usage(cfg_lib.config_path_from_args(os.args), option_value(os.args, "--daemon-url", ""))
		return
	}

	config_path := cfg_lib.config_path_from_args(os.args)
	loaded, ok := cfg_lib.load(config_path)
	if !ok {
		fmt.println("failed to load config", config_path)
		return
	}

	daemon_url := option_value(os.args, "--daemon-url", loaded.config.ctl.daemon_url)
	cmd := command_tokens(os.args)
	defer delete(cmd)

	if len(cmd) == 0 {
		print_usage(loaded.path, daemon_url)
		return
	}

	if cmd[0] == "health" {
		ctl_health(daemon_url)
		return
	}

	if cmd[0] == "list" || (len(cmd) >= 2 && cmd[0] == "agents" && cmd[1] == "list") {
		ctl_agents_list(daemon_url)
		return
	}

	if cmd[0] == "start" || (len(cmd) >= 2 && cmd[0] == "agents" && cmd[1] == "start") {
		idx := 1
		if cmd[0] == "agents" do idx = 2
		if idx >= len(cmd) {
			fmt.println("usage: bc-odinctl agents start <agent_instance_id>")
			return
		}
		ctl_agents_start(cmd[idx], os.args, config_path, daemon_url, loaded.config.daemon.data_dir)
		return
	}

	if cmd[0] == "send" || (len(cmd) >= 2 && cmd[0] == "messages" && cmd[1] == "send") {
		ctl_send(daemon_url, os.args)
		return
	}

	if cmd[0] == "inbox" || (len(cmd) >= 2 && cmd[0] == "messages" && cmd[1] == "inbox") {
		ctl_inbox(daemon_url, os.args)
		return
	}

	if len(cmd) >= 2 && cmd[0] == "tasks" {
		ctl_tasks(daemon_url, cmd[1], os.args)
		return
	}

	if len(cmd) >= 2 && cmd[0] == "task-chains" {
		ctl_task_chains(daemon_url, cmd[1], os.args)
		return
	}

	if len(cmd) >= 2 && cmd[0] == "users" {
		ctl_users(daemon_url, cmd[1], os.args)
		return
	}

	if len(cmd) >= 2 && cmd[0] == "chat" {
		ctl_chat(daemon_url, cmd[1], os.args)
		return
	}

	print_usage(loaded.path, daemon_url)
}

ctl_health :: proc(daemon_url: string) {
	response, ok := http.get(daemon_url, contracts.ROUTE_HEALTH)
	if !ok {
		fmt.println("daemon health failed")
		return
	}
	fmt.println(response.body)
}

ctl_agents_list :: proc(daemon_url: string) {
	response, ok := http.get(daemon_url, contracts.ROUTE_CLIENTS)
	if !ok {
		fmt.println("client list failed")
		return
	}
	fmt.println(response.body)
}

ctl_agents_start :: proc(agent_instance_id: string, args: []string, config_path, daemon_url, data_dir: string) {
	if has_flag(args, "--remote") {
		ctl_agents_start_remote(agent_instance_id, args, config_path, remote_daemon_url(args, daemon_url))
		return
	}

	health_response, health_ok := http.get(daemon_url, contracts.ROUTE_HEALTH)
	if !health_ok || health_response.status != 200 {
		fmt.println(`{"ok":false,"message":"daemon is not reachable; start bc-odin-daemon first"}`)
		return
	}

	// Do not preflight duplicate status from /clients here. The clients list can
	// contain stale records after a wrapper/terminal crash. Let wrapper -> daemon
	// registration decide active_duplicate using daemon-side liveness checks.
	wrapper_bin := option_value(args, "--wrapper-bin", default_wrapper_bin(args))
	command := make([dynamic]string)
	append(&command, wrapper_bin)
	append(&command, "--config")
	append(&command, config_path)
	if agent := option_value(args, "--agent", ""); agent != "" {
		append(&command, "--agent")
		append(&command, agent)
	}
	agent_token := generate_agent_token()
	append(&command, "--agent-token")
	append(&command, agent_token)
	append(&command, agent_instance_id)

	if has_flag(args, "--detached") {
		start_wrapper_detached(command[:], agent_instance_id, data_dir, agent_token)
		return
	}

	process, err := os.process_start(os.Process_Desc{
		command = command[:],
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
	})
	if err != nil {
		fmt.println(`{"ok":false,"message":"failed to start wrapper; ensure bc-agent-wrapper is on PATH or pass --wrapper-bin"}`)
		return
	}
	_, _ = os.process_wait(process)
}

ctl_agents_start_remote :: proc(agent_instance_id: string, args: []string, config_path, daemon_url: string) {
	health_response, health_ok := http.get(daemon_url, contracts.ROUTE_HEALTH)
	if !health_ok || health_response.status != 200 {
		fmt.println(`{"ok":false,"message":"remote daemon is not reachable"}`)
		return
	}

	request := remote_start_request_json(agent_instance_id, option_value(args, "--agent", ""), config_path)
	response, ok := http.post(daemon_url, contracts.ROUTE_AGENTS_START, request)
	if !ok {
		fmt.println(`{"ok":false,"message":"remote start request failed"}`)
		return
	}
	fmt.println(response.body)
}

ctl_send :: proc(daemon_url: string, args: []string) {
	token := option_value(args, "--token", "")
	target := option_value(args, "--to", "")
	body := option_value(args, "--body", "")
	if has_flag(args, "--stdin") {
		data, err := os.read_entire_file("/dev/stdin", context.allocator)
		if err == nil do body = string(data)
	}
	if token == "" || target == "" || body == "" {
		fmt.println("usage: bc-odinctl send --token <token> --to <agent_instance_id> --body <text>")
		return
	}

	request := send_request_json(token, target, body)
	response, ok := http.post(daemon_url, contracts.ROUTE_AGENT_RPC, request)
	if !ok {
		fmt.println(`{"ok":false,"message":"send request failed"}`)
		return
	}
	fmt.println(response.body)
}

ctl_inbox :: proc(daemon_url: string, args: []string) {
	token := option_value(args, "--token", "")
	limit := option_value(args, "--limit", "100")
	include_read := has_flag(args, "--include-read")
	json_output := has_flag(args, "--json")
	if token == "" {
		fmt.println("usage: bc-odinctl inbox --token <token> [--limit N] [--include-read] [--json]")
		return
	}

	request := inbox_request_json(token, limit, include_read)
	response, ok := http.post(daemon_url, contracts.ROUTE_AGENT_RPC, request)
	if !ok {
		fmt.println(`{"ok":false,"message":"inbox request failed"}`)
		return
	}
	if json_output {
		fmt.println(response.body)
		return
	}
	print_inbox_human(response.body)
}

send_request_json :: proc(token, target, body: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"agent_token":"`)
	json_write_string(&builder, token)
	strings.write_string(&builder, `","action":"send_message","target_agent_instance_id":"`)
	json_write_string(&builder, target)
	strings.write_string(&builder, `","payload":"`)
	json_write_string(&builder, body)
	strings.write_string(&builder, `"}`)
	return strings.to_string(builder)
}

remote_start_request_json :: proc(agent_instance_id, agent, config_path: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"agent_instance_id":"`)
	json_write_string(&builder, agent_instance_id)
	strings.write_string(&builder, `"`)
	if agent != "" {
		strings.write_string(&builder, `,"agent":"`)
		json_write_string(&builder, agent)
		strings.write_string(&builder, `"`)
	}
	if config_path != "" {
		strings.write_string(&builder, `,"config_path":"`)
		json_write_string(&builder, config_path)
		strings.write_string(&builder, `"`)
	}
	strings.write_string(&builder, `}`)
	return strings.to_string(builder)
}

ctl_tasks :: proc(daemon_url, action: string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" { fmt.println("usage: bc-odinctl tasks <list|next|show|log|comment|status|assign|participant|review> --token <token> ..."); return }
	path := ""
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token); strings.write_string(&body, `"`)
	task_id_value := option_value(args, "--task-id", option_value(args, "--task", ""))
	chain_id_value := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if task_id_value != "" { strings.write_string(&body, `,"task_id":"`); json_write_string(&body, task_id_value); strings.write_string(&body, `"`) }
	if chain_id_value != "" { strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, chain_id_value); strings.write_string(&body, `"`) }
	switch action {
	case "list":
		path = "/tasks/list"
	case "next":
		path = "/tasks/next"
	case "show":
		path = "/tasks/show"
	case "log":
		path = "/tasks/log"
	case "comment":
		path = "/tasks/comment"
		strings.write_string(&body, `,"body":"`); json_write_string(&body, option_value(args, "--body", "")); strings.write_string(&body, `"`)
	case "status":
		path = "/tasks/status"
		strings.write_string(&body, `,"status":"`); json_write_string(&body, option_value(args, "--status", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"body":"`); json_write_string(&body, option_value(args, "--body", "")); strings.write_string(&body, `"`)
	case "assign":
		path = "/tasks/assign"
		strings.write_string(&body, `,"agent_instance_id":"`); json_write_string(&body, option_value(args, "--agent-instance-id", "")); strings.write_string(&body, `"`)
	case "participant":
		path = "/tasks/participant"
		strings.write_string(&body, `,"agent_instance_id":"`); json_write_string(&body, option_value(args, "--agent-instance-id", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"role":"`); json_write_string(&body, option_value(args, "--role", "")); strings.write_string(&body, `"`)
	case "review":
		path = "/tasks/review"
		strings.write_string(&body, `,"result":"`); json_write_string(&body, option_value(args, "--result", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"comment":"`); json_write_string(&body, option_value(args, "--comment", "")); strings.write_string(&body, `"`)
	case:
		fmt.println("usage: bc-odinctl tasks <list|next|show|log|comment|status|assign|participant|review>"); return
	}
	strings.write_string(&body, `}`)
	response, ok := http.post(daemon_url, path, strings.to_string(body))
	if !ok { fmt.println(`{"ok":false,"message":"task request failed"}`); return }
	fmt.println(response.body)
}

ctl_task_chains :: proc(daemon_url, action: string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" { fmt.println("usage: bc-odinctl task-chains <status|retry-archives> --token <token> ..."); return }
	path := "/task-chains/retry-archives"
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token); strings.write_string(&body, `"`)
	if action == "status" {
		path = "/task-chains/status"
		strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, option_value(args, "--chain-id", option_value(args, "--chain", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"status":"`); json_write_string(&body, option_value(args, "--status", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"final_summary":"`); json_write_string(&body, option_value(args, "--final-summary", "")); strings.write_string(&body, `"`)
	} else if action == "complete" {
		path = "/task-chains/complete"
		strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, option_value(args, "--chain-id", option_value(args, "--chain", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"summary":"`); json_write_string(&body, option_value(args, "--summary", "")); strings.write_string(&body, `"`)
	} else if action == "show" {
		path = "/task-chains/show"
		strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, option_value(args, "--chain-id", option_value(args, "--chain", ""))); strings.write_string(&body, `"`)
	} else if action != "retry-archives" {
		fmt.println("usage: bc-odinctl task-chains <status|complete|show|retry-archives>"); return
	}
	strings.write_string(&body, `}`)
	response, ok := http.post(daemon_url, path, strings.to_string(body))
	if !ok { fmt.println(`{"ok":false,"message":"task-chain request failed"}`); return }
	fmt.println(response.body)
}

ctl_users :: proc(daemon_url, action: string, args: []string) {
	body := strings.builder_make()
	path := ""
	switch action {
	case "register":
		path = "/user-client/register"
		strings.write_string(&body, `{"user_id":"`); json_write_string(&body, option_value(args, "--user-id", ""))
		strings.write_string(&body, `","client_instance_id":"`); json_write_string(&body, option_value(args, "--client-instance-id", ""))
		strings.write_string(&body, `","client_token":"`); json_write_string(&body, option_value(args, "--token", "")); strings.write_string(&body, `"}`)
	case "heartbeat":
		path = "/user-client/heartbeat"
		strings.write_string(&body, `{"client_instance_id":"`); json_write_string(&body, option_value(args, "--client-instance-id", ""))
		strings.write_string(&body, `","client_token":"`); json_write_string(&body, option_value(args, "--token", "")); strings.write_string(&body, `"}`)
	case "presence":
		path = "/users/presence"
		strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, option_value(args, "--token", "")); strings.write_string(&body, `"}`)
	case:
		fmt.println("usage: bc-odinctl users <register|heartbeat|presence>"); return
	}
	response, ok := http.post(daemon_url, path, strings.to_string(body))
	if !ok { fmt.println(`{"ok":false,"message":"users request failed"}`); return }
	fmt.println(response.body)
}

ctl_chat :: proc(daemon_url, action: string, args: []string) {
	if action == "send-to-user" || action == "fetch-user" {
		ctl_agent_chat(daemon_url, action, args)
		return
	}
	body := strings.builder_make()
	strings.write_string(&body, `{"client_instance_id":"`); json_write_string(&body, option_value(args, "--client-instance-id", ""))
	strings.write_string(&body, `","client_token":"`); json_write_string(&body, option_value(args, "--token", ""))
	strings.write_string(&body, `","action":"`)
	switch action {
	case "list": strings.write_string(&body, "list_chats")
	case "fetch": strings.write_string(&body, "fetch_chat")
	case "send": strings.write_string(&body, "send_to_agent")
	case "mark-read": strings.write_string(&body, "mark_read")
	case:
		fmt.println("usage: bc-odinctl chat <list|fetch|send|mark-read|send-to-user|fetch-user>"); return
	}
	strings.write_string(&body, `"`)
	if agent := option_value(args, "--agent-instance-id", ""); agent != "" { strings.write_string(&body, `,"agent_instance_id":"`); json_write_string(&body, agent); strings.write_string(&body, `"`) }
	if message_id := option_value(args, "--message-id", ""); message_id != "" { strings.write_string(&body, `,"message_id":"`); json_write_string(&body, message_id); strings.write_string(&body, `"`) }
	if text := option_value(args, "--body", ""); text != "" { strings.write_string(&body, `,"body":"`); json_write_string(&body, text); strings.write_string(&body, `"`) }
	strings.write_string(&body, `}`)
	response, ok := http.post(daemon_url, "/user-rpc", strings.to_string(body))
	if !ok { fmt.println(`{"ok":false,"message":"chat request failed"}`); return }
	fmt.println(response.body)
}

ctl_agent_chat :: proc(daemon_url, action: string, args: []string) {
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, option_value(args, "--token", ""))
	strings.write_string(&body, `","user_id":"`); json_write_string(&body, option_value(args, "--user-id", ""))
	if action == "send-to-user" {
		strings.write_string(&body, `","action":"send_to_user","body":"`); json_write_string(&body, option_value(args, "--body", "")); strings.write_string(&body, `"}`)
	} else {
		strings.write_string(&body, `","action":"fetch_user_chat"}`)
	}
	response, ok := http.post(daemon_url, contracts.ROUTE_AGENT_RPC, strings.to_string(body))
	if !ok { fmt.println(`{"ok":false,"message":"agent chat request failed"}`); return }
	fmt.println(response.body)
}

inbox_request_json :: proc(token, limit: string, include_read: bool) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"agent_token":"`)
	json_write_string(&builder, token)
	strings.write_string(&builder, `","action":"fetch_messages","include_read":`)
	if include_read {
		strings.write_string(&builder, "true")
	} else {
		strings.write_string(&builder, "false")
	}
	strings.write_string(&builder, `,"limit":`)
	strings.write_string(&builder, limit)
	strings.write_string(&builder, `}`)
	return strings.to_string(builder)
}

print_inbox_human :: proc(body: string) {
	idx := 0
	printed := false
	for {
		msg_idx := strings.index(body[idx:], `{"id":"`)
		if msg_idx < 0 do break
		start := idx + msg_idx
		end_rel := strings.index(body[start:], `}`)
		if end_rel < 0 do break
		object := body[start:start + end_rel + 1]
		id := extract_json_string(object, "id", "")
		from := extract_json_string(object, "from_agent_instance_id", "")
		message_body := extract_json_string(object, "body", "")
		fmt.println(fmt.tprintf("%s from %s:", id, from))
		fmt.println(message_body)
		printed = true
		idx = start + end_rel + 1
	}
	if !printed do fmt.println("No unread messages.")
}

command_tokens :: proc(args: []string) -> [dynamic]string {
	cmd := make([dynamic]string)
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if arg == cfg_lib.CONFIG_PATH_FLAG || arg == "--daemon-url" || arg == "--wrapper-bin" || arg == "--agent" || arg == "--token" || arg == "--to" || arg == "--body" || arg == "--limit" || arg == "--task-id" || arg == "--task" || arg == "--chain-id" || arg == "--chain" || arg == "--status" || arg == "--agent-instance-id" || arg == "--role" || arg == "--final-summary" || arg == "--summary" || arg == "--user-id" || arg == "--client-instance-id" || arg == "--message-id" || arg == "--result" || arg == "--comment" {
			i += 1
			continue
		}
		if arg == "--remote" {
			if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "--") do i += 1
			continue
		}
		if strings.has_prefix(arg, "--") do continue
		append(&cmd, arg)
	}
	return cmd
}

option_value :: proc(args: []string, name, fallback: string) -> string {
	for i := 0; i + 1 < len(args); i += 1 {
		if args[i] == name do return args[i + 1]
	}
	return fallback
}

has_flag :: proc(args: []string, name: string) -> bool {
	for arg in args {
		if arg == name do return true
	}
	return false
}

remote_daemon_url :: proc(args: []string, fallback: string) -> string {
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--remote" {
			if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "--") {
				return normalize_daemon_url(args[i + 1])
			}
			return fallback
		}
	}
	return fallback
}

normalize_daemon_url :: proc(value: string) -> string {
	if strings.has_prefix(value, "http://") do return value
	return fmt.tprintf("http://%s", value)
}

start_wrapper_detached :: proc(command: []string, agent_instance_id, data_dir, agent_token: string) {
	log_dir := fmt.tprintf("%s/logs", expand_home(data_dir))
	_ = os.make_directory_all(log_dir)
	log_path := fmt.tprintf("%s/wrapper-%s.log", log_dir, safe_path_part(agent_instance_id))

	builder := strings.builder_make()
	strings.write_string(&builder, "nohup")
	for arg in command {
		strings.write_string(&builder, " ")
		strings.write_string(&builder, shell_quote(arg))
	}
	strings.write_string(&builder, " > ")
	strings.write_string(&builder, shell_quote(log_path))
	strings.write_string(&builder, " 2>&1 < /dev/null &")

	state, _, stderr, err := os.process_exec(os.Process_Desc{command = []string{"sh", "-c", strings.to_string(builder)}}, context.allocator)
	if err != nil || !state.success {
		fmt.println(`{"ok":false,"message":"failed to start detached wrapper"}`)
		if len(stderr) > 0 do fmt.println(string(stderr))
		return
	}

	out := strings.builder_make()
	strings.write_string(&out, "{\"ok\":true,\"mode\":\"detached\",\"agent_instance_id\":\"")
	json_write_string(&out, agent_instance_id)
	strings.write_string(&out, "\",\"conversation_id\":\"")
	json_write_string(&out, conversation_id_for_instance(agent_instance_id))
	strings.write_string(&out, "\",\"agent_token\":\"")
	json_write_string(&out, agent_token)
	strings.write_string(&out, "\",\"wrapper_log\":\"")
	json_write_string(&out, log_path)
	strings.write_string(&out, "\"}")
	fmt.println(strings.to_string(out))
}

agent_active_in_clients :: proc(body, agent_instance_id: string) -> bool {
	pattern := fmt.tprintf("\"agent_instance_id\":\"%s\"", agent_instance_id)
	idx := strings.index(body, pattern)
	if idx < 0 do return false
	object_end_rel := strings.index(body[idx:], "}")
	if object_end_rel < 0 do return false
	object := body[idx:idx + object_end_rel]
	return strings.index(object, `"connected":true`) >= 0
}

expand_home :: proc(path: string) -> string {
	if path == "~" {
		home := os.get_env_alloc("HOME", context.allocator)
		if home != "" do return home
	}
	if strings.has_prefix(path, "~/") {
		home := os.get_env_alloc("HOME", context.allocator)
		if home != "" do return fmt.tprintf("%s/%s", home, path[2:])
	}
	return path
}

generate_agent_token :: proc() -> string {
	bytes: [32]byte
	if rand.read(bytes[:]) != len(bytes) {
		// Fallback is still process-local/non-identity-derived; normally rand.read succeeds.
		now := u64(now_unix_ms())
		for i in 0..<len(bytes) {
			bytes[i] = byte((now >> uint((i % 8) * 8)) & 0xff)
		}
	}
	builder := strings.builder_make()
	strings.write_string(&builder, "agt_")
	for b in bytes {
		hex_write_byte(&builder, b)
	}
	return strings.to_string(builder)
}

hex_write_byte :: proc(builder: ^strings.Builder, b: byte) {
	digits := "0123456789abcdef"
	strings.write_byte(builder, digits[int(b >> 4)])
	strings.write_byte(builder, digits[int(b & 0x0f)])
}

now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

safe_path_part :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in value {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '@', '.': strings.write_rune(&builder, ch)
		case: strings.write_string(&builder, "_")
		}
	}
	return strings.to_string(builder)
}

shell_quote :: proc(value: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "'")
	for ch in value {
		if ch == '\'' {
			strings.write_string(&builder, "'\\''")
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	strings.write_string(&builder, "'")
	return strings.to_string(builder)
}

default_wrapper_bin :: proc(args: []string) -> string {
	if len(args) > 0 {
		exe := args[0]
		slash := strings.last_index_byte(exe, '/')
		if slash >= 0 {
			return fmt.tprintf("%s/bc-agent-wrapper", exe[:slash])
		}
	}
	return "bc-agent-wrapper"
}

conversation_id_for_instance :: proc(agent_instance_id: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "conv_")
	for ch in agent_instance_id {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-': strings.write_rune(&builder, ch)
		case: strings.write_string(&builder, "_")
		}
	}
	return strings.to_string(builder)
}

extract_json_string :: proc(body, key, fallback: string) -> string {
	pattern := fmt.tprintf("\"%s\":\"", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	start := idx + len(pattern)
	end := strings.index_byte(body[start:], '"')
	if end < 0 do return fallback
	return body[start:start + end]
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

print_usage :: proc(config_path, daemon_url: string) {
	fmt.println("bc-odinctl", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("config", config_path)
	fmt.println("daemon_url", daemon_url)
	fmt.println("commands:")
	fmt.println("  health")
	fmt.println("  agents list        (alias: list)")
	fmt.println("  agents start <agent_instance_id> [--agent pi|claude] [--detached|--remote [host:port]] [--wrapper-bin path]  (alias: start)")
	fmt.println("  send --token <token> --to <agent_instance_id> --body <text>")
	fmt.println("  send --token <token> --to <agent_instance_id> --stdin")
	fmt.println("  inbox --token <token> [--limit N] [--include-read] [--json]")
	fmt.println("  tasks list")
	fmt.println("  tasks comment --token <token> --task-id <id> [--chain-id <id>] --body <text>")
	fmt.println("  tasks status --token <token> --task-id <id> [--chain-id <id>] --status <status> --body <text>")
	fmt.println("  tasks assign --token <token> --task-id <id> [--chain-id <id>] --agent-instance-id <agent>")
	fmt.println("  tasks participant --token <token> --task-id <id> [--chain-id <id>] --agent-instance-id <agent> --role <role>")
	fmt.println("  tasks review --token <token> --task-id <id> [--chain-id <id>] --result approved|needs_improvements|rejected --comment <text>")
	fmt.println("  task-chains status --token <token> --chain-id <id> --status <status> --final-summary <text>")
	fmt.println("  task-chains complete --token <token> --chain <id> --summary <text>")
	fmt.println("  task-chains show --token <token> --chain-id <id>")
	fmt.println("  task-chains retry-archives --token <token>")
	fmt.println("  users register --user-id <user> --client-instance-id <client> [--token <client_token>]")
	fmt.println("  users heartbeat --client-instance-id <client> --token <client_token>")
	fmt.println("  users presence --token <agent_token>")
	fmt.println("  chat list|fetch|send|mark-read --client-instance-id <client> --token <client_token> [--agent-instance-id <agent>] [--body <text>] [--message-id <id>]")
	fmt.println("  chat send-to-user --token <agent_token> --user-id <user> --body <text>")
	fmt.println("  chat fetch-user --token <agent_token> --user-id <user>")
	fmt.println("global flags: --config <path>, --daemon-url <url>, --version, --help")
}
