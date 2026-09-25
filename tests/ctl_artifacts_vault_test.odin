package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ── REQ-VAULT-ARTIFACTS-1 CLI Specification Unit Tests ────────────────────────

TEST_ARTIFACT_VAULT_KEY_SPEC :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_ARTIFACT_VAULT_KEY_SPEC  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_artifact_create_encryption_with_vault_key_spec :: proc(t: ^testing.T) {
	orig_name := "production-database-creds.env"
	orig_desc := "Production credentials for core distributed database cluster"
	orig_content := "DB_USER=admin\nDB_PASS=ultra_secret_pw_99\n"

	args := []string{
		"--name", orig_name,
		"--description", orig_desc,
		"--content", orig_content,
		"--kind", "text",
		"--project", "proj_core_99",
		"--vault-key", TEST_ARTIFACT_VAULT_KEY_SPEC,
	}

	out := ctl_agentmode_artifact_create_params(args)

	testing.expect(t, strings.contains(out, `"kind":"text"`), "kind must be plaintext")
	testing.expect(t, strings.contains(out, `"project_id":"proj_core_99"`), "project_id must be plaintext")

	testing.expect(t, !strings.contains(out, orig_name), "name must not leak plaintext")
	testing.expect(t, strings.contains(out, `"name":"vault:v1:`), "name must be armored with vault:v1:")
	testing.expect(t, !strings.contains(out, orig_desc), "description must not leak plaintext")
	testing.expect(t, strings.contains(out, `"description":"vault:v1:`), "description must be armored with vault:v1:")
	testing.expect(t, !strings.contains(out, orig_content), "content must not leak plaintext")
	testing.expect(t, strings.contains(out, `"content":"vault:v1:`), "content must be armored with vault:v1:")

	val, err := json.parse_string(out, parse_integers = true, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "emitted params must be valid JSON")
	obj := val.(json.Object)

	enc_name := string(obj["name"].(json.String))
	dec_name, dn_ok := vault_decrypt_text_hex(enc_name, TEST_ARTIFACT_VAULT_KEY_SPEC, context.temp_allocator)
	testing.expect(t, dn_ok, "name must decrypt successfully")
	testing.expect_value(t, dec_name, orig_name)

	enc_desc := string(obj["description"].(json.String))
	dec_desc, dd_ok := vault_decrypt_text_hex(enc_desc, TEST_ARTIFACT_VAULT_KEY_SPEC, context.temp_allocator)
	testing.expect(t, dd_ok, "description must decrypt successfully")
	testing.expect_value(t, dec_desc, orig_desc)

	enc_content := string(obj["content"].(json.String))
	dec_content, dc_ok := vault_decrypt_text_hex(enc_content, TEST_ARTIFACT_VAULT_KEY_SPEC, context.temp_allocator)
	testing.expect(t, dc_ok, "content must decrypt successfully")
	testing.expect_value(t, dec_content, orig_content)
}

@(test)
test_artifact_show_and_list_transparent_decryption_spec :: proc(t: ^testing.T) {
	orig_name := "zero-knowledge-keys.json"
	orig_desc := "Distributed vault root key shards"
	orig_content := "{\"shard_1\":\"secret_key_material\"}"

	enc_name, _ := vault_encrypt_text_hex(orig_name, TEST_ARTIFACT_VAULT_KEY_SPEC, context.temp_allocator)
	enc_desc, _ := vault_encrypt_text_hex(orig_desc, TEST_ARTIFACT_VAULT_KEY_SPEC, context.temp_allocator)
	enc_content, _ := vault_encrypt_text_hex(orig_content, TEST_ARTIFACT_VAULT_KEY_SPEC, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"v":1,"ok":true,"data":{{"data":{{"artifact_id":"art_spec_001","name":"%s","description":"%s","content":"%s","kind":"json"}}}}}}`,
		enc_name, enc_desc, enc_content,
	)

	decrypted := ctl_decrypt_json_string(raw_json, TEST_ARTIFACT_VAULT_KEY_SPEC, true, context.temp_allocator)
	testing.expect(t, strings.contains(decrypted, orig_name), "decrypted json must contain original name")
	testing.expect(t, strings.contains(decrypted, orig_desc), "decrypted json must contain original description")
	testing.expect(t, strings.contains(decrypted, orig_content), "decrypted json must contain original content")
	testing.expect(t, strings.contains(decrypted, `"kind":"json"`), "kind must be preserved")
	testing.expect(t, !strings.contains(decrypted, "vault:v1:"), "decrypted json must not contain vault armor")
}

@(test)
test_artifact_download_and_content_decryption_spec :: proc(t: ^testing.T) {
	orig_content := "# Sensitive Deployment Topology\nNodes must connect through bastion host."
	enc_content, enc_ok := vault_encrypt_text_hex(orig_content, TEST_ARTIFACT_VAULT_KEY_SPEC, context.temp_allocator)
	testing.expect(t, enc_ok, "encryption must succeed")

	// Decrypt with configured key
	decrypted := ctl_decrypt_or_fallback_armored(enc_content, TEST_ARTIFACT_VAULT_KEY_SPEC, true, context.temp_allocator)
	testing.expect_value(t, decrypted, orig_content)

	// Unconfigured key returns fallback
	unconf := ctl_decrypt_or_fallback_armored(enc_content, "", false, context.temp_allocator)
	testing.expect(t, strings.has_prefix(unconf, "[Encrypted: vault:v1:"), "unconfigured key must yield fallback")

	// Legacy unarmored content returns unchanged
	legacy := "# Public Documentation\nThis is completely unencrypted."
	dec_legacy := ctl_decrypt_or_fallback_armored(legacy, TEST_ARTIFACT_VAULT_KEY_SPEC, true, context.temp_allocator)
	testing.expect_value(t, dec_legacy, legacy)
}
