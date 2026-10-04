package main

import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

KEYSTORE_ERR_EPERM    :: 1
KEYSTORE_ERR_EACCES   :: 13
KEYSTORE_ERR_ENOSYS   :: 38
KEYSTORE_ERR_ENOKEY   :: 126

// Global state for in-memory JIT unsealed buffer fallback on Darwin / macOS
g_keystore_in_memory_buffer: Secure_Key
g_keystore_in_memory_set: bool
g_keystore_mu: sync.Mutex

// Testing hooks for simulation
_keystore_mock_syscall_errno: int = 0

keystore_set_mock_syscall_error :: proc(errno: int) {
	_keystore_mock_syscall_errno = errno
}

// Stores the unsealed vault key in process-isolated JIT memory (mlock'd buffer)
keystore_store_in_memory_vault_key :: proc(key_hex: string) -> bool {
	sync.mutex_lock(&g_keystore_mu)
	defer sync.mutex_unlock(&g_keystore_mu)

	if !bridge_is_valid_hex_key(key_hex) do return false

	if g_keystore_in_memory_set {
		secure_key_wipe_and_free(&g_keystore_in_memory_buffer)
		g_keystore_in_memory_set = false
	}

	key, ok := secure_key_alloc(len(key_hex))
	if !ok {
		return false
	}

	mem.copy(rawptr(key.ptr), raw_data(key_hex), len(key_hex))
	g_keystore_in_memory_buffer = key
	g_keystore_in_memory_set = true
	return true
}

// Retrieves the unsealed vault key from process-isolated JIT memory
keystore_read_in_memory_vault_key :: proc(allocator := context.allocator) -> (key_hex: string, ok: bool) {
	sync.mutex_lock(&g_keystore_mu)
	defer sync.mutex_unlock(&g_keystore_mu)

	if !g_keystore_in_memory_set || g_keystore_in_memory_buffer.ptr == nil {
		return "", false
	}

	bytes := g_keystore_in_memory_buffer.ptr[:g_keystore_in_memory_buffer.len]
	str_val := string(bytes)
	if !bridge_is_valid_hex_key(str_val) {
		return "", false
	}

	return strings.clone(str_val, allocator), true
}

// Explicitly wipes and frees the process-isolated JIT memory buffer
keystore_wipe_in_memory_vault_key :: proc() {
	sync.mutex_lock(&g_keystore_mu)
	defer sync.mutex_unlock(&g_keystore_mu)

	if g_keystore_in_memory_set {
		secure_key_wipe_and_free(&g_keystore_in_memory_buffer)
		g_keystore_in_memory_set = false
	}
}

// On Darwin / macOS, stores vault key in process-isolated locked memory buffer
keystore_store_vault_key :: proc(key_hex: string) -> (ok: bool, err_code: int) {
	if !bridge_is_valid_hex_key(key_hex) {
		return false, -1
	}

	if _keystore_mock_syscall_errno != 0 {
		mem_ok := keystore_store_in_memory_vault_key(key_hex)
		return mem_ok, _keystore_mock_syscall_errno
	}

	mem_ok := keystore_store_in_memory_vault_key(key_hex)
	return mem_ok, 0
}

// On Darwin, kernel user keyring (@u) is Linux-specific, so keyring retrieval returns false
keystore_read_keyring_vault_key :: proc(allocator := context.allocator) -> (key_hex: string, ok: bool) {
	_ = allocator
	return "", false
}

// On Darwin, unlinks in-memory key
keystore_unlink_vault_key :: proc() -> bool {
	keystore_wipe_in_memory_vault_key()
	return true
}

// Purges in-memory unsealed buffers on bridge lock / shutdown.
keystore_lock_and_purge :: proc() {
	keystore_wipe_in_memory_vault_key()
}
