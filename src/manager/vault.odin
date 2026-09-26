// heimdall vault: manage this node's zero-knowledge vault key (REQ-DIST-7).
//
// The vault key is the 256-bit AES-GCM key material shared with the bridge and
// ham-ctl (src/ctl/vault.odin, bridge_read_vault_key in src/bridge/main.odin):
// a 64-character hex string (32 bytes) stored with strict 0600 permissions in
// the same directory as config.toml — default ~/.config/heimdall/vault_key.
// This file deliberately does not change ham-ctl vault; it is the non-hub
// node's standalone equivalent.
package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

MANAGER_VAULT_KEY_FILE_NAME :: "vault_key"
MANAGER_VAULT_KEY_HEX_LENGTH :: 64

manager_print_vault_usage :: proc() {
	fmt.println("usage: heimdall vault <command> [options]")
	fmt.println("")
	fmt.println("Manages the local zero-knowledge vault key: a 64-character hex string")
	fmt.println("(32 bytes) stored next to config.toml (default ~/.config/heimdall/vault_key)")
	fmt.println("with strict 0600 permissions.")
	fmt.println("")
	fmt.println("Commands:")
	fmt.println("  status              Report whether the vault key is configured and valid")
	fmt.println("  set-key <64-hex>    Store the vault key (also: --key <64-hex>)")
	fmt.println("  show [--reveal]     Show vault key status and the masked (or full) key")
	fmt.println("  clear               Remove the vault key file")
	fmt.println("")
	fmt.println("Options:")
	fmt.println("  --config <path>     config.toml whose directory holds vault_key; default")
	fmt.println("                      $HEIMDALL_HOME/config.toml, else $XDG_CONFIG_HOME/heimdall/,")
	fmt.println("                      else ~/.config/heimdall/config.toml")
}

// manager_vault_command dispatches the vault verb group. `tokens` are the
// arguments after "vault" (subcommand first); `args` is the full argv so the
// shared option helpers can resolve --config. Returns the process exit code.
manager_vault_command :: proc(tokens, args: []string) -> int {
	action := ""
	if len(tokens) > 0 do action = tokens[0]
	if action == "" || action == "help" || action == "--help" || manager_has_flag(args, "--help") || manager_has_flag(args, "-h") {
		manager_print_vault_usage()
		return 0
	}
	switch action {
	case "status":
		return manager_vault_status_command(args)
	case "set-key":
		return manager_vault_set_key_command(tokens[1:], args)
	case "show":
		return manager_vault_show_command(args)
	case "clear":
		return manager_vault_clear_command(args)
	case:
		fmt.eprintfln("heimdall: unknown vault command %q", action)
		manager_print_vault_usage()
		return 2
	}
}

// manager_vault_key_path derives the vault key file from the same directory
// as the resolved config.toml, mirroring manager_token_path for bridge-token.
manager_vault_key_path :: proc(args: []string) -> string {
	config_path := manager_config_path(args)
	return strings.concatenate({manager_dir_of(config_path), "/", MANAGER_VAULT_KEY_FILE_NAME})
}

manager_is_valid_hex_key :: proc(key: string) -> bool {
	if len(key) != MANAGER_VAULT_KEY_HEX_LENGTH do return false
	for i in 0 ..< len(key) {
		ch := key[i]
		switch ch {
		case '0'..='9', 'a'..='f', 'A'..='F':
		case:
			return false
		}
	}
	return true
}

Manager_Vault_Key_Status :: struct {
	exists:            bool,
	configured:        bool, // exactly 64 hex characters
	permissions_valid: bool, // strict 0600
	mode:              int,  // -1 when the file is missing
	key_length:        int,
}

manager_vault_key_status :: proc(path: string) -> Manager_Vault_Key_Status {
	status := Manager_Vault_Key_Status{mode = -1}
	fi, err := os.stat(path, context.allocator)
	if err != nil do return status
	defer os.file_info_delete(fi, context.allocator)
	status.exists = true
	status.mode = manager_permissions_mode(fi.mode)
	status.permissions_valid = (status.mode & 0o777) == 0o600

	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do return status
	defer delete(data)
	trimmed := strings.trim_space(string(data))
	status.key_length = len(trimmed)
	status.configured = manager_is_valid_hex_key(trimmed)
	return status
}

manager_vault_print_status :: proc(path: string, status: Manager_Vault_Key_Status) {
	fmt.println("heimdall vault status")
	fmt.printfln("  key file:    %s", path)
	fmt.printfln("  configured:  %s", "yes" if status.configured else "no")
	switch {
	case !status.exists:
		fmt.println("  permissions: n/a (file missing)")
	case status.permissions_valid:
		fmt.printfln("  permissions: valid (%s, strict 0600)", manager_mode_string(status.mode))
	case:
		fmt.printfln("  permissions: INVALID (%s, must be 0600) — fix: chmod 600 %s", manager_mode_string(status.mode), path)
	}
	fmt.printfln("  key length:  %d", status.key_length)
	if status.exists && !status.configured && status.key_length > 0 {
		fmt.println("  note:        key must be exactly 64 hexadecimal characters")
	}
}

manager_vault_status_command :: proc(args: []string) -> int {
	path := manager_vault_key_path(args)
	status := manager_vault_key_status(path)
	manager_vault_print_status(path, status)
	return 0
}

manager_vault_set_key_command :: proc(tokens, args: []string) -> int {
	key := ""
	if len(tokens) > 0 && !strings.has_prefix(tokens[0], "-") {
		key = tokens[0]
	} else {
		key = manager_option_value(args, "--key", "")
	}
	key = strings.trim_space(key)

	// Validate before touching the filesystem: an invalid key must fail fast
	// with nothing written to disk.
	if key == "" {
		fmt.eprintln("heimdall vault set-key: requires a 64-character hex key")
		fmt.eprintln("  usage: heimdall vault set-key <64-char-hex>   (or: --key <64-char-hex>)")
		return 1
	}
	if !manager_is_valid_hex_key(key) {
		fmt.eprintln("heimdall vault set-key: invalid key — must be exactly 64 hexadecimal characters (32 bytes)")
		return 1
	}

	path := manager_vault_key_path(args)
	manager_make_parent_dirs(path)

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	fd := posix.open(c_path, posix.O_Flags{.WRONLY, .CREAT, .TRUNC}, posix.mode_t{.IRUSR, .IWUSR})
	if fd < 0 {
		fmt.eprintfln("heimdall vault set-key: cannot open %s for writing", path)
		return 1
	}
	defer posix.close(fd)

	// The open mode only applies when creating (and is masked by umask); chmod
	// enforces 0600 even when overwriting an existing too-open key file.
	if posix.chmod(c_path, posix.mode_t{.IRUSR, .IWUSR}) != .OK {
		fmt.eprintfln("heimdall vault set-key: cannot set mode 0600 on %s", path)
		return 1
	}

	content := strings.concatenate({key, "\n"})
	defer delete(content)
	bytes := transmute([]byte)content
	written := posix.write(fd, raw_data(bytes), c.size_t(len(bytes)))
	if written != c.ssize_t(len(bytes)) {
		fmt.eprintfln("heimdall vault set-key: failed to write %s", path)
		return 1
	}

	fmt.printfln("heimdall vault: key stored (%s, mode 0600, %d hex chars)", path, MANAGER_VAULT_KEY_HEX_LENGTH)
	return 0
}

// manager_vault_masked_key renders "abcd...ef01" (first and last 4
// characters). Keys shorter than 8 characters are fully masked — a prefix
// would reveal most of the material.
manager_vault_masked_key :: proc(key: string) -> string {
	if len(key) >= 8 {
		return fmt.tprintf("%s...%s", key[:4], key[len(key) - 4:])
	}
	return strings.repeat("*", len(key))
}

manager_vault_show_command :: proc(args: []string) -> int {
	path := manager_vault_key_path(args)
	status := manager_vault_key_status(path)
	if !status.exists {
		fmt.eprintfln("heimdall vault show: no vault key at %s — set one first: heimdall vault set-key <64-char-hex>", path)
		return 1
	}

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("heimdall vault show: cannot read %s", path)
		return 1
	}
	defer delete(data)
	key := strings.trim_space(string(data))
	if len(key) == 0 {
		fmt.eprintfln("heimdall vault show: vault key file at %s is empty", path)
		return 1
	}

	manager_vault_print_status(path, status)
	if manager_has_flag(args, "--reveal") {
		fmt.printfln("  key:         %s", key)
	} else {
		fmt.printfln("  key:         %s", manager_vault_masked_key(key))
		fmt.println("               (use --reveal to show the full key)")
	}
	return 0
}

manager_vault_clear_command :: proc(args: []string) -> int {
	path := manager_vault_key_path(args)
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	st: posix.stat_t
	if posix.stat(c_path, &st) != .OK {
		fmt.printfln("heimdall vault: no vault key at %s", path)
		return 0
	}

	// Zero the key material before unlink so it does not linger in freed
	// blocks (mirrors ham-ctl vault clear).
	fd := posix.open(c_path, posix.O_Flags{.WRONLY})
	if fd >= 0 {
		zeroes: [128]byte
		size := int(st.st_size)
		if size <= 0 do size = MANAGER_VAULT_KEY_HEX_LENGTH
		if size > len(zeroes) do size = len(zeroes)
		_ = posix.write(fd, raw_data(zeroes[:]), c.size_t(size))
		_ = posix.fsync(fd)
		_ = posix.ftruncate(fd, 0)
		posix.close(fd)
	}

	if posix.unlink(c_path) != .OK {
		fmt.eprintfln("heimdall vault clear: cannot remove %s", path)
		return 1
	}
	fmt.printfln("heimdall vault: key cleared (%s)", path)
	return 0
}
