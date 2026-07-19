package main

import base64 "core:encoding/base64"
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
	if len(os.args) == 2 && os.args[1] == "--version" {
		fmt.println("ham-ctl", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
		return
	}
	if len(os.args) == 2 && (os.args[1] == "--help" || os.args[1] == "-h") {
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

	if len(cmd) >= 2 && cmd[0] == "agents" && cmd[1] == "defaults" {
		ctl_agents_defaults(daemon_url, cmd[2:], os.args)
		return
	}

	if cmd[0] == "start" || cmd[0] == "run" || (len(cmd) >= 2 && cmd[0] == "agents" && (cmd[1] == "start" || cmd[1] == "run")) {
		idx := 1
		if cmd[0] == "agents" do idx = 2
		target := option_value(os.args, "--agent-id", "")
		if target == "" && idx < len(cmd) do target = cmd[idx]
		if target == "" {
			fmt.println("usage: ham-ctl agents run <agent_id|agent_instance_id> [--agent-id <agent_id>]")
			return
		}
		ctl_agents_start(target, os.args, config_path, daemon_url)
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

	if len(cmd) >= 2 && cmd[0] == "artifacts" {
		ctl_artifacts(daemon_url, cmd[1], os.args)
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


	if len(cmd) >= 2 && cmd[0] == "workspace" {
		ctl_workspace(daemon_url, cmd[1], os.args)
		return
	}

	if len(cmd) >= 1 && cmd[0] == "attention" {
		ctl_attention(daemon_url, os.args)
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

ctl_agents_start :: proc(target: string, args: []string, config_path, daemon_url: string) {
	health_response, health_ok := http.get(daemon_url, contracts.ROUTE_HEALTH)
	if !health_ok || health_response.status != 200 {
		fmt.println(`{"ok":false,"message":"daemon is not reachable; start ham-daemon first"}`)
		return
	}

	request := remote_start_request_json(target, option_value(args, "--agent", ""), config_path, option_value(args, "--agent-id", "") != "")
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

ctl_agents_defaults :: proc(daemon_url: string, cmd: []string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" { fmt.println("usage: ham-ctl agents defaults --token <token> [--use <role>] | ham-ctl agents defaults set --token <token> --use <role> --agent-id <agent_id>"); return }
	if len(cmd) > 0 && cmd[0] == "set" {
		default_use := option_value(args, "--use", option_value(args, "--role", ""))
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		if default_use == "" || agent_id == "" { fmt.println("usage: ham-ctl agents defaults set --token <token> --use <role> --agent-id <agent_id>"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("agent_token", token))
		append(&fields, json_kv("use", default_use))
		append(&fields, json_kv("agent_id", agent_id))
		body := fmt.tprintf("{%s}", strings.join(fields[:], ","))
		response, ok := http.post(daemon_url, "/agents/defaults", body)
		if !ok { fmt.println(`{"ok":false,"message":"agent defaults set request failed"}`); return }
		fmt.println(response.body)
		return
	}
	path := fmt.tprintf("/agents/defaults?agent_token=%s", token)
	if default_use := option_value(args, "--use", option_value(args, "--role", "")); default_use != "" {
		path = fmt.tprintf("%s&use=%s", path, default_use)
	}
	response, ok := http.get(daemon_url, path)
	if !ok { fmt.println(`{"ok":false,"message":"agent defaults request failed"}`); return }
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
	chain_id := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	json_output := has_flag(args, "--json")
	if token == "" {
		fmt.println("usage: ham-ctl inbox --token <token> [--limit N] [--chain-id <id>] [--include-read] [--json]")
		return
	}

	response: http.Response
	ok := false
	if chain_id != "" {
		path := fmt.tprintf("/chat/inbox?agent_token=%s&limit=%s&include_read=%s&chain_id=%s", token, limit, "true" if include_read else "false", chain_id)
		response, ok = http.get(daemon_url, path)
	} else {
		request := inbox_request_json(token, limit, include_read, "")
		response, ok = http.post(daemon_url, contracts.ROUTE_AGENT_RPC, request)
	}
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

remote_start_request_json :: proc(target, agent, config_path: string, target_is_agent_id: bool = false) -> string {
	builder := strings.builder_make()
	if target_is_agent_id {
		strings.write_string(&builder, `{"agent_id":"`)
	} else {
		strings.write_string(&builder, `{"agent_instance_id":"`)
	}
	json_write_string(&builder, target)
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
	if task_action_requires_task_id(action) && task_id_value == "" {
		fmt.println(`{"ok":false,"message":"missing required --task-id"}`)
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
		strings.write_string(&body, `,"reviewer_agent_instance_id":"`);    json_write_string(&body, option_value(args, "--reviewer", "")); strings.write_string(&body, `"`)
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
		if has_flag(args, "--force") do strings.write_string(&body, `,"force":true`)
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
		if has_flag(args, "--force") do strings.write_string(&body, `,"force":true`)
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

ctl_artifacts :: proc(daemon_url, action: string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" {
		fmt.println("usage: ham-ctl artifacts <create|get|fetch|list|update|delete|versions|rollback|annotate|annotations|annotation-update|annotation-delete> --token <token> ...")
		return
	}

	switch action {
	case "create":
		file_path := option_value(args, "--file", "")
		if file_path == "" {
			fmt.println(artifact_ctl_error_json("artifacts create requires --file"))
			return
		}
		data, err := os.read_entire_file(file_path, context.allocator)
		if err != nil {
			fmt.println(artifact_ctl_error_json(fmt.tprintf("failed to read file: %s", file_path)))
			return
		}
		name := option_value(args, "--name", "")
		if name == "" do name = artifact_ctl_basename(file_path)
		if name == "" {
			fmt.println(artifact_ctl_error_json("artifacts create requires --name when the file path has no basename"))
			return
		}
		content_base64 := base64.encode(data)
		defer delete(content_base64)
		body := strings.builder_make()
		strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token)
		strings.write_string(&body, `","name":"`); json_write_string(&body, name)
		if kind := option_value(args, "--kind", ""); kind != "" {
			strings.write_string(&body, `","kind":"`); json_write_string(&body, kind)
		}
		if project_id := option_value(args, "--project-id", option_value(args, "--project", "")); project_id != "" {
			strings.write_string(&body, `","project_id":"`); json_write_string(&body, project_id)
		}
		if has_flag(args, "--description") {
			strings.write_string(&body, `","description":"`); json_write_string(&body, option_value(args, "--description", ""))
		}
		strings.write_string(&body, `","content_base64":"`); json_write_string(&body, content_base64)
		strings.write_string(&body, `"}`)
		response, ok := http.post(daemon_url, contracts.ROUTE_ARTIFACTS_CREATE, strings.to_string(body))
		if !ok { fmt.println(`{"ok":false,"message":"artifacts create request failed"}`); return }
		fmt.println(response.body)
	case "get":
		artifact_id, ok := artifact_ctl_arg_id(args)
		if !ok {
			fmt.println(artifact_ctl_error_json("artifacts get requires --artifact-id <art_...|artifact://art_...>"))
			return
		}
		path := fmt.tprintf("%s/%s?token=%s", contracts.ROUTE_ARTIFACTS_PREFIX, artifact_id, token)
		response, req_ok := http.get(daemon_url, path)
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts get request failed"}`); return }
		fmt.println(response.body)
	case "fetch":
		artifact_id, ok := artifact_ctl_arg_id(args)
		if !ok {
			fmt.println(artifact_ctl_error_json("artifacts fetch requires --artifact-id <art_...|artifact://art_...>"))
			return
		}
		out_path := option_value(args, "--out", "")
		if out_path == "" {
			fmt.println(artifact_ctl_error_json("artifacts fetch requires --out <path>"))
			return
		}
		path := fmt.tprintf("%s/%s%s?token=%s", contracts.ROUTE_ARTIFACTS_PREFIX, artifact_id, contracts.ROUTE_ARTIFACTS_CONTENT_SUFFIX, token)
		if version := option_value(args, "--version", ""); version != "" {
			path = fmt.tprintf("%s&version=%s", path, version)
		}
		response, req_ok := http.get(daemon_url, path)
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts fetch request failed"}`); return }
		if response.status != 200 {
			fmt.println(response.body)
			return
		}
		if os.write_entire_file(out_path, transmute([]byte)response.body) != nil {
			fmt.println(artifact_ctl_error_json(fmt.tprintf("failed to write artifact bytes to %s", out_path)))
			return
		}
		result := strings.builder_make()
		strings.write_string(&result, `{"ok":true,"artifact_id":"`); json_write_string(&result, artifact_id)
		strings.write_string(&result, `","out":"`); json_write_string(&result, out_path); strings.write_string(&result, `"`)
		if version := option_value(args, "--version", ""); version != "" {
			strings.write_string(&result, `,"version":`); strings.write_string(&result, version)
		}
		strings.write_string(&result, `,"bytes":`); strings.write_string(&result, fmt.tprintf("%d", len(response.body)))
		strings.write_string(&result, `}`)
		fmt.println(strings.to_string(result))
	case "list":
		parts := make([dynamic]string)
		append(&parts, fmt.tprintf("token=%s", token))
		if project_id := option_value(args, "--project-id", option_value(args, "--project", "")); project_id != "" do append(&parts, fmt.tprintf("project_id=%s", project_id))
		if creator_id := option_value(args, "--creator-id", ""); creator_id != "" do append(&parts, fmt.tprintf("creator_id=%s", creator_id))
		if origin_ref := option_value(args, "--origin-ref", ""); origin_ref != "" do append(&parts, fmt.tprintf("origin_ref=%s", origin_ref))
		if limit := option_value(args, "--limit", ""); limit != "" do append(&parts, fmt.tprintf("limit=%s", limit))
		if has_flag(args, "--include-deleted") do append(&parts, "include_deleted=true")
		path := fmt.tprintf("%s?%s", contracts.ROUTE_ARTIFACTS_PREFIX, strings.join(parts[:], "&"))
		response, req_ok := http.get(daemon_url, path)
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts list request failed"}`); return }
		fmt.println(response.body)
	case "update":
		artifact_id, ok := artifact_ctl_arg_id(args)
		if !ok {
			fmt.println(artifact_ctl_error_json("artifacts update requires --artifact-id <art_...|artifact://art_...>"))
			return
		}
		file_path := option_value(args, "--file", "")
		has_changes := file_path != ""
		name_set := has_flag(args, "--name")
		kind_set := has_flag(args, "--kind")
		description_set := has_flag(args, "--description")
		project_id_set := has_flag(args, "--project-id") || has_flag(args, "--project")
		origin_kind_set := has_flag(args, "--origin-kind")
		origin_ref_set := has_flag(args, "--origin-ref")
		if name_set || kind_set || description_set || project_id_set || origin_kind_set || origin_ref_set do has_changes = true
		if !has_changes {
			fmt.println(artifact_ctl_error_json("artifacts update requires at least one of --file, --name, --kind, --description, --project-id, --origin-kind, or --origin-ref"))
			return
		}

		body := strings.builder_make()
		strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token)
		strings.write_string(&body, `","artifact_id":"`); json_write_string(&body, artifact_id)

		if name_set {
			strings.write_string(&body, `","name":"`); json_write_string(&body, option_value(args, "--name", ""))
		} else if file_path != "" {
			if inferred_name := artifact_ctl_basename(file_path); inferred_name != "" {
				strings.write_string(&body, `","name":"`); json_write_string(&body, inferred_name)
			}
		}
		if kind_set {
			strings.write_string(&body, `","kind":"`); json_write_string(&body, option_value(args, "--kind", ""))
		}
		if description_set {
			strings.write_string(&body, `","description":"`); json_write_string(&body, option_value(args, "--description", ""))
		}
		if project_id_set {
			strings.write_string(&body, `","project_id":"`); json_write_string(&body, option_value(args, "--project-id", option_value(args, "--project", "")))
		}
		if origin_kind_set {
			strings.write_string(&body, `","origin_kind":"`); json_write_string(&body, option_value(args, "--origin-kind", ""))
		}
		if origin_ref_set {
			strings.write_string(&body, `","origin_ref":"`); json_write_string(&body, option_value(args, "--origin-ref", ""))
		}
		if change_reason := option_value(args, "--change-reason", ""); change_reason != "" {
			strings.write_string(&body, `","change_reason":"`); json_write_string(&body, change_reason)
		}
		if file_path != "" {
			data, err := os.read_entire_file(file_path, context.allocator)
			if err != nil {
				fmt.println(artifact_ctl_error_json(fmt.tprintf("failed to read file: %s", file_path)))
				return
			}
			content_base64 := base64.encode(data)
			defer delete(content_base64)
			strings.write_string(&body, `","content_base64":"`); json_write_string(&body, content_base64)
		}
		strings.write_string(&body, `"}`)
		response, req_ok := http.post(daemon_url, contracts.ROUTE_ARTIFACTS_UPDATE, strings.to_string(body))
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts update request failed"}`); return }
		fmt.println(response.body)
	case "delete":
		artifact_id, ok := artifact_ctl_arg_id(args)
		if !ok {
			fmt.println(artifact_ctl_error_json("artifacts delete requires --artifact-id <art_...|artifact://art_...>"))
			return
		}
		body := strings.builder_make()
		strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token)
		strings.write_string(&body, `","artifact_id":"`); json_write_string(&body, artifact_id)
		strings.write_string(&body, `"}`)
		response, req_ok := http.post(daemon_url, contracts.ROUTE_ARTIFACTS_DELETE, strings.to_string(body))
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts delete request failed"}`); return }
		fmt.println(response.body)
	case "versions":
		artifact_id, ok := artifact_ctl_arg_id(args)
		if !ok {
			fmt.println(artifact_ctl_error_json("artifacts versions requires --artifact-id <art_...|artifact://art_...>"))
			return
		}
		path := fmt.tprintf("%s/%s%s?token=%s", contracts.ROUTE_ARTIFACTS_PREFIX, artifact_id, contracts.ROUTE_ARTIFACTS_VERSIONS_SUFFIX, token)
		response, req_ok := http.get(daemon_url, path)
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts versions request failed"}`); return }
		fmt.println(response.body)
	case "rollback":
		artifact_id, ok := artifact_ctl_arg_id(args)
		if !ok {
			fmt.println(artifact_ctl_error_json("artifacts rollback requires --artifact-id <art_...|artifact://art_...>"))
			return
		}
		version := option_value(args, "--version", "")
		if version == "" {
			fmt.println(artifact_ctl_error_json("artifacts rollback requires --version <n>"))
			return
		}
		body := strings.builder_make()
		strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token)
		strings.write_string(&body, `","artifact_id":"`); json_write_string(&body, artifact_id)
		strings.write_string(&body, `","version_no":`); strings.write_string(&body, version)
		if change_reason := option_value(args, "--change-reason", ""); change_reason != "" {
			strings.write_string(&body, `,"change_reason":"`); json_write_string(&body, change_reason); strings.write_string(&body, `"`)
		}
		strings.write_string(&body, `}`)
		response, req_ok := http.post(daemon_url, contracts.ROUTE_ARTIFACTS_ROLLBACK, strings.to_string(body))
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts rollback request failed"}`); return }
		fmt.println(response.body)
	case "annotate":
		artifact_id, ok := artifact_ctl_arg_id(args)
		if !ok {
			fmt.println(artifact_ctl_error_json("artifacts annotate requires --artifact-id <art_...|artifact://art_...>"))
			return
		}
		context_type := option_value(args, "--context-type", "")
		context_json := option_value(args, "--context-json", "")
		if context_type == "" || context_json == "" {
			fmt.println(artifact_ctl_error_json("artifacts annotate requires --context-type <text|image> and --context-json <json>"))
			return
		}
		body := strings.builder_make()
		strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token)
		strings.write_string(&body, `","artifact_id":"`); json_write_string(&body, artifact_id)
		if version := option_value(args, "--version", ""); version != "" {
			strings.write_string(&body, `","version_no":`); strings.write_string(&body, version)
		}
		strings.write_string(&body, `,"context_type":"`); json_write_string(&body, context_type)
		strings.write_string(&body, `","context_json":`); strings.write_string(&body, context_json)
		strings.write_string(&body, `,"comment":"`); json_write_string(&body, option_value(args, "--comment", ""))
		strings.write_string(&body, `"}`)
		response, req_ok := http.post(daemon_url, contracts.ROUTE_ARTIFACTS_ANNOTATIONS_CREATE, strings.to_string(body))
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts annotate request failed"}`); return }
		fmt.println(response.body)
	case "annotations":
		artifact_id, ok := artifact_ctl_arg_id(args)
		if !ok {
			fmt.println(artifact_ctl_error_json("artifacts annotations requires --artifact-id <art_...|artifact://art_...>"))
			return
		}
		path := fmt.tprintf("%s/%s%s?token=%s", contracts.ROUTE_ARTIFACTS_PREFIX, artifact_id, contracts.ROUTE_ARTIFACTS_ANNOTATIONS_SUFFIX, token)
		if version := option_value(args, "--version", ""); version != "" {
			path = fmt.tprintf("%s&version=%s", path, version)
		}
		response, req_ok := http.get(daemon_url, path)
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts annotations request failed"}`); return }
		fmt.println(response.body)
	case "annotation-update":
		annotation_id := option_value(args, "--annotation-id", "")
		if annotation_id == "" {
			fmt.println(artifact_ctl_error_json("artifacts annotation-update requires --annotation-id <id>"))
			return
		}
		body := strings.builder_make()
		strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token)
		strings.write_string(&body, `","annotation_id":"`); json_write_string(&body, annotation_id)
		strings.write_string(&body, `","comment":"`); json_write_string(&body, option_value(args, "--comment", ""))
		strings.write_string(&body, `"}`)
		response, req_ok := http.post(daemon_url, contracts.ROUTE_ARTIFACTS_ANNOTATIONS_UPDATE, strings.to_string(body))
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts annotation-update request failed"}`); return }
		fmt.println(response.body)
	case "annotation-delete":
		annotation_id := option_value(args, "--annotation-id", "")
		if annotation_id == "" {
			fmt.println(artifact_ctl_error_json("artifacts annotation-delete requires --annotation-id <id>"))
			return
		}
		body := strings.builder_make()
		strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token)
		strings.write_string(&body, `","annotation_id":"`); json_write_string(&body, annotation_id)
		strings.write_string(&body, `"}`)
		response, req_ok := http.post(daemon_url, contracts.ROUTE_ARTIFACTS_ANNOTATIONS_DELETE, strings.to_string(body))
		if !req_ok { fmt.println(`{"ok":false,"message":"artifacts annotation-delete request failed"}`); return }
		fmt.println(response.body)
	case:
		fmt.println("usage: ham-ctl artifacts <create|get|fetch|list|update|delete|versions|rollback|annotate|annotations|annotation-update|annotation-delete> --token <token> ...")
	}
}

artifact_ctl_error_json :: proc(message: string) -> string {
	body := strings.builder_make()
	strings.write_string(&body, `{"ok":false,"message":"`)
	json_write_string(&body, message)
	strings.write_string(&body, `"}`)
	return strings.to_string(body)
}

artifact_ctl_arg_id :: proc(args: []string) -> (string, bool) {
	raw := option_value(args, "--artifact-id", option_value(args, "--artifact", ""))
	if raw == "" do return "", false
	if artifact_id, ok := contracts.artifact_parse_link(raw); ok do return artifact_id, true
	if contracts.artifact_id_valid(raw) do return raw, true
	return "", false
}

artifact_ctl_basename :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	backslash := strings.last_index_byte(path, '\\')
	idx := slash
	if backslash > idx do idx = backslash
	if idx >= 0 && idx + 1 < len(path) do return strings.clone(path[idx + 1:])
	return strings.clone(path)
}

task_action_requires_task_id :: proc(action: string) -> bool {
	switch action {
	case "show", "log", "comment", "comment-resolve", "comments", "status", "update", "done", "blocked", "later", "assign", "participant", "vote", "nudge":
		return true
	case:
		return false
	}
}

ctl_task_chains :: proc(daemon_url, action: string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" { fmt.println("usage: ham-ctl task-chains <create|activate|update|status|complete|show|retry-archives> --token <token> ..."); return }
	path := "/task-chains/retry-archives"
	body := strings.builder_make()
	strings.write_string(&body, `{"agent_token":"`); json_write_string(&body, token); strings.write_string(&body, `"`)
	if action == "create" {
		if has_flag_or_equals(args, "--kind") || has_flag_or_equals(args, "--scaffold") || has_flag_or_equals(args, "--no-scaffold") {
			fmt.println(`{"ok":false,"message":"chain create no longer accepts kind/scaffold; use goal plus scaffold skills"}`)
			return
		}
		path = "/task-chains/create"
		strings.write_string(&body, `,"chain_id":"`); json_write_string(&body, option_value(args, "--chain-id", option_value(args, "--chain", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"project_id":"`); json_write_string(&body, option_value(args, "--project-id", option_value(args, "--project", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"title":"`); json_write_string(&body, option_value(args, "--title", "")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"description":"`); json_write_string(&body, option_value(args, "--description", option_value(args, "--goal", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"status":"`); json_write_string(&body, option_value(args, "--status", "in_progress")); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"coordinator_agent_instance_id":"`); json_write_string(&body, option_value(args, "--coordinator-agent-instance-id", option_value(args, "--coordinator", ""))); strings.write_string(&body, `"`)
		strings.write_string(&body, `,"default_reviewer_agent_instance_id":"`); json_write_string(&body, option_value(args, "--reviewer", "")); strings.write_string(&body, `"`)
		if has_flag(args, "--vcs") { strings.write_string(&body, `,"wants_vcs":true`) }
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

ctl_attention :: proc(daemon_url: string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" { fmt.println("usage: ham-ctl attention list --token <token>"); return }
	response, ok := http.get(daemon_url, fmt.tprintf("/attention?agent_token=%s", token))
	if !ok { fmt.println(`{"ok":false,"message":"attention request failed"}`); return }
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

MEMORY_DEPRECATED_SUBJECT_MESSAGE :: "deprecated memory target fields are not accepted; use target_agent_id and target_project_id"

memory_ctl_legacy_role_target_flag :: proc() -> string {
	return fmt.tprintf("--target-%s", "role")
}

memory_ctl_legacy_removed_target_flag :: proc() -> string {
	return fmt.tprintf("--target-%s-%s", "team", "kind")
}

memory_ctl_has_removed_target_flag :: proc(args: []string, flag: string) -> bool {
	for arg in args {
		if arg == flag do return true
		if strings.has_prefix(arg, fmt.tprintf("%s=", flag)) do return true
	}
	return false
}

memory_ctl_deprecated_subject_args :: proc(args: []string) -> string {
	deprecated_flags := []string{"--subject-key", "--subject-agent", "--agent", "--agent-instance-id", "--scope", "--team", "--team-id", "--project", "--project-id", "--project-ids", "--role-key", "--role-keys", "--task-chain-type", "--task-chain-types", "--template-key", "--template"}
	for flag in deprecated_flags {
		if has_flag(args, flag) do return MEMORY_DEPRECATED_SUBJECT_MESSAGE
	}
	if memory_ctl_has_removed_target_flag(args, memory_ctl_legacy_role_target_flag()) do return MEMORY_DEPRECATED_SUBJECT_MESSAGE
	if memory_ctl_has_removed_target_flag(args, memory_ctl_legacy_removed_target_flag()) do return MEMORY_DEPRECATED_SUBJECT_MESSAGE
	return ""
}

memory_ctl_error_json :: proc(message: string) -> string {
	body := strings.builder_make()
	strings.write_string(&body, `{"ok":false,"message":"`)
	json_write_string(&body, message)
	strings.write_string(&body, `"}`)
	return strings.to_string(body)
}

ctl_memory :: proc(daemon_url: string, cmd: []string, args: []string) {
	token := option_value(args, "--token", "")
	if token == "" { fmt.println("usage: ham-ctl memory <propose new|edit|archive|rollback|decide|list|show|history> --token <token> ..."); return }
	if msg := memory_ctl_deprecated_subject_args(args); msg != "" { fmt.println(memory_ctl_error_json(msg)); return }
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

memory_ctl_has_deprecated_subject_flag :: proc(args: []string) -> bool {
	return memory_ctl_deprecated_subject_args(args) != ""
}

memory_ctl_add_filter_fields :: proc(body: ^strings.Builder, args: []string) {
	if target_agent_id := option_value(args, "--target-agent-id", ""); target_agent_id != "" { strings.write_string(body, `,"target_agent_id":"`); json_write_string(body, target_agent_id); strings.write_string(body, `"`) }
	if target_project_id := option_value(args, "--target-project-id", ""); target_project_id != "" { strings.write_string(body, `,"target_project_id":"`); json_write_string(body, target_project_id); strings.write_string(body, `"`) }
	if typ := option_value(args, "--type", ""); typ != "" { strings.write_string(body, `,"type":"`); json_write_string(body, typ); strings.write_string(body, `"`) }
	if status := option_value(args, "--status", ""); status != "" { strings.write_string(body, `,"status":"`); json_write_string(body, status); strings.write_string(body, `"`) }
	if has_flag(args, "--all") do strings.write_string(body, `,"include_all_statuses":true`)
}


ctl_chains :: proc(daemon_url, action: string, args: []string) {
	switch action {
	case "create", "show":
		ctl_task_chains(daemon_url, action, args)
		return
	case "focus":
		chain_id := option_value(args, "--chain", option_value(args, "--chain-id", ""))
		if chain_id == "" {
			fmt.println("usage: ham-ctl chains <create|show|focus> ...")
			return
		}
		response, ok := http.post(daemon_url, fmt.tprintf("/task-chains/%s/focus", chain_id), "{}")
		if !ok { fmt.println(`{"ok":false,"message":"chains focus failed"}`); return }
		if has_flag(args, "--json") { fmt.println(response.body); return }
		fmt.println("chain focus", extract_json_string(response.body, "chain_id", chain_id), extract_json_string(response.body, "action", "unknown"), extract_json_string(response.body, "reason", ""))
		return
	case:
		fmt.println("usage: ham-ctl chains <create|show|focus> ...")
		return
	}
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
	if action == "approvals" {
		ctl_chat_approvals(daemon_url, args)
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
		fmt.println("usage: ham-ctl chat <list|fetch|send|mark-read|send-to-user|fetch-user|approvals>"); return
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
		if chain_id := option_value(args, "--chain-id", option_value(args, "--chain", "")); chain_id != "" {
			strings.write_string(&body, `","chain_id":"`)
			json_write_string(&body, chain_id)
		}
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

ctl_chat_approvals :: proc(daemon_url: string, args: []string) {
	if len(args) < 3 {
		fmt.println("usage: ham-ctl chat approvals <list|answer|dismiss|cancel> --token <token> [--approval-id <id>] [--reply <text>] [--reason <text>] [--notify]")
		return
	}
	sub := args[2]
	token := option_value(args, "--token", "")
	if token == "" {
		fmt.println(`{"ok":false,"message":"--token is required"}`)
		return
	}
	switch sub {
	case "list":
		path := fmt.tprintf("/chat-approvals/pending?token=%s", token)
		response, ok := http.get(daemon_url, path)
		if !ok { fmt.println(`{"ok":false,"message":"list request failed"}`); return }
		fmt.println(response.body)
	case "answer":
		approval_id := option_value(args, "--approval-id", "")
		reply := option_value(args, "--reply", "")
		if approval_id == "" || reply == "" {
			fmt.println(`{"ok":false,"message":"answer requires --approval-id and --reply"}`); return
		}
		b := strings.builder_make()
		strings.write_string(&b, `{"approval_id":"`); json_write_string(&b, approval_id)
		strings.write_string(&b, `","reply":"`); json_write_string(&b, reply)
		strings.write_string(&b, `","token":"`); json_write_string(&b, token)
		strings.write_string(&b, `"}`)
		response, ok := http.post(daemon_url, "/chat-approvals/answer", strings.to_string(b))
		if !ok { fmt.println(`{"ok":false,"message":"answer request failed"}`); return }
		fmt.println(response.body)
	case "dismiss":
		approval_id := option_value(args, "--approval-id", "")
		if approval_id == "" { fmt.println(`{"ok":false,"message":"dismiss requires --approval-id"}`); return }
		reason := option_value(args, "--reason", "user_dismissed")
		notify := has_flag(args, "--notify")
		b := strings.builder_make()
		strings.write_string(&b, `{"approval_id":"`); json_write_string(&b, approval_id)
		strings.write_string(&b, `","reason":"`); json_write_string(&b, reason)
		strings.write_string(&b, `","notify":`); strings.write_string(&b, "true" if notify else "false")
		strings.write_string(&b, `,"token":"`); json_write_string(&b, token)
		strings.write_string(&b, `"}`)
		response, ok := http.post(daemon_url, "/chat-approvals/dismiss", strings.to_string(b))
		if !ok { fmt.println(`{"ok":false,"message":"dismiss request failed"}`); return }
		fmt.println(response.body)
	case "cancel":
		approval_id := option_value(args, "--approval-id", "")
		if approval_id == "" { fmt.println(`{"ok":false,"message":"cancel requires --approval-id"}`); return }
		reason := option_value(args, "--reason", "agent_cancelled")
		b := strings.builder_make()
		strings.write_string(&b, `{"approval_id":"`); json_write_string(&b, approval_id)
		strings.write_string(&b, `","reason":"`); json_write_string(&b, reason)
		strings.write_string(&b, `","agent_token":"`); json_write_string(&b, token)
		strings.write_string(&b, `"}`)
		response, ok := http.post(daemon_url, "/chat-approvals/cancel", strings.to_string(b))
		if !ok { fmt.println(`{"ok":false,"message":"cancel request failed"}`); return }
		fmt.println(response.body)
	case:
		fmt.println("usage: ham-ctl chat approvals <list|answer|dismiss|cancel> ...")
	}
}

inbox_request_json :: proc(token, limit: string, include_read: bool, chain_id: string = "") -> string {
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
	if chain_id != "" {
		strings.write_string(&builder, `,"chain_id":"`)
		json_write_string(&builder, chain_id)
		strings.write_string(&builder, `"`)
	}
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
		if arg == cfg_lib.CONFIG_PATH_FLAG || arg == "--daemon-url" || arg == "--wrapper-bin" || arg == "--agent" || arg == "--agent-id" || arg == "--token" || arg == "--to" || arg == "--body" || arg == "--limit" || arg == "--task-id" || arg == "--task" || arg == "--chain-id" || arg == "--chain" || arg == "--status" || arg == "--agent-instance-id" || arg == "--role" || arg == "--use" || arg == "--final-summary" || arg == "--summary" || arg == "--user-id" || arg == "--client-instance-id" || arg == "--message-id" || arg == "--result" || arg == "--comment" || arg == "--title" || arg == "--description" || arg == "--goal" || arg == "--priority" || arg == "--assignee-agent-instance-id" || arg == "--assignee" || arg == "--coordinator-agent-instance-id" || arg == "--coordinator" || arg == "--reviewer" || arg == "--comment-id" || arg == "--depends-on" || arg == "--subject-agent" || arg == "--subject-key" || arg == "--scope" || arg == "--type" || arg == "--memory-id" || arg == "--memory" || arg == "--proposal-id" || arg == "--decision" || arg == "--reason" || arg == "--evidence" || arg == "--source-task-id" || arg == "--source-task" || arg == "--expected-version" || arg == "--project-id" || arg == "--project" || arg == "--name" || arg == "--anchor-type" || arg == "--anchor-value" || arg == "--anchor-note" || arg == "--cursor" || arg == "--target-project-id" || arg == memory_ctl_legacy_role_target_flag() || arg == memory_ctl_legacy_removed_target_flag() || arg == "--team" || arg == "--team-id" || arg == "--project-ids" || arg == "--role-key" || arg == "--role-keys" || arg == "--task-chain-type" || arg == "--task-chain-types" || arg == "--template-key" || arg == "--template" || arg == "--file" || arg == "--out" || arg == "--artifact-id" || arg == "--artifact" || arg == "--kind" || arg == "--mime" || arg == "--creator-id" || arg == "--origin-kind" || arg == "--origin-ref" || arg == "--data" || arg == "--version" || arg == "--change-reason" || arg == "--annotation-id" || arg == "--context-type" || arg == "--context-json" {
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

has_flag_or_equals :: proc(args: []string, name: string) -> bool {
	for arg in args {
		if arg == name do return true
		if strings.has_prefix(arg, fmt.tprintf("%s=", name)) do return true
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
	fmt.println("  agents run <agent_id|agent_instance_id> [--agent-id <agent_id>] [--agent pi|claude]  (aliases: agents start, run, start)")
	fmt.println("  agents create --name <agent_instance_id> [--provider pi|claude] [--tier cheap|normal|smart] [--display-name <name>] [--template <id>] [--project <id>]")
	fmt.println("  agents update --id <agent_instance_id> [--tier cheap|normal|smart] [--display-name <name>] [--provider <profile>]")
	fmt.println("  agents defaults --token <token> [--use <role>] ; agents defaults set --token <token> --use <role> --agent-id <agent_id>")
	fmt.println("  send --token <token> --to <agent_instance_id> --body <text>")
	fmt.println("  send --token <token> --to <agent_instance_id> --stdin")
	fmt.println("  inbox --token <token> [--limit N] [--include-read] [--json]")
	fmt.println("  tasks create --token <token> --title <title> [--description <text>] [--assignee <agent>] [--reviewer <agent>] [--status planning] [--depends-on <task-id,...>] [--chain-id <id>|--standalone]")
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
	fmt.println("  tasks status --token <token> --task-id <id> --status <status> --body <text> [--force]   (user tokens, or coordinator/operator with --force for any status)")
	fmt.println("  tasks update --token <token> --task-id <id> [--title <text>] [--description <text>]")
	fmt.println("  tasks done --token <token> --task-id <id> [--comment <text>] [--force]")
	fmt.println("  tasks blocked --token <token> --task-id <id> [--reason <text>]")
	fmt.println("  tasks later --token <token> --task-id <id> [--reason <text>]")
	fmt.println("  tasks assign --token <token> --task-id <id> --agent-instance-id <agent>")
	fmt.println("  tasks participant --token <token> --task-id <id> --agent-instance-id <agent> --role <assignee|lgtm_required|lgtm_optional|coordinator|subscriber>")
	fmt.println("  tasks vote --token <token> --task-id <id> --result lgtm|ngtm --comment <text>")
	fmt.println("  tasks nudge --token <token> --task-id <id> --body <text>")
	fmt.println("  artifacts create --token <token> --file <path> [--name <name>] [--kind <kind>] [--project <id>] [--description <text>]")
	fmt.println("  artifacts get --token <token> --artifact-id <art_...|artifact://art_...>")
	fmt.println("  artifacts fetch --token <token> --artifact-id <art_...|artifact://art_...> --out <path> [--version <n>]")
	fmt.println("  artifacts list --token <token> [--project <id>] [--creator-id <id>] [--origin-ref <ref>] [--limit N] [--include-deleted]")
	fmt.println("  artifacts update --token <token> --artifact-id <art_...|artifact://art_...> [--file <path>] [--name <name>] [--kind <kind>] [--description <text>] [--project <id>] [--origin-kind <kind>] [--origin-ref <ref>] [--change-reason <text>]")
	fmt.println("  artifacts versions --token <token> --artifact-id <art_...|artifact://art_...>")
	fmt.println("  artifacts rollback --token <token> --artifact-id <art_...|artifact://art_...> --version <n> [--change-reason <text>]")
	fmt.println("  artifacts annotate --token <token> --artifact-id <art_...|artifact://art_...> [--version <n>] --context-type <text|image> --context-json <json> [--comment <text>]")
	fmt.println("  artifacts annotations --token <token> --artifact-id <art_...|artifact://art_...> [--version <n>]")
	fmt.println("  artifacts annotation-update --token <token> --annotation-id <id> --comment <text>")
	fmt.println("  artifacts annotation-delete --token <token> --annotation-id <id>")
	fmt.println("  artifacts delete --token <token> --artifact-id <art_...|artifact://art_...>")
	fmt.println("  chains create --token <token> [--project-id <id>] [--title <title>] [--description|--goal <text>] [--vcs|--no-vcs] [--reviewer <agent>] [--coordinator <agent> advanced override]")
	fmt.println("  chains show --token <token> --chain-id <id>")
	fmt.println("  chains focus --chain <chain_id> [--json]")
	fmt.println("  task-chains create --token <token> [--project-id <id>] [--title <title>] [--description|--goal <text>] [--vcs|--no-vcs] [--reviewer <agent>] [--coordinator <agent> advanced override]")
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
	fmt.println("  memory propose new --token <token> [--target-agent-id <agent>] [--target-project-id <project>] --type <type> --title <title> --body <body> [--reason <text>] [--evidence <text>] [--source-task-id <id>]   (deprecated legacy target flags are rejected)")
	fmt.println("  memory propose edit --token <token> --memory-id <id> --expected-version <version> [--target-agent-id <agent>] [--target-project-id <project>] --title <title> --body <body> [--reason <text>] [--evidence <text>]")
	fmt.println("  memory propose archive --token <token> --memory-id <id> --expected-version <version> [--reason <text>] [--evidence <text>]")
	fmt.println("  memory propose rollback --token <token> --memory-id <id> --expected-version <version> [--reason <text>] [--evidence <text>]")
	fmt.println("  memory decide --token <token> --proposal-id <id> --decision approve|reject [--reason <text>]")
	fmt.println("  memory list --token <token> [--target-agent-id <agent>] [--target-project-id <project>] [--type <type>] [--status <status>] [--all]")
	fmt.println("  memory show --token <token> --memory-id <id>")
	fmt.println("  memory history --token <token> --memory-id <id>")
	fmt.println("  users register --user-id <user> --client-instance-id <client> [--token <client_token>]")
	fmt.println("  users heartbeat --client-instance-id <client> --token <client_token>")
	fmt.println("  users presence --token <agent_token>")
	fmt.println("  chat list|fetch|send|mark-read --client-instance-id <client> --token <client_token> [--agent-instance-id <agent>] [--body <text>] [--message-id <id>]")
	fmt.println("  chat send-to-user --token <agent_token> --user-id <user> [--body <text>] [--chain-id <chain>|--chain <chain>] [--type questions --data <json>]")
	fmt.println("  chat approvals list --token <user_token>")
	fmt.println("  chat approvals answer --token <user_token> --approval-id <id> --reply <text>")
	fmt.println("  chat approvals dismiss --token <user_token> --approval-id <id> [--reason <text>] [--notify]")
	fmt.println("  chat approvals cancel --token <agent_token> --approval-id <id> [--reason <text>]")
	fmt.println("    coordinator best practice: include --chain-id for chain replies; non-coordinator chain sends are redirected to the coordinator")
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
