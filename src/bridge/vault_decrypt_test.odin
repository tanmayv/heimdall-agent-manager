package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import cfg_lib "odin_test:lib/config"

TEST_VAULT_KEY_HEX :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

keystore_test_mutex: sync.Mutex

@(test)
test_bridge_vault_encrypt_decrypt_roundtrip :: proc(t: ^testing.T) {
	plaintext := "Secret Task Title for Agents"
	armored, enc_ok := bridge_encrypt_vault_ciphertext_hex(plaintext, TEST_VAULT_KEY_HEX)
	testing.expect(t, enc_ok, "encryption must succeed")
	defer delete(armored)
	testing.expect(t, strings.has_prefix(armored, "vault:v1:"), "armored string must start with vault:v1:")

	decrypted, dec_ok := bridge_decrypt_vault_ciphertext_hex(armored, TEST_VAULT_KEY_HEX)
	testing.expect(t, dec_ok, "decryption must succeed")
	defer delete(decrypted)
	testing.expect_value(t, decrypted, plaintext)
}

@(test)
test_bridge_vault_decrypt_wrong_key_fails :: proc(t: ^testing.T) {
	plaintext := "Top Secret"
	armored, _ := bridge_encrypt_vault_ciphertext_hex(plaintext, TEST_VAULT_KEY_HEX)
	defer delete(armored)

	wrong_key := "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
	decrypted, ok := bridge_decrypt_vault_ciphertext_hex(armored, wrong_key)
	defer if ok do delete(decrypted)
	testing.expect(t, !ok, "decryption with wrong key must fail")
}

@(test)
test_bridge_vault_decrypt_unarmored_fallback :: proc(t: ^testing.T) {
	raw := "Plain unarmored task title"
	decrypted, ok := bridge_decrypt_vault_ciphertext_hex(raw, TEST_VAULT_KEY_HEX)
	testing.expect(t, ok, "unarmored text must pass through")
	defer delete(decrypted)
	testing.expect_value(t, decrypted, raw)
}

@(test)
test_bridge_vault_embedded_decryption_suite :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL. keystore_test_mutex alone does not
	// serialise this test against the ~29 env-mutating tests that hold
	// bridge_test_config_mutex instead - two disjoint locks exclude nobody, so those
	// two sets raced on one shared value (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	os.set_env("HEIMDALL_VAULT_KEY", TEST_VAULT_KEY_HEX)
	defer os.unset_env("HEIMDALL_VAULT_KEY")

	// 1. Embedded vault tokens in notices
	{
		title_plaintext := "Implement Feature X"
		armored_title, _ := bridge_encrypt_vault_ciphertext_hex(title_plaintext, TEST_VAULT_KEY_HEX)
		defer delete(armored_title)

		comment_plaintext := "All tests green!"
		armored_comment, _ := bridge_encrypt_vault_ciphertext_hex(comment_plaintext, TEST_VAULT_KEY_HEX)
		defer delete(armored_comment)

		notice := strings.concatenate({`[Comment] @Alice commented on "`, armored_title, `" (task_42): "`, armored_comment, `"`})
		defer delete(notice)

		decrypted := bridge_decrypt_embedded_vault_tokens(notice)
		defer delete(decrypted)

		expected := `[Comment] @Alice commented on "Implement Feature X" (task_42): "All tests green!"`
		testing.expect_value(t, decrypted, expected)
	}

	// 2. Corrupted token fallback
	{
		corrupted := `[Review Requested] @coder submitted "vault:v1:invalid_base64_payload==" (task_1)`
		decrypted := bridge_decrypt_embedded_vault_tokens(corrupted)
		defer delete(decrypted)

		expected := `[Review Requested] @coder submitted "[Encrypted]" (task_1)`
		testing.expect_value(t, decrypted, expected)
	}

	// 3. Bootstrap header decryption & coordinator display name
	{
		chain_title := "Confidential Chain"
		armored_title, _ := bridge_encrypt_vault_ciphertext_hex(chain_title, TEST_VAULT_KEY_HEX)
		defer delete(armored_title)

		d := Bridge_Bootstrap_Descriptor{
			instance_id              = "inst_worker_1",
			agent_name               = "heimdall-engineer",
			role                     = "worker",
			chain_id                 = "chain_abc",
			chain_title              = armored_title,
			coordinator_id           = "inst_coord_1",
			coordinator_display_name = "Coordinator Agent #1",
		}

		header := bridge_bootstrap_render_header(d)
		defer delete(header)

		testing.expect(t, strings.contains(header, "Task chain: Confidential Chain (chain_abc)"), "header must have decrypted chain title")
	}
}

@(test)
test_bridge_read_vault_key_from_disk :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL. keystore_test_mutex alone does not
	// serialise this test against the ~29 env-mutating tests that hold
	// bridge_test_config_mutex instead - two disjoint locks exclude nobody, so those
	// two sets raced on one shared value (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_lock_and_purge()
	defer keystore_lock_and_purge()

	prev_env, had_env := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_env {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_env)
			delete(prev_env)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEY")

	// This test used to write its fixture over the OPERATOR'S REAL key: it resolved
	// the true `~/.config/heimdall/vault_key`, O_TRUNC'd it, wrote a dummy key on
	// top, and put the original back only from a `defer` — with an `os.remove(path)`
	// on the error branch. `defer` does not run on a panic, abort, timeout or
	// SIGKILL, so a run that died at the wrong moment DESTROYED the credential
	// outright. That is strictly worse than the rename in unseal_security_test.odin,
	// which at least left the bytes on disk under a backup name (iss_18db4d8f4b153b62).
	//
	// The sandbox redirects HOME and HEIMDALL_HOME, so `cfg_lib.expand_home` below
	// resolves inside a temp dir and the real key is unreachable by construction.
	// Nothing of the operator's is in scope any more, so there is no longer anything
	// to back up or restore — the read-and-restore block this replaces is gone, not
	// merely hardened.
	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "read_from_disk")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

	// Only heap-allocated when expansion actually happened; see the note on the
	// guarded deletes in unseal_security_test.odin. The sandbox above sets both
	// HOME and HEIMDALL_HOME, so expansion normally does happen -- the guard keeps
	// this correct if the sandbox ever fails to open rather than freeing a literal.
	key_rel := "~/.config/heimdall/vault_key"
	path := cfg_lib.expand_home(key_rel)
	defer if raw_data(path) != raw_data(key_rel) do delete(path)

	test_key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	fd := posix.open(c_path, posix.O_Flags{.CREAT, .WRONLY, .TRUNC}, posix.mode_t{.IRUSR, .IWUSR})
	if fd >= 0 {
		_ = posix.write(fd, raw_data(test_key), len(test_key))
		_ = posix.close(fd)
	}

	key, ok := bridge_read_vault_key()
	testing.expect(t, ok, "bridge_read_vault_key should read disk key")
	if ok {
		testing.expect_value(t, key, test_key)
		delete(key)
	}
}

@(test)
test_bridge_vault_tri_state_lifecycle :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL. keystore_test_mutex alone does not
	// serialise this test against the ~29 env-mutating tests that hold
	// bridge_test_config_mutex instead - two disjoint locks exclude nobody, so those
	// two sets raced on one shared value (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_lock_and_purge()
	defer keystore_lock_and_purge()

	// bridge_vault_status() falls back to bridge_read_vault_key(), which resolves
	// ~/.config/heimdall/vault_key through cfg_lib.expand_home. Without this
	// redirect it finds the OPERATOR'S REAL KEY and reports Unlocked at step 2,
	// where this test requires Locked -- so the test both read a real credential
	// and only passed on hosts that happened not to have one. Opened INSIDE
	// bridge_test_config_mutex, which is already held outermost above.
	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "tri_state")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

	prev_env, had_env := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_env {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_env)
			delete(prev_env)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEY")

	// 1. When workspace vault is not configured -> Disabled
	bridge_workspace_vault_configured = false
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)
	testing.expect_value(t, bridge_vault_status_string(), "disabled")

	// 2. When workspace vault is configured but no key is present -> Locked
	bridge_workspace_vault_configured = true
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)
	testing.expect_value(t, bridge_vault_status_string(), "locked")

	// 3. When unsealed / key is set -> Unlocked
	keystore_store_vault_key(TEST_VAULT_KEY_HEX)
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Unlocked)
	testing.expect_value(t, bridge_vault_status_string(), "unlocked")

	// 4. When bridge_vault_lock() is called -> key purged, returns to Locked
	bridge_vault_lock()
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)
	testing.expect_value(t, bridge_vault_status_string(), "locked")

	// Reset
	bridge_workspace_vault_configured = false
}

@(test)
test_bridge_fs_rejects_when_vault_locked :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL. keystore_test_mutex alone does not
	// serialise this test against the ~29 env-mutating tests that hold
	// bridge_test_config_mutex instead - two disjoint locks exclude nobody, so those
	// two sets raced on one shared value (iss_18db48473fc5cb6d, 2026-10-04).
	// Taken OUTERMOST, before keystore_test_mutex: the acquisition graph stays acyclic.
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_lock_and_purge()
	defer keystore_lock_and_purge()

	// Same reason as test_bridge_vault_tri_state_lifecycle: the Locked assertion
	// below is only true if bridge_read_vault_key() cannot find a key on disk.
	sb, sandbox_ok := bridge_vault_test_sandbox_open(t, "fs_locked")
	defer bridge_vault_test_sandbox_close(&sb)
	if !sandbox_ok do return

	prev_env, had_env := os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	defer {
		if had_env {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_env)
			delete(prev_env)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEY")

	bridge_workspace_vault_configured = true
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)

	// fs_management reject check
	read_res := bridge_fs_read_file("test.txt", "/tmp", 0, 100)
	testing.expect(t, !read_res.ok, "read_file must fail when locked")
	testing.expect_value(t, read_res.error_code, "vault_locked")

	write_res := bridge_fs_write_file("test.txt", "content", "/tmp")
	testing.expect(t, !write_res.ok, "write_file must fail when locked")
	testing.expect_value(t, write_res.error_code, "vault_locked")

	grep_res := bridge_fs_grep("pattern", false, 10, "/tmp")
	testing.expect(t, !grep_res.ok, "grep must fail when locked")
	testing.expect_value(t, grep_res.error_code, "vault_locked")

	bridge_workspace_vault_configured = false
}
