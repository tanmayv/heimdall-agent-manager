// Tests for `heimdall vault` (src/manager/vault.odin): vault key path
// derivation (sibling of config.toml), 64-hex validation, key file status
// (strict 0600 contract), set-key fail-fast/write semantics, show masking and
// clear (zero-wipe + removal).
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

MANAGER_VAULT_TEST_KEY :: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

@(test)
test_manager_vault_key_path :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("vault-path")
	defer manager_test_cleanup(tmp)
	previous := os.get_env("HEIMDALL_HOME", context.allocator)
	defer {
		if previous != "" do os.set_env("HEIMDALL_HOME", previous)
		else do os.unset_env("HEIMDALL_HOME")
	}
	os.set_env("HEIMDALL_HOME", tmp)

	path := manager_vault_key_path([]string{"heimdall", "vault", "status"})
	testing.expect(t, path == fmt.tprintf("%s/vault_key", tmp), fmt.tprintf("default vault key path is sibling of config: %s", path))

	custom := fmt.tprintf("%s/nested/custom.toml", tmp)
	override := manager_vault_key_path([]string{"heimdall", "vault", "status", "--config", custom})
	testing.expect(t, override == fmt.tprintf("%s/nested/vault_key", tmp), fmt.tprintf("--config derives sibling vault_key: %s", override))
}

@(test)
test_manager_is_valid_hex_key :: proc(t: ^testing.T) {
	testing.expect(t, manager_is_valid_hex_key(MANAGER_VAULT_TEST_KEY), "64 lowercase hex accepted")
	testing.expect(t, manager_is_valid_hex_key(strings.to_upper(MANAGER_VAULT_TEST_KEY)), "64 uppercase hex accepted")
	testing.expect(t, !manager_is_valid_hex_key(MANAGER_VAULT_TEST_KEY[:63]), "63 characters rejected")
	testing.expect(t, !manager_is_valid_hex_key(strings.concatenate({MANAGER_VAULT_TEST_KEY, "0"})), "65 characters rejected")
	testing.expect(t, !manager_is_valid_hex_key(strings.repeat("z", 64)), "non-hex characters rejected")
	testing.expect(t, !manager_is_valid_hex_key(""), "empty rejected")
}

@(test)
test_manager_vault_masked_key :: proc(t: ^testing.T) {
	masked := manager_vault_masked_key(MANAGER_VAULT_TEST_KEY)
	testing.expect(t, masked == "0011...eeff", fmt.tprintf("64-hex key masks to first4...last4: %s", masked))
	testing.expect(t, manager_vault_masked_key("deadbeef") == "dead...beef", "8-char key still masks to first4...last4")
	testing.expect(t, manager_vault_masked_key("abc") == "***", "short key is fully masked")
	testing.expect(t, manager_vault_masked_key("") == "", "empty key masks to empty")
}

@(test)
test_manager_vault_key_status :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("vault-status")
	defer manager_test_cleanup(tmp)
	key_path := fmt.tprintf("%s/vault_key", tmp)

	missing := manager_vault_key_status(key_path)
	testing.expect(t, !missing.exists, "missing file reports not exists")
	testing.expect(t, !missing.configured, "missing file reports not configured")
	testing.expect(t, !missing.permissions_valid, "missing file reports invalid permissions")
	testing.expect(t, missing.key_length == 0, "missing file reports zero key length")

	// Valid key, strict 0600.
	testing.expect(t, os.write_entire_file(key_path, MANAGER_VAULT_TEST_KEY, os.Permissions{.Read_User, .Write_User}) == nil, "write valid key")
	testing.expect(t, os.chmod(key_path, os.Permissions{.Read_User, .Write_User}) == nil, "chmod 0600")
	valid := manager_vault_key_status(key_path)
	testing.expect(t, valid.exists && valid.configured && valid.permissions_valid, "valid 0600 64-hex key is configured with valid permissions")
	testing.expect(t, valid.key_length == 64, "valid key reports length 64")
	testing.expect(t, valid.mode == 0o600, fmt.tprintf("valid key reports mode 0600: 0%o", valid.mode))

	// Valid hex content but too-open permissions.
	testing.expect(t, os.chmod(key_path, os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}) == nil, "chmod 0644")
	open := manager_vault_key_status(key_path)
	testing.expect(t, open.configured, "0644 file with valid content still reports configured")
	testing.expect(t, !open.permissions_valid, "0644 permissions are invalid")
	testing.expect(t, open.mode == 0o644, fmt.tprintf("0644 mode reported: 0%o", open.mode))

	// Invalid content with correct permissions.
	testing.expect(t, os.write_entire_file(key_path, "zz", os.Permissions{.Read_User, .Write_User}) == nil, "write invalid content")
	testing.expect(t, os.chmod(key_path, os.Permissions{.Read_User, .Write_User}) == nil, "chmod 0600 again")
	bad_content := manager_vault_key_status(key_path)
	testing.expect(t, !bad_content.configured, "non-hex content reports not configured")
	testing.expect(t, bad_content.permissions_valid, "0600 permissions remain valid")
	testing.expect(t, bad_content.key_length == 2, "raw key length reported")
}

@(test)
test_manager_vault_set_key_command :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("vault-setkey")
	defer manager_test_cleanup(tmp)

	// Positional form; parent directories are created on demand.
	nested_config := fmt.tprintf("%s/deep/nested/config.toml", tmp)
	args := []string{"heimdall", "vault", "set-key", MANAGER_VAULT_TEST_KEY, "--config", nested_config}
	testing.expect(t, manager_vault_command(args[2:], args) == 0, "positional set-key succeeds")

	nested_key := fmt.tprintf("%s/deep/nested/vault_key", tmp)
	testing.expect(t, manager_path_exists(nested_key), "parent directory created and key file written")
	testing.expect(t, manager_test_file_mode(nested_key) == 0o600, fmt.tprintf("key file mode is 0600: 0%o", manager_test_file_mode(nested_key)))
	data, err := os.read_entire_file(nested_key, context.allocator)
	testing.expect(t, err == nil, "key file is readable")
	testing.expect(t, strings.trim_space(string(data)) == MANAGER_VAULT_TEST_KEY, "key file holds the stored key")

	// --key flag form.
	flag_config := fmt.tprintf("%s/flag/config.toml", tmp)
	flag_args := []string{"heimdall", "vault", "set-key", "--key", MANAGER_VAULT_TEST_KEY, "--config", flag_config}
	testing.expect(t, manager_vault_command(flag_args[2:], flag_args) == 0, "--key flag form succeeds")
	testing.expect(t, manager_path_exists(fmt.tprintf("%s/flag/vault_key", tmp)), "--key flag form writes the file")

	// Overwriting an existing too-open file must tighten it back to 0600.
	loose_config := fmt.tprintf("%s/loose/config.toml", tmp)
	loose_key := fmt.tprintf("%s/loose/vault_key", tmp)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/loose", tmp)) == nil, "make loose dir")
	testing.expect(t, os.write_entire_file(loose_key, "stale\n", os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}) == nil, "write loose key file")
	overwrite_args := []string{"heimdall", "vault", "set-key", MANAGER_VAULT_TEST_KEY, "--config", loose_config}
	testing.expect(t, manager_vault_command(overwrite_args[2:], overwrite_args) == 0, "set-key overwrites an existing file")
	testing.expect(t, manager_test_file_mode(loose_key) == 0o600, "chmod enforces 0600 on overwrite")
}

@(test)
test_manager_vault_set_key_rejects_invalid :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("vault-setkey-invalid")
	defer manager_test_cleanup(tmp)
	config := fmt.tprintf("%s/config.toml", tmp)

	invalid := []string{
		"",
		MANAGER_VAULT_TEST_KEY[:63],
		strings.repeat("z", 64),
		strings.concatenate({MANAGER_VAULT_TEST_KEY, "0"}),
	}
	for bad in invalid {
		args := []string{"heimdall", "vault", "set-key", bad, "--config", config}
		code := manager_vault_command(args[2:], args)
		testing.expect(t, code == 1, fmt.tprintf("invalid key (len %d) fails fast with exit 1", len(bad)))
	}
	testing.expect(t, !manager_path_exists(fmt.tprintf("%s/vault_key", tmp)), "invalid keys write nothing to disk")
}

@(test)
test_manager_vault_show_command :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("vault-show")
	defer manager_test_cleanup(tmp)
	config := fmt.tprintf("%s/config.toml", tmp)
	show_args := []string{"heimdall", "vault", "show", "--config", config}

	testing.expect(t, manager_vault_command(show_args[2:], show_args) == 1, "show without a key fails with exit 1")

	set_args := []string{"heimdall", "vault", "set-key", MANAGER_VAULT_TEST_KEY, "--config", config}
	testing.expect(t, manager_vault_command(set_args[2:], set_args) == 0, "set-key before show")
	testing.expect(t, manager_vault_command(show_args[2:], show_args) == 0, "show with a key exits 0 (masked)")

	reveal_args := []string{"heimdall", "vault", "show", "--reveal", "--config", config}
	testing.expect(t, manager_vault_command(reveal_args[2:], reveal_args) == 0, "show --reveal exits 0")

	empty_config := fmt.tprintf("%s/empty/config.toml", tmp)
	empty_key := fmt.tprintf("%s/empty/vault_key", tmp)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/empty", tmp)) == nil, "make empty dir")
	testing.expect(t, os.write_entire_file(empty_key, "   \n", os.Permissions{.Read_User, .Write_User}) == nil, "write whitespace-only key file")
	empty_args := []string{"heimdall", "vault", "show", "--config", empty_config}
	testing.expect(t, manager_vault_command(empty_args[2:], empty_args) == 1, "show on a whitespace-only key file fails with exit 1")
}

@(test)
test_manager_vault_clear_command :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("vault-clear")
	defer manager_test_cleanup(tmp)
	config := fmt.tprintf("%s/config.toml", tmp)
	key_path := fmt.tprintf("%s/vault_key", tmp)

	set_args := []string{"heimdall", "vault", "set-key", MANAGER_VAULT_TEST_KEY, "--config", config}
	testing.expect(t, manager_vault_command(set_args[2:], set_args) == 0, "set-key before clear")
	testing.expect(t, manager_path_exists(key_path), "key file exists before clear")

	clear_args := []string{"heimdall", "vault", "clear", "--config", config}
	testing.expect(t, manager_vault_command(clear_args[2:], clear_args) == 0, "clear succeeds")
	testing.expect(t, !manager_path_exists(key_path), "clear removes the key file")
	testing.expect(t, manager_vault_command(clear_args[2:], clear_args) == 0, "clear without a key is idempotent")

	status := manager_vault_key_status(key_path)
	testing.expect(t, !status.exists && !status.configured, "status after clear reports unconfigured")
}

@(test)
test_manager_vault_command_dispatch :: proc(t: ^testing.T) {
	tmp := manager_test_tmp_dir("vault-dispatch")
	defer manager_test_cleanup(tmp)
	config := fmt.tprintf("%s/config.toml", tmp)

	testing.expect(t, manager_vault_command([]string{}, []string{"heimdall", "vault"}) == 0, "bare vault prints usage")
	help_args := []string{"heimdall", "vault", "--help"}
	testing.expect(t, manager_vault_command(help_args[2:], help_args) == 0, "vault --help prints usage")

	unknown_args := []string{"heimdall", "vault", "bogus", "--config", config}
	testing.expect(t, manager_vault_command(unknown_args[2:], unknown_args) == 2, "unknown vault subcommand exits 2")

	status_args := []string{"heimdall", "vault", "status", "--config", config}
	testing.expect(t, manager_vault_command(status_args[2:], status_args) == 0, "status on an unconfigured node still exits 0 (report)")
}
