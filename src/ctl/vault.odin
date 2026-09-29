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

// ctl_read_vault_key resolves the vault key from, in order:
//   1. --vault-key <hex>
//   2. $HEIMDALL_VAULT_KEY
//   3. ~/.config/heimdall/vault_key (strict 0600)
//   4. the local bridge, via agent.vault.get (agent mode only)
//
// Sources 1 and 2 are EXPLICIT: if either is present but not a valid key it is
// rejected immediately and the later sources are NOT consulted, so a typo'd key
// surfaces as an error instead of silently resolving to a different one. Only
// genuine ABSENCE falls through.
//
// Source 4 exists because sources 1-3 are all fixed at, or before, the moment an
// agent is spawned, whereas the bridge holds the key live. An agent spawned before
// the operator ran `ham-ctl vault set-key` could previously never decrypt anything
// for the rest of its life; now its next invocation asks the bridge and succeeds,
// with no respawn. The fetched key is never written to disk — the point is that the
// bridge is the live source, so each invocation re-asks.
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

	// 3. Check ~/.config/heimdall/vault_key with strict 0600 permissions.
	//
	// DO NOT "restore" these four fall-throughs to hard failures. Every way source 3
	// can fail — file absent, wrong permissions, unreadable, or not 64 hex chars —
	// deliberately falls through to source 4 rather than returning ("", false).
	//
	// The asymmetry with sources 1 and 2 is intentional, not an oversight. Those two
	// are a caller EXPLICITLY handing us a key; silently substituting a different one
	// for the key someone typed would be wrong, so an invalid value there is rejected
	// outright. The key file is not an assertion by a caller, it is a local cache, and
	// a broken cache is a reason to go and ask the live source. Note also that the
	// original bug this whole change exists to fix — an agent spawned before the
	// operator ran `vault set-key` — is literally the "file absent" branch. Recovering
	// on absent but hard-failing on malformed would be an arbitrary line through one
	// behaviour, so all four branches do the same thing.
	//
	// Pinned by test_vault_bad_permissions_file_falls_through_to_bridge and
	// test_vault_malformed_file_falls_through_to_bridge.
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	st: posix.stat_t
	if posix.stat(c_path, &st) != .OK do return ctl_vault_key_from_bridge(allocator)

	all_perms := posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	permissions_valid := (st.st_mode & all_perms) == posix.mode_t{.IRUSR, .IWUSR}
	if !permissions_valid do return ctl_vault_key_from_bridge(allocator)

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return ctl_vault_key_from_bridge(allocator)
	defer delete(data)

	trimmed := strings.trim_space(string(data))
	if len(trimmed) != 64 || !is_valid_hex_key(trimmed) do return ctl_vault_key_from_bridge(allocator)

	return strings.clone(trimmed, allocator), true
}

// ctl_vault_key_from_bridge is source 4 of ctl_read_vault_key: ask the local bridge
// for the key it currently holds. Reached only once sources 1-3 have all failed.
//
// It deliberately uses ctl_agent_local_call, NOT ctl_agent_call: the latter prints
// the response to stdout and os.exit(1)s on failure, which inside a decrypt path
// would corrupt the JSON of every command that needs a key. We need the value
// returned to us, and an unreachable bridge must be an ordinary "no key".
//
// Any failure — no endpoint, no token, unreachable socket, an error response such
// as `not_found`, malformed JSON, or a key that is not 64 hex chars — resolves to
// ("", false), i.e. exactly the "no key" the caller already handles by emitting the
// [Encrypted: ...] fallback. It never aborts and never partially applies a key.
ctl_vault_key_from_bridge :: proc(allocator := context.allocator) -> (key_hex: string, ok: bool) {
	// Agent mode only: in hub mode these are unset and behaviour is unchanged.
	endpoint, has_endpoint := os.lookup_env("HEIMDALL_BRIDGE_ENDPOINT", context.temp_allocator)
	if !has_endpoint || strings.trim_space(endpoint) == "" do return "", false
	token, has_token := os.lookup_env("HEIMDALL_AGENT_TOKEN", context.temp_allocator)
	if !has_token || strings.trim_space(token) == "" do return "", false

	response, call_ok := ctl_agent_local_call(endpoint, token, "agent.vault.get", "{}")
	if !call_ok do return "", false
	// We own the response buffer, and the key is cloned out below, so release it
	// rather than leaving the whole read buffer alive for the rest of the process.
	defer delete(response)

	return ctl_vault_key_from_response(response, allocator)
}

// ctl_vault_key_from_response pulls the key out of an agent.vault.get response and
// validates it. Split out from the socket call so the parsing and validation rules
// can be tested exhaustively without standing up a bridge.
//
// Returns ("", false) for every non-conforming response: an error envelope such as
// `not_found` (which has no "key" member at all), truncated or malformed JSON, or a
// value that is not exactly 64 hex characters. There is deliberately no separate
// `"ok":true` check — absence of a usable key is already the same outcome, and
// validating the value itself is the stronger test.
ctl_vault_key_from_response :: proc(response: string, allocator := context.allocator) -> (key_hex: string, ok: bool) {
	// The matched pattern is `"key":"`, so this cannot pick up "key_length".
	fetched := strings.trim_space(extract_json_string(response, "key", ""))
	if len(fetched) != 64 || !is_valid_hex_key(fetched) do return "", false
	return strings.clone(fetched, allocator), true
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

// ctl_vault_status reports the LOCAL key file's state, and additionally the
// bridge's own view when one is reachable.
//
// Every field of the original payload (top-level ok/configured/permissions_valid/
// key_length plus the nested data{} carrying the same three) is preserved with the
// same meaning, because callers and tests parse this JSON. The bridge view is
// strictly ADDITIVE, under a new top-level "bridge" key, and is omitted entirely in
// hub mode so that output there is byte-identical to before.
//
// The distinction matters operationally: inside an agent the local file may be
// absent while the bridge holds a key, which since source 4 of ctl_read_vault_key
// is now a working key source means decryption succeeds even though "configured" is
// false. Reporting only the local file made that state look broken when it is not.
ctl_vault_status :: proc(args: []string) {
	_ = args
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	bridge_suffix := ctl_vault_status_bridge_suffix()

	st: posix.stat_t
	if posix.stat(c_path, &st) != .OK {
		fmt.println(strings.concatenate({
			"{\"ok\":true,\"configured\":false,\"permissions_valid\":false,\"key_length\":0,",
			"\"data\":{\"configured\":false,\"permissions_valid\":false,\"key_length\":0}",
			bridge_suffix,
			"}",
		}))
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
		strings.write_string(&b, ",\"key_length\":0}")
		strings.write_string(&b, bridge_suffix)
		strings.write_byte(&b, '}')
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
	strings.write_string(&b, "}")
	strings.write_string(&b, bridge_suffix)
	strings.write_byte(&b, '}')
	fmt.println(strings.to_string(b))
}

// ctl_vault_status_bridge_suffix renders `,"bridge":{...}` for splicing into the
// vault status payload, or "" when no bridge endpoint is configured (hub mode), so
// that the existing output is left untouched there.
//
// "available" distinguishes "the bridge says it has no key" from "we could not ask
// it", which are very different things when diagnosing a decryption failure.
ctl_vault_status_bridge_suffix :: proc() -> string {
	endpoint, has_endpoint := os.lookup_env("HEIMDALL_BRIDGE_ENDPOINT", context.temp_allocator)
	if !has_endpoint || strings.trim_space(endpoint) == "" do return ""
	token, has_token := os.lookup_env("HEIMDALL_AGENT_TOKEN", context.temp_allocator)
	if !has_token || strings.trim_space(token) == "" do return ""

	response, call_ok := ctl_agent_local_call(endpoint, token, "agent.vault.status", "{}")
	if !call_ok do return ",\"bridge\":{\"available\":false}"

	// The bridge's vault.status data is {configured, permissions_valid, key_length};
	// forward it verbatim rather than re-deriving it, so the two views cannot drift.
	data_raw, data_ok := extract_json_object_raw(response, "data")
	if !data_ok do return ",\"bridge\":{\"available\":false}"

	b := strings.builder_make()
	strings.write_string(&b, ",\"bridge\":{\"available\":true,\"status\":")
	strings.write_string(&b, data_raw)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
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
