package main

import "core:testing"
import "core:os"
import httpc "odin_test:lib/httpc"
import "core:strings"
import "core:sync"
import "core:encoding/json"

capability_body :: proc(t: ^testing.T, req: Ctl_Request) -> json.Object {
	body, ok := ctl_request_body_text(req.body)
	testing.expect(t, ok)
	value, parsed := ctl_parse_json_document(body)
	testing.expect(t, parsed, body)
	return value.(json.Object)
}

@(test)
test_ctl_projects_archive_unarchive_requests :: proc(t: ^testing.T) {
	for action in ([]string{"archive", "unarchive"}) {
		req := ctl_projects_archive_request("proj_1", action)
		testing.expect_value(t, req.method, httpc.Method.POST)
		testing.expect_value(t, ctl_test_target(t, req), strings.concatenate({"/api/v1/projects/proj_1/", action}, context.temp_allocator))
		body, _ := ctl_request_body_text(req.body)
		testing.expect_value(t, body, "{}")
	}
}

@(test)
test_ctl_projects_create_requires_default_path :: proc(t: ^testing.T) {
	testing.expect(t, !ctl_projects_create_valid(nil, "name"))
	testing.expect(t, ctl_projects_create_valid([]string{"--default-path", "/repo"}, "name"))
	testing.expect(t, strings.contains(CTL_PROJECT_CREATE_USAGE, "--default-path <path>"))
}

@(test)
test_ctl_memory_create_sends_active_status_and_no_default_agent_scope :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("capabilities-create")
	defer ctl_vault_test_sandbox_close(&sb)
	args := with_kr([]string{"--type", "fact", "--title", "Title", "--body", "Body"})
	req, ok, _ := ctl_memory_write_request("create", "", args)
	testing.expect(t, ok)
	testing.expect_value(t, req.method, httpc.Method.POST)
	testing.expect_value(t, ctl_test_target(t, req), "/api/v1/memories")
	obj := capability_body(t, req)
	testing.expect_value(t, string(obj["status"].(json.String)), "active")
	testing.expect(t, "agent_ids" not_in obj)
	testing.expect(t, strings.has_prefix(string(obj["title"].(json.String)), "vault:v2:"))
	testing.expect(t, strings.has_prefix(string(obj["body"].(json.String)), "vault:v2:"))
	for missing in ([]string{"--type", "--title", "--body"}) {
		bad := []string{"--type", "fact", "--title", "Title", "--body", "Body"}
		for &value, i in bad { if i > 0 && bad[i-1] == missing do value = "" }
		_, valid, _ := ctl_memory_write_request("create", "", bad)
		testing.expect(t, !valid)
	}
}

@(test)
test_ctl_memory_update_sends_only_given_fields :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("capabilities-update")
	defer ctl_vault_test_sandbox_close(&sb)
	req, ok, _ := ctl_memory_write_request("update", "mem_1", with_kr([]string{"--description", "", "--agent-ids", "", "--project-ids", "proj_a,proj_b"}))
	testing.expect(t, ok)
	testing.expect_value(t, req.method, httpc.Method.PATCH)
	testing.expect_value(t, ctl_test_target(t, req), "/api/v1/memories/mem_1")
	obj := capability_body(t, req)
	testing.expect_value(t, len(obj), 3)
	testing.expect_value(t, string(obj["description"].(json.String)), "")
	testing.expect_value(t, len(obj["agent_ids"].(json.Array)), 0)
	testing.expect_value(t, len(obj["project_ids"].(json.Array)), 2)
}

@(test)
test_ctl_memory_archive_request :: proc(t: ^testing.T) {
	req, ok, _ := ctl_memory_write_request("archive", "mem_1", nil)
	testing.expect(t, ok)
	testing.expect_value(t, req.method, httpc.Method.POST)
	testing.expect_value(t, ctl_test_target(t, req), "/api/v1/memories/mem_1/archive")
	body, _ := ctl_request_body_text(req.body)
	testing.expect_value(t, body, "{}")
}

@(test)
test_ctl_memory_propose_unchanged :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("capabilities-propose")
	defer ctl_vault_test_sandbox_close(&sb)
	params := ctl_agentmode_memory_propose_params(with_kr([]string{"--type", "fact", "--title", "Title", "--body", "Body", "--agent-ids", "agt_a,agt_b"}))
	decrypted := unseal_out(params)
	defer delete(decrypted)
	obj_value, ok := ctl_parse_json_document(decrypted)
	testing.expect(t, ok)
	obj := obj_value.(json.Object)
	testing.expect_value(t, string(obj["title"].(json.String)), "Title")
	testing.expect_value(t, string(obj["body"].(json.String)), "Body")
	testing.expect_value(t, len(obj["agent_ids"].(json.Array)), 2)
	testing.expect(t, "status" not_in obj && "params" not_in obj)
}

@(test)
test_ctl_agents_identity_update_body_and_validation :: proc(t: ^testing.T) {
	req, ok, _ := ctl_agents_identity_request("update", "agt_1", []string{"--name", "New", "--template", "tmpl_1", "--instructions", "", "--permission-mode", "ask"})
	testing.expect(t, ok)
	testing.expect_value(t, req.method, httpc.Method.PATCH)
	testing.expect_value(t, ctl_test_target(t, req), "/api/v1/agents/agt_1")
	obj := capability_body(t, req)
	testing.expect_value(t, len(obj), 4)
	testing.expect_value(t, string(obj["template_id"].(json.String)), "tmpl_1")
	testing.expect_value(t, string(obj["instructions"].(json.String)), "")
	for args in ([][]string{
		{"--permission-mode", "bad"}, {"--instructions", "x", "--instructions-file", "/missing"}, {},
		{"--instructions-file", "/missing-capabilities-file"},
	}) {
		_, valid, _ := ctl_agents_identity_request("update", "agt_1", args)
		testing.expect(t, !valid)
	}
	show, valid, _ := ctl_agents_identity_request("show", "agt_1", nil)
	testing.expect(t, valid && show.method == .GET)
	_, missing_valid, missing_message := ctl_agents_identity_request("show", "", nil)
	testing.expect(t, !missing_valid)
	testing.expect_value(t, missing_message, "usage: ham-ctl agents identity show <agent-id>")
	tokens := command_tokens([]string{"ham-ctl", "agents", "identity", "update", "agt_1", "--instructions-file", "/file"})
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 4)
}


@(test)
test_ctl_capability_response_requires_top_level_success :: proc(t: ^testing.T) {
	hub_success := `{"data":{"id":"proj_1"},"meta":{"request_id":"test"}}`
	testing.expect(t, ctl_capability_success(.User, 200, hub_success))
	testing.expect(t, ctl_capability_success(.User, 201, hub_success))
	testing.expect(t, ctl_capability_success(.User, 204, ""))
	testing.expect(t, !ctl_capability_success(.Agent, 200, hub_success))
	for status in ([]int{0, 199, 300, 400, 403, 500}) {
		testing.expect(t, !ctl_capability_success(.User, status, `{"error":{"message":"refused"}}`))
		// A success-looking body must not override HTTP failure.
		testing.expect(t, !ctl_capability_success(.User, status, `{"ok":true}`))
	}
	testing.expect(t, ctl_capability_success(.Agent, 0, `{"ok":true,"data":{}}`))
	for response in ([]string{
		`{"ok":false,"error":{"code":"hub_error","message":"refused","ok":true}}`,
		`{"error":{"code":"hub_error"}}`, `{"ok":"true"}`, `[]`, `invalid`,
	}) {
		testing.expect(t, !ctl_capability_success(.Agent, 0, response), response)
	}
}

@(test)
test_ctl_agents_identity_instructions_file :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("capabilities-instructions")
	defer ctl_vault_test_sandbox_close(&sb)
	path := strings.concatenate({sb.dir, "/instructions.md"}, context.temp_allocator)
	instructions := "Follow the café checklist.\nKeep this newline.\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)instructions) == nil)
	req, valid, message := ctl_agents_identity_request("update", "agt_1", []string{"--instructions-file", path})
	testing.expect(t, valid, message)
	obj := capability_body(t, req)
	testing.expect_value(t, len(obj), 1)
	testing.expect_value(t, string(obj["instructions"].(json.String)), instructions)
	testing.expect(t, os.write_entire_file(path, []u8{0xff}) == nil)
	_, valid, message = ctl_agents_identity_request("update", "agt_1", []string{"--instructions-file", path})
	testing.expect(t, !valid)
	testing.expect_value(t, message, "could not read --instructions-file")
}
