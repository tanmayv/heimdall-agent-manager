package main

import "core:fmt"
import "core:os"
import "core:strings"

Ctl_Transport_Kind :: enum {
	User,
	Agent,
}

Ctl_Transport :: struct {
	kind: Ctl_Transport_Kind,
	user_base_url: string,
	user_token: string,
	agent_endpoint: string,
	agent_token: string,
}

resolve_ctl_transport :: proc(args: []string) -> (Ctl_Transport, bool) {
	as_override := option_value(args, "--as", "")
	hub_url := hub_user_mode_url(args)
	user_tok := hub_user_mode_token(args)
	ag_endpoint := agent_mode_endpoint(args)
	ag_tok := agent_mode_token(args)

	if as_override == "user" {
		if hub_url == "" || user_tok == "" {
			fmt.println(`{"ok":false,"message":"--as user requires --hub-url and --user-token (or HAM_HUB_URL and HAM_USER_TOKEN)"}`)
			return Ctl_Transport{}, false
		}
		return Ctl_Transport{kind = .User, user_base_url = strings.trim_right(hub_url, "/"), user_token = user_tok}, true
	}

	if as_override == "agent" {
		if ag_endpoint == "" || ag_tok == "" {
			fmt.println(`{"ok":false,"message":"--as agent requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint and --agent-token)"}`)
			return Ctl_Transport{}, false
		}
		return Ctl_Transport{kind = .Agent, agent_endpoint = ag_endpoint, agent_token = ag_tok}, true
	}

	if hub_url != "" && user_tok != "" {
		return Ctl_Transport{kind = .User, user_base_url = strings.trim_right(hub_url, "/"), user_token = user_tok}, true
	}

	if ag_endpoint != "" && ag_tok != "" {
		return Ctl_Transport{kind = .Agent, agent_endpoint = ag_endpoint, agent_token = ag_tok}, true
	}

	return Ctl_Transport{kind = .User, user_base_url = strings.trim_right(hub_url, "/"), user_token = user_tok}, true
}

ctl_tasks_request :: proc(transport: Ctl_Transport, method, path, body_json: string) {
	if transport.kind == .User {
		if transport.user_base_url == "" || transport.user_token == "" {
			fmt.println(`{"ok":false,"message":"user transport requires --hub-url and --user-token (or HAM_HUB_URL/HEIMDALL_HUB_URL and HAM_HUB_USER_TOKEN/HEIMDALL_USER_TOKEN)"}`)
			return
		}
		ctl_hub_request(transport.user_base_url, transport.user_token, method, path, body_json)
		return
	}

	if transport.kind == .Agent {
		if transport.agent_endpoint == "" || transport.agent_token == "" {
			fmt.println(`{"ok":false,"message":"agent transport requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint/--agent-token)"}`)
			return
		}
		params := json_object(
			json_kv("http_method", method),
			json_kv("path", path),
			json_kv("body", body_json),
		)
		ctl_agent_call(transport.agent_endpoint, transport.agent_token, "agent.rest.request", params)
		return
	}
}

resolve_chain_id :: proc(transport: Ctl_Transport, args: []string) -> string {
	cid := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if cid != "" do return cid
	if transport.kind == .Agent {
		res, ok := ctl_agent_local_call(transport.agent_endpoint, transport.agent_token, "agent.context.get", "{}")
		if ok {
			chain_id := extract_json_string_unescaped(res, "chain_id", "")
			if chain_id != "" do return chain_id
		}
	}
	return ""
}

resolve_task_id :: proc(transport: Ctl_Transport, args: []string) -> string {
	tid := option_value(args, "--task-id", option_value(args, "--task", ""))
	if tid != "" do return tid
	if transport.kind == .Agent {
		res, ok := ctl_agent_local_call(transport.agent_endpoint, transport.agent_token, "agent.context.get", "{}")
		if ok {
			task_id := extract_json_string_unescaped(res, "current_task_id", "")
			if task_id == "" do task_id = extract_json_string_unescaped(res, "task_id", "")
			if task_id != "" do return task_id
		}
	}
	return ""
}

print_task_chains_help :: proc(action: string) {
	_ = action
	fmt.println("usage: ham-ctl task-chains <list|create|show|update|members|add-agent|publish|complete|reopen>")
}

// Destructive chain verbs must NEVER fall back to the auto-resolved caller
// chain: acting on the wrong chain here (e.g. completing your own chain by
// omitting --chain) is unrecoverable-by-accident. These verbs require an
// explicit --chain/--chain-id. Non-destructive verbs (show/list) keep the
// convenience default via resolve_chain_id.
is_destructive_chain_verb :: proc(action: string) -> bool {
	return action == "complete" || action == "publish" || action == "reopen"
}

print_tasks_help :: proc(action: string) {
	_ = action
	fmt.println("usage: ham-ctl tasks <list|create|update|status|done|depend|cancel|comment|comments|vote|votes|nudge>")
}

ctl_task_chains_command :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && (cmd[0] == "task-chains" || cmd[0] == "task-chain" || cmd[0] == "chains" || cmd[0] == "chain") do idx = 1
	action := ""
	if idx < len(cmd) do action = cmd[idx]
	if action == "help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_task_chains_help(action)
		return
	}

	transport, ok := resolve_ctl_transport(args)
	if !ok do return

	if action == "" || action == "list" {
		ctl_tasks_request(transport, "GET", "/api/v1/task-chains", "")
		return
	}

	if action == "create" {
		title := option_value(args, "--title", "")
		if title == "" {
			fmt.println("usage: ham-ctl task-chains create --title <title> [--description <text>] [--kind <kind>] [--coordinator <id>] [--bridge <id>] [--project <id>]")
			return
		}
		fields := make([dynamic]string)
		append(&fields, json_kv("title", title))
		append(&fields, json_kv("description", option_value(args, "--description", "")))
		append(&fields, json_kv("kind", option_value(args, "--kind", "team_work")))
		append(&fields, json_kv("coordinator_agent_id", option_value(args, "--coordinator-agent-id", option_value(args, "--coordinator", ""))))
		append(&fields, json_kv("bridge_id", option_value(args, "--bridge-id", option_value(args, "--bridge", ""))))
		append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", ""))))
		ctl_tasks_request(transport, "POST", "/api/v1/task-chains", json_object_from_slice(fields[:]))
		return
	}

	// Guard destructive verbs: require an explicit --chain, never the caller default.
	if is_destructive_chain_verb(action) {
		explicit := option_value(args, "--chain-id", option_value(args, "--chain", ""))
		if explicit == "" {
			msg := strings.concatenate({"ham-ctl task-chains ", action, " requires an explicit --chain <id>; refusing to act on the auto-resolved caller chain"})
			fmt.println(json_object(json_kv_raw("ok", "false"), json_kv("message", msg)))
			os.exit(1)
		}
	}

	chain_id := resolve_chain_id(transport, args)
	if chain_id == "" {
		fmt.println("usage: ham-ctl task-chains <show|update|members|add-agent|publish|complete|reopen> --chain <id>")
		return
	}

	if action == "show" {
		ctl_tasks_request(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), "")
		return
	}

	if action == "update" {
		fields := make([dynamic]string)
		if title := option_value(args, "--title", ""); title != "" do append(&fields, json_kv("title", title))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", desc))
		if status := option_value(args, "--status", ""); status != "" do append(&fields, json_kv("status", status))
		ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object_from_slice(fields[:]))
		return
	}

	if action == "members" {
		sub := option_value(args, "--action", "")
		if idx + 1 < len(cmd) do sub = cmd[idx + 1]
		if sub == "" || sub == "list" {
			ctl_tasks_request(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/members", safe_path_part(chain_id)), "")
			return
		}
		if sub == "add" {
			inst := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", option_value(args, "--agent", "")))
			role := option_value(args, "--role", "worker")
			if inst == "" {
				fmt.println("usage: ham-ctl task-chains members --chain <id> add --agent <instance_id> [--role <role>]")
				return
			}
			ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/members", safe_path_part(chain_id)), json_object(json_kv("agent_instance_id", inst), json_kv("role", role)))
			return
		}
		if sub == "remove" {
			inst := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", option_value(args, "--agent", "")))
			if inst == "" {
				fmt.println("usage: ham-ctl task-chains members --chain <id> remove --agent <instance_id>")
				return
			}
			ctl_tasks_request(transport, "DELETE", fmt.tprintf("/api/v1/task-chains/%s/members/%s", safe_path_part(chain_id), safe_path_part(inst)), "")
			return
		}
	}

	if action == "add-agent" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		if agent_id == "" {
			fmt.println("usage: ham-ctl task-chains add-agent --chain <id> --agent <id> [--bridge <id>] [--provider <profile>] [--tier <tier>] [--project <id>]")
			return
		}
		fields := make([dynamic]string)
		append(&fields, json_kv("agent_id", agent_id))
		append(&fields, json_kv("chain_id", chain_id))
		if b := option_value(args, "--bridge-id", option_value(args, "--bridge", "")); b != "" do append(&fields, json_kv("bridge_id", b))
		if p := option_value(args, "--provider", ""); p != "" do append(&fields, json_kv("provider", p))
		if t := option_value(args, "--tier", ""); t != "" do append(&fields, json_kv("tier", t))
		if pr := option_value(args, "--project-id", option_value(args, "--project", "")); pr != "" do append(&fields, json_kv("project_id", pr))
		ctl_tasks_request(transport, "POST", "/api/v1/agent-instances", json_object_from_slice(fields[:]))
		return
	}

	if action == "publish" {
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/publish", safe_path_part(chain_id)), "{}")
		return
	}

	if action == "complete" {
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/complete", safe_path_part(chain_id)), "{}")
		return
	}

	// Coordinator-only recovery: return an accidentally-completed chain to active.
	if action == "reopen" {
		ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object(json_kv("status", "active")))
		return
	}

	fmt.println("usage: ham-ctl task-chains <list|create|show|update|members|add-agent|publish|complete|reopen>")
}

ctl_tasks_command :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && (cmd[0] == "tasks" || cmd[0] == "task") do idx = 1
	action := ""
	if idx < len(cmd) do action = cmd[idx]
	if action == "help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_tasks_help(action)
		return
	}

	transport, ok := resolve_ctl_transport(args)
	if !ok do return

	chain_id := resolve_chain_id(transport, args)

	if action == "" || action == "list" {
		if chain_id == "" {
			fmt.println("usage: ham-ctl tasks list --chain <id>")
			return
		}
		ctl_tasks_request(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks", safe_path_part(chain_id)), "")
		return
	}

	if action == "create" {
		title := option_value(args, "--title", "")
		if chain_id == "" || title == "" {
			fmt.println("usage: ham-ctl tasks create --chain <id> --title <title> [--description <desc>] [--assignee <id>] [--reviewer <ref>] [--depends-on <id,id>]")
			return
		}
		fields := make([dynamic]string)
		append(&fields, json_kv("title", title))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", desc))
		if assignee := option_value(args, "--assignee-agent-instance-id", option_value(args, "--assignee", "")); assignee != "" {
			append(&fields, strings.concatenate({"\"assignee_ref\":", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", assignee))}))
		}
		if reviewer := option_value(args, "--reviewer", ""); reviewer != "" {
			append(&fields, strings.concatenate({"\"reviewer_refs\":[", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", reviewer)), "]"}))
		}
		if deps := option_value(args, "--depends-on", option_value(args, "--on", "")); deps != "" {
			parts := strings.split(deps, ",")
			defer delete(parts)
			buf := strings.builder_make()
			strings.write_string(&buf, "\"depends_on\":[")
			for p, i in parts {
				if i > 0 do strings.write_byte(&buf, ',')
				strings.write_byte(&buf, '"')
				strings.write_string(&buf, strings.trim_space(p))
				strings.write_byte(&buf, '"')
			}
			strings.write_byte(&buf, ']')
			append(&fields, strings.to_string(buf))
		}
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks", safe_path_part(chain_id)), json_object_from_slice(fields[:]))
		return
	}

	task_id := resolve_task_id(transport, args)
	if chain_id == "" || task_id == "" {
		fmt.println("usage: ham-ctl tasks <update|status|done|depend|cancel|comment|comments|vote|votes|nudge> --chain <id> --task <id>")
		return
	}

	if action == "update" {
		fields := make([dynamic]string)
		if title := option_value(args, "--title", ""); title != "" do append(&fields, json_kv("title", title))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", desc))
		if assignee := option_value(args, "--assignee-agent-instance-id", option_value(args, "--assignee", "")); assignee != "" {
			append(&fields, strings.concatenate({"\"assignee_ref\":", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", assignee))}))
		}
		if reviewer := option_value(args, "--reviewer", ""); reviewer != "" {
			append(&fields, strings.concatenate({"\"reviewer_refs\":[", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", reviewer)), "]"}))
		}
		if deps := option_value(args, "--depends-on", option_value(args, "--on", "")); deps != "" {
			parts := strings.split(deps, ",")
			defer delete(parts)
			buf := strings.builder_make()
			strings.write_string(&buf, "\"depends_on\":[")
			for p, i in parts {
				if i > 0 do strings.write_byte(&buf, ',')
				strings.write_byte(&buf, '"')
				strings.write_string(&buf, strings.trim_space(p))
				strings.write_byte(&buf, '"')
			}
			strings.write_byte(&buf, ']')
			append(&fields, strings.to_string(buf))
		}
		ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", safe_path_part(chain_id), safe_path_part(task_id)), json_object_from_slice(fields[:]))
		return
	}

	if action == "status" {
		status := option_value(args, "--status", "")
		if status == "" {
			fmt.println("usage: ham-ctl tasks status --chain <id> --task <id> --status <status>")
			return
		}
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("status", status)))
		return
	}

	if action == "done" {
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("status", "in_validation")))
		return
	}

	if action == "depend" {
		on_id := option_value(args, "--on", option_value(args, "--depends-on", ""))
		if on_id == "" {
			fmt.println("usage: ham-ctl tasks depend --chain <id> --task <id> --depends-on <id>")
			return
		}
		ctl_tasks_request(transport, "PATCH", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", safe_path_part(chain_id), safe_path_part(task_id)), json_object(strings.concatenate({"\"depends_on\":[\"", on_id, "\"]"})))
		return
	}

	if action == "cancel" {
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/cancel", safe_path_part(chain_id), safe_path_part(task_id)), "{}")
		return
	}

	if action == "comment" {
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") {
			data, err := os.read_entire_file("/dev/stdin", context.allocator)
			if err == nil do body = string(data)
		}
		if body == "" {
			fmt.println("usage: ham-ctl tasks comment --chain <id> --task <id> --body <text>")
			return
		}
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/comments", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("body", body)))
		return
	}

	if action == "comments" {
		sub := option_value(args, "--action", "")
		if idx + 1 < len(cmd) && (cmd[idx + 1] == "add" || cmd[idx + 1] == "list") do sub = cmd[idx + 1]
		if sub == "" || sub == "list" {
			ctl_tasks_request(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/comments", safe_path_part(chain_id), safe_path_part(task_id)), "")
			return
		}
		if sub == "add" {
			body := option_value(args, "--body", "")
			if has_flag(args, "--stdin") {
				data, err := os.read_entire_file("/dev/stdin", context.allocator)
				if err == nil do body = string(data)
			}
			if body == "" {
				fmt.println("usage: ham-ctl tasks comments --chain <id> --task <id> add --body <text>")
				return
			}
			ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/comments", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("body", body)))
			return
		}
	}

	if action == "vote" {
		v := option_value(args, "--vote", option_value(args, "--result", ""))
		comment := option_value(args, "--comment", "")
		if v == "" {
			fmt.println("usage: ham-ctl tasks vote --chain <id> --task <id> --result lgtm|ngtm [--comment <text>]")
			return
		}
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/vote", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("vote", v), json_kv("comment", comment)))
		return
	}

	if action == "votes" {
		sub := option_value(args, "--action", "")
		if idx + 1 < len(cmd) && (cmd[idx + 1] == "add" || cmd[idx + 1] == "list" || cmd[idx + 1] == "vote") do sub = cmd[idx + 1]
		if sub == "" || sub == "list" {
			ctl_tasks_request(transport, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/votes", safe_path_part(chain_id), safe_path_part(task_id)), "")
			return
		}
		if sub == "add" || sub == "vote" {
			v := option_value(args, "--vote", option_value(args, "--result", ""))
			comment := option_value(args, "--comment", "")
			if v == "" {
				fmt.println("usage: ham-ctl tasks votes --chain <id> --task <id> add --result lgtm|ngtm [--comment <text>]")
				return
			}
			ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/vote", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("vote", v), json_kv("comment", comment)))
			return
		}
	}

	if action == "nudge" {
		msg := option_value(args, "--message", "")
		ctl_tasks_request(transport, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/nudge", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("message", msg)))
		return
	}

	fmt.println("usage: ham-ctl tasks <list|create|update|status|done|depend|cancel|comment|comments|vote|votes|nudge>")
}
