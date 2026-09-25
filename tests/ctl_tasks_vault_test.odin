package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ── REQ-VAULT-TASKS-1 CLI Specification Unit Tests ───────────────────────────

TEST_TASK_VAULT_KEY_SPEC :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_TASK_VAULT_KEY_SPEC  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_task_create_encryption_with_vault_key_spec :: proc(t: ^testing.T) {
	orig_title := "Deploy Zero-Knowledge User Vault Secrets Engine"
	orig_desc := "Configure cloud hardware security module and distribute master keys."

	args := []string{
		"--title", orig_title,
		"--description", orig_desc,
		"--chain", "chain_vault_001",
		"--priority", "p1",
		"--assignee", "inst_worker_1",
		"--reviewer", "agt_reviewer_1,agt_reviewer_2",
		"--depends-on", "task_dep_alpha",
		"--vault-key", TEST_TASK_VAULT_KEY_SPEC,
	}

	out := ctl_agentmode_task_create_params(args)

	testing.expect(t, strings.contains(out, `"chain_id":"chain_vault_001"`), "chain_id must be plaintext")
	testing.expect(t, strings.contains(out, `"priority":"p1"`), "priority must be plaintext")
	testing.expect(t, strings.contains(out, `"assignee_ref"`), "assignee_ref must be preserved")
	testing.expect(t, strings.contains(out, `"reviewer_refs"`), "reviewer_refs must be preserved")
	testing.expect(t, strings.contains(out, `"depends_on":["task_dep_alpha"]`), "depends_on must be preserved")

	testing.expect(t, !strings.contains(out, orig_title), "title must not leak plaintext")
	testing.expect(t, strings.contains(out, `"title":"vault:v1:`), "title must be armored with vault:v1:")
	testing.expect(t, !strings.contains(out, orig_desc), "description must not leak plaintext")
	testing.expect(t, strings.contains(out, `"description":"vault:v1:`), "description must be armored with vault:v1:")

	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_title := string(obj["title"].(json.String))
	dec_title, dt_ok := vault_decrypt_text_hex(enc_title, TEST_TASK_VAULT_KEY_SPEC, context.temp_allocator)
	testing.expect(t, dt_ok, "title must decrypt successfully")
	testing.expect_value(t, dec_title, orig_title)

	enc_desc := string(obj["description"].(json.String))
	dec_desc, dd_ok := vault_decrypt_text_hex(enc_desc, TEST_TASK_VAULT_KEY_SPEC, context.temp_allocator)
	testing.expect(t, dd_ok, "description must decrypt successfully")
	testing.expect_value(t, dec_desc, orig_desc)
}

@(test)
test_task_show_and_list_transparent_decryption_spec :: proc(t: ^testing.T) {
	orig_title := "Confidential Microservice Migration"
	orig_desc := "Migrate payment authentication subsystem to zero-trust architecture."
	orig_preview := "Last comment: migration stage 1 completed smoothly."

	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_TASK_VAULT_KEY_SPEC, context.temp_allocator)
	enc_desc, _ := vault_encrypt_text_hex(orig_desc, TEST_TASK_VAULT_KEY_SPEC, context.temp_allocator)
	enc_preview, _ := vault_encrypt_text_hex(orig_preview, TEST_TASK_VAULT_KEY_SPEC, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"data":{{"task_id":"task_test_show_1","title":"%s","description":"%s","priority":"p1","status":"in_progress","comment_summary":{{"count":3,"last_comment_preview":"%s"}}}}}}}}`,
		enc_title, enc_desc, enc_preview,
	)

	decrypted := ctl_decrypt_json_string(raw_json, TEST_TASK_VAULT_KEY_SPEC, true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted, orig_title), "decrypted json must contain original title")
	testing.expect(t, strings.contains(decrypted, orig_desc), "decrypted json must contain original description")
	testing.expect(t, strings.contains(decrypted, orig_preview), "decrypted json must contain original comment preview")
	testing.expect(t, strings.contains(decrypted, `"priority":"p1"`), "priority must be preserved")
	testing.expect(t, !strings.contains(decrypted, "vault:v1:"), "decrypted json must not contain vault armor")
}

@(test)
test_task_comments_list_transparent_decryption_spec :: proc(t: ^testing.T) {
	orig_body_1 := "Detailed review: cryptographic primitives align with FIPS 140-3."
	orig_body_2 := "Second review comment: all unit tests passing with zero regressions."

	enc_body_1, _ := vault_encrypt_text_hex(orig_body_1, TEST_TASK_VAULT_KEY_SPEC, context.temp_allocator)
	enc_body_2, _ := vault_encrypt_text_hex(orig_body_2, TEST_TASK_VAULT_KEY_SPEC, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":[{{"comment_id":"cmt_1","task_id":"task_1","body":"%s"}},{{"comment_id":"cmt_2","task_id":"task_1","body":"%s"}}]}}`,
		enc_body_1, enc_body_2,
	)

	decrypted := ctl_decrypt_json_string(raw_json, TEST_TASK_VAULT_KEY_SPEC, true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted, orig_body_1), "decrypted comments must contain first body")
	testing.expect(t, strings.contains(decrypted, orig_body_2), "decrypted comments must contain second body")
	testing.expect(t, !strings.contains(decrypted, "vault:v1:"), "decrypted comments must not contain vault armor")
}
