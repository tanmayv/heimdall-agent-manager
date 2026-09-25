package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import cfg_lib "odin_test:lib/config"

// ── REQ-VAULT-ISSUES-CLI-1 Unit Tests ────────────────────────────────────────

TEST_ISSUE_VAULT_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ALT_ISSUE_VAULT_KEY  :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_ctl_read_vault_key_resolution :: proc(t: ^testing.T) {
	// 1. CLI flag override (--vault-key)
	args_flag := [?]string{"ham-ctl", "issue", "list", "--vault-key", TEST_ISSUE_VAULT_KEY}
	key_flag, ok_flag := ctl_read_vault_key(args_flag[:], context.temp_allocator)
	testing.expect(t, ok_flag, "vault key from --vault-key flag must resolve")
	testing.expect_value(t, key_flag, TEST_ISSUE_VAULT_KEY)

	// Invalid hex flag must be rejected
	args_invalid := [?]string{"ham-ctl", "issue", "list", "--vault-key", "invalid_short_hex"}
	_, ok_invalid := ctl_read_vault_key(args_invalid[:], context.temp_allocator)
	testing.expect(t, !ok_invalid, "invalid vault-key flag must be rejected")

	// 2. Environment variable HEIMDALL_VAULT_KEY
	_ = os.set_env("HEIMDALL_VAULT_KEY", TEST_ISSUE_VAULT_KEY)
	defer os.unset_env("HEIMDALL_VAULT_KEY")

	key_env, ok_env := ctl_read_vault_key(nil, context.temp_allocator)
	testing.expect(t, ok_env, "vault key from HEIMDALL_VAULT_KEY env must resolve")
	testing.expect_value(t, key_env, TEST_ISSUE_VAULT_KEY)

	// 3. Flag takes precedence over Environment variable
	args_override := [?]string{"ham-ctl", "issue", "list", "--vault-key", ALT_ISSUE_VAULT_KEY}
	key_override, ok_override := ctl_read_vault_key(args_override[:], context.temp_allocator)
	testing.expect(t, ok_override, "vault key flag override must resolve")
	testing.expect_value(t, key_override, ALT_ISSUE_VAULT_KEY)
}

@(test)
test_issue_write_encryption :: proc(t: ^testing.T) {
	orig_title := "Critical zero-day vulnerability in bridge authentication"
	orig_desc := "Steps to reproduce: send malformed token with null bytes to TCP socket."
	orig_body := "Investigating the root cause in src/bridge/agent_token_store.odin."

	// Encrypt title
	enc_title, title_ok := vault_encrypt_text_hex(orig_title, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	testing.expect(t, title_ok, "title encryption must succeed")
	testing.expect(t, is_vault_armored(enc_title), "encrypted title must have vault:v1: prefix")
	testing.expect(t, !strings.contains(enc_title, orig_title), "encrypted title must not leak plaintext")

	// Encrypt description
	enc_desc, desc_ok := vault_encrypt_text_hex(orig_desc, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	testing.expect(t, desc_ok, "description encryption must succeed")
	testing.expect(t, is_vault_armored(enc_desc), "encrypted description must have vault:v1: prefix")
	testing.expect(t, !strings.contains(enc_desc, orig_desc), "encrypted description must not leak plaintext")

	// Encrypt comment body
	enc_body, body_ok := vault_encrypt_text_hex(orig_body, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	testing.expect(t, body_ok, "body encryption must succeed")
	testing.expect(t, is_vault_armored(enc_body), "encrypted body must have vault:v1: prefix")
	testing.expect(t, !strings.contains(enc_body, orig_body), "encrypted body must not leak plaintext")

	// Decrypt round-trip
	dec_title, dt_ok := vault_decrypt_text_hex(enc_title, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dt_ok, "title decryption must succeed")
	testing.expect_value(t, dec_title, orig_title)

	dec_desc, dd_ok := vault_decrypt_text_hex(enc_desc, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	testing.expect(t, dd_ok, "description decryption must succeed")
	testing.expect_value(t, dec_desc, orig_desc)

	dec_body, db_ok := vault_decrypt_text_hex(enc_body, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	testing.expect(t, db_ok, "body decryption must succeed")
	testing.expect_value(t, dec_body, orig_body)
}

@(test)
test_issue_show_transparent_decryption :: proc(t: ^testing.T) {
	orig_title := "Zero-Knowledge Task Vault"
	orig_desc  := "All sensitive fields are encrypted with local AES-GCM key."
	orig_body  := "First comment with encrypted content."

	enc_title, _ := vault_encrypt_text_hex(orig_title, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_desc, _  := vault_encrypt_text_hex(orig_desc, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_body, _  := vault_encrypt_text_hex(orig_body, TEST_ISSUE_VAULT_KEY, context.temp_allocator)

	// User-mode response envelope
	user_json := fmt.tprintf(
		`{{"ok":true,"data":{{"issue_id":"iss_test_1","title":"%s","description":"%s","comments":[{{"comment_id":"cmt_1","body":"%s"}}]}}}}`,
		enc_title, enc_desc, enc_body,
	)

	dec_user := ctl_decrypt_issues_json(user_json, TEST_ISSUE_VAULT_KEY, true, context.temp_allocator)
	testing.expect(t, strings.contains(dec_user, orig_title), "user-mode response contains decrypted title")
	testing.expect(t, strings.contains(dec_user, orig_desc), "user-mode response contains decrypted description")
	testing.expect(t, strings.contains(dec_user, orig_body), "user-mode response contains decrypted comment body")
	testing.expect(t, !strings.contains(dec_user, "vault:v1:"), "user-mode response contains no raw armored strings")

	// Agent-mode response envelope (wrapped in {"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":...}})
	agent_json := fmt.tprintf(
		`{{"v":1,"id":"ham-ctl-agent","ok":true,"data":{{"data":{{"issue_id":"iss_test_1","title":"%s","description":"%s","comments":[{{"comment_id":"cmt_1","body":"%s"}}]}},"meta":{{"request_id":"req_1"}}}}}}`,
		enc_title, enc_desc, enc_body,
	)

	dec_agent := ctl_decrypt_issues_json(agent_json, TEST_ISSUE_VAULT_KEY, true, context.temp_allocator)
	testing.expect(t, strings.contains(dec_agent, orig_title), "agent-mode response contains decrypted title")
	testing.expect(t, strings.contains(dec_agent, orig_desc), "agent-mode response contains decrypted description")
	testing.expect(t, strings.contains(dec_agent, orig_body), "agent-mode response contains decrypted comment body")
	testing.expect(t, !strings.contains(dec_agent, "vault:v1:"), "agent-mode response contains no raw armored strings")
}

@(test)
test_issue_list_transparent_decryption :: proc(t: ^testing.T) {
	orig_title1 := "First Encrypted Issue"
	orig_preview1 := "Preview snippet of first issue"
	orig_title2 := "Second Encrypted Issue"
	orig_preview2 := "Preview snippet of second issue"

	enc_title1, _ := vault_encrypt_text_hex(orig_title1, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_preview1, _ := vault_encrypt_text_hex(orig_preview1, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_title2, _ := vault_encrypt_text_hex(orig_title2, TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_preview2, _ := vault_encrypt_text_hex(orig_preview2, TEST_ISSUE_VAULT_KEY, context.temp_allocator)

	list_json := fmt.tprintf(
		`{{"v":1,"id":"ham-ctl-agent","ok":true,"data":{{"data":[{{"issue_id":"iss_1","title":"%s","description_preview":"%s"}},{{"issue_id":"iss_2","title":"%s","description_preview":"%s"}}],"page":{{"limit":50,"has_more":false}}}}}}`,
		enc_title1, enc_preview1, enc_title2, enc_preview2,
	)

	dec_list := ctl_decrypt_issues_json(list_json, TEST_ISSUE_VAULT_KEY, true, context.temp_allocator)
	testing.expect(t, strings.contains(dec_list, orig_title1), "list contains decrypted title 1")
	testing.expect(t, strings.contains(dec_list, orig_preview1), "list contains decrypted preview 1")
	testing.expect(t, strings.contains(dec_list, orig_title2), "list contains decrypted title 2")
	testing.expect(t, strings.contains(dec_list, orig_preview2), "list contains decrypted preview 2")
	testing.expect(t, !strings.contains(dec_list, "vault:v1:"), "list contains no raw armored strings")
}

@(test)
test_issue_unconfigured_fallback :: proc(t: ^testing.T) {
	enc_title, _ := vault_encrypt_text_hex("Secret Title", TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	enc_desc, _  := vault_encrypt_text_hex("Secret Description", TEST_ISSUE_VAULT_KEY, context.temp_allocator)

	raw_json := fmt.tprintf(
		`{{"ok":true,"data":{{"issue_id":"iss_unconfigured","title":"%s","description":"%s","status":"new"}}}}`,
		enc_title, enc_desc,
	)

	// Decrypt without vault key (key_configured = false)
	fallback_json := ctl_decrypt_issues_json(raw_json, "", false, context.temp_allocator)

	// Fallback should format as [Encrypted: vault:v1:...] without crashing
	expected_title_fallback := fmt.tprintf("[Encrypted: %s]", enc_title)
	expected_desc_fallback  := fmt.tprintf("[Encrypted: %s]", enc_desc)

	testing.expect(t, strings.contains(fallback_json, expected_title_fallback), "fallback contains [Encrypted: vault:v1:...] title")
	testing.expect(t, strings.contains(fallback_json, expected_desc_fallback), "fallback contains [Encrypted: vault:v1:...] description")
	testing.expect(t, strings.contains(fallback_json, `"status":"new"`), "non-armored metadata preserved")
}

@(test)
test_issue_tampered_or_wrong_key_fallback :: proc(t: ^testing.T) {
	enc_title, _ := vault_encrypt_text_hex("Tamper Test Title", TEST_ISSUE_VAULT_KEY, context.temp_allocator)
	raw_json := fmt.tprintf(`{{"ok":true,"data":{{"issue_id":"iss_tamper","title":"%s"}}}}`, enc_title)

	// Decrypt with a completely different vault key
	fallback_wrong_key := ctl_decrypt_issues_json(raw_json, ALT_ISSUE_VAULT_KEY, true, context.temp_allocator)

	expected_fallback := fmt.tprintf("[Encrypted: %s]", enc_title)
	testing.expect(t, strings.contains(fallback_wrong_key, expected_fallback), "wrong key falls back to [Encrypted: vault:v1:...]")

	// Decrypt with truncated armored string
	truncated_armored := enc_title[:20]
	trunc_json := fmt.tprintf(`{{"ok":true,"data":{{"issue_id":"iss_trunc","title":"%s"}}}}`, truncated_armored)
	fallback_trunc := ctl_decrypt_issues_json(trunc_json, TEST_ISSUE_VAULT_KEY, true, context.temp_allocator)

	expected_trunc_fallback := fmt.tprintf("[Encrypted: %s]", truncated_armored)
	testing.expect(t, strings.contains(fallback_trunc, expected_trunc_fallback), "truncated payload falls back to [Encrypted: vault:v1:...]")
}
