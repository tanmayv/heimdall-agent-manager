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

// Agent API v2 dispatch (docs/agent-api-redesign.md). Groups: bridge, agents
// (identity|template|instance), task-chain, task, chat, memory, artifact,
// context, start-success. Positional ids; one flag per concept. The legacy
// `agent` prefix is still accepted (idx skips it) but not required.
ctl_agent_mode :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && cmd[0] == "agent" do idx = 1
	if idx >= len(cmd) || has_flag(args, "--help") || has_flag(args, "-h") || (idx < len(cmd) && cmd[idx] == "help") { print_agent_help(cmd[idx:]); return }
	resource := cmd[idx]
	rest := cmd[idx + 1:] // positional tokens after the group
	action := ""
	if len(rest) > 0 do action = rest[0]
	if action == "help" || has_flag(args, "--help") { print_agent_help(cmd[idx:]); return }
	endpoint := agent_mode_endpoint(args)
	token := agent_mode_token(args)
	if endpoint == "" || token == "" {
		fmt.println(`{"ok":false,"message":"agent mode requires HEIMDALL_BRIDGE_ENDPOINT and HEIMDALL_AGENT_TOKEN (or --bridge-endpoint/--agent-token)"}`)
		return
	}
	switch resource {
	case "context":       ctl_agentmode_context(endpoint, token, args); return
	case "start-success": ctl_agent_call(endpoint, token, "agent.start_success", "{}"); return
	case "bridge":        ctl_v2_bridge(endpoint, token, rest, args); return
	case "agents":        ctl_v2_agents(endpoint, token, rest, args); return
	case "task-chain", "task-chains": ctl_v2_task_chain(endpoint, token, rest, args); return
	case "task", "tasks": ctl_v2_task(endpoint, token, rest, args); return
	case "chat", "chats": ctl_v2_chat(endpoint, token, rest, args); return
	case "memory":        ctl_agentmode_memory(endpoint, token, action, args); return
	case "artifact", "artifacts": ctl_v2_artifact(endpoint, token, rest, args); return
	}
	print_agent_help(cmd[idx:])
}

// pos returns positional token i (0-based) from the group's remaining tokens, or
// "" if absent. tokens[0] is the verb; ids are typically tokens[1].
pos :: proc(tokens: []string, i: int) -> string {
	if i < len(tokens) do return tokens[i]
	return ""
}

// ---- bridge -------------------------------------------------------------
ctl_v2_bridge :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "list":
		scope := option_value(args, "--scope", "all")
		ctl_agent_call(endpoint, token, "agent.bridge.list", json_object(json_kv("scope", scope)))
	case "providers":
		bid := option_value(args, "--bridge", pos(tokens, 1))
		if bid != "" { ctl_agent_call(endpoint, token, "agent.bridge.providers", json_object(json_kv("bridge_id", bid))) }
		else { ctl_agent_call(endpoint, token, "agent.bridge.providers", "{}") }
	case:
		print_agent_help([]string{"bridge"})
	}
}

// ---- agents (identity | template | instance + lifecycle) ----------------
ctl_v2_agents :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "list":
		ctl_agent_call(endpoint, token, "agent.agents.list", "{}")
	case "identity":
		sub := pos(tokens, 1)
		if sub == "create" {
			name := option_value(args, "--name", "")
			if name == "" { print_agent_help([]string{"agents"}); return }
			fields := make([dynamic]string)
			append(&fields, json_kv("name", name))
			if v := option_value(args, "--template", ""); v != "" do append(&fields, json_kv("template_id", v))
			if v := option_value(args, "--provider", ""); v != "" do append(&fields, json_kv("provider", v))
			if v := option_value(args, "--tier", ""); v != "" do append(&fields, json_kv("tier", v))
			if v := option_value(args, "--slug", ""); v != "" do append(&fields, json_kv("slug", v))
			if v := option_value(args, "--instructions", ""); v != "" do append(&fields, json_kv("instructions", v))
			ctl_agent_call(endpoint, token, "agent.agents.create", json_object_from_slice(fields[:]))
			return
		}
		print_agent_help([]string{"agents"})
	case "template":
		sub := pos(tokens, 1)
		if sub == "" || sub == "list" { ctl_agent_call(endpoint, token, "agent.agents.template_list", "{}"); return }
		if sub == "create" {
			name := option_value(args, "--name", "")
			if name == "" { print_agent_help([]string{"agents"}); return }
			fields := make([dynamic]string)
			append(&fields, json_kv("name", name))
			if v := option_value(args, "--description", ""); v != "" do append(&fields, json_kv("description", v))
			if v := option_value(args, "--persona", ""); v != "" do append(&fields, json_kv("persona", v))
			if v := option_value(args, "--instructions", ""); v != "" do append(&fields, json_kv("instructions", v))
			ctl_agent_call(endpoint, token, "agent.agents.template_create", json_object_from_slice(fields[:]))
			return
		}
		print_agent_help([]string{"agents"})
	case "instance":
		sub := pos(tokens, 1)
		if sub == "" || sub == "list" {
			fields := make([dynamic]string)
			if v := option_value(args, "--agent", ""); v != "" do append(&fields, json_kv("agent_id", v))
			if has_flag(args, "--live") do append(&fields, json_kv_raw("live", "true"))
			ctl_agent_call(endpoint, token, "agent.agents.instance_list", json_object_from_slice(fields[:]))
			return
		}
		print_agent_help([]string{"agents"})
	case "new-instance":
		agent_id := pos(tokens, 1)
		if agent_id == "" { print_agent_help([]string{"agents"}); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("agent_id", agent_id))
		if v := option_value(args, "--project", ""); v != "" do append(&fields, json_kv("project_id", v))
		if v := option_value(args, "--bridge", ""); v != "" do append(&fields, json_kv("bridge_id", v))
		if v := option_value(args, "--provider", ""); v != "" do append(&fields, json_kv("provider", v))
		if v := option_value(args, "--tier", ""); v != "" do append(&fields, json_kv("tier", v))
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call(endpoint, token, "agent.agents.new_instance", json_object_from_slice(fields[:]))
	case "start", "stop", "restart":
		inst := pos(tokens, 1)
		if inst == "" { print_agent_help([]string{"agents"}); return }
		method := "agent.agents.instance_start"
		if verb == "stop" do method = "agent.agents.instance_stop"
		if verb == "restart" do method = "agent.agents.instance_restart"
		fields := make([dynamic]string)
		append(&fields, json_kv("instance_id", inst))
		if verb == "stop" { if v := option_value(args, "--reason", ""); v != "" do append(&fields, json_kv("reason", v)) }
		ctl_agent_call(endpoint, token, method, json_object_from_slice(fields[:]))
	case:
		print_agent_help([]string{"agents"})
	}
}

// ---- task-chain ---------------------------------------------------------
ctl_v2_task_chain :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "list":
		fields := make([dynamic]string)
		if has_flag(args, "--mine") do append(&fields, json_kv_raw("coordinated_by_me", "true"))
		if v := option_value(args, "--project", ""); v != "" do append(&fields, json_kv("project_id", v))
		ctl_agent_call(endpoint, token, "agent.task_chain.list", json_object_from_slice(fields[:]))
	case "show":
		cid := option_value(args, "--chain", pos(tokens, 1))
		if cid != "" { ctl_agent_call(endpoint, token, "agent.task_chain.show", json_object(json_kv("chain_id", cid))) }
		else { ctl_agent_call(endpoint, token, "agent.task_chain.show", "{}") }
	case "set-title":
		title := option_value(args, "--title", pos(tokens, 1))
		if title == "" { print_agent_help([]string{"task-chain"}); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("title", title))
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call(endpoint, token, "agent.task_chain.set_title", json_object_from_slice(fields[:]))
	case:
		print_agent_help([]string{"task-chain"})
	}
}

// ---- task (one command per action) --------------------------------------
ctl_v2_task :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "list":
		fields := make([dynamic]string)
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call(endpoint, token, "agent.task.list", json_object_from_slice(fields[:]))
	case "show":
		tid := pos(tokens, 1)
		if tid == "" { print_agent_help([]string{"task"}); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("task_id", tid))
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		ctl_agent_call(endpoint, token, "agent.task.show", json_object_from_slice(fields[:]))
	case "create":
		title := option_value(args, "--title", "")
		if title == "" { print_agent_help([]string{"task"}); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("title", title))
		if v := option_value(args, "--description", ""); v != "" do append(&fields, json_kv("description", v))
		if v := option_value(args, "--chain", ""); v != "" do append(&fields, json_kv("chain_id", v))
		if a := option_value(args, "--assignee", ""); a != "" do append(&fields, strings.concatenate({"\"assignee_ref\":", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", a))}))
		if r := option_value(args, "--reviewer", ""); r != "" do append(&fields, strings.concatenate({"\"reviewer_refs\":[", json_object(json_kv("type", "agent_instance"), json_kv("agent_instance_id", r)), "]"}))
		ctl_agent_call(endpoint, token, "agent.task.create", json_object_from_slice(fields[:]))
	case "comment":
		tid := pos(tokens, 1)
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if tid == "" || body == "" { print_agent_help([]string{"task"}); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("task_id", tid))
		append(&fields, json_kv("body", body))
		if notify := option_value(args, "--notify", ""); notify != "" do append(&fields, ctl_v2_json_string_array("notify", notify))
		ctl_agent_call(endpoint, token, "agent.task.comment", json_object_from_slice(fields[:]))
	case "status":
		tid := pos(tokens, 1)
		status := option_value(args, "--status", "")
		if tid == "" || status == "" { print_agent_help([]string{"task"}); return }
		ctl_agent_call(endpoint, token, "agent.task.status", json_object(json_kv("task_id", tid), json_kv("status", status)))
	case "vote":
		tid := pos(tokens, 1)
		result := option_value(args, "--result", "")
		if tid == "" || result == "" { print_agent_help([]string{"task"}); return }
		ctl_agent_call(endpoint, token, "agent.task.vote", json_object(json_kv("task_id", tid), json_kv("result", result), json_kv("comment", option_value(args, "--comment", ""))))
	case "nudge":
		tid := pos(tokens, 1)
		if tid == "" { print_agent_help([]string{"task"}); return }
		ctl_agent_call(endpoint, token, "agent.task.nudge", json_object(json_kv("task_id", tid), json_kv("message", option_value(args, "--message", ""))))
	case "set-current":
		tid := pos(tokens, 1)
		if tid == "" { print_agent_help([]string{"task"}); return }
		ctl_agent_call(endpoint, token, "agent.task.set_current", json_object(json_kv("task_id", tid)))
	case "depend":
		tid := pos(tokens, 1)
		on := option_value(args, "--on", "")
		if tid == "" || on == "" { print_agent_help([]string{"task"}); return }
		ctl_agent_call(endpoint, token, "agent.task.depend", json_object(json_kv("task_id", tid), json_kv("depends_on_task_id", on)))
	case:
		print_agent_help([]string{"task"})
	}
}

// ---- chat (send --to user|<instance-id>, read) --------------------------
ctl_v2_chat :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "", "read":
		ctl_agentmode_chat_fetch(endpoint, token, "read", args)
	case "send":
		to := option_value(args, "--to", "")
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if to == "" || body == "" { print_agent_help([]string{"chat"}); return }
		// to == "user" or an agent-instance-id; the bridge routes accordingly.
		ctl_agent_call(endpoint, token, "agent.chat.send", json_object(json_kv("to", to), json_kv("body", body)))
	case:
		print_agent_help([]string{"chat"})
	}
}

// ---- artifact -----------------------------------------------------------
ctl_v2_artifact :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	// artifact verbs keep their existing param shapes; only the method prefix
	// changed (artifacts -> artifact). Delegate to the shared impl.
	ctl_agentmode_artifacts_v2(endpoint, token, verb, tokens, args)
}

// ctl_v2_json_string_array builds "key":["a","b"] from a comma list.
ctl_v2_json_string_array :: proc(key, csv: string) -> string {
	parts := strings.split(csv, ",")
	defer delete(parts)
	b := strings.builder_make()
	strings.write_byte(&b, '"'); strings.write_string(&b, key); strings.write_string(&b, "\":[")
	for p, i in parts {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"'); strings.write_string(&b, strings.trim_space(p)); strings.write_byte(&b, '"')
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
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
	
	ctl_agent_call(endpoint, token, "agent.chat.read", json_object_from_slice(fields[:]))
}

// ctl_agentmode_artifacts_v2 is the v2 artifact dispatch: positional <artifact-id>
// and the singular `agent.artifact.*` methods.
ctl_agentmode_artifacts_v2 :: proc(endpoint, token, verb: string, tokens, args: []string) {
	switch verb {
	case "", "list":
		ctl_agent_call(endpoint, token, "agent.artifact.list", "{}")
	case "create":
		name := option_value(args, "--name", "")
		kind := option_value(args, "--kind", "markdown")
		if name == "" { print_agent_help([]string{"artifact"}); return }
		content := option_value(args, "--content", "")
		content_base64 := ""
		if file_path := option_value(args, "--file", ""); file_path != "" { data, err := os.read_entire_file(file_path, context.allocator); if err == nil do content_base64 = base64.encode(data) }
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do content_base64 = base64.encode(data) }
		fields := make([dynamic]string)
		append(&fields, json_kv("name", name)); append(&fields, json_kv("kind", kind))
		if content_base64 != "" { append(&fields, json_kv("content_base64", content_base64)) } else { append(&fields, json_kv("content", content)) }
		if ct := option_value(args, "--content-type", ""); ct != "" do append(&fields, json_kv("content_type", ct))
		if desc := option_value(args, "--description", ""); desc != "" do append(&fields, json_kv("description", desc))
		ctl_agent_call(endpoint, token, "agent.artifact.create", json_object_from_slice(fields[:]))
	case "show":
		artifact_id := pos(tokens, 1)
		if artifact_id == "" { print_agent_help([]string{"artifact"}); return }
		fields := make([dynamic]string)
		append(&fields, json_kv("artifact_id", artifact_id))
		if has_flag(args, "--with-content") do append(&fields, json_kv_raw("with_content", "true"))
		ctl_agent_call(endpoint, token, "agent.artifact.show", json_object_from_slice(fields[:]))
	case "content", "get", "read":
		artifact_id := pos(tokens, 1)
		if artifact_id == "" { print_agent_help([]string{"artifact"}); return }
		ctl_agent_artifact_content(endpoint, token, artifact_id)
	case "download":
		artifact_id := pos(tokens, 1)
		dir := option_value(args, "--dir", option_value(args, "--out", ""))
		if artifact_id == "" || dir == "" { print_agent_help([]string{"artifact"}); return }
		ctl_agent_artifact_download(endpoint, token, artifact_id, dir)
	case:
		print_agent_help([]string{"artifact"})
	}
}

ctl_agent_artifact_content :: proc(endpoint, token, artifact_id: string) {
	response, ok := ctl_agent_local_call(endpoint, token, "agent.artifact.content", json_object(json_kv("artifact_id", artifact_id)))
	if !ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	if !strings.contains(response, `"ok":true`) {
		fmt.println(response)
		return
	}
	content := extract_json_string_unescaped(response, "content", "")
	fmt.print(content)
}

ctl_agent_artifact_download :: proc(endpoint, token, artifact_id, dir: string) {
	meta_response, meta_ok := ctl_agent_local_call(endpoint, token, "agent.artifact.show", json_object(json_kv("artifact_id", artifact_id)))
	if !meta_ok { fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`); os.exit(1) }
	if !strings.contains(meta_response, `"ok":true`) { fmt.println(meta_response); return }
	content_response, content_ok := ctl_agent_local_call(endpoint, token, "agent.artifact.content", json_object(json_kv("artifact_id", artifact_id)))
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

// print_agent_help renders the two-level skill-style help
// (docs/agent-api-redesign.md §4.5). Level 1 = the overview; Level 2 = a
// detailed reference per group. Deterministic + no network.
print_agent_help :: proc(cmd: []string) {
	resource := ""
	if len(cmd) > 0 {
		if cmd[0] == "agent" || cmd[0] == "help" {
			if len(cmd) > 1 do resource = cmd[1]
		} else {
			resource = cmd[0]
		}
	}
	switch resource {
	case "bridge", "bridges": print_help_bridge(); return
	case "agents": print_help_agents(); return
	case "task-chain", "task-chains": print_help_task_chain(); return
	case "task", "tasks": print_help_task(); return
	case "chat", "chats": print_help_chat(); return
	case "artifact", "artifacts": print_help_artifact(); return
	case "memory": print_help_memory(); return
	case "context": fmt.println("ham-ctl context\nOne-shot snapshot of this instance: chain, current task, unread counts.\nExample:\n  ham-ctl context"); return
	case "start-success": fmt.println("ham-ctl start-success\nSignal this instance is ready (idempotent).\nExample:\n  ham-ctl start-success"); return
	}
	print_help_overview()
}

print_help_overview :: proc() {
	fmt.println("ham-ctl — Heimdall agent CLI (talks to your local Bridge with your agent token)")
	fmt.println("")
	fmt.println("USAGE")
	fmt.println("  ham-ctl <group> <verb> [<positional>] [--flags]")
	fmt.println("  Everything below is callable by any Bridge-launched agent. IDs are positional;")
	fmt.println("  each concept has exactly one flag. Run `ham-ctl <group> --help` for details.")
	fmt.println("")
	fmt.println("GROUPS")
	fmt.println("  bridge      Discover bridges + their providers (Hub-registered and configured)")
	fmt.println("  agents      Durable identities, templates, and runtime instances")
	fmt.println("  task-chain  Your task chains")
	fmt.println("  task        Tasks within a chain (one command per action)")
	fmt.println("  chat        Read your inbox / send to the user or another agent")
	fmt.println("  memory      Propose a memory")
	fmt.println("  artifact    Create / read / download artifacts")
	fmt.println("  context     One-shot snapshot of this instance (chain, task, unread)")
	fmt.println("  start-success  Signal this instance is ready")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl bridge list")
	fmt.println("  ham-ctl bridge providers --bridge brg_abc")
	fmt.println("  ham-ctl agents new-instance agt_abc --project proj_x --bridge brg_abc --provider claude --tier smart")
	fmt.println("  ham-ctl agents start   inst_123")
	fmt.println("  ham-ctl agents stop    inst_123 --reason \"done for now\"")
	fmt.println("  ham-ctl agents restart inst_123")
	fmt.println("  ham-ctl task show inst_task_1")
	fmt.println("  ham-ctl task comment inst_task_1 --body \"pushed fix, tests green\"")
	fmt.println("  ham-ctl task status  inst_task_1 --status in_validation")
	fmt.println("  ham-ctl chat read")
	fmt.println("  ham-ctl chat send --to user --body \"Done — ready for review.\"")
	fmt.println("  ham-ctl chat send --to inst_reviewer --body \"Can you LGTM inst_task_1?\"")
	fmt.println("")
	fmt.println("  ham-ctl <group> --help    # detailed help for any group")
}

print_help_bridge :: proc() {
	fmt.println("ham-ctl bridge — discover bridges and their providers")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list [--scope hub|configured|all]   List bridges. default all: Hub-registered")
	fmt.println("                                      + locally-configured peers + this host (self).")
	fmt.println("  providers [--bridge <id>]           Providers (+ tiers) for one/all Hub bridges.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl bridge list")
	fmt.println("  ham-ctl bridge list --scope configured")
	fmt.println("  ham-ctl bridge providers --bridge brg_abc")
}

print_help_agents :: proc() {
	fmt.println("ham-ctl agents — durable identities, templates, and runtime instances")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list                                List durable agent identities.")
	fmt.println("  identity create --name <n>          Create a durable agent.")
	fmt.println("      [--template <id>] [--provider <p>] [--tier <t>] [--slug <s>] [--instructions <t>]")
	fmt.println("  template list                       List agent templates (personas).")
	fmt.println("  template create --name <n>          Create a template.")
	fmt.println("      [--description <d>] [--persona <t>] [--instructions <t>]")
	fmt.println("  instance list [--agent <id>] [--live]   List instances (durable, or --live).")
	fmt.println("  new-instance <agent-id>             Launch a NEW instance of a durable agent.")
	fmt.println("      [--project <id>] [--bridge <id>] [--provider <p>] [--tier <t>] [--chain <id>]")
	fmt.println("  start   <agent-instance-id>          Start a STOPPED instance (409 if already running).")
	fmt.println("  stop    <agent-instance-id> [--reason <t>]   Stop a running instance.")
	fmt.println("  restart <agent-instance-id>          Restart (stop-then-start) an instance.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl agents list")
	fmt.println("  ham-ctl agents new-instance agt_abc --project proj_x --provider claude --tier smart")
	fmt.println("  ham-ctl agents start inst_123")
	fmt.println("  ham-ctl agents template create --name coder --persona 'You write code.'")
}

print_help_task_chain :: proc() {
	fmt.println("ham-ctl task-chain — your task chains")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list [--mine] [--project <id>]      List chains (--mine = ones you coordinate).")
	fmt.println("  show [<chain-id>]                   Show a chain (defaults to your current chain).")
	fmt.println("  set-title <title> [--chain <id>]    Rename a chain.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl task-chain list --mine")
	fmt.println("  ham-ctl task-chain show chain_abc")
	fmt.println("  ham-ctl task-chain set-title 'Auth hardening' --chain chain_abc")
}

print_help_task :: proc() {
	fmt.println("ham-ctl task — tasks within a task chain")
	fmt.println("")
	fmt.println("Exactly one command per action; there is no `done`, `comments`, or `votes`.")
	fmt.println("Positional <task-id> identifies the task. --chain defaults to your current chain.")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list [--chain <id>]                     List tasks in the chain.")
	fmt.println("  show <task-id>                          Show a task with its comments and votes.")
	fmt.println("  create --title <t>                      Create a task.")
	fmt.println("      [--description <d>] [--assignee <instance-id>] [--reviewer <instance-id>] [--chain <id>]")
	fmt.println("  comment <task-id> --body <t>            Add a comment (the only way to comment).")
	fmt.println("      [--notify <id,id>]")
	fmt.println("  status <task-id> --status <s>           Change status; use in_validation to submit for")
	fmt.println("                                          review (there is no separate `done`).")
	fmt.println("  vote <task-id> --result <lgtm|ngtm>     Cast a review vote (the only way to vote).")
	fmt.println("      [--comment <t>]")
	fmt.println("  nudge <task-id> [--message <t>]         Nudge the task's owner.")
	fmt.println("  set-current <task-id>                   Mark this task as your current task.")
	fmt.println("  depend <task-id> --on <task-id>         Add a dependency.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl task show inst_task_1")
	fmt.println("  ham-ctl task comment inst_task_1 --body 'pushed fix' --notify inst_rev")
	fmt.println("  ham-ctl task status inst_task_1 --status in_validation")
	fmt.println("  ham-ctl task vote inst_task_1 --result lgtm --comment 'clean'")
}

print_help_chat :: proc() {
	fmt.println("ham-ctl chat — read your inbox / send to the user or another agent")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  read [--limit N] [--since T] [--include-read] [--transcript]   Read messages.")
	fmt.println("  send --to <user|agent-instance-id> --body <t> | --stdin        Send a message.")
	fmt.println("      --to is REQUIRED: `user` for the bound user, or an agent-instance-id.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl chat read")
	fmt.println("  ham-ctl chat send --to user --body 'Done — ready for review.'")
	fmt.println("  ham-ctl chat send --to inst_reviewer --body 'Can you LGTM inst_task_1?'")
}

print_help_artifact :: proc() {
	fmt.println("ham-ctl artifact — create / read / download artifacts")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  list")
	fmt.println("  create --name <name> [--kind <kind>] [--content <text>|--file <path>|--stdin]")
	fmt.println("  show <artifact-id> [--with-content]")
	fmt.println("  content <artifact-id>                Print the raw artifact content.")
	fmt.println("  download <artifact-id> --dir <dir>   Write to a file (inferred extension).")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl artifact list")
	fmt.println("  ham-ctl artifact create --name test-log --kind markdown --file /tmp/test.log")
	fmt.println("  ham-ctl artifact content art_123")
	fmt.println("  ham-ctl artifact download art_123 --dir /tmp")
}

print_help_memory :: proc() {
	fmt.println("ham-ctl memory — propose a durable memory for later review")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  propose --type <t> --title <t> [--body <t>] [--evidence <t>]")
	fmt.println("      [--template <id>] [--project <id>] [--bridge <id>] [--agent <id>]")
	fmt.println("  Scope flags are optional: agent defaults to the caller's own; the rest to global.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl memory propose --type fact --title 'Test command' --body 'nix develop --command odin check src/hub'")
	fmt.println("  ham-ctl memory propose --type habit --title 'Reviewer checklist' --body '...' --template tmpl_reviewer")
}
