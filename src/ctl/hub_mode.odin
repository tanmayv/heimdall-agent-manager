package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import base64 "core:encoding/base64"
import httpc "odin_test:lib/httpc"

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
	if ctl_user_token_removed(user_token) do return
	if hub_url == "" || user_token == "" { fmt.println(`{"ok":false,"message":"hub mode requires --hub-url and --user-token (or HAM_HUB_URL/HEIMDALL_HUB_URL and HAM_HUB_USER_TOKEN/HEIMDALL_USER_TOKEN)"}`); return }
	hub := ctl_hub_make(strings.trim_right(hub_url, "/"), user_token)
	if resource == "me" { ctl_hub_request(hub, {method = .GET, path = ctl_api("me")}); return }
	if resource == "health" { ctl_hub_request(hub, {method = .GET, path = ctl_api("health")}); return }
	if resource == "agents" { ctl_hub_agents(hub, action, args); return }
	if resource == "launch" { ctl_hub_launch(hub, args); return }
	if resource == "chats" { ctl_hub_chats(hub, action, args); return }
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
	if resource == "projects" || resource == "project" { ctl_hub_projects(hub, action, args); return }
	if resource == "artifacts" || resource == "artifact" { ctl_hub_artifacts(hub, cmd[idx + 1:], args); return }
	if resource == "memories" || resource == "memory" { ctl_hub_memories(hub, cmd[idx + 1:], args); return }
	if resource == "cards" || resource == "card" { ctl_hub_cards(hub, cmd[idx + 1:], args); return }
	if resource == "actions" || resource == "action" { ctl_hub_actions(hub, cmd[idx + 1:], args); return }
	if resource == "issues" || resource == "issue" { ctl_issues_command(cmd[idx:], args); return }
	fmt.println("usage: ham-ctl hub <me|health|agents|launch|chats|tasks|task-chains|projects|artifacts|memories|cards|actions|issues> ...")
}

Ctl_Agent_Create_Body :: struct {
	name:         string `json:"name"`,
	slug:         string `json:"slug"`,
	template_id:  string `json:"template_id"`,
	instructions: string `json:"instructions"`,
}

ctl_hub_agents :: proc(hub: Ctl_Hub, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(hub, {method = .GET, path = ctl_api("agents")}); return }
	if action == "instances" { ctl_hub_request(hub, {method = .GET, path = ctl_api("agent-instances")}); return }
	if action == "running" || action == "live" {
		query := []httpc.Query_Param{{"runtime_status", "live"}}
		ctl_hub_request(hub, {method = .GET, path = ctl_api("agent-instances"), query = query})
		return
	}
	if action == "create" {
		name := option_value(args, "--name", "")
		if name == "" { fmt.println("usage: ham-ctl hub agents create --name <name> [--slug <slug>] [--template <id>]"); return }
		body := Ctl_Agent_Create_Body{
			name         = name,
			slug         = option_value(args, "--slug", name),
			template_id  = option_value(args, "--template", ""),
			instructions = option_value(args, "--instructions", ""),
		}
		ctl_hub_request(hub, {method = .POST, path = ctl_api("agents"), body = httpc.json_body(body)})
		return
	}
	if action == "update" {
		// User token only: an agent must not be able to lift its own permission
		// gate, so the hub PATCH stays user-authenticated (REQ-EXT-PERM-2).
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		if agent_id == "" { fmt.println(CTL_HUB_AGENTS_UPDATE_USAGE); return }
		body, ok, msg := ctl_agents_update_body(args)
		if !ok { fmt.println(msg); fmt.println(CTL_HUB_AGENTS_UPDATE_USAGE); return }
		ctl_hub_request(hub, {method = .PATCH, path = ctl_api("agents", agent_id), body = httpc.json_body(body)})
		return
	}
	fmt.println("usage: ham-ctl hub agents <list|instances|running|live|create|update>")
}

CTL_HUB_AGENTS_UPDATE_USAGE :: "usage: ham-ctl hub agents update --agent-id <agt_id> [--name <n>] [--slug <s>] [--template <id>] [--instructions <t>] [--permission-mode yolo|ask]"

// Ctl_Agent_Update_Body is the PATCH /api/v1/agents/<id> body: only the fields
// passed are sent (the hub keeps the rest).
Ctl_Agent_Update_Body :: struct {
	name:            string `json:"name,omitempty"`,
	slug:            string `json:"slug,omitempty"`,
	template_id:     string `json:"template_id,omitempty"`,
	instructions:    string `json:"instructions,omitempty"`,
	permission_mode: string `json:"permission_mode,omitempty"`,
}

// ctl_agents_update_body builds the PATCH body. --permission-mode is checked
// here so a typo fails locally instead of as a hub validation error.
ctl_agents_update_body :: proc(args: []string) -> (body: Ctl_Agent_Update_Body, ok: bool, msg: string) {
	body.name = option_value(args, "--name", "")
	body.slug = option_value(args, "--slug", "")
	body.template_id = option_value(args, "--template", "")
	body.instructions = option_value(args, "--instructions", "")
	if v := option_value(args, "--permission-mode", ""); v != "" {
		if v != "yolo" && v != "ask" do return {}, false, "--permission-mode must be 'yolo' or 'ask'"
		body.permission_mode = v
	}
	if body == {} do return {}, false, "agents update needs at least one of --name, --slug, --template, --instructions, --permission-mode"
	return body, true, ""
}

Ctl_Launch_Body :: struct {
	agent_id:     string `json:"agent_id"`,
	bridge_id:    string `json:"bridge_id"`,
	provider:     string `json:"provider"`,
	model:        string `json:"model"`,
	project_id:   string `json:"project_id"`,
	chain_id:     string `json:"chain_id"`,
	display_name: string `json:"display_name,omitempty"`,
}

ctl_hub_launch :: proc(hub: Ctl_Hub, args: []string) {
	agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
	provider := option_value(args, "--provider", "")
	model := option_value(args, "--model", "")
	if agent_id == "" || option_value(args, "--bridge-id", "") == "" || provider == "" || model == "" { fmt.println("usage: ham-ctl hub launch --agent-id <agent_id> --bridge-id <bridge_id> --provider <provider> --model <model> [--display-name <name>] [--project-id <id>] [--chain-id <id>]"); return }
	body := Ctl_Launch_Body{
		agent_id     = agent_id,
		bridge_id    = option_value(args, "--bridge-id", ""),
		provider     = provider,
		model        = model,
		project_id   = option_value(args, "--project-id", option_value(args, "--project", "")),
		chain_id     = option_value(args, "--chain-id", option_value(args, "--chain", "")),
		display_name = option_value(args, "--display-name", ""),
	}
	ctl_hub_request(hub, {method = .POST, path = ctl_api("agent-instances"), body = httpc.json_body(body)})
}

Ctl_Message_Body :: struct {
	body: string `json:"body"`,
}

Ctl_Chat_Create_Body :: struct {
	agent_id:          string                  `json:"agent_id"`,
	agent_instance_id: string                  `json:"agent_instance_id"`,
	bridge_id:         string                  `json:"bridge_id"`,
	provider:          string                  `json:"provider"`,
	model:             string                  `json:"model"`,
	project_id:        string                  `json:"project_id"`,
	chain_id:          string                  `json:"chain_id"`,
	title:             string                  `json:"title"`,
	initial_message:   Maybe(Ctl_Message_Body) `json:"initial_message,omitempty"`,
}

ctl_hub_chats :: proc(hub: Ctl_Hub, action: string, args: []string) {
	if action == "" || action == "list" { ctl_hub_request(hub, {method = .GET, path = ctl_api("chats")}); return }
	if action == "create" {
		agent_id := option_value(args, "--agent-id", option_value(args, "--agent", ""))
		instance_id := option_value(args, "--agent-instance-id", option_value(args, "--instance-id", ""))
		if agent_id == "" && instance_id == "" { fmt.println("usage: ham-ctl hub chats create --agent-id <agent_id>|--agent-instance-id <id> [--body <text>]"); return }
		body := Ctl_Chat_Create_Body{
			agent_id          = agent_id,
			agent_instance_id = instance_id,
			bridge_id         = option_value(args, "--bridge-id", ""),
			provider          = option_value(args, "--provider", ""),
			model             = option_value(args, "--model", ""),
			project_id        = option_value(args, "--project-id", option_value(args, "--project", "")),
			chain_id          = option_value(args, "--chain-id", option_value(args, "--chain", "")),
		}
		// The title and the first message are vault content (the UI seals and decrypts
		// both); sealed here too, never sent in plaintext (finding N3).
		title := option_value(args, "--title", "")
		first := option_value(args, "--body", "")
		if title != "" || first != "" {
			kr := ctl_vault_keyring_for_write(args)
			title = ctl_seal_if(title, kr)
			first = ctl_seal_if(first, kr)
		}
		body.title = title
		if first != "" do body.initial_message = Ctl_Message_Body{body = first}
		ctl_hub_request(hub, {method = .POST, path = ctl_api("chats"), body = httpc.json_body(body)})
		return
	}
	if action == "send" {
		cid := option_value(args, "--conversation-id", option_value(args, "--chat-id", ""))
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if cid == "" || body == "" { fmt.println("usage: ham-ctl hub chats send --conversation-id <id> --body <text>"); return }
		body = ctl_seal_if(body, ctl_vault_keyring_for_write(args))
		ctl_hub_request(hub, {method = .POST, path = ctl_api("chats", cid, "messages"), body = httpc.json_body(Ctl_Message_Body{body = body})})
		return
	}
	if action == "messages" || action == "fetch" {
		cid := option_value(args, "--conversation-id", option_value(args, "--chat-id", ""))
		if cid == "" { fmt.println("usage: ham-ctl hub chats messages --conversation-id <id>"); return }
		ctl_hub_request(hub, {method = .GET, path = ctl_api("chats", cid, "messages")})
		return
	}
	fmt.println("usage: ham-ctl hub chats <list|create|send|messages>")
}

Ctl_Hub_Project_Create_Body :: struct {
	name:         string `json:"name"`,
	slug:         string `json:"slug"`,
	description:  string `json:"description,omitempty"`,
	repo_url:     string `json:"repo_url"`,
	vcs_kind:     string `json:"vcs_kind"`,
	default_path: string `json:"default_path"`,
}

ctl_hub_projects :: proc(hub: Ctl_Hub, action: string, args: []string) {
	keyring, key_ok := ctl_read_vault_keyring(args, context.temp_allocator)

	if action == "" || action == "list" {
		resp, ok := ctl_hub_request_string(hub, {method = .GET, path = ctl_api("projects")})
		if !ok do return
		dec := ctl_decrypt_vault_json(resp, keyring, key_ok)
		defer delete(dec)
		fmt.println(dec)
		return
	}
	if action == "create" {
		name := option_value(args, "--name", "")
		if name == "" { fmt.println("usage: ham-ctl hub projects create --name <name> [--slug <slug>] [--description <text>] [--repo-url <url>] [--vcs-kind <git|jj|none>] [--default-path <path>]"); return }
		desc := option_value(args, "--description", option_value(args, "--desc", ""))
		keyring = ctl_vault_keyring_for_write(args)
		key_ok = true
		if !is_vault_armored(name) {
			name = ctl_seal_or_exit(name, keyring)
		}
		if desc != "" && !is_vault_armored(desc) {
			desc = ctl_seal_or_exit(desc, keyring)
		}
		body := Ctl_Hub_Project_Create_Body{
			name         = name,
			slug         = option_value(args, "--slug", ""),
			description  = desc,
			repo_url     = option_value(args, "--repo-url", option_value(args, "--repo", "")),
			vcs_kind     = option_value(args, "--vcs-kind", ""),
			default_path = option_value(args, "--default-path", option_value(args, "--path", "")),
		}
		resp, ok := ctl_hub_request_string(hub, {method = .POST, path = ctl_api("projects"), body = httpc.json_body(body)})
		if !ok do return
		dec := ctl_decrypt_vault_json(resp, keyring, key_ok)
		defer delete(dec)
		fmt.println(dec)
		return
	}
	project_id := option_value(args, "--project-id", option_value(args, "--project", ""))
	if project_id == "" { fmt.println("usage: ham-ctl hub projects <show|update> --project-id <id>"); return }
	if action == "show" {
		resp, ok := ctl_hub_request_string(hub, {method = .GET, path = ctl_api("projects", project_id)})
		if !ok do return
		dec := ctl_decrypt_vault_json(resp, keyring, key_ok)
		defer delete(dec)
		fmt.println(dec)
		return
	}
	if action == "update" {
		keyring = ctl_vault_keyring_for_write(args)
		key_ok = true
		body: Ctl_Project_Body
		if name := option_value(args, "--name", ""); name != "" {
			if !is_vault_armored(name) {
				name = ctl_seal_or_exit(name, keyring)
			}
			body.name = name
		}
		body.slug = option_value(args, "--slug", "")
		if desc := option_value(args, "--description", option_value(args, "--desc", "")); desc != "" {
			if !is_vault_armored(desc) {
				desc = ctl_seal_or_exit(desc, keyring)
			}
			body.description = desc
		}
		body.repo_url = option_value(args, "--repo-url", option_value(args, "--repo", ""))
		body.vcs_kind = option_value(args, "--vcs-kind", "")
		body.default_path = option_value(args, "--default-path", option_value(args, "--path", ""))
		resp, ok := ctl_hub_request_string(hub, {method = .PATCH, path = ctl_api("projects", project_id), body = httpc.json_body(body)})
		if !ok do return
		dec := ctl_decrypt_vault_json(resp, keyring, key_ok)
		defer delete(dec)
		fmt.println(dec)
		return
	}
	fmt.println("usage: ham-ctl hub projects <list|create|show|update>")
}

Ctl_Artifact_Create_Body :: struct {
	name:           string        `json:"name"`,
	kind:           string        `json:"kind"`,
	content_base64: string        `json:"content_base64,omitempty"`,
	content:        Maybe(string) `json:"content,omitempty"`,
	description:    string        `json:"description"`,
	content_type:   string        `json:"content_type"`,
	project_id:     string        `json:"project_id"`,
}

Ctl_Artifact_Update_Body :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
}

ctl_hub_artifacts :: proc(hub: Ctl_Hub, tokens, args: []string) {
	action := pos(tokens, 0)
	if action == "" || action == "list" {
		query := ctl_query_make()
		ctl_query_add(&query, "project_id", option_value(args, "--project-id", option_value(args, "--project", "")))
		ctl_query_add(&query, "agent_instance_id", option_value(args, "--agent-instance-id", option_value(args, "--agent-instance", "")))
		ctl_query_add(&query, "agent_id", option_value(args, "--agent-id", option_value(args, "--agent", "")))
		ctl_query_add(&query, "task_id", option_value(args, "--task-id", option_value(args, "--task", "")))
		ctl_query_add(&query, "chain_id", option_value(args, "--chain-id", option_value(args, "--chain", "")))
		ctl_query_add(&query, "kind", option_value(args, "--kind", ""))
		ctl_query_add(&query, "since", option_value(args, "--since", ""))
		ctl_query_add(&query, "until", option_value(args, "--until", ""))
		ctl_query_add(&query, "sort", option_value(args, "--sort", option_value(args, "--sort-field", "")))
		ctl_query_add(&query, "order", option_value(args, "--order", option_value(args, "--sort-order", "")))
		ctl_query_add(&query, "limit", option_value(args, "--limit", ""))
		ctl_query_add(&query, "cursor", option_value(args, "--cursor", ""))
		if has_flag(args, "--include-deleted") do ctl_query_add(&query, "include_deleted", "true")
		ctl_hub_request(hub, {method = .GET, path = ctl_api("artifacts"), query = query[:]})
		return
	}
	if action == "create" {
		name := option_value(args, "--name", "")
		content := option_value(args, "--content", "")
		content_base64 := ""
		if file_path := option_value(args, "--file", ""); file_path != "" {
			data, err := os.read_entire_file(file_path, context.allocator)
			if err != nil { fmt.println(ctl_error_json(fmt.tprintf("cannot read --file %q: %v", file_path, err))); os.exit(1) }
			if size_err := ctl_artifact_content_size_error(len(data)); size_err != "" { fmt.println(ctl_error_json(size_err)); os.exit(1) }
			content_base64 = base64.encode(data)
		}
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil { if size_err := ctl_artifact_content_size_error(len(data)); size_err != "" { fmt.println(ctl_error_json(size_err)); os.exit(1) }; content_base64 = base64.encode(data) } }
		if name == "" { fmt.println("usage: ham-ctl hub artifacts create --name <name> [--kind <kind>] [--content <text>|--file <path>|--stdin]"); return }
		body := Ctl_Artifact_Create_Body{
			name           = name,
			kind           = option_value(args, "--kind", "file"),
			content_base64 = content_base64,
			description    = option_value(args, "--description", ""),
			content_type   = option_value(args, "--content-type", option_value(args, "--mime", "")),
			project_id     = option_value(args, "--project-id", option_value(args, "--project", "")),
		}
		if content_base64 == "" do body.content = content
		ctl_hub_request(hub, {method = .POST, path = ctl_api("artifacts"), body = httpc.json_body(body)})
		return
	}
	artifact_id := pos(tokens, 1)
	if artifact_id == "" do artifact_id = option_value(args, "--artifact-id", option_value(args, "--artifact", option_value(args, "--id", "")))
	if artifact_id == "" { fmt.println("usage: ham-ctl hub artifacts <show|content|update|delete> --artifact-id <id>"); return }
	if action == "show" { ctl_hub_request(hub, {method = .GET, path = ctl_api("artifacts", artifact_id)}); return }
	if action == "content" || action == "get" { ctl_hub_request_raw(hub, {method = .GET, path = ctl_api("artifacts", artifact_id, "content")}); return }
	if action == "update" {
		body := Ctl_Artifact_Update_Body{name = option_value(args, "--name", ""), description = option_value(args, "--description", "")}
		ctl_hub_request(hub, {method = .PATCH, path = ctl_api("artifacts", artifact_id), body = httpc.json_body(body)})
		return
	}
	if action == "delete" { ctl_hub_request(hub, {method = .DELETE, path = ctl_api("artifacts", artifact_id)}); return }
	fmt.println("usage: ham-ctl hub artifacts <list|create|show|content|update|delete>")
}

// Ctl_Memory_Create_Body: targeting lists match the T1 contract
// (agent_ids/project_ids/bridge_ids/template_ids); an omitted dimension is sent
// as an empty array (applies to all).
Ctl_Memory_Create_Body :: struct {
	body:         string   `json:"body"`,
	type:         string   `json:"type"`,
	title:        string   `json:"title"`,
	description:  string   `json:"description"`,
	evidence:     string   `json:"evidence"`,
	agent_ids:    []string `json:"agent_ids"`,
	project_ids:  []string `json:"project_ids"`,
	bridge_ids:   []string `json:"bridge_ids"`,
	template_ids: []string `json:"template_ids"`,
}

ctl_hub_memories :: proc(hub: Ctl_Hub, tokens, args: []string) {
	action := pos(tokens, 0)
	if action == "" || action == "list" {
		query := ctl_query_make()
		ctl_query_add(&query, "status", option_value(args, "--status", ""))
		ctl_query_add(&query, "type", option_value(args, "--type", ""))
		ctl_query_add(&query, "limit", option_value(args, "--limit", ""))
		// Each targeting dimension is repeatable AND/OR comma-separated; the hub
		// takes one comma-separated value per dimension.
		ctl_query_add(&query, "agent_ids", strings.join(ctl_multi_values(args, "--agent-id", "--agent-ids", "--agent", "--agents"), ",", context.temp_allocator))
		ctl_query_add(&query, "project_ids", strings.join(ctl_multi_values(args, "--project-id", "--project-ids", "--project", "--projects"), ",", context.temp_allocator))
		ctl_query_add(&query, "bridge_ids", strings.join(ctl_multi_values(args, "--bridge-id", "--bridge-ids", "--bridge", "--bridges"), ",", context.temp_allocator))
		ctl_query_add(&query, "template_ids", strings.join(ctl_multi_values(args, "--template-id", "--template-ids", "--template", "--templates"), ",", context.temp_allocator))
		ctl_hub_request(hub, {method = .GET, path = ctl_api("memories"), query = query[:]})
		return
	}
	if action == "create" || action == "propose" {
		body := option_value(args, "--body", "")
		if has_flag(args, "--stdin") { data, err := os.read_entire_file("/dev/stdin", context.allocator); if err == nil do body = string(data) }
		if body == "" { fmt.println("usage: ham-ctl hub memories create --body <text> [--type <type>] [--title <title>] [--description <text>] [--agent-ids <id,...>] [--project-ids <id,...>] [--bridge-ids <id,...>] [--template-ids <id,...>]"); return }
		req := Ctl_Memory_Create_Body{
			body         = body,
			type         = option_value(args, "--type", "fact"),
			title        = option_value(args, "--title", ""),
			description  = option_value(args, "--description", ""),
			evidence     = option_value(args, "--evidence", ""),
			agent_ids    = ctl_multi_values(args, "--agent-id", "--agent-ids", "--agent", "--agents"),
			project_ids  = ctl_multi_values(args, "--project-id", "--project-ids", "--project", "--projects"),
			bridge_ids   = ctl_multi_values(args, "--bridge-id", "--bridge-ids", "--bridge", "--bridges"),
			template_ids = ctl_multi_values(args, "--template-id", "--template-ids", "--template", "--templates"),
		}
		ctl_hub_request(hub, {method = .POST, path = ctl_api("memories"), body = httpc.json_body(req)})
		return
	}
	memory_id := pos(tokens, 1)
	if memory_id == "" do memory_id = option_value(args, "--memory-id", option_value(args, "--memory", option_value(args, "--id", "")))
	if memory_id == "" { fmt.println("usage: ham-ctl hub memories <show|content|approve|reject|archive> <id> (or --memory-id <id>)"); return }
	if action == "show" { ctl_hub_request(hub, {method = .GET, path = ctl_api("memories", memory_id)}); return }
	if action == "content" || action == "get" {
		ctl_hub_memory_content(hub, memory_id)
		return
	}
	if action == "approve" || action == "reject" || action == "archive" { ctl_hub_request(hub, {method = .POST, path = ctl_api("memories", memory_id, action), body = ctl_empty_object_body()}); return }
	fmt.println("usage: ham-ctl hub memories <list|create|show|content|approve|reject|archive>")
}

ctl_hub_memory_content :: proc(hub: Ctl_Hub, memory_id: string) {
	resp, status, ok := ctl_hub_fetch(hub, {method = .GET, path = ctl_api("memories", memory_id)})
	if !ok { fmt.println(CTL_HUB_REQUEST_FAILED); return }
	if status >= 400 {
		fmt.println(resp)
		return
	}
	body := extract_json_string_unescaped(resp, "body", "")
	fmt.print(body)
}

// Ctl_Card_Create_Body: confidence is a JSON number; source_refs, operations
// and guard are the caller's JSON (validated locally).
Ctl_Card_Create_Body :: struct {
	title:        string     `json:"title"`,
	rationale:    string     `json:"rationale,omitempty"`,
	scope:        string     `json:"scope,omitempty"`,
	provider:     string     `json:"provider,omitempty"`,
	confidence:   Maybe(f64) `json:"confidence,omitempty"`,
	project_id:   string     `json:"project_id,omitempty"`,
	source_refs:  json.Value `json:"source_refs,omitempty"`,
	operations:   json.Value `json:"operations,omitempty"`,
	guard:        json.Value `json:"guard,omitempty"`,
	status:       string     `json:"status,omitempty"`,
	snooze_until: string     `json:"snooze_until,omitempty"`,
	ttl_at:       string     `json:"ttl_at,omitempty"`,
}

Ctl_Snooze_Body :: struct {
	snooze_until: string `json:"snooze_until"`,
}

ctl_hub_cards :: proc(hub: Ctl_Hub, tokens, args: []string) {
	action := pos(tokens, 0)
	if action == "" || action == "list" {
		query := ctl_query_make()
		ctl_query_add(&query, "status", option_value(args, "--status", ""))
		ctl_query_add(&query, "scope", option_value(args, "--scope", ""))
		ctl_query_add(&query, "provider", option_value(args, "--provider", ""))
		ctl_query_add(&query, "project_id", option_value(args, "--project", option_value(args, "--project-id", "")))
		ctl_query_add(&query, "limit", option_value(args, "--limit", ""))
		ctl_hub_request(hub, {method = .GET, path = ctl_api("cards"), query = query[:]})
		return
	}
	if action == "show" || action == "get" {
		card_id := pos(tokens, 1)
		if card_id == "" do card_id = option_value(args, "--card-id", option_value(args, "--card", option_value(args, "--id", "")))
		if card_id == "" { fmt.println("usage: ham-ctl hub cards show <card-id>"); return }
		if has_flag(args, "--json") || has_flag(args, "--raw") {
			ctl_hub_request(hub, {method = .GET, path = ctl_api("cards", card_id)})
			return
		}
		resp, _, ok := ctl_hub_fetch(hub, {method = .GET, path = ctl_api("cards", card_id)})
		if !ok { fmt.println(CTL_HUB_REQUEST_FAILED); return }
		render_human_card(resp)
		return
	}
	if action == "create" {
		title := option_value(args, "--title", pos(tokens, 1))
		if title == "" { fmt.println("usage: ham-ctl hub cards create --title <title> [--rationale <text>] [--scope <project|global>] [--provider <provider>] [--confidence <float>] [--project <id>] [--source-refs <json>] [--operations <json>] [--guard <json>]"); return }
		body := Ctl_Card_Create_Body{
			title        = title,
			rationale    = option_value(args, "--rationale", ""),
			scope        = option_value(args, "--scope", ""),
			provider     = option_value(args, "--provider", ""),
			project_id   = option_value(args, "--project", option_value(args, "--project-id", "")),
			status       = option_value(args, "--status", ""),
			snooze_until = option_value(args, "--snooze-until", ""),
			ttl_at       = option_value(args, "--ttl-at", ""),
		}
		if c := option_value(args, "--confidence", ""); c != "" do body.confidence = ctl_parse_number_flag("--confidence", c)
		if sr := option_value(args, "--source-refs", ""); sr != "" do body.source_refs = ctl_parse_json_flag("--source-refs", sr)
		if ops := option_value(args, "--operations", ""); ops != "" do body.operations = ctl_parse_json_flag("--operations", ops)
		if g := option_value(args, "--guard", ""); g != "" do body.guard = ctl_parse_json_flag("--guard", g)
		ctl_hub_request(hub, {method = .POST, path = ctl_api("cards"), body = httpc.json_body(body)})
		return
	}
	if action == "discard" || action == "accept" || action == "reject" || action == "snooze" {
		card_id := pos(tokens, 1)
		if card_id == "" do card_id = option_value(args, "--card-id", option_value(args, "--card", option_value(args, "--id", "")))
		if card_id == "" { fmt.printf("usage: ham-ctl hub cards %s <card-id>\n", action); return }
		body := ctl_empty_object_body()
		if action == "snooze" do body = httpc.json_body(Ctl_Snooze_Body{snooze_until = option_value(args, "--snooze-until", "")})
		ctl_hub_request(hub, {method = .POST, path = ctl_api("cards", card_id, action), body = body})
		return
	}
	fmt.println("usage: ham-ctl hub cards <list|show|create|discard|accept|reject|snooze> ...")
}

// API v2 actions. All request-building storage belongs to the command's
// temporary allocator; the transport marshals/sends it before that scope ends.
CTL_ACTIONS_USAGE :: "usage: ham-ctl hub actions <list|show|create|update|enable|disable|delete|runs> ..."
CTL_ACTIONS_HELP :: `ham-ctl hub actions <list|show|create|update|enable|disable|delete|runs>
  list
  show <action-id>
  create --prompt <text> [--name <text>] <target> [--min-interval <seconds>] [--disabled] [--trigger <spec>]... [--trigger-json <json>]...
  update <action-id> [--prompt <text>] [--name <text>] [<target>] [--min-interval <seconds>] [--trigger <spec>]... [--trigger-json <json>]...
  enable <action-id>
  disable <action-id>
  delete <action-id>
  runs <action-id> [--limit <n>] [--before <created_at>] [--before-id <run_id>]
Targets:
  --agent-id <id> [--project <id>] [--instance-strategy reuse|fresh_per_run] [--rule <bridge>:<provider>[:<model>]]...
  --instance <id>
  --bot <id>
Each rule part is a value or *; an omitted model means *. Rule order is flag order.
Triggers:
  cron:<5-field expr>[@<timezone>] (split at the last @)
  every:<seconds>
  at:<RFC3339>
  event:<event_type>[,chain=<id>][,<data key>=<value>]...
  --trigger-json takes a trigger object, including blackout_dates, active_from and active_until in its config.
On update, any --trigger or --trigger-json replaces the whole trigger list.
Any target flag replaces the whole target, including rules.
Delay: --delay <seconds|Ns|Nm|Nh> applies to the preceding --trigger or --trigger-json (0 disables; max 24h).

Examples:
  ham-ctl hub actions create --prompt 'Review' --agent-id agt_1 --rule '*:claude' --trigger 'cron:0 9 * * 1-5@America/New_York'
  ham-ctl hub actions update act_1 --trigger event:chain.state,state=completed
`

// Delays use whole seconds; accept a bare count or s/m/h suffix.
ctl_action_delay :: proc(text: string) -> (i64, bool) {
 if text == "" do return 0, false
 multiplier: i64 = 1
 number := text
 switch text[len(text)-1] {
 case 's': number = text[:len(text)-1]
 case 'm': number = text[:len(text)-1]; multiplier = 60
 case 'h': number = text[:len(text)-1]; multiplier = 3600
 }
 n, ok := strconv.parse_i64(number)
 if !ok || n < 0 || n > 86400/multiplier do return 0, false
 return n*multiplier, true
}

ctl_action_object :: proc() -> json.Object {
	return make(json.Object, context.temp_allocator)
}

ctl_action_trigger :: proc(spec: string) -> (json.Value, bool) {
	config := ctl_action_object()
	trigger := ctl_action_object()
	colon := strings.index(spec, ":")
	if colon < 1 || colon == len(spec) - 1 do return nil, false
	form, value := spec[:colon], spec[colon + 1:]
	switch form {
	case "cron":
		expr, zone := value, "UTC"
		if at := strings.last_index(value, "@"); at >= 0 {
			expr, zone = value[:at], value[at + 1:]
		}
		if strings.trim_space(expr) == "" || zone == "" do return nil, false
		trigger["kind"] = json.String("schedule")
		config["mode"] = json.String("cron")
		config["cron_expr"] = json.String(expr)
		config["timezone"] = json.String(zone)
	case "every":
		seconds, ok := strconv.parse_i64(value)
		if !ok || seconds <= 0 do return nil, false
		trigger["kind"] = json.String("schedule")
		config["mode"] = json.String("interval")
		config["interval_s"] = json.Integer(seconds)
	case "at":
		trigger["kind"] = json.String("schedule")
		config["mode"] = json.String("once")
		config["run_at"] = json.String(value)
	case "event":
		parts := strings.split(value, ",", context.temp_allocator)
		if parts[0] == "" do return nil, false
		trigger["kind"] = json.String("event")
		config["event_type"] = json.String(parts[0])
		data := ctl_action_object()
		for pair in parts[1:] {
			eq := strings.index(pair, "=")
			if eq <= 0 || eq == len(pair) - 1 do return nil, false
			key, val := pair[:eq], pair[eq + 1:]
			if key == "chain" {
				config["chain_id"] = json.String(val)
			} else {
				data[key] = json.String(val)
			}
		}
		config["data"] = data
	case:
		return nil, false
	}
	trigger["config"] = config
	return trigger, true
}

// Build without I/O so malformed syntax cannot send a partial request.
ctl_actions_request :: proc(tokens, args: []string) -> (Ctl_Request, bool) {
	action := pos(tokens, 0)
	if action == "" || action == "list" {
		return {method = .GET, path = ctl_api("actions")}, true
	}
	id := pos(tokens, 1)
	switch action {
	case "show", "delete", "enable", "disable", "runs":
		if id == "" || strings.has_prefix(id, "--") do return {}, false
		switch action {
		case "show":
			return {method = .GET, path = ctl_api("actions", id)}, true
		case "delete":
			return {method = .DELETE, path = ctl_api("actions", id)}, true
		case "enable", "disable":
			return {method = .POST, path = ctl_api("actions", id, action), body = ctl_empty_object_body()}, true
		case "runs":
			query := ctl_query_make()
			for flag in ([]string{"--limit", "--before", "--before-id"}) {
				if has_flag(args, flag) {
					value := option_value(args, flag, "")
					if value == "" || strings.has_prefix(value, "--") do return {}, false
					if flag == "--limit" {
						n, ok := strconv.parse_int(value)
						if !ok || n < 1 || n > 200 do return {}, false
						ctl_query_add(&query, "limit", value)
					} else {
						key := "before"
						if flag == "--before-id" do key = "before_id"
						ctl_query_add(&query, key, value)
					}
				}
			}
			return {method = .GET, path = ctl_api("actions", id, "runs"), query = query[:]}, true
		}
	case "create", "update":
	case:
		return {}, false
	}
	if action == "update" && (id == "" || strings.has_prefix(id, "--")) do return {}, false
	body := ctl_action_object()
	target := ctl_action_object()
	rules := make([dynamic]json.Value, context.temp_allocator)
	triggers := make([dynamic]json.Value, context.temp_allocator)
	target_given, triggers_given := false, false
	target_count := 0
	for i := 0; i < len(args); i += 1 {
		flag := args[i]
		switch flag {
		case "--disabled":
			if action != "create" do return {}, false
			body["enabled"] = json.Boolean(false)
		case "--prompt", "--name", "--min-interval", "--agent-id", "--project", "--instance-strategy", "--rule", "--instance", "--bot", "--trigger", "--trigger-json", "--delay":
			if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "--") do return {}, false
			i += 1
			value := args[i]
			switch flag {
			case "--delay":
                if len(triggers) == 0 do return {}, false
                delay, valid := ctl_action_delay(value)
                if !valid do return {}, false
                trigger, valid_object := triggers[len(triggers)-1].(json.Object)
                if !valid_object do return {}, false
                trigger["delay_s"] = json.Integer(delay)
            case "--prompt":
				body["prompt_text"] = json.String(value)
			case "--name":
				body["name"] = json.String(value)
			case "--min-interval":
				n, ok := strconv.parse_i64(value)
				if !ok do return {}, false
				body["min_interval_s"] = json.Integer(n)
			case "--agent-id", "--instance", "--bot":
				if value == "" do return {}, false
				target_given = true
				target_count += 1
				switch flag {
				case "--agent-id":
					target["kind"] = json.String("agent")
					target["agent_id"] = json.String(value)
				case "--instance":
					target["kind"] = json.String("instance")
					target["instance_id"] = json.String(value)
				case "--bot":
					target["kind"] = json.String("bot")
					target["bot_id"] = json.String(value)
				}
			case "--project":
				target_given = true
				target["project_id"] = json.String(value)
			case "--instance-strategy":
				target_given = true
				target["instance_strategy"] = json.String(value)
			case "--rule":
				target_given = true
				parts := strings.split(value, ":", context.temp_allocator)
				if len(parts) < 2 || len(parts) > 3 || parts[0] == "" || parts[1] == "" do return {}, false
				model := "*"
				if len(parts) == 3 {
					model = parts[2]
					if model == "" do return {}, false
				}
				rule := ctl_action_object()
				rule["bridge_id"] = json.String(parts[0])
				rule["provider"] = json.String(parts[1])
				rule["model"] = json.String(model)
				append(&rules, rule)
			case "--trigger", "--trigger-json":
				triggers_given = true
				trigger: json.Value
				ok := false
				if flag == "--trigger" {
					trigger, ok = ctl_action_trigger(value)
				} else {
					trigger, ok = ctl_parse_json_document(value)
					if _, object := trigger.(json.Object); !object do ok = false
				}
				if !ok do return {}, false
				append(&triggers, trigger)
			}
		}
	}
	if action == "create" {
		prompt, _ := body["prompt_text"].(json.String)
		if strings.trim_space(string(prompt)) == "" || !target_given do return {}, false
	}
	if target_given {
		if target_count != 1 do return {}, false
		kind, _ := target["kind"].(json.String)
		if kind != "agent" && (len(rules) > 0 || has_flag(args, "--project") || has_flag(args, "--instance-strategy")) do return {}, false
		if kind == "agent" do target["rules"] = json.Array(rules)
		body["target"] = target
	}
	if triggers_given do body["triggers"] = json.Array(triggers)
	if action == "create" {
		return {method = .POST, path = ctl_api("actions"), body = httpc.json_body(body)}, true
	}
	return {method = .PATCH, path = ctl_api("actions", id), body = httpc.json_body(body)}, true
}

// The same result is printed verbatim by the command, so API errors and newly
// added run states remain visible without maintaining a second server schema.
ctl_actions_response :: proc(hub: Ctl_Hub, tokens, args: []string) -> string {
	req, ok := ctl_actions_request(tokens, args)
	if !ok do return CTL_ACTIONS_USAGE
	response, _, reached := ctl_hub_fetch(hub, req, context.temp_allocator)
	if !reached do return CTL_HUB_REQUEST_FAILED
	return response
}

ctl_hub_actions :: proc(hub: Ctl_Hub, tokens, args: []string) {
	fmt.println(ctl_actions_response(hub, tokens, args))
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

print_hub_help :: proc(cmd: []string) {
	resource := ""
	if len(cmd) > 0 {
		if cmd[0] == "hub" || cmd[0] == "help" { if len(cmd) > 1 do resource = cmd[1] } else { resource = cmd[0] }
	}
	if resource == "agents" { fmt.println("ham-ctl hub agents <list|create|update>\nPurpose: manage durable Hub agent identities.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... agents list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... agents create --name reviewer --model normal\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... agents update --agent-id agt_123 --permission-mode ask"); return }
	if resource == "launch" { fmt.println("ham-ctl hub launch --agent-id <id> [--bridge-id <id>] [--model <model>]\nPurpose: start a new agent instance through Hub/Bridge.\nExample:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... launch --agent-id reviewer --model normal"); return }
	if resource == "chats" { fmt.println("ham-ctl hub chats <list|create|send|messages>\nPurpose: read/write user chat conversations.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... chats list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... chats send --conversation-id chat_123 --body 'Hello'"); return }
	if resource == "tasks" { fmt.println("ham-ctl hub tasks <list|create|update|publish|cancel|depend|comments> --chain-id <id>\nPurpose: manage Hub task records.\nUser approval:\n  create ... --require-user-approval\n  update ... --require-user-approval | --no-require-user-approval\n  --assignee/--reviewer take durable agent ids (agt_...) only.\nExample:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... tasks list --chain-id chain_123"); return }
	if resource == "task-chains" { fmt.println("ham-ctl hub task-chains <list|create|show|directory|publish|complete|pin|unpin>\nPurpose: manage Hub task chains.\nExample:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... task-chains create --title 'Fix bug'"); return }
	if resource == "projects" { fmt.println("ham-ctl hub projects <list|create|show|update>\nPurpose: manage Hub projects.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... projects list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... projects create --name demo --repo-url https://example/repo.git"); return }
	if resource == "artifacts" { fmt.println("ham-ctl hub artifacts <list|create|show|content|update|delete>\nPurpose: manage Hub artifacts.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... artifacts list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... artifacts create --name notes --content 'hello'"); return }
	if resource == "memories" || resource == "memory" { fmt.println("ham-ctl hub memories <list|create|show|content|approve|reject|archive>\nPurpose: manage Hub memories.\nExamples:\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... memories list\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... memories show mem_123\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... memories content mem_123\n  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... memories create --body 'Use nix check.' --title 'Test command'"); return }
	if resource == "cards" || resource == "card" {
		fmt.println("ham-ctl hub cards — action cards (user/Hub mode)")
		fmt.println("")
		fmt.println("VERBS")
		fmt.println("  list [--status <s>] [--scope <s>] [--provider <p>] [--project <id>] [--limit <n>]")
		fmt.println("                          List cards matching filters.")
		fmt.println("  show    <card-id> [--json|--raw]   Show card detail (formatted or raw JSON).")
		fmt.println("  create  --title <title> [--rationale <t>] [--scope <project|global>] [--provider <p>]")
		fmt.println("          [--confidence <f>] [--project <id>] [--source-refs <json>] [--operations <json>]")
		fmt.println("          [--guard <json>]   Create a new action card.")
		fmt.println("  discard <card-id>       Discard a card without executing operations.")
		fmt.println("  accept  <card-id>       Accept card and atomically execute all operations.")
		fmt.println("  reject  <card-id>       Reject a card (declined; operations not executed).")
		fmt.println("  snooze  <card-id> --snooze-until <ts>   Hide a card until the given time.")
		fmt.println("")
		fmt.println("OPERATIONS  (a card's operation types; each carries a human `label` shown in the dashboard)")
		fmt.println("  task.review             Post your review verdict on a task. args: task_id, attempt_no,")
		fmt.println("                          [verdict approve|request_changes (default approve)],")
		fmt.println("                          [summary (required for request_changes)], [findings <json array>].")
		fmt.println("  memory.approve          Approve a pending memory proposal.")
		fmt.println("  memory.reject           Reject a pending memory proposal.")
		fmt.println("  memory.create           Create a new durable memory.")
		fmt.println("  memory.update           Edit an existing memory's fields (incl. scope: agent/project/bridge/template ids).")
		fmt.println("  memory.delete           Archive (soft-delete) a memory.  (alias: memory.archive)")
		fmt.println("  project.update          Edit a project's name/description.")
		fmt.println("  project.delete          Archive (soft-delete) a project.")
		fmt.println("  task_chain.set_status   Change a task chain's status.")
		fmt.println("  agent.prompt            Send a prompt/message to an agent instance's conversation.")
		fmt.println("  agent.update            Edit a durable agent's fields (name/provider/model/instructions/...).")
		fmt.println("  agent.delete            Archive (soft-delete) a durable agent.")
		fmt.println("")
		fmt.println("  Operations run ATOMICALLY (all-or-nothing) only when a card is ACCEPTED; a single")
		fmt.println("  card may bundle several, applied in order.")
		fmt.println("")
		fmt.println("EXAMPLES")
		fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... cards list")
		fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... cards show crd_123")
		fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... cards accept crd_123")
		return
	}
	if resource == "actions" || resource == "action" { fmt.println(CTL_ACTIONS_HELP); return }
	if resource == "issues" || resource == "issue" { print_issues_help(); return }
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
	fmt.println("  memories     List/create/show/content/approve/reject/archive memories")
	fmt.println("  cards        List/show/create/discard/accept/reject/snooze action cards")
	fmt.println("  actions      List/show/create/update/enable/disable/delete/runs actions")
	fmt.println("  issues       List/show/create/update/comment/vote/unvote issues")
	fmt.println("examples:")
	fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... me")
	fmt.println("  ham-ctl hub --hub-url http://127.0.0.1:49322 --user-token hut_... cards list")
}

