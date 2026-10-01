package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
test_task_chain_create_params_plaintext :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("task-chain-create-params-plaintext")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{
		"--title", "Alpha Task Chain",
		"--description", "Autonomous task chain for deployment.",
		"--kind", "team_work",
		"--coordinator", "agt_coord_1",
		"--bridge", "brg_local_1",
		"--project", "proj_alpha",
		"--provider", "jetski",
		"--tier", "smart",
	}

	params := ctl_agentmode_task_chain_create_params(args)
	defer delete(params)

	testing.expect(t, strings.contains(params, `"title":"Alpha Task Chain"`), "title should remain plaintext")
	testing.expect(t, strings.contains(params, `"description":"Autonomous task chain for deployment."`), "description should remain plaintext")
	testing.expect(t, strings.contains(params, `"kind":"team_work"`), "kind should be team_work")
	testing.expect(t, strings.contains(params, `"coordinator_agent_id":"agt_coord_1"`), "coordinator_agent_id should match")
	testing.expect(t, strings.contains(params, `"bridge_id":"brg_local_1"`), "bridge_id should match")
	testing.expect(t, strings.contains(params, `"project_id":"proj_alpha"`), "project_id should match")
	testing.expect(t, strings.contains(params, `"provider":"jetski"`), "provider should match")
	testing.expect(t, strings.contains(params, `"tier":"smart"`), "tier should match")
	testing.expect(t, !strings.contains(params, "vault:v1:"), "should not be encrypted without vault key")
}

@(test)
test_task_chain_create_params_aliases :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("task-chain-create-params-aliases")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{
		"--title", "Beta Chain",
		"--coordinator-agent-id", "agt_coord_2",
		"--bridge-id", "brg_2",
		"--project-id", "proj_2",
	}

	params := ctl_agentmode_task_chain_create_params(args)
	defer delete(params)

	testing.expect(t, strings.contains(params, `"title":"Beta Chain"`), "title should match")
	testing.expect(t, strings.contains(params, `"coordinator_agent_id":"agt_coord_2"`), "coordinator-agent-id alias should work")
	testing.expect(t, strings.contains(params, `"bridge_id":"brg_2"`), "bridge-id alias should work")
	testing.expect(t, strings.contains(params, `"project_id":"proj_2"`), "project-id alias should work")
	testing.expect(t, strings.contains(params, `"kind":"team_work"`), "default kind should be team_work")
}

@(test)
test_task_chain_create_params_positional_title :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("task-chain-create-params-positional-title")
	defer ctl_vault_test_sandbox_close(&sb)
	args := []string{
		"--coordinator", "agt_coord_3",
	}

	params := ctl_agentmode_task_chain_create_params(args, "Positional Title Chain")
	defer delete(params)

	testing.expect(t, strings.contains(params, `"title":"Positional Title Chain"`), "positional title should be used if --title is omitted")
}

@(test)
test_task_chain_create_params_with_vault_encryption :: proc(t: ^testing.T) {
	orig_title := "Confidential Microservice Deployment"
	orig_desc := "Deploy zero-trust proxy and internal tokens."

	args := []string{
		"--title", orig_title,
		"--description", orig_desc,
		"--coordinator", "agt_sec_coord",
		"--bridge", "brg_sec_1",
		"--project", "proj_sec",
		"--vault-key", TEST_CHAIN_VAULT_KEY,
	}

	params := ctl_agentmode_task_chain_create_params(args)
	defer delete(params)

	testing.expect(t, !strings.contains(params, orig_title), "title must not leak in plaintext")
	testing.expect(t, !strings.contains(params, orig_desc), "description must not leak in plaintext")
	testing.expect(t, strings.contains(params, `"title":"vault:v1:`), "title must be vault armored")
	testing.expect(t, strings.contains(params, `"description":"vault:v1:`), "description must be vault armored")
	testing.expect(t, strings.contains(params, `"coordinator_agent_id":"agt_sec_coord"`), "coordinator must remain plaintext")
	testing.expect(t, strings.contains(params, `"bridge_id":"brg_sec_1"`), "bridge must remain plaintext")
	testing.expect(t, strings.contains(params, `"project_id":"proj_sec"`), "project must remain plaintext")

	val, err := json.parse_string(params, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_title := string(obj["title"].(json.String))
	dec_title, dt_ok := vault_decrypt_text_hex(enc_title, TEST_CHAIN_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dt_ok, "title must decrypt successfully")
	testing.expect_value(t, dec_title, orig_title)

	enc_desc := string(obj["description"].(json.String))
	dec_desc, dd_ok := vault_decrypt_text_hex(enc_desc, TEST_CHAIN_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dd_ok, "description must decrypt successfully")
	testing.expect_value(t, dec_desc, orig_desc)
}
