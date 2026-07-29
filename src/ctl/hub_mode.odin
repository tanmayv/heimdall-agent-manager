package main

import "core:fmt"
import "core:os"
import "core:strings"
import base64 "core:encoding/base64"
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
	if resource == "tasks" {
		fmt.eprintln("Notice: 'ham-ctl hub tasks' is deprecated; use top-level 'ham-ctl tasks' instead.")
		ctl_tasks_command(cmd[idx:], args)
		return
	}
	if resource == "task-chains" {
		fmt.eprintln("Notice: 'ham-ctl hub task-chains' is deprecated; use top-level 'ham-ctl task-chains' instead.")
		ctl_task_chains_command(cmd[idx:], args)
		return
	}
	if resource == "projects" { ctl_hub_projects(base, user_token, action, args); return }
	if resource == "artifacts" { ctl_hub_artifacts(base, user_token, action, args); return }
	if resource == "memories" || resource == "memory" { ctl_hub_memories(base, user_token, action, args); return }
	fmt.println("usage: ham-ctl hub <me|health|agents|launch|chats|tasks|task-chains|projects|artifacts|memories> ...")
}

ctl_hub_agents :: proc(base, token, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(base, token, "GET", "/api/v1/agents", ""); return }
	if action == "instances" { ctl_hub_request(base, token, "GET", "/api/v1/agent-instances", ""); return }
	if action == "running" || action == "live" { ctl_hub_request(base, token, "GET", "/api/v1/agent-instances?runtime_status=live", ""); return }
	if action == "create" {
		name := option_value(args, "--name", "")
		if name == "" { fmt.println("usage: ham-ctl hub agents create --name <name> [--slug <slug>] [--template <id>] [--provider <profile>] [--tier <tier>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("name", name)); append(&fields, json_kv("slug", option_value(args, "--slug", name))); append(&fields, json_kv("template_id", option_value(args, "--template", ""))); append(&fields, json_kv("default_provider", option_value(args, "--provider", ""))); append(&fields, json_kv("default_tier", option_value(args, "--tier", ""))); append(&fields, json_kv("instructions", option_value(args, "--instructions", "")))
		ctl_hub_request(base, token, "POST", "/api/v1/agents", json_object_from_slice(fields[:]))
		return
	}
	fmt.println("usage: ham-ctl hub agents <list|instances|running|live|create>")
}

ctl_hub_launch :: proc(base, token: string, args: []string) {
	agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
	if agent_id == "" { fmt.println("usage: ham-ctl hub launch --agent-id <agent_id> --bridge-id <bridge_id> [--provider <profile>] [--tier <tier>] [--project-id <id>] [--chain-id <id>]"); return }
	if option_value(args, "--bridge-id", "") == "" { fmt.println("usage: ham-ctl hub launch --agent-id <agent_id> --bridge-id <bridge_id> [--provider <profile>] [--tier <tier>] [--project-id <id>] [--chain-id <id>]"); return }
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
		if title == "" { fmt.println("usage: ham-ctl hub task-chains create --title <title> [--description <text>] [--kind <kind>] [--coordinator <id>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("title", title)); append(&fields, json_kv("description", option_value(args, "--description", ""))); append(&fields, json_kv("kind", option_value(args, "--kind", "team_work"))); append(&fields, json_kv("coordinator_agent_id", option_value(args, "--coordinator-agent-id", option_value(args, "--coordinator", "")))); append(&fields, json_kv("bridge_id", option_value(args, "--bridge-id", ""))); append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", ""))))
		ctl_hub_request(base, token, "POST", "/api/v1/task-chains", json_object_from_slice(fields[:]))
		return
	}
	chain_id := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if chain_id == "" { fmt.println("usage: ham-ctl hub task-chains <show|update|members|publish|complete> --chain-id <id>"); return }
	if action == "show" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), ""); return }
	if action == "update" {
		fields := make([dynamic]string)
		if title := option_value(args, "--title", ""); title != "" do append(&fields, json_kv("title", title))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", desc))
		if status := option_value(args, "--status", ""); status != "" do append(&fields, json_kv("status", status))
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/task-chains/%s", safe_path_part(chain_id)), json_object_from_slice(fields[:]))
		return
	}
	if action == "members" {
		sub := option_value(args, "--action", "")
		if len(args) > 4 && (args[3] == "add" || args[3] == "remove" || args[3] == "list") do sub = args[3]
		if sub == "" || sub == "list" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s/members", safe_path_part(chain_id)), ""); return }
		if sub == "add" {
			inst := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", ""))
			role := option_value(args, "--role", "assignee")
			if inst == "" { fmt.println("usage: ham-ctl hub task-chains members --chain-id <id> add --agent-instance-id <id> [--role <role>]"); return }
			ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/members", safe_path_part(chain_id)), json_object(json_kv("agent_instance_id", inst), json_kv("role", role))); return
		}
		if sub == "remove" {
			inst := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", ""))
			if inst == "" { fmt.println("usage: ham-ctl hub task-chains members --chain-id <id> remove --agent-instance-id <id>"); return }
			ctl_hub_request(base, token, "DELETE", fmt.tprintf("/api/v1/task-chains/%s/members/%s", safe_path_part(chain_id), safe_path_part(inst)), ""); return
		}
	}
	if action == "add-agent" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		if chain_id == "" || agent_id == "" { fmt.println("usage: ham-ctl hub task-chains add-agent --chain-id <id> --agent-id <id> [--bridge-id <id>] [--provider <profile>] [--tier <tier>] [--project-id <id>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("agent_id", agent_id))
		append(&fields, json_kv("chain_id", chain_id))
		if b := option_value(args, "--bridge-id", ""); b != "" do append(&fields, json_kv("bridge_id", b))
		if p := option_value(args, "--provider", ""); p != "" do append(&fields, json_kv("provider", p))
		if t := option_value(args, "--tier", ""); t != "" do append(&fields, json_kv("tier", t))
		if pr := option_value(args, "--project-id", ""); pr != "" do append(&fields, json_kv("project_id", pr))
		ctl_hub_request(base, token, "POST", "/api/v1/agent-instances", json_object_from_slice(fields[:])); return
	}
	if action == "publish" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/publish", safe_path_part(chain_id)), "{}"); return }
	if action == "complete" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/complete", safe_path_part(chain_id)), "{}"); return }
	fmt.println("usage: ham-ctl hub task-chains <list|create|show|update|members|add-agent|publish|complete>")
}

ctl_hub_tasks :: proc(base, token, action: string, args: []string) {
	chain_id := option_value(args, "--chain-id", option_value(args, "--chain", ""))
	if action == "list" {
		if chain_id == "" { fmt.println("usage: ham-ctl hub tasks list --chain-id <id>"); return }
		ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks", safe_path_part(chain_id)), ""); return
	}
	if action == "create" {
		title := option_value(args, "--title", "")
		if chain_id == "" || title == "" { fmt.println("usage: ham-ctl hub tasks create --chain-id <id> --title <title> [--description <desc>] [--assignee <id>] [--reviewer <ref>] [--depends-on <id,id>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("title", title))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", desc))
		if assignee := option_value(args, "--assignee-agent-instance-id", option_value(args, "--assignee", "")); assignee != "" do append(&fields, strings.concatenate({"\"assignee_ref\":", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", assignee))}))
		if reviewer := option_value(args, "--reviewer", ""); reviewer != "" do append(&fields, strings.concatenate({"\"reviewer_refs\":[", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", reviewer)), "]"}))
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
		ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks", safe_path_part(chain_id)), json_object_from_slice(fields[:])); return
	}
	task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
	if chain_id == "" || task_id == "" { fmt.println("usage: ham-ctl hub tasks <update|publish|status|done|cancel|depend|comments|votes|nudge> --chain-id <id> --task-id <id>"); return }
	if action == "update" {
		fields := make([dynamic]string)
		if title := option_value(args, "--title", ""); title != "" do append(&fields, json_kv("title", title))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", desc))
		if assignee := option_value(args, "--assignee-agent-instance-id", option_value(args, "--assignee", "")); assignee != "" do append(&fields, strings.concatenate({"\"assignee_ref\":", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", assignee))}))
		if reviewer := option_value(args, "--reviewer", ""); reviewer != "" do append(&fields, strings.concatenate({"\"reviewer_refs\":[", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", reviewer)), "]"}))
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
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", safe_path_part(chain_id), safe_path_part(task_id)), json_object_from_slice(fields[:])); return
	}
	if action == "done" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("status", "in_validation"))); return }
	if action == "depend" {
		on_id := option_value(args, "--on", option_value(args, "--depends-on", ""))
		if on_id == "" { fmt.println("usage: ham-ctl hub tasks depend --chain-id <id> --task-id <id> --on <depends_on_task_id>"); return }
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s", safe_path_part(chain_id), safe_path_part(task_id)), json_object(strings.concatenate({"\"depends_on\":[\"", on_id, "\"]"}))); return
	}
	if action == "publish" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/publish", safe_path_part(chain_id), safe_path_part(task_id)), "{}"); return }
	if action == "status" { status := option_value(args, "--status", ""); if status == "" { fmt.println("usage: ham-ctl hub tasks status --chain-id <id> --task-id <id> --status <status>"); return }; ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/status", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("status", status))); return }
	if action == "cancel" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/cancel", safe_path_part(chain_id), safe_path_part(task_id)), "{}"); return }
	if action == "comments" {
		sub := option_value(args, "--action", "")
		if len(args) > 5 && (args[5] == "add" || args[5] == "list") do sub = args[5]
		if sub == "" || sub == "list" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/comments", safe_path_part(chain_id), safe_path_part(task_id)), ""); return }
		if sub == "add" {
			body := option_value(args, "--body", "")
			if body == "" { fmt.println("usage: ham-ctl hub tasks comments --chain-id <id> --task-id <id> add --body <text>"); return }
			ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/comments", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("body", body))); return
		}
	}
	if action == "votes" {
		sub := option_value(args, "--action", "")
		if len(args) > 5 && (args[5] == "add" || args[5] == "list" || args[5] == "vote") do sub = args[5]
		if sub == "" || sub == "list" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/votes", safe_path_part(chain_id), safe_path_part(task_id)), ""); return }
		if sub == "add" || sub == "vote" {
			vote := option_value(args, "--vote", option_value(args, "--result", ""))
			comment := option_value(args, "--comment", "")
			if vote == "" { fmt.println("usage: ham-ctl hub tasks votes --chain-id <id> --task-id <id> vote --vote <lgtm|ngtm> [--comment <text>]"); return }
			ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/vote", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("vote", vote), json_kv("comment", comment))); return
		}
	}
	if action == "nudge" { message := option_value(args, "--message", option_value(args, "--body", "")); ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/task-chains/%s/tasks/%s/nudge", safe_path_part(chain_id), safe_path_part(task_id)), json_object(json_kv("message", message))); return }
	fmt.println("usage: ham-ctl hub tasks <list|create|update|publish|status|done|cancel|depend|comments|votes|nudge>")
}

ctl_hub_projects :: proc(base, token, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(base, token, "GET", "/api/v1/projects", ""); return }
	if action == "create" {
		name := option_value(args, "--name", "")
		if name == "" { fmt.println("usage: ham-ctl hub projects create --name <name> [--slug <slug>] [--description <text>] [--repo-url <url>] [--vcs-kind <git|jj|none>] [--default-path <path>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("name", name)); append(&fields, json_kv("slug", option_value(args, "--slug", ""))); append(&fields, json_kv("description", option_value(args, "--description", ""))); append(&fields, json_kv("repo_url", option_value(args, "--repo-url", option_value(args, "--repo", "")))); append(&fields, json_kv("vcs_kind", option_value(args, "--vcs-kind", ""))); append(&fields, json_kv("default_path", option_value(args, "--default-path", option_value(args, "--path", ""))))
		ctl_hub_request(base, token, "POST", "/api/v1/projects", json_object_from_slice(fields[:]))
		return
	}
	project_id := option_value(args, "--project-id", option_value(args, "--project", ""))
	if project_id == "" { fmt.println("usage: ham-ctl hub projects <show|update> --project-id <id>"); return }
	if action == "show" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/projects/%s", safe_path_part(project_id)), ""); return }
	if action == "update" {
		fields := make([dynamic]string)
		if name := option_value(args, "--name", ""); name != "" do append(&fields, json_kv("name", name))
		if slug := option_value(args, "--slug", ""); slug != "" do append(&fields, json_kv("slug", slug))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", desc))
		if repo := option_value(args, "--repo-url", option_value(args, "--repo", "")); repo != "" do append(&fields, json_kv("repo_url", repo))
		if vcs := option_value(args, "--vcs-kind", ""); vcs != "" do append(&fields, json_kv("vcs_kind", vcs))
		if path := option_value(args, "--default-path", option_value(args, "--path", "")); path != "" do append(&fields, json_kv("default_path", path))
		ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/projects/%s", safe_path_part(project_id)), json_object_from_slice(fields[:]))
		return
	}
	fmt.println("usage: ham-ctl hub projects <list|create|show|update>")
}

ctl_hub_artifacts :: proc(base, token, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(base, token, "GET", "/api/v1/artifacts", ""); return }
	if action == "create" {
		name := option_value(args, "--name", "")
		content := option_value(args, "--content", "")
		content_base64 := ""
		if file_path := option_value(args, "--file", ""); file_path != "" { data, err := os.read_entire_file(file_path, context.allocator); if err == nil do content_base64 = base64.encode(data) }
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do content_base64 = base64.encode(data) }
		if name == "" { fmt.println("usage: ham-ctl hub artifacts create --name <name> [--kind <kind>] [--content <text>|--file <path>|--stdin]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("name", name)); append(&fields, json_kv("kind", option_value(args, "--kind", "file")))
		if content_base64 != "" { append(&fields, json_kv("content_base64", content_base64)) } else { append(&fields, json_kv("content", content)) }
		append(&fields, json_kv("description", option_value(args, "--description", ""))); append(&fields, json_kv("content_type", option_value(args, "--content-type", option_value(args, "--mime", "")))); append(&fields, json_kv("project_id", option_value(args, "--project-id", option_value(args, "--project", ""))))
		ctl_hub_request(base, token, "POST", "/api/v1/artifacts", json_object_from_slice(fields[:]))
		return
	}
	artifact_id := option_value(args, "--artifact-id", option_value(args, "--artifact", ""))
	if artifact_id == "" { fmt.println("usage: ham-ctl hub artifacts <show|content|update|delete> --artifact-id <id>"); return }
	if action == "show" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/artifacts/%s", safe_path_part(artifact_id)), ""); return }
	if action == "content" || action == "get" { ctl_hub_request_raw(base, token, "GET", fmt.tprintf("/api/v1/artifacts/%s/content", safe_path_part(artifact_id)), ""); return }
	if action == "update" { ctl_hub_request(base, token, "PATCH", fmt.tprintf("/api/v1/artifacts/%s", safe_path_part(artifact_id)), json_object(json_kv("name", option_value(args, "--name", "")), json_kv("description", option_value(args, "--description", "")))); return }
	if action == "delete" { ctl_hub_request(base, token, "DELETE", fmt.tprintf("/api/v1/artifacts/%s", safe_path_part(artifact_id)), ""); return }
	fmt.println("usage: ham-ctl hub artifacts <list|create|show|content|update|delete>")
}

ctl_hub_memories :: proc(base, token, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(base, token, "GET", "/api/v1/memories", ""); return }
	if action == "create" || action == "propose" {
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if body == "" { fmt.println("usage: ham-ctl hub memories create --body <text> [--type <type>] [--title <title>] [--agent-id <id>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("body", body)); append(&fields, json_kv("type", option_value(args, "--type", "fact"))); append(&fields, json_kv("title", option_value(args, "--title", ""))); append(&fields, json_kv("agent_id", option_value(args, "--agent-id", option_value(args, "--agent", "")))); append(&fields, json_kv("evidence", option_value(args, "--evidence", "")))
		ctl_hub_request(base, token, "POST", "/api/v1/memories", json_object_from_slice(fields[:]))
		return
	}
	memory_id := option_value(args, "--memory-id", option_value(args, "--memory", ""))
	if memory_id == "" { fmt.println("usage: ham-ctl hub memories <show|approve|reject|archive> --memory-id <id>"); return }
	if action == "show" { ctl_hub_request(base, token, "GET", fmt.tprintf("/api/v1/memories/%s", safe_path_part(memory_id)), ""); return }
	if action == "approve" || action == "reject" || action == "archive" { ctl_hub_request(base, token, "POST", fmt.tprintf("/api/v1/memories/%s/%s", safe_path_part(memory_id), action), "{}"); return }
	fmt.println("usage: ham-ctl hub memories <list|create|show|approve|reject|archive>")
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
	if v := os.get_env_alloc("HAM_USER_TOKEN", context.allocator); v != "" do return v
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

ctl_hub_request_raw :: proc(base, user_token, method, path, body: string) {
	full_path := hub_url_path_prefix_join(base, path)
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", user_token})}}
	response, ok := http.request_with_headers_timeout(method, base, full_path, body, headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok { fmt.println(`{"ok":false,"message":"Hub request failed"}`); return }
	_, _ = os.write(os.stdout, transmute([]byte)response.body)
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
	if resource == "projects" { fmt.println("ham-ctl hub projects <list|create|show|update>\nPurpose: manage Hub projects.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... projects list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... projects create --name demo --repo-url https://example/repo.git"); return }
	if resource == "artifacts" { fmt.println("ham-ctl hub artifacts <list|create|show|content|update|delete>\nPurpose: manage Hub artifacts.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... artifacts list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... artifacts create --name notes --content 'hello'"); return }
	if resource == "memories" || resource == "memory" { fmt.println("ham-ctl hub memories <list|create|show|approve|reject|archive>\nPurpose: manage Hub memories.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... memories list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... memories create --body 'Use nix check.' --title 'Test command'"); return }
	fmt.println("ham-ctl hub — Hub /api/v1 user mode; uses Authorization: Bearer only")
	fmt.println("commands:")
	fmt.println("  me           Show authenticated user")
	fmt.println("  health       Check Hub API health")
	fmt.println("  agents       List/create durable agent identities")
	fmt.println("  launch       Start an agent instance")
	fmt.println("  chats        List/create/send/fetch chat")
	fmt.println("  tasks        List/create/update tasks")
	fmt.println("  task-chains  List/create/publish/complete chains")
	fmt.println("  projects     List/create/show/update projects")
	fmt.println("  artifacts    List/create/show/update artifacts")
	fmt.println("  memories     List/create/approve/reject/archive memories")
	fmt.println("examples:")
	fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... me")
	fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... launch --agent-id reviewer")
}
