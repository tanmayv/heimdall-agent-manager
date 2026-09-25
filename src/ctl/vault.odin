package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import cfg_lib "odin_test:lib/config"

// ── vault verb group (REQ-VAULT-BRIDGE-CLI-1) ──────────────────────────────
// Manages local 256-bit AES-GCM Vault Key in ~/.config/heimdall/vault_key with
// strict 0600 POSIX permissions.

print_vault_help :: proc() {
	fmt.println("ham-ctl vault — manage local zero-knowledge vault key")
	fmt.println("")
	fmt.println("USAGE:")
	fmt.println("  ham-ctl vault status")
	fmt.println("  ham-ctl vault set-key <64-char-hex>")
	fmt.println("  ham-ctl vault show [--reveal]")
	fmt.println("  ham-ctl vault clear")
}

is_valid_hex_key :: proc(key: string) -> bool {
	if len(key) != 64 do return false
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

// Reads local vault key either from --vault-key CLI flag, HEIMDALL_VAULT_KEY env var,
// or ~/.config/heimdall/vault_key (strict 0600).
ctl_read_vault_key :: proc(args: []string = nil, allocator := context.allocator) -> (key_hex: string, ok: bool) {
	// 1. Check --vault-key command line flag if args passed
	if args != nil && has_flag(args, "--vault-key") {
		flag_val := option_value(args, "--vault-key", "")
		trimmed := strings.trim_space(flag_val)
		if len(trimmed) == 64 && is_valid_hex_key(trimmed) {
			return strings.clone(trimmed, allocator), true
		}
		// Explicit flag provided but invalid hex key: reject immediately, do NOT fall through
		return "", false
	}

	// 2. Check environment variable HEIMDALL_VAULT_KEY
	if env_val, found := os.lookup_env("HEIMDALL_VAULT_KEY", context.temp_allocator); found {
		trimmed := strings.trim_space(env_val)
		if trimmed != "" {
			if len(trimmed) == 64 && is_valid_hex_key(trimmed) {
				return strings.clone(trimmed, allocator), true
			}
			// Explicit env var set but invalid hex key: reject immediately, do NOT fall through
			return "", false
		}
	}

	// 3. Check ~/.config/heimdall/vault_key with strict 0600 permissions
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	st: posix.stat_t
	if posix.stat(c_path, &st) != .OK do return "", false

	all_perms := posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	permissions_valid := (st.st_mode & all_perms) == posix.mode_t{.IRUSR, .IWUSR}
	if !permissions_valid do return "", false

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return "", false
	defer delete(data)

	trimmed := strings.trim_space(string(data))
	if len(trimmed) != 64 || !is_valid_hex_key(trimmed) do return "", false

	return strings.clone(trimmed, allocator), true
}

ctl_vault_command :: proc(cmd: []string, args: []string) {
	idx := 0
	if len(cmd) > 0 && cmd[0] == "vault" do idx = 1
	action := ""
	if idx < len(cmd) do action = cmd[idx]

	if action == "" || action == "help" || action == "--help" || has_flag(args, "--help") || has_flag(args, "-h") {
		print_vault_help()
		return
	}

	tokens := cmd[idx + 1:] if idx + 1 <= len(cmd) else []string{}

	switch action {
	case "status":
		ctl_vault_status(args)
	case "set-key":
		ctl_vault_set_key(tokens, args)
	case "show":
		ctl_vault_show(args)
	case "clear":
		ctl_vault_clear(args)
	case:
		msg := strings.concatenate({"{\"ok\":false,\"message\":\"unknown vault command: ", action, ". Run 'ham-ctl vault --help' for usage.\"}"})
		defer delete(msg)
		fmt.println(msg)
	}
}

ctl_vault_status :: proc(args: []string) {
	_ = args
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	st: posix.stat_t
	if posix.stat(c_path, &st) != .OK {
		fmt.println("{\"ok\":true,\"configured\":false,\"permissions_valid\":false,\"key_length\":0," +
			"\"data\":{\"configured\":false,\"permissions_valid\":false,\"key_length\":0}}")
		return
	}

	all_perms := posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	permissions_valid := (st.st_mode & all_perms) == posix.mode_t{.IRUSR, .IWUSR}

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		b := strings.builder_make()
		strings.write_string(&b, "{\"ok\":true,\"configured\":false,\"permissions_valid\":")
		strings.write_string(&b, "true" if permissions_valid else "false")
		strings.write_string(&b, ",\"key_length\":0,\"data\":{\"configured\":false,\"permissions_valid\":")
		strings.write_string(&b, "true" if permissions_valid else "false")
		strings.write_string(&b, ",\"key_length\":0}}")
		fmt.println(strings.to_string(b))
		return
	}
	defer delete(data)

	trimmed := strings.trim_space(string(data))
	key_length := len(trimmed)
	configured := key_length == 64 && is_valid_hex_key(trimmed)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"configured\":")
	strings.write_string(&b, "true" if configured else "false")
	strings.write_string(&b, ",\"permissions_valid\":")
	strings.write_string(&b, "true" if permissions_valid else "false")
	strings.write_string(&b, ",\"key_length\":")
	strings.write_int(&b, key_length)
	strings.write_string(&b, ",\"data\":{\"configured\":")
	strings.write_string(&b, "true" if configured else "false")
	strings.write_string(&b, ",\"permissions_valid\":")
	strings.write_string(&b, "true" if permissions_valid else "false")
	strings.write_string(&b, ",\"key_length\":")
	strings.write_int(&b, key_length)
	strings.write_string(&b, "}}")
	fmt.println(strings.to_string(b))
}

ctl_vault_set_key :: proc(tokens: []string, args: []string) {
	key := ""
	if len(tokens) > 0 && !strings.has_prefix(tokens[0], "-") {
		key = tokens[0]
	} else {
		key = option_value(args, "--key", "")
	}

	key = strings.trim_space(key)
	if key == "" {
		fmt.println("{\"ok\":false,\"message\":\"set-key requires a 64-character hex key: ham-ctl vault set-key <64-char-hex>\"}")
		return
	}

	if len(key) != 64 || !is_valid_hex_key(key) {
		fmt.println("{\"ok\":false,\"message\":\"invalid vault key: must be exactly 64 hexadecimal characters (32 bytes)\"}")
		return
	}

	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)

	dir := cfg_lib.expand_home("~/.config/heimdall")
	defer delete(dir)
	_ = os.make_directory_all(dir)

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	fd := posix.open(c_path, posix.O_Flags{.WRONLY, .CREAT, .TRUNC}, posix.mode_t{.IRUSR, .IWUSR})
	if fd < 0 {
		fmt.println("{\"ok\":false,\"message\":\"failed to open vault key file for writing\"}")
		return
	}
	defer posix.close(fd)

	_ = posix.chmod(c_path, posix.mode_t{.IRUSR, .IWUSR})

	content := strings.concatenate({key, "\n"})
	defer delete(content)
	bytes := transmute([]byte)content
	written := posix.write(fd, raw_data(bytes), c.size_t(len(bytes)))
	if written != c.ssize_t(len(bytes)) {
		fmt.println("{\"ok\":false,\"message\":\"failed to write vault key to file\"}")
		return
	}

	fmt.println("{\"ok\":true,\"message\":\"vault key stored successfully\",\"key_length\":64,\"data\":{\"configured\":true,\"permissions_valid\":true,\"key_length\":64}}")
}

ctl_vault_show :: proc(args: []string) {
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	st: posix.stat_t
	if posix.stat(c_path, &st) != .OK {
		fmt.println("{\"ok\":false,\"message\":\"vault key is not configured\"}")
		return
	}

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.println("{\"ok\":false,\"message\":\"failed to read vault key file\"}")
		return
	}
	defer delete(data)

	key := strings.trim_space(string(data))
	if len(key) == 0 {
		fmt.println("{\"ok\":false,\"message\":\"vault key file is empty\"}")
		return
	}

	reveal := has_flag(args, "--reveal")
	display_key := key
	masked := false
	if !reveal {
		masked = true
		if len(key) >= 8 {
			display_key = strings.concatenate({key[:4], "********************************************************", key[len(key) - 4:]})
		} else {
			display_key = "****************************************************************"
		}
	}

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"key\":\"")
	strings.write_string(&b, display_key)
	strings.write_string(&b, "\",\"masked\":")
	strings.write_string(&b, "true" if masked else "false")
	strings.write_string(&b, ",\"revealed\":")
	strings.write_string(&b, "false" if masked else "true")
	strings.write_string(&b, ",\"data\":{\"key\":\"")
	strings.write_string(&b, display_key)
	strings.write_string(&b, "\",\"masked\":")
	strings.write_string(&b, "true" if masked else "false")
	strings.write_string(&b, ",\"revealed\":")
	strings.write_string(&b, "false" if masked else "true")
	strings.write_string(&b, "}}")
	fmt.println(strings.to_string(b))
}

ctl_vault_clear :: proc(args: []string) {
	_ = args
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	st: posix.stat_t
	if posix.stat(c_path, &st) == .OK {
		fd := posix.open(c_path, posix.O_Flags{.WRONLY})
		if fd >= 0 {
			zeroes: [128]byte
			size := int(st.st_size)
			if size <= 0 do size = 64
			if size > len(zeroes) do size = len(zeroes)
			_ = posix.write(fd, raw_data(zeroes[:]), c.size_t(size))
			_ = posix.fsync(fd)
			_ = posix.ftruncate(fd, 0)
			posix.close(fd)
		}
		_ = posix.unlink(c_path)
	}

	fmt.println("{\"ok\":true,\"message\":\"vault key cleared successfully\",\"data\":{\"cleared\":true}}")
}
