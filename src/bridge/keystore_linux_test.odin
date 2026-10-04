#+build linux
package main

import "core:os"
import "core:sync"
import "core:testing"

KEYSTORE_TEST_KEY_1 :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
KEYSTORE_TEST_KEY_2 :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

@(test)
test_keystore_kernel_keyring_roundtrip :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_set_mock_syscall_error(0)
	keystore_lock_and_purge()
	defer keystore_lock_and_purge()

	// Store key into kernel keyring
	ok, err := keystore_store_vault_key(KEYSTORE_TEST_KEY_1)
	testing.expect(t, ok, "keystore_store_vault_key must succeed")
	testing.expect_value(t, err, 0)

	// Read key from kernel keyring
	read_key, read_ok := keystore_read_keyring_vault_key()
	testing.expect(t, read_ok, "keystore_read_keyring_vault_key must find key")
	defer if read_ok do delete(read_key)
	testing.expect_value(t, read_key, KEYSTORE_TEST_KEY_1)

	// Unlink key from kernel keyring
	unlinked := keystore_unlink_vault_key()
	testing.expect(t, unlinked, "keystore_unlink_vault_key must succeed")

	// Read should now fail to find key in keyring
	after_key, after_unlink_ok := keystore_read_keyring_vault_key()
	if after_unlink_ok do delete(after_key)
	testing.expect(t, !after_unlink_ok, "key should no longer exist in keyring after unlink")
}

@(test)
test_keystore_container_eperm_fallback :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	// Simulate container environment where keyctl returns EPERM (seccomp restriction)
	keystore_set_mock_syscall_error(KEYSTORE_ERR_EPERM)
	defer keystore_set_mock_syscall_error(0)

	keystore_wipe_in_memory_vault_key()
	defer keystore_wipe_in_memory_vault_key()

	// Must fall back gracefully to in-memory mode without failing startup (REQ-VAULT-HARDEN-9)
	ok, err := keystore_store_vault_key(KEYSTORE_TEST_KEY_2)
	testing.expect(t, ok, "keystore_store_vault_key must succeed via fallback on EPERM")
	testing.expect_value(t, err, KEYSTORE_ERR_EPERM)

	// In-memory buffer should have the key
	mem_key, mem_ok := keystore_read_in_memory_vault_key()
	testing.expect(t, mem_ok, "keystore_read_in_memory_vault_key must return key from memory")
	defer if mem_ok do delete(mem_key)
	testing.expect_value(t, mem_key, KEYSTORE_TEST_KEY_2)
}

@(test)
test_keystore_container_enosys_fallback :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	// Simulate container environment where syscall returns ENOSYS
	keystore_set_mock_syscall_error(KEYSTORE_ERR_ENOSYS)
	defer keystore_set_mock_syscall_error(0)

	keystore_wipe_in_memory_vault_key()
	defer keystore_wipe_in_memory_vault_key()

	// Must fall back gracefully to in-memory mode without failing startup (REQ-VAULT-HARDEN-9)
	ok, err := keystore_store_vault_key(KEYSTORE_TEST_KEY_1)
	testing.expect(t, ok, "keystore_store_vault_key must succeed via fallback on ENOSYS")
	testing.expect_value(t, err, KEYSTORE_ERR_ENOSYS)

	// In-memory buffer should have the key
	mem_key, mem_ok := keystore_read_in_memory_vault_key()
	testing.expect(t, mem_ok, "keystore_read_in_memory_vault_key must return key from memory")
	defer if mem_ok do delete(mem_key)
	testing.expect_value(t, mem_key, KEYSTORE_TEST_KEY_1)
}

@(test)
test_secure_memory_allocation_mlock_madvise_zero :: proc(t: ^testing.T) {
	size := 64
	skey, ok := secure_key_alloc(size)
	testing.expect(t, ok, "secure_key_alloc must succeed")
	testing.expect(t, skey.ptr != nil, "secure buffer pointer must be non-nil")
	testing.expect(t, skey.capacity >= size, "capacity must be at least requested size")
	testing.expect(t, skey.locked, "secure key memory must be locked with mlock")
	testing.expect(t, skey.dontdump, "secure key memory must have MADV_DONTDUMP set")

	// Write sensitive material
	for i in 0 ..< size {
		skey.ptr[i] = u8(i + 1)
	}

	// Verify content was written
	testing.expect_value(t, skey.ptr[0], u8(1))
	testing.expect_value(t, skey.ptr[size - 1], u8(size))

	// Free and wipe
	secure_key_wipe_and_free(&skey)
	testing.expect(t, skey.ptr == nil, "pointer must be nil after wipe and free")
	testing.expect(t, !skey.locked, "locked must be false after wipe and free")
}

@(test)
test_bridge_read_vault_key_precedence :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_set_mock_syscall_error(0)
	keystore_lock_and_purge()
	defer keystore_lock_and_purge()

	os.unset_env("HEIMDALL_VAULT_KEY")

	// 1. Only in-memory key configured
	keystore_store_in_memory_vault_key(KEYSTORE_TEST_KEY_1)
	key1, ok1 := bridge_read_vault_key()
	testing.expect(t, ok1, "read vault key should succeed from in-memory fallback")
	defer if ok1 do delete(key1)
	testing.expect_value(t, key1, KEYSTORE_TEST_KEY_1)

	// 2. Kernel keyring configured: takes precedence over in-memory key
	_, _ = keystore_store_vault_key(KEYSTORE_TEST_KEY_2)
	key2, ok2 := bridge_read_vault_key()
	testing.expect(t, ok2, "read vault key should succeed from kernel keyring")
	defer if ok2 do delete(key2)
	testing.expect_value(t, key2, KEYSTORE_TEST_KEY_2)

	// 3. HEIMDALL_VAULT_KEY env var: takes precedence over kernel keyring
	env_key := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	os.set_env("HEIMDALL_VAULT_KEY", env_key)
	defer os.unset_env("HEIMDALL_VAULT_KEY")

	key3, ok3 := bridge_read_vault_key()
	testing.expect(t, ok3, "read vault key should succeed from env var")
	defer if ok3 do delete(key3)
	testing.expect_value(t, key3, env_key)
}

@(test)
test_bridge_vault_lock_and_shutdown_purges_keys :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	keystore_set_mock_syscall_error(0)
	keystore_lock_and_purge()
	defer keystore_lock_and_purge()

	os.unset_env("HEIMDALL_VAULT_KEY")

	// Set key
	ok, _ := keystore_store_vault_key(KEYSTORE_TEST_KEY_1)
	testing.expect(t, ok, "key store must succeed")

	// Verify readable
	k_before, ok_before := keystore_read_keyring_vault_key()
	testing.expect(t, ok_before, "key must be readable from keyring")
	defer if ok_before do delete(k_before)

	// Perform bridge vault lock
	bridge_vault_lock()

	// Verify unlinked from keyring and wiped from memory
	k_after, ok_keyring_after := keystore_read_keyring_vault_key()
	if ok_keyring_after do delete(k_after)
	testing.expect(t, !ok_keyring_after, "keyring must be empty after bridge_vault_lock")

	m_after, ok_mem_after := keystore_read_in_memory_vault_key()
	if ok_mem_after do delete(m_after)
	testing.expect(t, !ok_mem_after, "in-memory buffer must be empty after bridge_vault_lock")
}
