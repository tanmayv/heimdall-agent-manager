package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:sync"
import cfg_lib "odin_test:lib/config"

vault_test_mutex: sync.Mutex

@(test)
test_vault_hex_validation :: proc(t: ^testing.T) {
	testing.expect(t, !is_valid_hex_key(""), "empty key should fail")
	testing.expect(t, !is_valid_hex_key("abcd"), "short key should fail")
	testing.expect(t, !is_valid_hex_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef00"), "long key should fail")
	testing.expect(t, !is_valid_hex_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg"), "non-hex char 'g' should fail")
	testing.expect(t, is_valid_hex_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"), "lowercase 64-char hex should pass")
	testing.expect(t, is_valid_hex_key("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"), "uppercase 64-char hex should pass")
}

@(test)
test_vault_storage_and_lifecycle :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	test_key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)

	// Clean any pre-existing key
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	_ = posix.unlink(c_path)

	// 1. Initial status: unconfigured
	set_cmd := [?]string{"vault", "set-key", test_key}
	args_set := [?]string{"ham-ctl", "vault", "set-key", test_key}
	ctl_vault_command(set_cmd[:], args_set[:])

	// 2. Verify file exists with mode 0600
	st: posix.stat_t
	stat_res := posix.stat(c_path, &st)
	testing.expect(t, stat_res == .OK, "stat must return .OK")

	all_perms := posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	perms_valid := (st.st_mode & all_perms) == posix.mode_t{.IRUSR, .IWUSR}
	testing.expect(t, perms_valid, "vault_key file mode must be strictly 0600")

	// Verify ctl_read_vault_key reads configured 0600 file correctly
	key_read, read_ok := ctl_read_vault_key(nil, context.temp_allocator)
	testing.expect(t, read_ok, "ctl_read_vault_key must read configured 0600 file")
	testing.expect_value(t, key_read, test_key)

	// Verify invalid flag does not fall through to configured file
	args_bad_flag := [?]string{"ham-ctl", "issue", "list", "--vault-key", "invalid_short_hex"}
	_, bad_flag_ok := ctl_read_vault_key(args_bad_flag[:], context.temp_allocator)
	testing.expect(t, !bad_flag_ok, "invalid --vault-key flag must not fall through to file")

	// Verify invalid HEIMDALL_VAULT_KEY env does not fall through to configured file
	_ = os.set_env("HEIMDALL_VAULT_KEY", "invalid_short_hex")
	_, bad_env_ok := ctl_read_vault_key(nil, context.temp_allocator)
	testing.expect(t, !bad_env_ok, "invalid HEIMDALL_VAULT_KEY env must not fall through to file")
	os.unset_env("HEIMDALL_VAULT_KEY")

	// 3. Clear key
	clear_cmd := [?]string{"vault", "clear"}
	args_clear := [?]string{"ham-ctl", "vault", "clear"}
	ctl_vault_command(clear_cmd[:], args_clear[:])

	// 4. Verify file is removed
	stat_after_clear := posix.stat(c_path, &st)
	testing.expect(t, stat_after_clear != .OK, "vault_key file must be removed after clear")

	// Verify ctl_read_vault_key returns false after clear
	_, after_clear_ok := ctl_read_vault_key(nil, context.temp_allocator)
	testing.expect(t, !after_clear_ok, "ctl_read_vault_key must return false after clear")
}

