package main

// REQ-VAULT-HARDEN-6, REQ-VAULT-HARDEN-9, REQ-VAULT-HARDEN-12:
// Automated test suite for keystore container fallback and in-memory resilience.

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

KEYSTORE_SEC_TEST_KEY_1 :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
KEYSTORE_SEC_TEST_KEY_2 :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_keystore_container_fallback_in_memory_resilience :: proc(t: ^testing.T) {
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

	// 1. Simulate Docker / Kubernetes seccomp profile blocking keyctl with EPERM (REQ-VAULT-HARDEN-9)
	keystore_set_mock_syscall_error(KEYSTORE_ERR_EPERM)
	defer keystore_set_mock_syscall_error(0)

	keystore_wipe_in_memory_vault_key()

	// Storing key must succeed via in-memory fallback without crashing
	ok_eperm, err_eperm := keystore_store_vault_key(KEYSTORE_SEC_TEST_KEY_1)
	testing.expect(t, ok_eperm, "keystore_store_vault_key must succeed via in-memory fallback on EPERM")
	testing.expect_value(t, err_eperm, KEYSTORE_ERR_EPERM)

	// In-memory buffer must hold the unsealed key
	mem_key, mem_ok := keystore_read_in_memory_vault_key()
	testing.expect(t, mem_ok, "keystore_read_in_memory_vault_key must return key from JIT memory")
	defer if mem_ok do delete(mem_key)
	testing.expect_value(t, mem_key, KEYSTORE_SEC_TEST_KEY_1)

	// bridge_read_vault_key() must transparently resolve the in-memory key
	bridge_key, bridge_ok := bridge_read_vault_key()
	testing.expect(t, bridge_ok, "bridge_read_vault_key must resolve key from in-memory fallback")
	defer if bridge_ok do delete(bridge_key)
	testing.expect_value(t, bridge_key, KEYSTORE_SEC_TEST_KEY_1)

	// Vault status must report Unlocked
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Unlocked)

	// 2. Simulate environment without CONFIG_KEYS returning ENOSYS
	keystore_set_mock_syscall_error(KEYSTORE_ERR_ENOSYS)
	keystore_wipe_in_memory_vault_key()

	ok_enosys, err_enosys := keystore_store_vault_key(KEYSTORE_SEC_TEST_KEY_2)
	testing.expect(t, ok_enosys, "keystore_store_vault_key must succeed via in-memory fallback on ENOSYS")
	testing.expect_value(t, err_enosys, KEYSTORE_ERR_ENOSYS)

	bridge_key2, bridge_ok2 := bridge_read_vault_key()
	testing.expect(t, bridge_ok2, "bridge_read_vault_key must resolve second key from in-memory fallback")
	defer if bridge_ok2 do delete(bridge_key2)
	testing.expect_value(t, bridge_key2, KEYSTORE_SEC_TEST_KEY_2)

	// 3. Purging must zero and wipe the in-memory buffer
	keystore_lock_and_purge()
	_, after_purge_ok := keystore_read_in_memory_vault_key()
	testing.expect(t, !after_purge_ok, "in-memory buffer must be purged after keystore_lock_and_purge")
}

@(test)
test_keystore_in_memory_rejection_of_invalid_keys :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_wipe_in_memory_vault_key()
	defer keystore_wipe_in_memory_vault_key()

	// Short key
	ok_short := keystore_store_in_memory_vault_key("abcd1234")
	testing.expect(t, !ok_short, "short hex key must be rejected from in-memory storage")

	// Non-hex characters
	non_hex := "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
	ok_non_hex := keystore_store_in_memory_vault_key(non_hex)
	testing.expect(t, !ok_non_hex, "non-hex key must be rejected from in-memory storage")

	// Empty key
	ok_empty := keystore_store_in_memory_vault_key("")
	testing.expect(t, !ok_empty, "empty key must be rejected from in-memory storage")
}
