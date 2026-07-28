package main

import "core:c"
import "core:fmt"
import "core:net"
import "core:os"
import base64 "core:encoding/base64"
import "core:strings"
import "core:sys/posix"

// ── agent mode: local Bridge endpoint client (RTE2E-7) ───────────────────────
// Agent mode talks ONLY to the local Bridge endpoint over JSONL v1 using the
// local agent token. It never holds or sends a Hub URL or Hub credential; the
// Bridge is the sole runtime process with Hub access and relays on the agent's
// behalf. Endpoint discovery: --bridge-endpoint / HEIMDALL_BRIDGE_ENDPOINT.
// Token discovery: --agent-token / HEIMDALL_AGENT_TOKEN.

ctl_agent_mode :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && cmd[0] == "agent" do idx = 1
	if idx >= len(cmd) || has_flag(args, "--help") || has_flag(args, "-h") || (idx < len(cmd) && cmd[idx] == "help") { print_agent_help(cmd[idx:]); return }
	resource := cmd[idx]
	action := ""
	if idx + 1 < len(cmd) do action = cmd[idx + 1]
	if action == "help" { print_agent_help(cmd[idx:]); return }
	endpoint := agent_mode_endpoint(args)
	token := agent_mode_token(args)
	if endpoint == "" || token == "" {
		fmt.println(`{"ok":false,"message":"agent mode requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint/--agent-token)"}`)
		return
	}
	if resource == "context" { ctl_agentmode_context(endpoint, token, args); return }
	if resource == "start-success" { ctl_agent_call(endpoint, token, "agent.start_success", "{}"); return }
	if resource == "agents" || resource == "instances" { ctl_agentmode_agents(endpoint, token, action, args); return }
	if resource == "chat" || resource == "chats" { ctl_agentmode_chat(endpoint, token, action, args); return }
	if resource == "tasks" || resource == "task" { ctl_agentmode_tasks(endpoint, token, action, args); return }
	if resource == "artifacts" || resource == "artifact" { ctl_agentmode_artifacts(endpoint, token, action, args); return }
	if resource == "memory" { ctl_agentmode_memory(endpoint, token, action, args); return }
	fmt.println("usage: ham-ctl agent <context|start-success|agents|chat|tasks|artifacts|memory> ...")
}

agent_mode_endpoint :: proc(args: []string) -> string {
	if v := option_value(args, "--bridge-endpoint", ""); v != "" do return v
	if v := os.get_env_alloc("HEIMDALL_BRIDGE_ENDPOINT", context.allocator); v != "" do return v
	return ""
}

agent_mode_token :: proc(args: []string) -> string {
	if v := option_value(args, "--agent-token", ""); v != "" do return v
	if v := os.get_env_alloc("HEIMDALL_AGENT_TOKEN", context.allocator); v != "" do return v
	return ""
}

ctl_agentmode_context :: proc(endpoint, token: string, args: []string) {
	_ = args
	ctl_agent_call(endpoint, token, "agent.context.get", "{}")
}

ctl_agentmode_agents :: proc(endpoint, token, action: string, args: []string) {
	_ = args
	if action == "" || action == "live" || action == "running" { ctl_agent_call(endpoint, token, "agent.agents.live", "{}"); return }
	fmt.println("usage: ham-ctl agent agents <live|running>")
}

ctl_agentmode_chat :: proc(endpoint, token, action: string, args: []string) {
	if action == "" || action == "send" || action == "send-to-user" {
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if body == "" { fmt.println("usage: ham-ctl agent chat send --body <text>"); return }
		ctl_agent_call(endpoint, token, "agent.chat.send_to_user", json_object(json_kv("body", body)))
		return
	}
	if action == "send-to-agent" {
		body := option_value(args, "--body", "")
		to_instance := option_value(args, "--to-instance", option_value(args, "--target-agent-instance-id", ""))
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if body == "" || to_instance == "" { fmt.println("usage: ham-ctl agent chat send-to-agent --to-instance <id> --body <text>"); return }
		ctl_agent_call(endpoint, token, "agent.chat.send_to_agent", json_object(json_kv("to_instance", to_instance), json_kv("body", body)))
		return
	}
	if action == "fetch" || action == "read" || action == "read-messages" {
		ctl_agentmode_chat_fetch(endpoint, token, args)
		return
	}
	if action == "mark-read" {
		ctl_agent_call(endpoint, token, "agent.chat.read", "{}")
		return
	}
	fmt.println("usage: ham-ctl agent chat <send|send-to-agent|fetch|read>")
}

ctl_agentmode_chat_fetch :: proc(endpoint, token: string, args: []string) {
	fields := make([dynamic]string)
	append(&fields, json_kv_raw("limit", option_value(args, "--limit", "50")))
	if cursor := option_value(args, "--since", option_value(args, "--cursor", "")); cursor != "" do append(&fields, json_kv("cursor", cursor))
	ctl_agent_call(endpoint, token, "agent.chat.fetch", json_object_from_slice(fields[:]))
}

ctl_agentmode_tasks :: proc(endpoint, token, action: string, args: []string) {
	if action == "fetch" || action == "read" || action == "context" {
		ctl_agentmode_context(endpoint, token, args)
		return
	}
	if action == "comment" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if task_id == "" || body == "" { fmt.println("usage: ham-ctl agent tasks comment --task-id <id> --body <text>"); return }
		ctl_agent_call(endpoint, token, "agent.tasks.comment", json_object(json_kv("task_id", task_id), json_kv("body", body)))
		return
	}
	if action == "status" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		status := option_value(args, "--status", "")
		if task_id == "" || status == "" { fmt.println("usage: ham-ctl agent tasks status --task-id <id> --status <status>"); return }
		ctl_agent_call(endpoint, token, "agent.tasks.status", json_object(json_kv("task_id", task_id), json_kv("status", status)))
		return
	}
	if action == "vote" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		result := option_value(args, "--result", "")
		if task_id == "" || result == "" { fmt.println("usage: ham-ctl agent tasks vote --task-id <id> --result <lgtm|ngtm>"); return }
		ctl_agent_call(endpoint, token, "agent.tasks.vote", json_object(json_kv("task_id", task_id), json_kv("result", result)))
		return
	}
	if action == "nudge" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		message := option_value(args, "--message", option_value(args, "--body", ""))
		if task_id == "" { fmt.println("usage: ham-ctl agent tasks nudge --task-id <id> [--message <text>]"); return }
		ctl_agent_call(endpoint, token, "agent.tasks.nudge", json_object(json_kv("task_id", task_id), json_kv("message", message)))
		return
	}
	fmt.println("usage: ham-ctl agent tasks <fetch|comment|status|vote|nudge>")
}

ctl_agentmode_artifacts :: proc(endpoint, token, action: string, args: []string) {
	if action == "" || action == "create" {
		name := option_value(args, "--name", "")
		kind := option_value(args, "--kind", "markdown")
		if name == "" { fmt.println("usage: ham-ctl agent artifacts create --name <name> [--kind <kind>] [--content <text>|--file <path>]"); return }
		content := option_value(args, "--content", "")
		content_base64 := ""
		if file_path := option_value(args, "--file", ""); file_path != "" { data, err := os.read_entire_file(file_path, context.allocator); if err == nil do content_base64 = base64.encode(data) }
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do content_base64 = base64.encode(data) }
		if content == "" do content = ""
		fields := make([dynamic]string)
		append(&fields, json_kv("name", name)); append(&fields, json_kv("kind", kind))
		if content_base64 != "" { append(&fields, json_kv("content_base64", content_base64)) } else { append(&fields, json_kv("content", content)) }
		if ct := option_value(args, "--content-type", ""); ct != "" do append(&fields, json_kv("content_type", ct))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", desc))
		ctl_agent_call(endpoint, token, "agent.artifacts.create", json_object_from_slice(fields[:]))
		return
	}
	fmt.println("usage: ham-ctl agent artifacts <create>")
}

ctl_agentmode_memory :: proc(endpoint, token, action: string, args: []string) {
	if action == "" || action == "propose" {
		mem_type := option_value(args, "--type", "")
		title := option_value(args, "--title", "")
		if mem_type == "" || title == "" { fmt.println("usage: ham-ctl agent memory propose --type <type> --title <title> [--body <text>] [--evidence <text>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("type", mem_type)); append(&fields, json_kv("title", title)); append(&fields, json_kv("body", option_value(args, "--body", "")))
		if ev := option_value(args, "--evidence", ""); ev != "" do append(&fields, json_kv("evidence", ev))
		ctl_agent_call(endpoint, token, "agent.memory.propose", json_object_from_slice(fields[:]))
		return
	}
	fmt.println("usage: ham-ctl agent memory <propose>")
}

ctl_agent_call :: proc(endpoint, token, method, params_json: string) {
	response, ok := ctl_agent_local_call(endpoint, token, method, params_json)
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	fmt.println(response)
}

// JSONL v1 local endpoint client. Sends one request line, reads one response
// line. Supports unix:<path> (primary, §12.0.2) and tcp:<host>:<port> (fallback).
ctl_agent_local_call :: proc(endpoint, token, method, params_json: string) -> (string, bool) {
	request := ctl_agent_jsonl_request(token, method, params_json)
	if strings.has_prefix(endpoint, "tcp:") do return ctl_agent_send_tcp(endpoint, request)
	if strings.has_prefix(endpoint, "unix:") do return ctl_agent_send_unix(endpoint, request)
	return "", false
}

ctl_agent_jsonl_request :: proc(token, method, params_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"v":1,"id":"ham-ctl-agent","token":"`)
	json_write_string(&b, token)
	strings.write_string(&b, `","method":"`)
	json_write_string(&b, method)
	strings.write_string(&b, `","params":`)
	if strings.trim_space(params_json) == "" { strings.write_string(&b, "{}") } else { strings.write_string(&b, params_json) }
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

ctl_agent_send_tcp :: proc(endpoint, line: string) -> (string, bool) {
	parts := strings.split(endpoint, ":")
	defer delete(parts)
	if len(parts) != 3 do return "", false
	port_i, port_ok := strconv_parse_int_agent(parts[2])
	if !port_ok do return "", false
	address := net.IP4_Loopback
	if parsed, ok := net.parse_ip4_address(parts[1]); ok do address = parsed
	socket, err := net.dial_tcp(address, int(port_i))
	if err != nil do return "", false
	defer net.close(socket)
	_, send_err := net.send_tcp(socket, transmute([]byte)line)
	if send_err != nil do return "", false
	buf: [8192]byte
	n, _ := net.recv_tcp(socket, buf[:])
	if n <= 0 do return "", false
	return string(buf[:n]), true
}

ctl_agent_send_unix :: proc(endpoint, line: string) -> (string, bool) {
	path := strings.trim_prefix(endpoint, "unix:")
	if strings.trim_space(path) == "" || len(path) + 1 > len(posix.sockaddr_un{}.sun_path) do return "", false
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return "", false
	defer posix.close(fd)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD || ODIN_OS == .Haiku {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for i in 0..<len(path) do addr.sun_path[i] = c.char(path[i])
	addr.sun_path[len(path)] = 0
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK do return "", false
	bytes := transmute([]byte)line
	if posix.send(fd, raw_data(bytes), c.size_t(len(bytes)), {}) < 0 do return "", false
	buf: [8192]byte
	n := posix.recv(fd, raw_data(buf[:]), c.size_t(len(buf)), {})
	if n <= 0 do return "", false
	return string(buf[:n]), true
}

strconv_parse_int_agent :: proc(value: string) -> (int, bool) {
	result := 0
	if value == "" do return 0, false
	for ch in value {
		if ch < '0' || ch > '9' do return 0, false
		result = result * 10 + int(ch - '0')
	}
	return result, true
}

print_agent_help :: proc(cmd: []string) {
	resource := ""
	action := ""
	if len(cmd) > 0 {
		if cmd[0] == "agent" || cmd[0] == "help" {
			if len(cmd) > 1 do resource = cmd[1]
			if len(cmd) > 2 do action = cmd[2]
		} else {
			resource = cmd[0]
			if len(cmd) > 1 do action = cmd[1]
		}
	}
	if resource == "chat" || resource == "chats" { print_agent_chat_help(action); return }
	if resource == "agents" || resource == "instances" { fmt.println("ham-ctl agent agents <live|running>\nPurpose: list live agent instances visible to this agent's owner via the local Bridge.\nExamples:\n  ham-ctl agents live\n  ham-ctl agent agents live"); return }
	if resource == "tasks" || resource == "task" { print_agent_tasks_help(action); return }
	if resource == "artifacts" || resource == "artifact" { print_agent_artifacts_help(action); return }
	if resource == "memory" { print_agent_memory_help(action); return }
	if resource == "context" { fmt.println("ham-ctl agent context\nPurpose: fetch this running instance's compact Hub context snapshot via the local Bridge.\nExample:\n  ham-ctl agent context"); return }
	if resource == "start-success" { fmt.println("ham-ctl agent start-success\nPurpose: signal that this agent instance is ready.\nExample:\n  ham-ctl agent start-success"); return }
	fmt.println("ham-ctl agent — Bridge-local commands for a running agent")
	fmt.println("commands:")
	fmt.println("  context        Fetch instance, conversation, chain, task, and unread summary")
	fmt.println("  start-success  Mark startup ready")
	fmt.println("  chat           Read/send the bound user conversation")
	fmt.println("  agents         List live/running agent instances")
	fmt.println("  tasks          Fetch current task context and comment/status/vote/nudge assigned tasks")
	fmt.println("  artifacts      Create artifacts attached to this instance")
	fmt.println("  memory         Propose memory")
	fmt.println("examples:")
	fmt.println("  ham-ctl agent context")
	fmt.println("  ham-ctl agents live")
	fmt.println("  ham-ctl agent chat read --since 2026-07-27T10:00:00Z")
	fmt.println("  ham-ctl agent chat send --body 'Done; tests pass.'")
}

print_agent_chat_help :: proc(action: string) {
	_ = action
	fmt.println("ham-ctl agent chat <send|send-to-agent|fetch|read>")
	fmt.println("Purpose: read or write this instance's bound conversation through the Bridge.")
	fmt.println("Commands:")
	fmt.println("  send --body <text> | --stdin")
	fmt.println("  send-to-agent --to-instance <id> --body <text> | --stdin")
	fmt.println("  fetch [--since <cursor|timestamp>] [--limit N]")
	fmt.println("  read [--since <cursor|timestamp>] [--limit N]  # fetches user_to_agent and agent_to_agent messages")
	fmt.println("  mark-read  # acknowledges without fetching")
	fmt.println("Examples:")
	fmt.println("  ham-ctl agent chat fetch --since 2026-07-27T10:00:00Z --limit 20")
	fmt.println("  ham-ctl agent chat read --since msg_cursor")
	fmt.println("  ham-ctl agent chat send --body 'I started work.'")
}

print_agent_tasks_help :: proc(action: string) {
	_ = action
	fmt.println("ham-ctl agent tasks <fetch|comment|status|vote|nudge>")
	fmt.println("Purpose: fetch compact current task context or update tasks assigned to/reviewed by this instance.")
	fmt.println("Examples:")
	fmt.println("  ham-ctl agent tasks fetch")
	fmt.println("  ham-ctl agent tasks comment --task-id task_123 --body 'Implemented the fix.'")
	fmt.println("  ham-ctl agent tasks status --task-id task_123 --status in_validation")
	fmt.println("  ham-ctl agent tasks vote --task-id task_123 --result lgtm")
}

print_agent_artifacts_help :: proc(action: string) {
	_ = action
	fmt.println("ham-ctl agent artifacts create --name <name> [--kind <kind>] [--content <text>|--file <path>|--stdin]")
	fmt.println("Purpose: create an artifact scoped to this agent instance.")
	fmt.println("Example:")
	fmt.println("  ham-ctl agent artifacts create --name test-log --kind markdown --file /tmp/test.log")
}

print_agent_memory_help :: proc(action: string) {
	_ = action
	fmt.println("ham-ctl agent memory propose --type <type> --title <title> --body <text> [--evidence <text>]")
	fmt.println("Purpose: propose durable memory for later review.")
	fmt.println("Example:")
	fmt.println("  ham-ctl agent memory propose --type fact --title 'Project test command' --body 'Use nix develop --command odin check src/hub.'")
}
