package main

import json "core:encoding/json"
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
		fmt.println("ham-ctl", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
		return
	}
	if has_flag(os.args, "--help") || has_flag(os.args, "-h") {
		print_usage(cfg_lib.config_path_from_args(os.args), option_value(os.args, "--daemon-url", ""))
		return
	}

	// Dispatch config-free RPC commands before loading config.
	// These only need --daemon-url and --token — used by agents in sandboxed envs.
	{
		early_cmd := command_tokens(os.args)
		defer delete(early_cmd)
		if len(early_cmd) > 0 {
			early_url := option_value(os.args, "--daemon-url", "http://127.0.0.1:49322")
			if early_cmd[0] == "start-success" {
				ctl_start_success(early_url, os.args)
				return
			}
		}
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

	if cmd[0] == "help" {
		ctl_help(cmd[:])
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

	if len(cmd) >= 2 && cmd[0] == "agents" && cmd[1] == "create" {
		ctl_agents_create(daemon_url, os.args)
		return
	}

	if len(cmd) >= 2 && cmd[0] == "agents" && cmd[1] == "update" {
		ctl_agents_update(daemon_url, os.args)
		return
	}

	if cmd[0] == "start" || (len(cmd) >= 2 && cmd[0] == "agents" && cmd[1] == "start") {
		idx := 1
		if cmd[0] == "agents" do idx = 2
		if idx >= len(cmd) {
			fmt.println("usage: ham-ctl agents start <agent_instance_id>")
			return
		}
		ctl_agents_start(cmd[idx], os.args, config_path, daemon_url)
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

	if len(cmd) >= 2 && cmd[0] == "memory" {
		ctl_memory(daemon_url, cmd[1:], os.args)
		return
	}

	if len(cmd) >= 2 && cmd[0] == "projects" {
		ctl_projects(daemon_url, cmd[1], os.args)
		return
	}

	if len(cmd) >= 2 && cmd[0] == "chains" {
		ctl_chains(daemon_url, cmd[1], os.args)
		return
	}

	if len(cmd) >= 2 && cmd[0] == "teams" {
		ctl_teams(daemon_url, cmd[1], os.args)
		return
	}

	if len(cmd) >= 2 && cmd[0] == "workspace" {
		ctl_workspace(daemon_url, cmd[1], os.args)
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

	if cmd[0] == "start-success" {
		ctl_start_success(daemon_url, os.args)
		return
	}

	print_usage(loaded.path, daemon_url)
}

ctl_help :: proc(cmd: []string) {
	if len(cmd) >= 2 && cmd[1] == "work-guide" {
		fmt.println(strings.trim_space(#load("../prompts/bootstrap_profile_guidance.md", string)))
		return
	}
	fmt.println("usage: ham-ctl help work-guide")
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
	response, ok := http.get(daemon_url, "/agents")
	if !ok {
		fmt.println("agents list failed")
		return
	}
	fmt.println(response.body)
}

ctl_agents_start :: proc(agent_instance_id: string, args: []string, config_path, daemon_url: string) {
	health_response, health_ok := http.get(daemon_url, contracts.ROUTE_HEALTH)
	if !health_ok || health_response.status != 200 {
		fmt.println(`{"ok":false,"message":"daemon is not reachable; start ham-daemon first"}`)
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

ctl_agents_create :: proc(daemon_url: string, args: []string) {
	name := option_value(args, "--name", option_value(args, "--id", ""))
	agent := option_value(args, "--agent", option_value(args, "--provider", "pi"))
	tier := option_value(args, "--tier", "normal")
	display_name := option_value(args, "--display-name", name)
	template_id := option_value(args, "--template", "")
	project_id := option_value(args, "--project", "")

	fields := make([dynamic]string)
	append(&fields, json_kv("agent_instance_id", name))
	append(&fields, json_kv("display_name", display_name))
	append(&fields, json_kv("provider_profile", agent))
	append(&fields, json_kv("template_id", template_id))
	append(&fields, json_kv("project_id", project_id))
	append(&fields, json_kv("model_tier", tier))
	body := fmt.tprintf("{%s}", strings.join(fields[:], ","))
	response, ok := http.post(daemon_url, "/agents/create", body)
	if !ok { fmt.println(`{"ok":false,"message":"create request failed"}`); return }
	fmt.println(response.body)
}

ctl_agents_update :: proc(daemon_url: string, args: []string) {
	agent_instance_id := option_value(args, "--id", "")
	if agent_instance_id == "" { fmt.println("usage: ham-ctl agents update --id <agent_instance_id> [--tier cheap|normal|smart] [--display-name <name>]"); return }

	fields := make([dynamic]string)
	append(&fields, json_kv("agent_instance_id", agent_instance_id))
	if tier := option_value(args, "--tier", ""); tier != "" do append(&fields, json_kv("model_tier", tier))
	if dn := option_value(args, "--display-name", ""); dn != "" do append(&fields, json_kv("display_name", dn))
	if pp := option_value(args, "--provider", ""); pp != "" do append(&fields, json_kv("provider_profile", pp))
	body := fmt.tprintf("{%s}", strings.join(fields[:], ","))
	response, ok := http.post(daemon_url, "/agents/update", body)
	if !ok { fmt.println(`{"ok":false,"message":"update request failed"}`); return }
	fmt.println(response.body)
}

ctl_start_success :: proc(daemon_url: string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" {
		fmt.println("usage: ham-ctl --token <token> start-success")
		os.exit(1)
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"agent_token":"`)
	json_write_string(&builder, token)
	strings.write_string(&builder, `","action":"start_success"}`)
	response, ok := http.post(daemon_url, contracts.ROUTE_AGENT_RPC, strings.to_string(builder))
	if !ok {
		fmt.println(`{"ok":false,"message":"start-success request failed"}`)
		os.exit(1)
	}
	fmt.println(response.body)
	if response.status != 200 {
		os.exit(1)
	}
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
		fmt.println("usage: ham-ctl send --token <token> --to <agent_instance_id> --body <text>")
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
		fmt.println("usage: ham-ctl inbox --token <token> [--limit N] [--include-read] [--json]")
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
	if token == "" { fmt.println("usage: ham-ctl tasks <create|list|next|show|log|comment|comment-resolve|comments|status|update|done|blocked|later|assign|participant|vote|nudge> --token <token> ..."); return }
	path := ""
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token); strings.write_string(&body, `"`)
	task_id_value  := option_value(args, "--task-id", option_value(args, "--task", ""))
	chain_id_value := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if action == "create" && task_id_value != "" {
		fmt.println(`{"ok":false,"message":"task_id is generated by daemon; omit --task-id on create"}`)
		return
	}
	if task_id_value != ""  { strings.write_string(&body, `,"task_id":"`);  json_write_string(&body, task_id_value);  strings.write_string(&body, `"`) }
	if chain_id_value != "" { strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, chain_id_value); strings.write_string(&body, `"`) }
	switch action {
	case "create":
		path = "/tasks/create"
		strings.write_string(&body, `,"title":"`);       json_write_string(&body, option_value(args, "--title", ""));       strings.write_string(&body, `"`)
		strings.write_string(&body, `,"description":"`); json_write_string(&body, option_value(args, "--description", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"status":"`);      json_write_string(&body, option_value(args, "--status", ""));      strings.write_string(&body, `"`)
		strings.write_string(&body, `,"priority":"`);    json_write_string(&body, option_value(args, "--priority", ""));    strings.write_string(&body, `"`)
		strings.write_string(&body, `,"assignee_agent_instance_id":"`);    json_write_string(&body, option_value(args, "--assignee-agent-instance-id", option_value(args, "--assignee", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"depends_on":"`);  json_write_string(&body, option_value(args, "--depends-on", ""));  strings.write_string(&body, `"`)
		if has_flag(args, "--standalone") do strings.write_string(&body, `,"standalone":true`)
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
	case "comment-resolve":
		path = "/tasks/comment-resolve"
		strings.write_string(&body, `,"comment_id":"`); json_write_string(&body, option_value(args, "--comment-id", "")); strings.write_string(&body, `"`)
	case "comments":
		path = "/tasks/comments"
		if has_flag(args, "--unresolved") do strings.write_string(&body, `,"unresolved_only":true`)
	case "status":
		path = "/tasks/status"
		strings.write_string(&body, `,"status":"`); json_write_string(&body, option_value(args, "--status", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"body":"`);   json_write_string(&body, option_value(args, "--body", ""));   strings.write_string(&body, `"`)
	case "update":
		path = "/tasks/update"
		if has_flag(args, "--title") {
			strings.write_string(&body, `,"title":"`); json_write_string(&body, option_value(args, "--title", "")); strings.write_string(&body, `"`)
		}
		if has_flag(args, "--description") {
			strings.write_string(&body, `,"description":"`); json_write_string(&body, option_value(args, "--description", "")); strings.write_string(&body, `"`)
		}
	case "done":
		path = "/tasks/done"
		strings.write_string(&body, `,"body":"`);   json_write_string(&body, option_value(args, "--body", option_value(args, "--comment", "Done.")));   strings.write_string(&body, `"`)
	case "blocked":
		path = "/tasks/blocked"
		strings.write_string(&body, `,"body":"`);   json_write_string(&body, option_value(args, "--body", option_value(args, "--reason", "Blocked.")));   strings.write_string(&body, `"`)
	case "later":
		path = "/tasks/later"
		strings.write_string(&body, `,"body":"`);   json_write_string(&body, option_value(args, "--body", option_value(args, "--reason", "Later/Deferred.")));   strings.write_string(&body, `"`)
	case "assign":
		path = "/tasks/assign"
		strings.write_string(&body, `,"agent_instance_id":"`); json_write_string(&body, option_value(args, "--agent-instance-id", "")); strings.write_string(&body, `"`)
	case "participant":
		path = "/tasks/participant"
		strings.write_string(&body, `,"agent_instance_id":"`); json_write_string(&body, option_value(args, "--agent-instance-id", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"role":"`);              json_write_string(&body, option_value(args, "--role", ""));              strings.write_string(&body, `"`)
	case "vote":
		path = "/tasks/vote"
		strings.write_string(&body, `,"result":"`);  json_write_string(&body, option_value(args, "--result", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"comment":"`); json_write_string(&body, option_value(args, "--comment", "")); strings.write_string(&body, `"`)
	case "nudge":
		path = "/tasks/nudge"
		strings.write_string(&body, `,"body":"`); json_write_string(&body, option_value(args, "--body", "")); strings.write_string(&body, `"`)
	case:
		fmt.println("usage: ham-ctl tasks <create|list|next|show|log|comment|comment-resolve|comments|status|update|done|blocked|later|assign|participant|vote|nudge>"); return
	}
	strings.write_string(&body, `}`)
	response, ok := http.post(daemon_url, path, strings.to_string(body))
	if !ok { fmt.println(`{"ok":false,"message":"task request failed"}`); return }
	fmt.println(response.body)
}

ctl_task_chains :: proc(daemon_url, action: string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" { fmt.println("usage: ham-ctl task-chains <create|activate|update|status|complete|show|retry-archives> --token <token> ..."); return }
	path := "/task-chains/retry-archives"
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token); strings.write_string(&body, `"`)
	if action == "create" {
		path = "/task-chains/create"
		strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, option_value(args, "--chain-id", option_value(args, "--chain", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"project_id":"`); json_write_string(&body, option_value(args, "--project-id", option_value(args, "--project", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"kind":"`); json_write_string(&body, option_value(args, "--kind", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"title":"`); json_write_string(&body, option_value(args, "--title", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"description":"`); json_write_string(&body, option_value(args, "--description", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"status":"`); json_write_string(&body, option_value(args, "--status", "planning")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"coordinator_agent_instance_id":"`); json_write_string(&body, option_value(args, "--coordinator-agent-instance-id", option_value(args, "--coordinator", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"default_reviewer_agent_instance_id":"`); json_write_string(&body, option_value(args, "--reviewer", "")); strings.write_string(&body, `"`)
		if has_flag(args, "--no-vcs") { strings.write_string(&body, `,"wants_vcs":false`) }
	} else if action == "activate" {
		path = "/task-chains/activate"
		strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, option_value(args, "--chain-id", option_value(args, "--chain", ""))); strings.write_string(&body, `"`)
	} else if action == "update" {
		path = "/task-chains/update"
		strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, option_value(args, "--chain-id", option_value(args, "--chain", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"title":"`); json_write_string(&body, option_value(args, "--title", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"description":"`); json_write_string(&body, option_value(args, "--description", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"coordinator_agent_instance_id":"`); json_write_string(&body, option_value(args, "--coordinator-agent-instance-id", option_value(args, "--coordinator", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"default_reviewer_agent_instance_id":"`); json_write_string(&body, option_value(args, "--reviewer", "")); strings.write_string(&body, `"`)
	} else if action == "status" {
		path = "/task-chains/status"
		strings.write_string(&body, `,"chain_id":"`);      json_write_string(&body, option_value(args, "--chain-id", option_value(args, "--chain", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"status":"`);        json_write_string(&body, option_value(args, "--status", ""));       strings.write_string(&body, `"`)
		strings.write_string(&body, `,"final_summary":"`); json_write_string(&body, option_value(args, "--final-summary", "")); strings.write_string(&body, `"`)
	} else if action == "complete" {
		path = "/task-chains/complete"
		strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, option_value(args, "--chain-id", option_value(args, "--chain", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"summary":"`);  json_write_string(&body, option_value(args, "--summary", "")); strings.write_string(&body, `"`)
	} else if action == "show" {
		path = "/task-chains/show"
		strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, option_value(args, "--chain-id", option_value(args, "--chain", ""))); strings.write_string(&body, `"`)
	} else if action != "retry-archives" {
		fmt.println("usage: ham-ctl task-chains <create|activate|update|status|complete|show|retry-archives>"); return
	}
	strings.write_string(&body, `}`)
	response, ok := http.post(daemon_url, path, strings.to_string(body))
	if !ok { fmt.println(`{"ok":false,"message":"task-chain request failed"}`); return }
	fmt.println(response.body)
}

ctl_workspace :: proc(daemon_url, action: string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" { fmt.println("usage: ham-ctl workspace <show|diff|pull|merge|forget|refresh> --token <token> --chain <id>"); return }
	chain_id := option_value(args, "--chain", option_value(args, "--chain-id", ""))
	path := fmt.tprintf("/chains/%s/workspace", chain_id)
	use_get := action == "show" || action == "diff" || (action == "merge" && !has_flag(args, "--execute"))
	if action == "diff" do path = fmt.tprintf("/chains/%s/workspace/diff?file=%s&agent_token=%s", chain_id, option_value(args, "--file", ""), token)
	else if action == "pull" || action == "pull-base" do path = fmt.tprintf("/chains/%s/workspace/pull-base", chain_id)
	else if action == "merge" && !has_flag(args, "--execute") do path = fmt.tprintf("/chains/%s/workspace/merge-preview?agent_token=%s&target=%s", chain_id, token, option_value(args, "--target", ""))
	else if action == "merge" && has_flag(args, "--execute") do path = fmt.tprintf("/chains/%s/workspace/merge", chain_id)
	else if action == "forget" || action == "archive" do path = fmt.tprintf("/chains/%s/workspace/archive", chain_id)
	else if action == "refresh" do path = fmt.tprintf("/chains/%s/workspace/refresh", chain_id)
	else if action != "show" { fmt.println("usage: ham-ctl workspace <show|diff|pull|merge|forget|refresh>"); return }
	if use_get {
		if action == "show" do path = fmt.tprintf("/chains/%s/workspace?agent_token=%s", chain_id, token)
		response, ok := http.get(daemon_url, path); if !ok { fmt.println(`{"ok":false,"message":"workspace request failed"}`); return }; fmt.println(response.body); return
	}
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token); strings.write_string(&body, `"`)
	if file := option_value(args, "--file", ""); file != "" { strings.write_string(&body, `,"file":"`); json_write_string(&body, file); strings.write_string(&body, `"`) }
	if target := option_value(args, "--target", ""); target != "" { strings.write_string(&body, `,"target":"`); json_write_string(&body, target); strings.write_string(&body, `"`) }
	if has_flag(args, "--force") { strings.write_string(&body, `,"force":true`) }
	strings.write_string(&body, `}`)
	response, ok := http.post(daemon_url, path, strings.to_string(body))
	if !ok { fmt.println(`{"ok":false,"message":"workspace request failed"}`); return }
	fmt.println(response.body)
}

ctl_projects :: proc(daemon_url, action: string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" { fmt.println("usage: ham-ctl projects <create|update|list|show> --token <token> ..."); return }
	path := ""
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token); strings.write_string(&body, `"`)
	project_id := option_value(args, "--project-id", option_value(args, "--project", ""))
	if project_id != "" { strings.write_string(&body, `,"project_id":"`); json_write_string(&body, project_id); strings.write_string(&body, `"`) }
	if action == "create" || action == "update" {
		path = fmt.tprintf("/projects/%s", action)
		if name := option_value(args, "--name", ""); name != "" { strings.write_string(&body, `,"name":"`); json_write_string(&body, name); strings.write_string(&body, `"`) }
		if desc := option_value(args, "--description", ""); desc != "" { strings.write_string(&body, `,"description":"`); json_write_string(&body, desc); strings.write_string(&body, `"`) }
		anchor_type := option_value(args, "--anchor-type", "")
		anchor_value := option_value(args, "--anchor-value", "")
		anchor_note := option_value(args, "--anchor-note", "")
		if anchor_type != "" || anchor_value != "" || anchor_note != "" {
			strings.write_string(&body, `,"anchors":[{"type":"`); json_write_string(&body, anchor_type)
			strings.write_string(&body, `","value":"`); json_write_string(&body, anchor_value)
			strings.write_string(&body, `","note":"`); json_write_string(&body, anchor_note)
			strings.write_string(&body, `"}]`)
		}
	} else if action == "list" {
		path = "/projects/list"
	} else if action == "show" {
		path = "/projects/show"
	} else {
		fmt.println("usage: ham-ctl projects <create|update|list|show>"); return
	}
	strings.write_string(&body, `}`)
	response, ok := http.post(daemon_url, path, strings.to_string(body))
	if !ok { fmt.println(`{"ok":false,"message":"project request failed"}`); return }
	fmt.println(response.body)
}

ctl_memory :: proc(daemon_url: string, cmd: []string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" { fmt.println("usage: ham-ctl memory <propose new|edit|archive|rollback|decide|list|show|history> --token <token> ..."); return }
	path := ""
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token); strings.write_string(&body, `"`)
	if len(cmd) >= 2 && cmd[0] == "propose" {
		switch cmd[1] {
		case "new": path = "/memory/propose/new"
		case "edit": path = "/memory/propose/edit"
		case "archive": path = "/memory/propose/archive"
		case "rollback": path = "/memory/propose/rollback"
		case: fmt.println("usage: ham-ctl memory propose <new|edit|archive|rollback>"); return
		}
		memory_ctl_add_common_fields(&body, args)
	} else if len(cmd) >= 1 && cmd[0] == "decide" {
		path = "/memory/decide"
		strings.write_string(&body, `,"proposal_id":"`); json_write_string(&body, option_value(args, "--proposal-id", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"decision":"`); json_write_string(&body, option_value(args, "--decision", option_value(args, "--result", ""))); strings.write_string(&body, `"`)
	} else if len(cmd) >= 1 && cmd[0] == "list" {
		path = "/memory/list"
		memory_ctl_add_filter_fields(&body, args)
	} else if len(cmd) >= 1 && cmd[0] == "show" {
		path = "/memory/show"
		strings.write_string(&body, `,"memory_id":"`); json_write_string(&body, option_value(args, "--memory-id", option_value(args, "--memory", ""))); strings.write_string(&body, `"`)
	} else if len(cmd) >= 1 && cmd[0] == "history" {
		path = "/memory/history"
		strings.write_string(&body, `,"memory_id":"`); json_write_string(&body, option_value(args, "--memory-id", option_value(args, "--memory", ""))); strings.write_string(&body, `"`)
	} else {
		fmt.println("usage: ham-ctl memory <propose new|edit|archive|rollback|decide|list|show|history>"); return
	}
	strings.write_string(&body, `}`)
	response, ok := http.post(daemon_url, path, strings.to_string(body))
	if !ok { fmt.println(`{"ok":false,"message":"memory request failed"}`); return }
	fmt.println(response.body)
}

memory_ctl_add_common_fields :: proc(body: ^strings.Builder, args: []string) {
	memory_ctl_add_filter_fields(body, args)
	if memory_id := option_value(args, "--memory-id", option_value(args, "--memory", "")); memory_id != "" { strings.write_string(body, `,"memory_id":"`); json_write_string(body, memory_id); strings.write_string(body, `"`) }
	if title := option_value(args, "--title", ""); title != "" { strings.write_string(body, `,"title":"`); json_write_string(body, title); strings.write_string(body, `"`) }
	if text := option_value(args, "--body", ""); text != "" { strings.write_string(body, `,"body":"`); json_write_string(body, text); strings.write_string(body, `"`) }
	if reason := option_value(args, "--reason", ""); reason != "" { strings.write_string(body, `,"reason":"`); json_write_string(body, reason); strings.write_string(body, `"`) }
	if evidence := option_value(args, "--evidence", ""); evidence != "" { strings.write_string(body, `,"evidence":"`); json_write_string(body, evidence); strings.write_string(body, `"`) }
	if source_task := option_value(args, "--source-task-id", option_value(args, "--source-task", "")); source_task != "" { strings.write_string(body, `,"source_task_id":"`); json_write_string(body, source_task); strings.write_string(body, `"`) }
	if expected := option_value(args, "--expected-version", ""); expected != "" { strings.write_string(body, `,"expected_version":`); strings.write_string(body, expected) }
}

memory_ctl_add_filter_fields :: proc(body: ^strings.Builder, args: []string) {
	if agent := option_value(args, "--subject-agent", option_value(args, "--agent", "")); agent != "" { strings.write_string(body, `,"subject_agent":"`); json_write_string(body, agent); strings.write_string(body, `"`) }
	if scope := option_value(args, "--scope", ""); scope != "" { strings.write_string(body, `,"scope":"`); json_write_string(body, scope); strings.write_string(body, `"`) }
	if typ := option_value(args, "--type", ""); typ != "" { strings.write_string(body, `,"type":"`); json_write_string(body, typ); strings.write_string(body, `"`) }
	if status := option_value(args, "--status", ""); status != "" { strings.write_string(body, `,"status":"`); json_write_string(body, status); strings.write_string(body, `"`) }
	if has_flag(args, "--all") do strings.write_string(body, `,"include_all_statuses":true`)
}


ctl_chains :: proc(daemon_url, action: string, args: []string) {
	if action != "focus" {
		fmt.println("usage: ham-ctl chains focus --chain <chain_id> [--json]")
		return
	}
	chain_id := option_value(args, "--chain", option_value(args, "--chain-id", ""))
	if chain_id == "" {
		fmt.println("usage: ham-ctl chains focus --chain <chain_id> [--json]")
		return
	}
	response, ok := http.post(daemon_url, fmt.tprintf("/task-chains/%s/focus", chain_id), "{}")
	if !ok { fmt.println(`{"ok":false,"message":"chains focus failed"}`); return }
	if has_flag(args, "--json") { fmt.println(response.body); return }
	fmt.println("chain focus", extract_json_string(response.body, "chain_id", chain_id), extract_json_string(response.body, "action", "unknown"), extract_json_string(response.body, "reason", ""))
}

ctl_teams :: proc(daemon_url, action: string, args: []string) {
	if action == "start" {
		fmt.println("usage: teams start is not supported; create or focus a chain instead")
		return
	}
	path := ""
	switch action {
	case "list":
		path = "/teams"
		query := ""
		if project_id := option_value(args, "--project-id", option_value(args, "--project", "")); project_id != "" do query = fmt.tprintf("project_id=%s", project_id)
		if status := option_value(args, "--status", ""); status != "" {
			if query != "" do query = fmt.tprintf("%s&", query)
			query = fmt.tprintf("%sstatus=%s", query, status)
		}
		if query != "" do path = fmt.tprintf("%s?%s", path, query)
	case "show", "show-members":
		team_id := option_value(args, "--team", option_value(args, "--team-id", ""))
		if team_id == "" { fmt.println("usage: ham-ctl teams show|show-members --team <team_id> [--json]"); return }
		path = fmt.tprintf("/teams/%s", team_id)
		if action == "show-members" do path = fmt.tprintf("%s/members", path)
	case:
		fmt.println("usage: ham-ctl teams <list|show|show-members> [--json]")
		return
	}
	response, ok := http.get(daemon_url, path)
	if !ok { fmt.println(`{"ok":false,"message":"teams request failed"}`); return }
	if has_flag(args, "--json") { fmt.println(response.body); return }
	ctl_print_teams_human(action, response.body)
}

ctl_print_teams_human :: proc(action, body: string) {
	if action == "list" {
		printed := false
		for object, ok, next := next_json_object_with_key(body, "team_id", 0); ok; object, ok, next = next_json_object_with_key(body, "team_id", next) {
			fmt.println("team", extract_json_string(object, "team_id", ""), extract_json_string(object, "kind", ""), extract_json_string(object, "status", ""), "chain", extract_json_string(object, "chain_id", ""))
			printed = true
		}
		if !printed do fmt.println("teams none")
		return
	}
	if action == "show" {
		fmt.println("team", extract_json_string(body, "team_id", "none"), extract_json_string(body, "kind", ""), extract_json_string(body, "status", ""), "chain", extract_json_string(body, "chain_id", ""))
		return
	}
	printed := false
	for object, ok, next := next_json_object_with_key(body, "role_key", 0); ok; object, ok, next = next_json_object_with_key(body, "role_key", next) {
		fmt.println("member", extract_json_string(object, "role_key", ""), "index", extract_json_string(object, "role_index", "0"), "agent", extract_json_string(object, "agent_record_id", "null"), "status", extract_json_string(object, "lifecycle_status", ""))
		printed = true
	}
	if !printed do fmt.println("members none")
}

next_json_object_with_key :: proc(body, key: string, offset: int) -> (string, bool, int) {
	if offset >= len(body) do return "", false, len(body)
	pattern := fmt.tprintf(`"%s":`, key)
	key_rel := strings.index(body[offset:], pattern)
	if key_rel < 0 do return "", false, len(body)
	key_idx := offset + key_rel
	start := key_idx
	for start > 0 && body[start] != '{' do start -= 1
	if body[start] != '{' do return "", false, len(body)
	end_rel := strings.index(body[key_idx:], "}")
	if end_rel < 0 do return "", false, len(body)
	end := key_idx + end_rel + 1
	return body[start:end], true, end
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
		fmt.println("usage: ham-ctl users <register|heartbeat|presence>"); return
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
		fmt.println("usage: ham-ctl chat <list|fetch|send|mark-read|send-to-user|fetch-user>"); return
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
		body_val := option_value(args, "--body", "")
		type_val := option_value(args, "--type", "")
		data_val := option_value(args, "--data", "")

		final_body := ""
		if type_val == "questions" || type_val == "smart_answer" {
			if data_val == "" {
				fmt.printf(`{"ok":false,"error":"validation_error","message":"--type %s requires --data <json>"}\n`, type_val)
				os.exit(1)
			}
			val_body, val_err, val_ok := validate_and_build_special_message(type_val, data_val)
			if !val_ok {
				escaped_err, _ := strings.replace_all(val_err, `"`, `\"`)
				fmt.printf(`{"ok":false,"error":"validation_error","message":"%s"}\n`, escaped_err)
				delete(escaped_err)
				os.exit(1)
			}
			final_body = val_body
		} else {
			if type_val != "" {
				fmt.printf(`{"ok":false,"error":"validation_error","message":"Unsupported message type '%s'. Supported types: questions, smart_answer"}\n`, type_val)
				os.exit(1)
			}
			final_body = strings.clone(body_val)
		}
		defer delete(final_body)

		strings.write_string(&body, `","action":"send_to_user","body":"`)
		json_write_string(&body, final_body)
		strings.write_string(&body, `"}`)
	} else {
		include_read := has_flag(args, "--include-read")
		limit := option_value(args, "--limit", "3")
		cursor := option_value(args, "--cursor", "0")
		strings.write_string(&body, `","action":"fetch_user_chat","unread_only":`)
		if include_read {
			strings.write_string(&body, "false")
		} else {
			strings.write_string(&body, "true")
		}
		strings.write_string(&body, `,"limit":`)
		strings.write_string(&body, limit)
		if cursor != "0" {
			strings.write_string(&body, `,"cursor":`)
			strings.write_string(&body, cursor)
		}
		strings.write_string(&body, `}`)
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
		if arg == cfg_lib.CONFIG_PATH_FLAG || arg == "--daemon-url" || arg == "--wrapper-bin" || arg == "--agent" || arg == "--token" || arg == "--to" || arg == "--body" || arg == "--limit" || arg == "--task-id" || arg == "--task" || arg == "--chain-id" || arg == "--chain" || arg == "--status" || arg == "--agent-instance-id" || arg == "--role" || arg == "--final-summary" || arg == "--summary" || arg == "--user-id" || arg == "--client-instance-id" || arg == "--message-id" || arg == "--result" || arg == "--comment" || arg == "--title" || arg == "--description" || arg == "--priority" || arg == "--assignee-agent-instance-id" || arg == "--assignee" || arg == "--coordinator-agent-instance-id" || arg == "--coordinator" || arg == "--reviewer" || arg == "--comment-id" || arg == "--depends-on" || arg == "--subject-agent" || arg == "--scope" || arg == "--type" || arg == "--memory-id" || arg == "--memory" || arg == "--proposal-id" || arg == "--decision" || arg == "--reason" || arg == "--evidence" || arg == "--source-task-id" || arg == "--source-task" || arg == "--expected-version" || arg == "--project-id" || arg == "--project" || arg == "--name" || arg == "--anchor-type" || arg == "--anchor-value" || arg == "--anchor-note" || arg == "--cursor" {
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



normalize_daemon_url :: proc(value: string) -> string {
	if strings.has_prefix(value, "http://") do return value
	return fmt.tprintf("http://%s", value)
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
	home := os.get_env_alloc("HEIMDALL_HOME", context.allocator)
	if home == "" {
		home = os.get_env_alloc("HOME", context.allocator)
	}
	if path == "~" {
		if home != "" do return home
	}
	if strings.has_prefix(path, "~/") {
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
			return fmt.tprintf("%s/ham-wrapper", exe[:slash])
		}
	}
	return "ham-wrapper"
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

json_kv :: proc(key, value: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `"`)
	json_write_string(&b, key)
	strings.write_string(&b, `":"`)
	json_write_string(&b, value)
	strings.write_string(&b, `"`)
	return strings.to_string(b)
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
	fmt.println("ham-ctl", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("config", config_path)
	fmt.println("daemon_url", daemon_url)
	fmt.println("commands:")
	fmt.println("  health")
	fmt.println("  agents list        (alias: list)")
	fmt.println("  agents start <agent_instance_id> [--agent pi|claude]  (alias: start)")
	fmt.println("  agents create --name <agent_instance_id> [--provider pi|claude] [--tier cheap|normal|smart] [--display-name <name>] [--template <id>] [--project <id>]")
	fmt.println("  agents update --id <agent_instance_id> [--tier cheap|normal|smart] [--display-name <name>] [--provider <profile>]")
	fmt.println("  send --token <token> --to <agent_instance_id> --body <text>")
	fmt.println("  send --token <token> --to <agent_instance_id> --stdin")
	fmt.println("  inbox --token <token> [--limit N] [--include-read] [--json]")
	fmt.println("  tasks create --token <token> --title <title> [--description <text>] [--assignee <agent>] [--status planning] [--depends-on <task-id,...>] [--chain-id <id>|--standalone]")
	fmt.println("    task_id is always generated by daemon; root tasks auto-create a planning chain unless --standalone is set")
	fmt.println("    statuses: planning ready in_progress review_ready approved blocked cancelled")
	fmt.println("    tasks auto-transition: planning→ready (deps+chain active), ready→in_progress (assignee free), review_ready→approved (all lgtm_required voted)")
	fmt.println("  tasks list")
	fmt.println("  tasks next --token <token>")
	fmt.println("  tasks show --token <token> --task-id <id>")
	fmt.println("  tasks log --token <token> --task-id <id>")
	fmt.println("  tasks comment --token <token> --task-id <id> --body <text>")
	fmt.println("  tasks comment-resolve --token <token> --task-id <id> --comment-id <id>")
	fmt.println("  tasks comments --token <token> --task-id <id> [--unresolved]")
	fmt.println("  tasks status --token <token> --task-id <id> --status <status> --body <text>   (restricted to user tokens)")
	fmt.println("  tasks update --token <token> --task-id <id> [--title <text>] [--description <text>]")
	fmt.println("  tasks done --token <token> --task-id <id> [--comment <text>]")
	fmt.println("  tasks blocked --token <token> --task-id <id> [--reason <text>]")
	fmt.println("  tasks later --token <token> --task-id <id> [--reason <text>]")
	fmt.println("  tasks assign --token <token> --task-id <id> --agent-instance-id <agent>")
	fmt.println("  tasks participant --token <token> --task-id <id> --agent-instance-id <agent> --role <assignee|lgtm_required|lgtm_optional|coordinator|subscriber>")
	fmt.println("  tasks vote --token <token> --task-id <id> --result lgtm|ngtm --comment <text>")
	fmt.println("  tasks nudge --token <token> --task-id <id> --body <text>")
	fmt.println("  task-chains create --token <token> --title <title> [--project-id <id>] [--coordinator <agent>]")
	fmt.println("  task-chains activate --token <token> --chain-id <id>    (planning → in_progress, tasks begin auto-promoting)")
	fmt.println("  task-chains update --token <token> --chain-id <id> [--title <text>] [--description <text>] [--coordinator <agent>] [--reviewer <agent>]")
	fmt.println("  task-chains status --token <token> --chain-id <id> --status <status> [--final-summary <text>]")
	fmt.println("  task-chains complete --token <token> --chain <id> --summary <text>")
	fmt.println("  task-chains show --token <token> --chain-id <id>")
	fmt.println("  task-chains retry-archives --token <token>")
	fmt.println("  projects create --token <token> [--project-id <id>] [--name <name>] [--description <text>] [--anchor-type <type> --anchor-value <val> [--anchor-note <note>]]")
	fmt.println("  projects update --token <token> --project-id <id> [--name <name>] [--description <text>] [--anchor-type <type> --anchor-value <val> [--anchor-note <note>]]")
	fmt.println("  projects list --token <token>")
	fmt.println("  projects show --token <token> --project-id <id>")
	fmt.println("  memory propose new --token <token> --agent <agent> --type <type> --title <title> --body <body> [--reason <text>] [--evidence <text>] [--source-task-id <id>]")
	fmt.println("  memory propose edit --token <token> --memory-id <id> --expected-version <version> --title <title> --body <body> [--reason <text>] [--evidence <text>]")
	fmt.println("  memory propose archive --token <token> --memory-id <id> --expected-version <version> [--reason <text>] [--evidence <text>]")
	fmt.println("  memory propose rollback --token <token> --memory-id <id> --expected-version <version> [--reason <text>] [--evidence <text>]")
	fmt.println("  memory decide --token <token> --proposal-id <id> --decision approve|reject [--reason <text>]")
	fmt.println("  memory list --token <token> [--agent <agent>] [--scope <scope>] [--type <type>] [--status <status>] [--all]")
	fmt.println("  memory show --token <token> --memory-id <id>")
	fmt.println("  memory history --token <token> --memory-id <id>")
	fmt.println("  users register --user-id <user> --client-instance-id <client> [--token <client_token>]")
	fmt.println("  users heartbeat --client-instance-id <client> --token <client_token>")
	fmt.println("  users presence --token <agent_token>")
	fmt.println("  chat list|fetch|send|mark-read --client-instance-id <client> --token <client_token> [--agent-instance-id <agent>] [--body <text>] [--message-id <id>]")
	fmt.println("  chat send-to-user --token <agent_token> --user-id <user> [--body <text>] [--type questions --data <json>]")
	fmt.println("  chat fetch-user --token <agent_token> --user-id <user> [--include-read] [--limit N] [--cursor TS]")
	fmt.println("  start-success --token <agent_token>   (signal to daemon that agent is alive and ready)")
	fmt.println("global flags: --config <path>, --daemon-url <url>, --version, --help")
}

validate_and_build_special_message :: proc(msg_type, data_json: string) -> (result_body: string, error_msg: string, ok: bool) {
	data_bytes := transmute([]byte)data_json
	val, err := json.parse(data_bytes)
	if err != .None {
		return "", fmt.tprintf("Invalid JSON payload: {}", err), false
	}
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !is_obj {
		return "", "Data payload must be a JSON object", false
	}

	if msg_type == "smart_answer" {
		body_val, has_body := obj["body"]
		replies_val, has_replies := obj["suggested_replies"]

		for k, _ in obj {
			if k != "body" && k != "suggested_replies" {
				schema := 
					"{\n" +
					"  \"body\": \"<question_text_string>\",\n" +
					"  \"suggested_replies\": [\"reply_1\", \"reply_2\", ...]\n" +
					"}"
				return "", fmt.tprintf("Validation Error: Extra field '{}' is not allowed in smart_answer schema.\nExpected Schema:\n{}", k, schema), false
			}
		}

		if !has_body || !has_replies {
			schema := 
				"{\n" +
				"  \"body\": \"<question_text_string>\",\n" +
				"  \"suggested_replies\": [\"reply_1\", \"reply_2\", ...]\n" +
				"}"
			return "", fmt.tprintf("Validation Error: Missing required fields. Both 'body' and 'suggested_replies' are required.\nExpected Schema:\n{}", schema), false
		}

		body_str, body_ok := body_val.(json.String)
		replies_arr, replies_ok := replies_val.(json.Array)
		if !body_ok || !replies_ok {
			return "", "Validation Error: 'body' must be a string and 'suggested_replies' must be an array of strings.", false
		}

		replies_list := make([dynamic]string, context.temp_allocator)
		for r_val in replies_arr {
			r_str, r_ok := r_val.(json.String)
			if !r_ok {
				return "", "Validation Error: All items in 'suggested_replies' must be strings.", false
			}
			append(&replies_list, r_str)
		}

		ab := strings.builder_make()
		strings.write_string(&ab, `{"type":"smart_answer","body":"`)
		json_write_string(&ab, body_str)
		strings.write_string(&ab, `","suggested_replies":[`)
		for reply, idx in replies_list {
			if idx > 0 do strings.write_string(&ab, ",")
			strings.write_string(&ab, `"`)
			json_write_string(&ab, reply)
			strings.write_string(&ab, `"`)
		}
		strings.write_string(&ab, `]}`)
		return strings.to_string(ab), "", true

	} else if msg_type == "questions" {
		_, has_questions := obj["questions"]
		_, has_question := obj["question"]

		if has_questions && has_question {
			return "", "Validation Error: Payload cannot contain both 'questions' and 'question' fields. Choose either multi-question or single-question schema.", false
		}

		if !has_questions && !has_question {
			schema_single := 
				"Single Question Schema:\n" +
				"{\n" +
				"  \"question\": \"<question_text_string>\",\n" +
				"  \"suggested_answers\": [\"ans_1\", \"ans_2\", ...]\n" +
				"}"
			schema_multi := 
				"Multi-Question Questionnaire Schema:\n" +
				"{\n" +
				"  \"questions\": [\n" +
				"    {\n" +
				"      \"id\": \"<optional_unique_id>\",\n" +
				"      \"text\": \"<question_text_string>\",\n" +
				"      \"options\": [\"opt_1\", \"opt_2\", ...]\n" +
				"    },\n" +
				"    ...\n" +
				"  ]\n" +
				"}"
			return "", fmt.tprintf("Validation Error: Missing required fields. Must match either Single Question or Multi-Question schema.\n\n{}\n\n{}", schema_single, schema_multi), false
		}

		if has_questions {
			questions_val := obj["questions"]
			questions_arr, q_arr_ok := questions_val.(json.Array)
			if !q_arr_ok {
				return "", "Validation Error: 'questions' must be an array of question objects.", false
			}

			for k, _ in obj {
				if k != "questions" {
					return "", fmt.tprintf("Validation Error: Extra field '{}' is not allowed at root of multi-question schema.", k), false
				}
			}

			ab := strings.builder_make()
			strings.write_string(&ab, `{"type":"multi_question","questions":[`)

			for q_val, q_idx in questions_arr {
				q_obj, q_obj_ok := q_val.(json.Object)
				if !q_obj_ok {
					return "", "Validation Error: Items in 'questions' array must be JSON objects.", false
				}

				q_text_val, q_has_text := q_obj["text"]
				q_options_val, q_has_options := q_obj["options"]
				q_id_val, q_has_id := q_obj["id"]

				for k, _ in q_obj {
					if k != "text" && k != "options" && k != "id" {
						schema_item := 
							"Expected Question Item Schema:\n" +
							"{\n" +
							"  \"id\": \"<optional_unique_id>\",\n" +
							"  \"text\": \"<question_text_string>\",\n" +
							"  \"options\": [\"opt_1\", \"opt_2\", ...]\n" +
							"}"
						return "", fmt.tprintf("Validation Error: Extra field '{}' is not allowed in question item at index {}.\n{}", k, q_idx, schema_item), false
					}
				}

				if !q_has_text || !q_has_options {
					return "", fmt.tprintf("Validation Error: Question item at index {} is missing required fields. Both 'text' and 'options' are required.", q_idx), false
				}

				q_text_str, q_text_ok := q_text_val.(json.String)
				q_options_arr, q_options_ok := q_options_val.(json.Array)
				if !q_text_ok || !q_options_ok {
					return "", fmt.tprintf("Validation Error: In question item at index {}, 'text' must be a string and 'options' must be an array of strings.", q_idx), false
				}

				q_id_str := ""
				if q_has_id {
					id_str, id_ok := q_id_val.(json.String)
					if !id_ok {
						return "", fmt.tprintf("Validation Error: In question item at index {}, 'id' must be a string.", q_idx), false
					}
					q_id_str = id_str
				}

				if q_idx > 0 do strings.write_string(&ab, ",")
				strings.write_string(&ab, "{")
				if q_has_id {
					strings.write_string(&ab, `"id":"`)
					json_write_string(&ab, q_id_str)
					strings.write_string(&ab, `",`)
				}
				strings.write_string(&ab, `"text":"`)
				json_write_string(&ab, q_text_str)
				strings.write_string(&ab, `","options":[`)
				for opt_val, opt_idx in q_options_arr {
					opt_str, opt_ok := opt_val.(json.String)
					if !opt_ok {
						return "", fmt.tprintf("Validation Error: All items in 'options' at question index {} must be strings.", q_idx), false
					}
					if opt_idx > 0 do strings.write_string(&ab, ",")
					strings.write_string(&ab, `"`)
					json_write_string(&ab, opt_str)
					strings.write_string(&ab, `"`)
				}
				strings.write_string(&ab, `]}`)
			}

			strings.write_string(&ab, `]}`)
			return strings.to_string(ab), "", true

		} else {
			question_val := obj["question"]
			answers_val, has_answers := obj["suggested_answers"]

			for k, _ in obj {
				if k != "question" && k != "suggested_answers" {
					schema := 
						"Expected Single Question Schema:\n" +
						"{\n" +
						"  \"question\": \"<question_text_string>\",\n" +
						"  \"suggested_answers\": [\"ans_1\", \"ans_2\", ...]\n" +
						"}"
					return "", fmt.tprintf("Validation Error: Extra field '{}' is not allowed in single question schema.\n{}", k, schema), false
				}
			}

			if !has_answers {
				return "", "Validation Error: Single question schema requires both 'question' and 'suggested_answers' fields.", false
			}

			question_str, q_ok := question_val.(json.String)
			answers_arr, a_ok := answers_val.(json.Array)
			if !q_ok || !a_ok {
				return "", "Validation Error: 'question' must be a string and 'suggested_answers' must be an array of strings.", false
			}

			ab := strings.builder_make()
			strings.write_string(&ab, `{"type":"structured_question","question":"`)
			json_write_string(&ab, question_str)
			strings.write_string(&ab, `","suggested_answers":[`)
			for ans_val, ans_idx in answers_arr {
				ans_str, ans_ok := ans_val.(json.String)
				if !ans_ok {
					return "", "Validation Error: All items in 'suggested_answers' must be strings.", false
				}
				if ans_idx > 0 do strings.write_string(&ab, ",")
				strings.write_string(&ab, `"`)
				json_write_string(&ab, ans_str)
				strings.write_string(&ab, `"`)
			}
			strings.write_string(&ab, `]}`)
			return strings.to_string(ab), "", true
		}
	}

	return "", "Unknown message type", false
}
