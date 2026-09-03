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
	if resource == "instances" { ctl_agentmode_instances(endpoint, token, action, args); return }
	if resource == "agents" { ctl_agentmode_agents(endpoint, token, action, args); return }
	if resource == "templates" || resource == "template" { ctl_agentmode_templates(endpoint, token, action, args); return }
	if resource == "bridges" || resource == "bridge" { ctl_agentmode_bridges(endpoint, token, action, args); return }
	if resource == "projects" || resource == "project" { ctl_agentmode_projects(endpoint, token, action, args); return }
	if resource == "chat" || resource == "chats" { ctl_agentmode_chat(endpoint, token, action, args); return }
	if resource == "conversation" || resource == "conversations" { ctl_agentmode_conversation(endpoint, token, action, args); return }
	if resource == "chain" || resource == "chains" { ctl_agentmode_chain(endpoint, token, action, args); return }
	if resource == "tasks" || resource == "task" {
		fmt.eprintln("Notice: 'ham-ctl agent tasks' is deprecated; use top-level 'ham-ctl tasks' instead.")
		ctl_tasks_command(cmd[idx:], args)
		return
	}
	if resource == "artifacts" || resource == "artifact" { ctl_agentmode_artifacts(endpoint, token, action, args); return }
	if resource == "memory" { ctl_agentmode_memory(endpoint, token, action, args); return }
	fmt.println("usage: ham-ctl agent <context|start-success|agents|templates|bridges|projects|chat|tasks|artifacts|memory> ...")
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
	if action == "" || action == "live" || action == "running" { ctl_agent_call(endpoint, token, "agent.agents.live", "{}"); return }
	// H5 coordinator team-bootstrap: discover durable agents (same-owner) and create
	// a durable agent from a template, using ONLY the agent token.
	if action == "list" { ctl_agent_call(endpoint, token, "agent.agents.list", "{}"); return }
	if action == "create" {
		name := option_value(args, "--name", "")
		if name == "" { fmt.println("usage: ham-ctl agent agents create --name <name> [--template-id <id>] [--provider <p>] [--tier <t>] [--slug <slug>] [--instructions <text>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("name", name))
		if v := option_value(args, "--slug", ""); v != "" do append(&fields, json_kv("slug", v))
		if v := option_value(args, "--template-id", option_value(args, "--template", "")); v != "" do append(&fields, json_kv("template_id", v))
		if v := option_value(args, "--provider", option_value(args, "--default-provider", "")); v != "" do append(&fields, json_kv("default_provider", v))
		if v := option_value(args, "--tier", option_value(args, "--default-tier", "")); v != "" do append(&fields, json_kv("default_tier", v))
		if v := option_value(args, "--instructions", ""); v != "" do append(&fields, json_kv("instructions", v))
		ctl_agent_call(endpoint, token, "agent.agents.create", json_object_from_slice(fields[:]))
		return
	}
	fmt.println("usage: ham-ctl agent agents <live|list|create>")
}

// H5: discover/create agent templates (personas) via the agent token.
ctl_agentmode_templates :: proc(endpoint, token, action: string, args: []string) {
	if action == "" || action == "list" { ctl_agent_call(endpoint, token, "agent.templates.list", "{}"); return }
	if action == "create" {
		name := option_value(args, "--name", "")
		if name == "" { fmt.println("usage: ham-ctl agent templates create --name <name> [--description <text>] [--persona <text>] [--instructions <text>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("name", name))
		if v := option_value(args, "--description", ""); v != "" do append(&fields, json_kv("description", v))
		if v := option_value(args, "--persona", ""); v != "" do append(&fields, json_kv("persona", v))
		if v := option_value(args, "--instructions", ""); v != "" do append(&fields, json_kv("instructions", v))
		ctl_agent_call(endpoint, token, "agent.templates.create", json_object_from_slice(fields[:]))
		return
	}
	fmt.println("usage: ham-ctl agent templates <list|create>")
}

// H5: discover bridges owned by this agent's owner (read-only) via the agent token.
ctl_agentmode_bridges :: proc(endpoint, token, action: string, args: []string) {
	_ = args
	if action == "" || action == "list" { ctl_agent_call(endpoint, token, "agent.bridges.list", "{}"); return }
	fmt.println("usage: ham-ctl agent bridges <list>")
}

// H5: discover projects owned by this agent's owner (read-only) via the agent token.
ctl_agentmode_projects :: proc(endpoint, token, action: string, args: []string) {
	_ = args
	if action == "" || action == "list" { ctl_agent_call(endpoint, token, "agent.projects.list", "{}"); return }
	fmt.println("usage: ham-ctl agent projects <list>")
}

// Agent-token instance lifecycle so a running agent (e.g. a coordinator) can
// launch/relaunch/stop agents it owns WITHOUT a user token. Routes through the
// bridge-local agent endpoint (agent.instances.*), which relays to the raw hub
// /api/v1/agent-instances endpoints with the instance token (same-owner scoped).
ctl_agentmode_instances :: proc(endpoint, token, action: string, args: []string) {
	if action == "" || action == "live" || action == "running" {
		// Back-compat: `ham-ctl agent instances` (no verb) lists live instances.
		ctl_agent_call(endpoint, token, "agent.agents.live", "{}")
		return
	}
	if action == "launch" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		if agent_id == "" { fmt.println("usage: ham-ctl agent instances launch --agent-id <agent_id> [--bridge-id <id>] [--provider <p>] [--tier <t>] [--project-id <id>] [--chain-id <id>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("agent_id", agent_id))
		if v := option_value(args, "--bridge-id", option_value(args, "--bridge", "")); v != "" do append(&fields, json_kv("bridge_id", v))
		if v := option_value(args, "--provider", ""); v != "" do append(&fields, json_kv("provider", v))
		if v := option_value(args, "--tier", ""); v != "" do append(&fields, json_kv("tier", v))
		if v := option_value(args, "--project-id", option_value(args, "--project", "")); v != "" do append(&fields, json_kv("project_id", v))
		if v := option_value(args, "--chain-id", option_value(args, "--chain", "")); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call(endpoint, token, "agent.instances.launch", json_object_from_slice(fields[:]))
		return
	}
	if action == "restart" || action == "stop" {
		instance_id := option_value(args, "--instance", option_value(args, "--instance-id", ""))
		if instance_id == "" { fmt.printf("usage: ham-ctl agent instances %s --instance <agent_instance_id>%s\n", action, " [--reason <text>]" if action == "stop" else ""); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("instance_id", instance_id))
		if action == "stop" { if v := option_value(args, "--reason", ""); v != "" do append(&fields, json_kv("reason", v)) }
		ctl_agent_call(endpoint, token, action == "restart" ? "agent.instances.restart" : "agent.instances.stop", json_object_from_slice(fields[:]))
		return
	}
	fmt.println("usage: ham-ctl agent instances <live|launch|restart|stop> ...")
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
		ctl_agentmode_chat_fetch(endpoint, token, action, args)
		return
	}
	if action == "mark-read" {
		ctl_agent_call(endpoint, token, "agent.chat.read", "{}")
		return
	}
	fmt.println("usage: ham-ctl agent chat <send|send-to-agent|fetch|read>")
}

// ctl_agentmode_conversation handles 'ham-ctl agent conversation set-title'
// (REQ-3): rename this instance's bound conversation. Marks title_source=agent.
ctl_agentmode_conversation :: proc(endpoint, token, action: string, args: []string) {
	if action == "set-title" || action == "rename" {
		title := option_value(args, "--title", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do title = strings.trim_space(string(data)) }
		if title == "" { fmt.println("usage: ham-ctl agent conversation set-title --title <text>"); return }
		ctl_agent_call(endpoint, token, "agent.conversation.set_title", json_object(json_kv("title", title)))
		return
	}
	fmt.println("usage: ham-ctl agent conversation set-title --title <text>")
}

// ctl_agentmode_chain handles 'ham-ctl agent chain set-title' (REQ-3): rename the
// task chain this instance belongs to. Marks title_source=agent. --chain-id is
// optional (defaults to the instance's own chain server-side).
ctl_agentmode_chain :: proc(endpoint, token, action: string, args: []string) {
	if action == "set-title" || action == "rename" {
		title := option_value(args, "--title", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do title = strings.trim_space(string(data)) }
		if title == "" { fmt.println("usage: ham-ctl agent chain set-title --title <text> [--chain-id <id>]"); return }
		chain_id := option_value(args, "--chain-id", "")
		if chain_id != "" {
			ctl_agent_call(endpoint, token, "agent.chain.set_title", json_object(json_kv("title", title), json_kv("chain_id", chain_id)))
		} else {
			ctl_agent_call(endpoint, token, "agent.chain.set_title", json_object(json_kv("title", title)))
		}
		return
	}
	fmt.println("usage: ham-ctl agent chain set-title --title <text> [--chain-id <id>]")
}

ctl_agentmode_chat_fetch :: proc(endpoint, token, action: string, args: []string) {
	fields := make([dynamic]string)
	append(&fields, json_kv_raw("limit", option_value(args, "--limit", "50")))
	if cursor := option_value(args, "--since", option_value(args, "--cursor", "")); cursor != "" do append(&fields, json_kv("cursor", cursor))
	
	is_read := action == "read" || action == "read-messages"
	
	// Default low-noise
	unread_only := true
	receiver_only := true
	include_outgoing := false
	include_debug := false
	mark_read := is_read

	if has_flag(args, "--include-read") {
		unread_only = false
	}
	
	if has_flag(args, "--transcript") || has_flag(args, "--all") {
		unread_only = false
		receiver_only = false
		include_outgoing = true
		include_debug = true
	}
	
	if has_flag(args, "--include-outgoing") do include_outgoing = true
	if has_flag(args, "--include-debug") do include_debug = true

	if unread_only { append(&fields, json_kv_raw("unread_only", "true")) } else { append(&fields, json_kv_raw("unread_only", "false")) }
	if receiver_only { append(&fields, json_kv_raw("receiver_only", "true")) } else { append(&fields, json_kv_raw("receiver_only", "false")) }
	if mark_read { append(&fields, json_kv_raw("mark_read", "true")) } else { append(&fields, json_kv_raw("mark_read", "false")) }
	
	if include_outgoing { append(&fields, json_kv_raw("include_outgoing", "true")) } else { append(&fields, json_kv_raw("include_outgoing", "false")) }
	if include_debug { append(&fields, json_kv_raw("include_debug", "true")) } else { append(&fields, json_kv_raw("include_debug", "false")) }
	
	ctl_agent_call(endpoint, token, "agent.chat.fetch", json_object_from_slice(fields[:]))
}

ctl_agentmode_tasks :: proc(endpoint, token, action: string, args: []string) {
	if action == "" || action == "list" || action == "fetch" || action == "read" || action == "context" {
		ctl_agentmode_context(endpoint, token, args)
		return
	}
	if action == "done" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		if task_id == "" { fmt.println("usage: ham-ctl agent tasks done --task-id <id>"); return }
		ctl_agent_call(endpoint, token, "agent.tasks.status", json_object(json_kv("task_id", task_id), json_kv("status", "in_validation")))
		return
	}
	if action == "create" {
		title := option_value(args, "--title", "")
		if title == "" { fmt.println("usage: ham-ctl agent tasks create --title <title> [--description <desc>] [--assignee <id>] [--reviewer <ref>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("title", title))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", desc))
		if assignee := option_value(args, "--assignee-agent-instance-id", option_value(args, "--assignee", "")); assignee != "" do append(&fields, strings.concatenate({"\"assignee_ref\":", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", assignee))}))
		if reviewer := option_value(args, "--reviewer", ""); reviewer != "" do append(&fields, strings.concatenate({"\"reviewer_refs\":[", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", reviewer)), "]"}))
		ctl_agent_call(endpoint, token, "agent.tasks.create", json_object_from_slice(fields[:]))
		return
	}
	if action == "depend" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		on_id := option_value(args, "--depends-on", option_value(args, "--on", ""))
		if task_id == "" || on_id == "" { fmt.println("usage: ham-ctl agent tasks depend --task-id <id> --depends-on <id>"); return }
		ctl_agent_call(endpoint, token, "agent.tasks.depend", json_object(json_kv("task_id", task_id), json_kv("depends_on_task_id", on_id)))
		return
	}
	if action == "comment" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if task_id == "" || body == "" { fmt.println("usage: ham-ctl agent tasks comment --task-id <id> --body <text> [--notify <id,id...>]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("task_id", task_id))
		append(&fields, json_kv("body", body))
		if notify := option_value(args, "--notify", ""); notify != "" {
			parts := strings.split(notify, ",")
			defer delete(parts)
			buf := strings.builder_make()
			strings.write_string(&buf, "\"notify\":[")
			for p, i in parts {
				if i > 0 do strings.write_byte(&buf, ',')
				strings.write_byte(&buf, '"')
				strings.write_string(&buf, strings.trim_space(p))
				strings.write_byte(&buf, '"')
			}
			strings.write_byte(&buf, ']')
			append(&fields, strings.to_string(buf))
		}
		ctl_agent_call(endpoint, token, "agent.tasks.comment", json_object_from_slice(fields[:]))
		return
	}
	if action == "status" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		status := option_value(args, "--status", "")
		if task_id == "" || status == "" { fmt.println("usage: ham-ctl agent tasks status --task-id <id> --status <status>"); return }
		ctl_agent_call(endpoint, token, "agent.tasks.status", json_object(json_kv("task_id", task_id), json_kv("status", status)))
		return
	}
	if action == "set-current" || action == "current" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		if task_id == "" { fmt.println("usage: ham-ctl agent tasks set-current --task-id <id>"); return }
		ctl_agent_call(endpoint, token, "agent.tasks.set_current", json_object(json_kv("task_id", task_id)))
		return
	}
	if action == "vote" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		result := option_value(args, "--result", option_value(args, "--vote", ""))
		comment := option_value(args, "--comment", "")
		if task_id == "" || result == "" { fmt.println("usage: ham-ctl agent tasks vote --task-id <id> --result <lgtm|ngtm> [--comment <text>]"); return }
		ctl_agent_call(endpoint, token, "agent.tasks.vote", json_object(json_kv("task_id", task_id), json_kv("result", result), json_kv("comment", comment)))
		return
	}
	if action == "nudge" {
		task_id := option_value(args, "--task-id", option_value(args, "--task", ""))
		message := option_value(args, "--message", option_value(args, "--body", ""))
		if task_id == "" { fmt.println("usage: ham-ctl agent tasks nudge --task-id <id> [--message <text>]"); return }
		ctl_agent_call(endpoint, token, "agent.tasks.nudge", json_object(json_kv("task_id", task_id), json_kv("message", message)))
		return
	}
	fmt.println("usage: ham-ctl agent tasks <fetch|create|depend|comment|status|set-current|vote|nudge>")
}

ctl_agentmode_artifacts :: proc(endpoint, token, action: string, args: []string) {
	if action == "" || action == "list" {
		ctl_agent_call(endpoint, token, "agent.artifacts.list", "{}")
		return
	}
	if action == "create" {
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
	if action == "show" {
		artifact_id := option_value(args, "--artifact-id", option_value(args, "--artifact", ""))
		if artifact_id == "" { fmt.println("usage: ham-ctl agent artifacts show --artifact-id <id> [--with-content]"); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("artifact_id", artifact_id))
		if has_flag(args, "--with-content") do append(&fields, json_kv_raw("with_content", "true"))
		ctl_agent_call(endpoint, token, "agent.artifacts.show", json_object_from_slice(fields[:]))
		return
	}
	if action == "content" || action == "get" || action == "read" {
		artifact_id := option_value(args, "--artifact-id", option_value(args, "--artifact", ""))
		if artifact_id == "" { fmt.println("usage: ham-ctl agent artifacts content --artifact-id <id>"); return }
		ctl_agent_artifact_content(endpoint, token, artifact_id)
		return
	}
	if action == "download" {
		artifact_id := option_value(args, "--artifact-id", option_value(args, "--artifact", ""))
		dir := option_value(args, "--dir", option_value(args, "--directory", option_value(args, "--out-dir", "")))
		if artifact_id == "" || dir == "" { fmt.println("usage: ham-ctl agent artifacts download --artifact-id <id> --dir <directory>"); return }
		ctl_agent_artifact_download(endpoint, token, artifact_id, dir)
		return
	}
	fmt.println("usage: ham-ctl agent artifacts <list|create|show|content|download>")
}

ctl_agent_artifact_content :: proc(endpoint, token, artifact_id: string) {
	response, ok := ctl_agent_local_call(endpoint, token, "agent.artifacts.content", json_object(json_kv("artifact_id", artifact_id)))
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	if !strings.contains(response, `"ok":true`) {
		fmt.println(response)
		return
	}
	content := extract_json_string_unescaped(response, "content", "")
	fmt.print(content)
}

ctl_agent_artifact_download :: proc(endpoint, token, artifact_id, dir: string) {
	meta_response, meta_ok := ctl_agent_local_call(endpoint, token, "agent.artifacts.show", json_object(json_kv("artifact_id", artifact_id)))
	if !meta_ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	if !strings.contains(meta_response, `"ok":true`) { fmt.println(meta_response); return }
	content_response, content_ok := ctl_agent_local_call(endpoint, token, "agent.artifacts.content", json_object(json_kv("artifact_id", artifact_id)))
	if !content_ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	if !strings.contains(content_response, `"ok":true`) { fmt.println(content_response); return }
	if os.make_directory_all(dir) != nil { fmt.println(`{"ok":false,"message":"download directory could not be created"}`); os.exit(1) }
	ext := artifact_download_extension(meta_response, content_response)
	filename := artifact_download_random_filename(ext)
	path := path_join_agent(dir, filename)
	content := extract_json_string_unescaped(content_response, "content", "")
	if os.write_entire_file(path, transmute([]byte)content) != nil { fmt.println(`{"ok":false,"message":"artifact could not be written"}`); os.exit(1) }
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"filename":"`); json_write_string(&b, filename)
	strings.write_string(&b, `","path":"`); json_write_string(&b, path)
	strings.write_string(&b, `","artifact_id":"`); json_write_string(&b, artifact_id)
	strings.write_string(&b, `"}`)
	fmt.println(strings.to_string(b))
}

ctl_agentmode_memory :: proc(endpoint, token, action: string, args: []string) {
	if action == "" || action == "propose" {
		mem_type := option_value(args, "--type", "")
		title := option_value(args, "--title", "")
		if mem_type == "" || title == "" { fmt.println("usage: ham-ctl agent memory propose --type <type> --title <title> [--body <text>] [--evidence <text>] [--template-id <id>] [--project-id <id>] [--bridge-id <id>] [--agent-id <id>]"); return }
		ctl_agent_call(endpoint, token, "agent.memory.propose", ctl_agentmode_memory_propose_params(args))
		return
	}
	fmt.println("usage: ham-ctl agent memory <propose>")
}

// ctl_agentmode_memory_propose_params builds the agent.memory.propose params
// JSON from CLI args. Pure (no I/O) so it is unit-testable. type/title/body are
// always present; evidence and the H8 scope flags (template/project/bridge/agent)
// are included ONLY when provided so the hub's defaults apply (agent -> caller's
// own agent, the rest -> global). Each scope flag accepts a short alias.
ctl_agentmode_memory_propose_params :: proc(args: []string) -> string {
	fields := make([dynamic]string)
	append(&fields, json_kv("type", option_value(args, "--type", "")))
	append(&fields, json_kv("title", option_value(args, "--title", "")))
	append(&fields, json_kv("body", option_value(args, "--body", "")))
	if ev := option_value(args, "--evidence", ""); ev != "" do append(&fields, json_kv("evidence", ev))
	if v := option_value(args, "--template-id", option_value(args, "--template", "")); v != "" do append(&fields, json_kv("template_id", v))
	if v := option_value(args, "--project-id", option_value(args, "--project", "")); v != "" do append(&fields, json_kv("project_id", v))
	if v := option_value(args, "--bridge-id", option_value(args, "--bridge", "")); v != "" do append(&fields, json_kv("bridge_id", v))
	if v := option_value(args, "--agent-id", option_value(args, "--agent", "")); v != "" do append(&fields, json_kv("agent_id", v))
	return json_object_from_slice(fields[:])
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
	return ctl_agent_recv_tcp(socket)
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
	return ctl_agent_recv_unix(fd)
}

ctl_agent_recv_tcp :: proc(socket: net.TCP_Socket) -> (string, bool) {
	out := make([dynamic]byte, 0, 8192)
	buf: [8192]byte
	for len(out) < 64 * 1024 * 1024 {
		n, err := net.recv_tcp(socket, buf[:])
		if err != nil || n <= 0 do break
		append(&out, ..buf[:n])
		if byte_slice_contains(out[:], '\n') do return string(out[:]), true
	}
	if len(out) == 0 do return "", false
	return string(out[:]), true
}

ctl_agent_recv_unix :: proc(fd: posix.FD) -> (string, bool) {
	out := make([dynamic]byte, 0, 8192)
	buf: [8192]byte
	for len(out) < 64 * 1024 * 1024 {
		n := posix.recv(fd, raw_data(buf[:]), c.size_t(len(buf)), {})
		if n <= 0 do break
		append(&out, ..buf[:int(n)])
		if byte_slice_contains(out[:], '\n') do return string(out[:]), true
	}
	if len(out) == 0 do return "", false
	return string(out[:]), true
}

byte_slice_contains :: proc(values: []byte, needle: byte) -> bool {
	for v in values { if v == needle do return true }
	return false
}

artifact_download_extension :: proc(meta_response, content_response: string) -> string {
	if ext := normalize_extension(extract_json_string_unescaped(meta_response, "ext", "")); ext != "" do return ext
	if ext := extension_from_name(extract_json_string_unescaped(meta_response, "name", "")); ext != "" do return ext
	mime := extract_json_string_unescaped(content_response, "mime", "")
	if mime == "" do mime = extract_json_string_unescaped(meta_response, "mime", "")
	if mime == "" do mime = extract_json_string_unescaped(content_response, "content_type", "")
	if mime == "" do mime = extract_json_string_unescaped(meta_response, "content_type", "")
	if ext := extension_from_mime(mime); ext != "" do return ext
	if ext := extension_from_kind(extract_json_string_unescaped(meta_response, "kind", "")); ext != "" do return ext
	return "bin"
}

normalize_extension :: proc(value: string) -> string {
	v := strings.to_lower(strings.trim_space(value))
	for strings.has_prefix(v, ".") do v = v[1:]
	if len(v) == 0 || len(v) > 16 do return ""
	for ch in v { if !((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) do return "" }
	return v
}

extension_from_name :: proc(name: string) -> string {
	trimmed := strings.trim_space(name)
	slash := strings.last_index_byte(trimmed, '/')
	backslash := strings.last_index_byte(trimmed, '\\')
	sep := slash
	if backslash > sep do sep = backslash
	dot := strings.last_index_byte(trimmed, '.')
	if dot <= sep || dot < 0 || dot + 1 >= len(trimmed) do return ""
	return normalize_extension(trimmed[dot + 1:])
}

extension_from_mime :: proc(mime: string) -> string {
	m := strings.to_lower(strings.trim_space(mime))
	if semicolon := strings.index_byte(m, ';'); semicolon >= 0 do m = strings.trim_space(m[:semicolon])
	switch m {
	case "text/markdown", "text/x-markdown": return "md"
	case "text/plain": return "txt"
	case "application/json", "text/json": return "json"
	case "text/html": return "html"
	case "text/css": return "css"
	case "application/javascript", "text/javascript": return "js"
	case "image/png": return "png"
	case "image/jpeg", "image/jpg": return "jpg"
	case "image/gif": return "gif"
	case "image/webp": return "webp"
	case "image/svg+xml": return "svg"
	case "application/pdf": return "pdf"
	case "application/zip": return "zip"
	case "application/gzip": return "gz"
	case "application/octet-stream": return "bin"
	}
	return ""
}

extension_from_kind :: proc(kind: string) -> string {
	switch strings.to_lower(strings.trim_space(kind)) {
	case "markdown", "md": return "md"
	case "text", "txt", "log": return "txt"
	case "json": return "json"
	case "html": return "html"
	case "png": return "png"
	case "jpeg", "jpg": return "jpg"
	case "gif": return "gif"
	case "webp": return "webp"
	case "pdf": return "pdf"
	}
	return ""
}

artifact_download_random_filename :: proc(ext: string) -> string {
	suffix, ok := random_hex_agent(8)
	if !ok do suffix = fmt.tprintf("%d", os.get_pid())
	clean_ext := normalize_extension(ext)
	if clean_ext == "" do clean_ext = "bin"
	return fmt.tprintf("artifact_%s.%s", suffix, clean_ext)
}

random_hex_agent :: proc(n: int) -> (string, bool) {
	if n <= 0 do return "", true
	f, err := os.open("/dev/urandom")
	if err != nil do return "", false
	defer os.close(f)
	buf := make([]byte, n)
	defer delete(buf)
	got := 0
	for got < n {
		r, rerr := os.read(f, buf[got:])
		if rerr != nil || r <= 0 do return "", false
		got += r
	}
	b := strings.builder_make()
	hex := "0123456789abcdef"
	for byte_value in buf {
		strings.write_byte(&b, hex[int(byte_value >> 4)])
		strings.write_byte(&b, hex[int(byte_value & 0x0f)])
	}
	return strings.to_string(b), true
}

path_join_agent :: proc(dir, filename: string) -> string {
	base := strings.trim_right(dir, "/")
	if base == "" do return filename
	return strings.concatenate({base, "/", filename})
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
	if resource == "agents" || resource == "instances" { fmt.println("ham-ctl agent agents <live|list|create>\nPurpose: list live agent instances, discover durable agents, or create a durable agent (H5) — all same-owner scoped via the local Bridge.\nExamples:\n  ham-ctl agent agents live\n  ham-ctl agent agents list\n  ham-ctl agent agents create --name reviewer --template-id tmpl_x --provider claude --tier smart"); return }
	if resource == "templates" || resource == "template" { fmt.println("ham-ctl agent templates <list|create>\nPurpose: discover or create agent templates (personas) via the agent token (H5).\nExamples:\n  ham-ctl agent templates list\n  ham-ctl agent templates create --name coder --persona 'You write code.' --instructions '...'"); return }
	if resource == "bridges" || resource == "bridge" { fmt.println("ham-ctl agent bridges <list>\nPurpose: discover bridges owned by this agent's owner (read-only) via the agent token (H5).\nExample:\n  ham-ctl agent bridges list"); return }
	if resource == "projects" || resource == "project" { fmt.println("ham-ctl agent projects <list>\nPurpose: discover projects owned by this agent's owner (read-only) via the agent token (H5).\nExample:\n  ham-ctl agent projects list"); return }
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
	fmt.println("  conversation   Set this conversation's title (set-title)")
	fmt.println("  chain          Set this task chain's title (set-title)")
	fmt.println("  agents         List live instances, discover durable agents, or create one (list|create)")
	fmt.println("  templates      Discover/create agent templates (personas): list|create")
	fmt.println("  bridges        Discover bridges owned by this agent's owner (list)")
	fmt.println("  projects       Discover projects owned by this agent's owner (list)")
	fmt.println("  tasks          Fetch current task context and comment/status/set-current/vote/nudge assigned tasks")
	fmt.println("  artifacts      List/create/read artifacts visible to this instance owner")
	fmt.println("  memory         Propose memory")
	fmt.println("examples:")
	fmt.println("  ham-ctl agent context")
	fmt.println("  ham-ctl agents live")
	fmt.println("  ham-ctl agent chat read --since 2026-07-27T10:00:00Z")
	fmt.println("  ham-ctl agent chat send --body 'Done; tests pass.'")
	fmt.println("  ham-ctl agent conversation set-title --title 'Fix auth bug'")
	fmt.println("  ham-ctl agent chain set-title --title 'Auth hardening sprint'")
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
	fmt.println("ham-ctl agent artifacts <list|create|show|content|download>")
	fmt.println("Purpose: list, create, and read artifacts through the local Bridge.")
	fmt.println("Commands:")
	fmt.println("  list")
	fmt.println("  create --name <name> [--kind <kind>] [--content <text>|--file <path>|--stdin]")
	fmt.println("  show --artifact-id <id> [--with-content]")
	fmt.println("  content|read|get --artifact-id <id>")
	fmt.println("  download --artifact-id <id> --dir <directory>  # writes a random filename with the inferred extension")
	fmt.println("Examples:")
	fmt.println("  ham-ctl agent artifacts list")
	fmt.println("  ham-ctl agent artifacts create --name test-log --kind markdown --file /tmp/test.log")
	fmt.println("  ham-ctl agent artifacts read --artifact-id art_123")
	fmt.println("  ham-ctl agent artifacts download --artifact-id art_123 --dir /tmp")
}

print_agent_memory_help :: proc(action: string) {
	_ = action
	fmt.println("ham-ctl agent memory propose --type <type> --title <title> --body <text> [--evidence <text>] [--template-id <id>] [--project-id <id>] [--bridge-id <id>] [--agent-id <id>]")
	fmt.println("Purpose: propose durable memory for later review.")
	fmt.println("Scope flags (optional; omit for defaults — agent scope defaults to the caller's own agent, the rest to global):")
	fmt.println("  --template-id <id>  (alias --template)  scope the memory to a template (guidance for agents from that template)")
	fmt.println("  --project-id  <id>  (alias --project)   scope to a project")
	fmt.println("  --bridge-id   <id>  (alias --bridge)    scope to a bridge")
	fmt.println("  --agent-id    <id>  (alias --agent)     target a specific agent (defaults to the caller's own)")
	fmt.println("Examples:")
	fmt.println("  ham-ctl agent memory propose --type fact --title 'Project test command' --body 'Use nix develop --command odin check src/hub.'")
	fmt.println("  ham-ctl agent memory propose --type habit --title 'Reviewer checklist' --body '...' --template-id tmpl_reviewer")
}
