package main

import "core:fmt"
import "core:os"
import "core:strings"
import http "odin_test:lib/http_client"

ctl_hub_user_mode :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && cmd[0] == "hub" do idx = 1
	if idx >= len(cmd) || has_flag(args, "--help") || has_flag(args, "-h") || (idx < len(cmd) && cmd[idx] == "help") { print_hub_help(cmd[idx:]); return }
	resource := cmd[idx]
	action := ""
	if idx + 1 < len(cmd) do action = cmd[idx + 1]
	if action == "help" { print_hub_help(cmd[idx:]); return }
	hub_url := hub_user_mode_url(args)
	user_token := hub_user_mode_token(args)
	if hub_url == "" || user_token == "" { fmt.println(`{"ok":false,"message":"hub mode requires --hub-url and --user-token (or HAM_HUB_URL/HEIMDALL_HUB_URL and HAM_HUB_USER_TOKEN/HEIMDALL_USER_TOKEN)"}`); return }
	base := strings.trim_right(hub_url, "/")
	if resource == "me" { ctl_hub_request(base, user_token, "GET", "/api/v1/me", ""); return }
	if resource == "health" { ctl_hub_request(base, user_token, "GET", "/api/v1/health", ""); return }
	if resource == "agents" { ctl_hub_agents(base, user_token, action, args); return }
	if resource == "launch" { ctl_hub_launch(base, user_token, args); return }
	if resource == "chats" { ctl_hub_chats(base, user_token, action, args); return }
	if resource == "tasks" { ctl_hub_tasks(base, user_token, action, args); return }
	if resource == "task-chains" { ctl_hub_task_chains(base, user_token, action, args); return }
	fmt.println("usage: ham-ctl hub <me|health|agents|launch|chats|tasks|task-chains> ...")
}

ctl_hub_agents :: proc(base, token, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(base, token, "GET", "/api/v1/agents", ""); return }
	if action == "create" {
		name := option_value(args, "--name", "")
		if name == "" { fmt.println("usage: ham-ctl hub agents create --name <name> [--slug <slug>] [--template <id>] [--provider <profile>] [--tier <tier>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("name", name)); append(&fields, json_kv("slug", option_value(args, "--slug", name))); append(&fields, json_kv("template_id", option_value(args, "--template", ""))); append(&fields, json_kv("default_provider", option_value(args, "--provider", ""))); append(&fields, json_kv("default_tier", option_value(args, "--tier", ""))); append(&fields, json_kv("instructions", option_value(args, "--instructions", "")))
		ctl_hub_request(base, token, "POST", "/api/v1/agents", json_object_from_slice(fields[:]))
		return
	}
	fmt.println("usage: ham-ctl hub agents <list|create>")
}

ctl_hub_launch :: proc(base, token: string, args: []string) {
	agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
	if agent_id == "" { fmt.println("usage: ham-ctl hub launch --agent-id <agent_id> [--bridge-id <bridge_id>] [--provider <profile>] [--tier <tier>] [--project-id <id>] [--chain-id <id>]"); return }
	fields := make([dynamic]string)
	append(&fields, json_kv("agent_id", agent_id)); append(&fields, json_kv("bridge_id", option_value(args, "--bridge-id", ""))); append(&fields, json_kv("provider", option_value(args, "--provider", ""))); append(&fields, json_kv("tier", option_value(args, "--tier", ""))); append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", "")))); append(&fields, json_kv("chain_id", option_value(args, "--chain-id", option_value(args, "--chain", ""))))
	ctl_hub_request(base, token, "POST", "/api/v1/agent-instances", json_object_from_slice(fields[:]))
}

ctl_hub_chats :: proc(base, token, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(base, token, "GET", "/api/v1/chats", ""); return }
	if action == "create" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		instance_id := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", ""))
		if agent_id == "" && instance_id == "" { fmt.println("usage: ham-ctl hub chats create --agent-id <agent_id>|--agent-instance-id <id> [--body <text>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("agent_id", agent_id)); append(&fields, json_kv("agent_instance_id", instance_id)); append(&fields, json_kv("bridge_id", option_value(args, "--bridge-id", ""))); append(&fields, json_kv("provider", option_value(args, "--provider", ""))); append(&fields, json_kv("tier", option_value(args, "--tier", ""))); append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", "")))); append(&fields, json_kv("chain_id", option_value(args, "--chain-id", option_value(args, "--chain", "")))); append(&fields, json_kv("title", option_value(args, "--title", "")))
		body := option_value(args, "--body", "")
		if body != "" do append(&fields, strings.concatenate({"\"initial_message\":", json_object(json_kv("body", body))}))
		ctl_hub_request(base, token, "POST", "/api/v1/chats", json_object_from_slice(fields[:]))
		return
	}
	if action == "send" {
		cid := option_value(args, "--conversation-id", option_value(args, "--chat-id", ""))
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if cid == "" || body == "" { fmt.println("usage: ham-ctl hub chats send --conversation-id <id> --body <text>"); return }
		ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/chats/%s/messages", safe_path_part(cid)), json_object(json_kv("body", body)))
		return
	}
	if action == "messages" || action == "fetch" {
		cid := option_value(args, "--conversation-id", option_value(args, "--chat-id", ""))
		if cid == "" { fmt.println("usage: ham-ctl hub chats messages --conversation-id <id>"); return }
		ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/chats/%s/messages", safe_path_part(cid)), "")
		return
	}
	fmt.println("usage: ham-ctl hub chats <list|create|send|messages>")
}

ctl_hub_task_chains :: proc(base, token, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(base, token, "GET", "/api/v1/task-chains", ""); return }
	if action == "create" {
		title := option_value(args, "--title", "")
		if title == "" { fmt.println("usage: ham-ctl hub task-chains create --title <title>"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("title", title)); append(&fields, json_kv("kind", option_value(args, "--kind", "team_work"))); append(&fields, json_kv("coordinator_agent_id", option_value(args, "--coordinator-agent-id", option_value(args, "--coordinator", "")))); append(&fields, json_kv("bridge_id", option_value(args, "--bridge-id", ""))); append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", ""))))
		ctl_hub_request(base, token, "POST", "/api/v1/task-chains", json_object_from_slice(fields[:]))
		return
	}
	chain_id := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if chain_id == "" { fmt.println("usage: ham-ctl hub task-chains <show|publish|complete> --chain-id <id>"); return }
	if action == "show" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), ""); return }
	if action == "publish" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/publish", safe_path_part(chain_id)), "{}"); return }
	if action == "complete" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/complete", safe_path_part(chain_id)), "{}"); return }
	fmt.println("usage: ham-ctl hub task-chains <list|create|show|publish|complete>")
}

ctl_hub_tasks :: proc(base, token, action: string, args: []string) {
	chain_id := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if action == "list" {
		if chain_id == "" { fmt.println("usage: ham-ctl hub tasks list --chain-id <id>"); return }
		ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks", safe_path_part(chain_id)), ""); return
	}
	if action == "create" {
		title := option_value(args, "--title", "")
		if chain_id == "" || title == "" { fmt.println("usage: ham-ctl hub tasks create --chain-id <id> --title <title>"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("title", title))
		if assignee := option_value(args, "--assignee-agent-instance-id", option_value(args, "--assignee", "")); assignee != "" do append(&fields, strings.concatenate({"\"assignee_ref\":", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", assignee))}))
		ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks", safe_path_part(chain_id)), json_object_from_slice(fields[:])); return
	}
	task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
	if chain_id == "" || task_id == "" { fmt.println("usage: ham-ctl hub tasks <publish|status|nudge> --chain-id <id> --task-id <id>"); return }
	if action == "publish" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/publish", safe_path_part(chain_id), safe_path_part(task_id)), "{}"); return }
	if action == "status" { status := option_value(args, "--status", ""); if status == "" { fmt.println("usage: ham-ctl hub tasks status --chain-id <id> --task-id <id> --status <status>"); return }; ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("status", status))); return }
	if action == "nudge" { message := option_value(args, "--message", option_value(args, "--body", "")); ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/nudge", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("message", message))); return }
	fmt.println("usage: ham-ctl hub tasks <list|create|publish|status|nudge>")
}

hub_user_mode_url :: proc(args: []string) -> string {
	if v := option_value(args, "--hub-url", ""); v != "" do return v
	if v := option_value(args, "--daemon-url", ""); v != "" do return v
	if v := os.get_env_alloc("HAM_HUB_URL", context.allocator); v != "" do return v
	if v := os.get_env_alloc("HEIMDALL_HUB_URL", context.allocator); v != "" do return v
	return ""
}

hub_user_mode_token :: proc(args: []string) -> string {
	if v := option_value(args, "--user-token", ""); v != "" do return v
	if v := option_value(args, "--token", ""); v != "" do return v
	if v := os.get_env_alloc("HAM_HUB_USER_TOKEN", context.allocator); v != "" do return v
	if v := os.get_env_alloc("HEIMDALL_USER_TOKEN", context.allocator); v != "" do return v
	return ""
}

ctl_hub_request :: proc(base, user_token, method, path, body: string) {
	// Preserve any path prefix present in the hub base URL (e.g. when the Hub is
	// served behind a reverse proxy under /heimdall). The HTTP client drops the
	// path from the base URL, so we prepend the prefix to the request path.
	// This makes `ham-ctl hub ... --hub-url http://host/prefix` match `curl`.
	full_path := hub_url_path_prefix_join(base, path)
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", user_token})}}
	response, ok := http.request_with_headers_timeout(method, base, full_path, body, headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok { fmt.println(`{"ok":false,"message":"Hub request failed"}`); return }
	fmt.println(response.body)
}

hub_url_path_prefix :: proc(base: string) -> string {
	url := base
	if strings.has_prefix(url, "https://") {
		url = url[len("https://"):]
	} else if strings.has_prefix(url, "http://") {
		url = url[len("http://"):]
	}
	slash := strings.index_byte(url, '/')
	if slash < 0 do return ""
	return strings.trim_right(url[slash:], "/")
}

hub_url_path_prefix_join :: proc(base, path: string) -> string {
	prefix := hub_url_path_prefix(base)
	if prefix == "" do return path
	return strings.concatenate({prefix, path})
}

print_hub_help :: proc(cmd: []string) {
	resource := ""
	if len(cmd) > 0 {
		if cmd[0] == "hub" || cmd[0] == "help" { if len(cmd) > 1 do resource = cmd[1] } else { resource = cmd[0] }
	}
	if resource == "agents" { fmt.println("ham-ctl hub agents <list|create>\nPurpose: manage durable Hub agent identities.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... agents list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... agents create --name reviewer --tier normal"); return }
	if resource == "launch" { fmt.println("ham-ctl hub launch --agent-id <id> [--bridge-id <id>] [--tier <tier>]\nPurpose: start a new agent instance through Hub/Bridge.\nExample:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... launch --agent-id reviewer --tier normal"); return }
	if resource == "chats" { fmt.println("ham-ctl hub chats <list|create|send|messages>\nPurpose: read/write user chat conversations.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... chats list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... chats send --conversation-id chat_123 --body 'Hello'"); return }
	if resource == "tasks" { fmt.println("ham-ctl hub tasks <list|create|publish|status|nudge> --chain-id <id>\nPurpose: manage Hub task records.\nExample:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... tasks list --chain-id chain_123"); return }
	if resource == "task-chains" { fmt.println("ham-ctl hub task-chains <list|create|show|publish|complete>\nPurpose: manage Hub task chains.\nExample:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... task-chains create --title 'Fix bug'"); return }
	fmt.println("ham-ctl hub — Hub /api/v1 user mode; uses Authorization: Bearer only")
	fmt.println("commands:")
	fmt.println("  me           Show authenticated user")
	fmt.println("  health       Check Hub API health")
	fmt.println("  agents       List/create durable agent identities")
	fmt.println("  launch       Start an agent instance")
	fmt.println("  chats        List/create/send/fetch chat")
	fmt.println("  tasks        List/create/update tasks")
	fmt.println("  task-chains  List/create/publish/complete chains")
	fmt.println("examples:")
	fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... me")
	fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... launch --agent-id reviewer")
}
