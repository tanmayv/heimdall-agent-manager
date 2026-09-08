package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import auth_service "odin_test:hub/service/auth"
import platform "odin_test:hub/platform"
import user_service "odin_test:hub/service/user"

main :: proc() {
	config := app.default_config()
	if is_users_command() {
		ok, message := run_users_command(&config)
		if !ok {
			fmt.eprintln(message)
			os.exit(1)
		}
		return
	}
	if is_tokens_command() {
		ok, message := run_tokens_command(&config)
		if !ok {
			fmt.eprintln(message)
			os.exit(1)
		}
		return
	}
	if is_snapshot_command() {
		ok, message := run_snapshot_command(&config)
		if !ok {
			fmt.eprintln(message)
			os.exit(1)
		}
		return
	}
	parse_args(&config)
	ok, message := app.run(config)
	if !ok {
		fmt.eprintln(message)
		return
	}
	fmt.println(message)
}

is_tokens_command :: proc() -> bool {
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "tokens" do return true
	}
	return false
}

is_users_command :: proc() -> bool {
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "users" do return true
	}
	return false
}

users_index :: proc() -> int {
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "users" do return i
	}
	return -1
}

run_users_command :: proc(config: ^app.Hub_Config) -> (bool, string) {
	idx := users_index()
	if idx < 0 || idx + 1 >= len(os.args) do return false, "usage: ham-hub users create --name <name> --email <email> [--label <label>] [--expires-in 90d]"
	action := os.args[idx + 1]
	parse_token_global_args(config)
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, config^)
	if !ok do return false, message
	defer app.shutdown_graph(&graph)
	switch action {
	case "create":
		name := arg_value("--name")
		email := arg_value("--email")
		if name == "" || email == "" do return false, "--name and --email are required"
		created, created_ok, created_err := user_service.create_user(&graph.users, user_service.Create_User_Input{name = name, email = email})
		if !created_ok do return false, created_err.message
		result, issued, err := auth_service.issue_user_api_token(&graph.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = created.user_id, label = arg_value("--label"), expires_at = token_expires_at()})
		if !issued do return false, err.message
		fmt.println("user_id=", string(created.user_id))
		fmt.println("token_id=", result.token.token_id)
		fmt.println("token=", result.plaintext)
		fmt.println("expires_at=", result.token.expires_at)
		return true, ""
	}
	return false, "usage: ham-hub users create --name <name> --email <email> [--label <label>] [--expires-in 90d]"
}

run_tokens_command :: proc(config: ^app.Hub_Config) -> (bool, string) {
	idx := tokens_index()
	if idx < 0 || idx + 1 >= len(os.args) do return false, "usage: ham-hub tokens issue --user <user_id> [--label <label>] [--expires-in 90d] | tokens list --user <user_id> | tokens revoke --token-id <token_id>"
	action := os.args[idx + 1]
	parse_token_global_args(config)
	graph: app.App_Graph
	ok, message := app.build_graph(&graph, config^)
	if !ok do return false, message
	defer app.shutdown_graph(&graph)
	switch action {
	case "issue":
		user_id := arg_value("--user")
		if user_id == "" do return false, "--user is required"
		result, issued, err := auth_service.issue_user_api_token(&graph.auth, auth_service.Issue_User_API_Token_Input{owner_user_id = domain.User_ID(user_id), label = arg_value("--label"), expires_at = token_expires_at()})
		if !issued do return false, err.message
		fmt.println("token_id=", result.token.token_id)
		fmt.println("user_id=", string(result.token.owner_user_id))
		fmt.println("token=", result.plaintext)
		fmt.println("expires_at=", result.token.expires_at)
		return true, ""
	case "list":
		user_id := arg_value("--user")
		if user_id == "" do return false, "--user is required"
		tokens, err := auth_service.list_user_api_tokens(&graph.auth, domain.User_ID(user_id))
		if err.code != .None do return false, err.message
		for token in tokens do print_token_metadata(token)
		return true, ""
	case "revoke":
		token_id := arg_value("--token-id")
		if token_id == "" do return false, "--token-id is required"
		token, revoked, err := auth_service.revoke_user_api_token(&graph.auth, token_id)
		if !revoked do return false, err.message
		fmt.println("revoked_token_id=", token.token_id)
		fmt.println("revoked_at=", token.revoked_at)
		return true, ""
	}
	return false, "usage: ham-hub tokens issue|list|revoke [options]"
}

is_snapshot_command :: proc() -> bool {
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "snapshot" do return true
	}
	return false
}

snapshot_index :: proc() -> int {
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "snapshot" do return i
	}
	return -1
}

run_snapshot_command :: proc(config: ^app.Hub_Config) -> (bool, string) {
	idx := snapshot_index()
	if idx < 0 || idx + 1 >= len(os.args) do return false, "usage: ham-hub snapshot export [--out <path>] | snapshot restore --file <path>"
	action := os.args[idx + 1]
	parse_args(config)

	home := os.get_env("HOME", context.allocator)
	if home == "" do home = "/tmp"
	default_snapshot_dir := fmt.tprintf("%s/.local/share/heimdall/snapshots", home)

	switch action {
	case "export":
		_ = os.make_directory_all(default_snapshot_dir)
		_ = os.chmod(default_snapshot_dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
		out_path := arg_value("--out")
		if out_path == "" {
			now_str := platform.expires_at_after_seconds(0)
			out_path = fmt.tprintf("%s/hub-%s.db", default_snapshot_dir, now_str)
		}
		data, read_err := os.read_entire_file(config.database_path, context.allocator)
		if read_err != nil do return false, fmt.tprintf("failed to read database at %s", config.database_path)
		write_err := os.write_entire_file(out_path, data, os.Permissions{.Read_User, .Write_User})
		if write_err != nil do return false, fmt.tprintf("failed to write snapshot at %s", out_path)
		_ = os.chmod(out_path, os.Permissions{.Read_User, .Write_User})
		fmt.println("snapshot_exported=", out_path)
		return true, ""
	case "restore":
		file_path := arg_value("--file")
		if file_path == "" do return false, "--file <path> is required for restore"
		data, read_err := os.read_entire_file(file_path, context.allocator)
		if read_err != nil do return false, fmt.tprintf("failed to read snapshot file %s", file_path)
		if slash := strings.last_index_byte(config.database_path, '/'); slash > 0 {
			_ = os.make_directory_all(config.database_path[:slash])
		}
		write_err := os.write_entire_file(config.database_path, data, os.Permissions{.Read_User, .Write_User})
		if write_err != nil do return false, fmt.tprintf("failed to restore database to %s", config.database_path)
		_ = os.chmod(config.database_path, os.Permissions{.Read_User, .Write_User})
		fmt.println("snapshot_restored=", config.database_path)
		return true, ""
	}
	return false, "usage: ham-hub snapshot export [--out <path>] | snapshot restore --file <path>"
}

print_token_metadata :: proc(token: domain.User_API_Token) {
	status := "active"
	if token.revoked_at != "" do status = "revoked"
	fmt.println(strings.concatenate({
		"token_id=", token.token_id,
		" user_id=", string(token.owner_user_id),
		" label=", token.label,
		" created_from=", token.created_from,
		" device_label=", token.device_label,
		" status=", status,
		" created_at=", token.created_at,
		" last_used_at=", token.last_used_at,
		" expires_at=", token.expires_at,
		" revoked_at=", token.revoked_at,
	}))
}

parse_token_global_args :: proc(config: ^app.Hub_Config) {
	parse_args(config)
}

tokens_index :: proc() -> int {
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "tokens" do return i
	}
	return -1
}

arg_value :: proc(name: string) -> string {
	for i := 1; i + 1 < len(os.args); i += 1 {
		if os.args[i] == name do return os.args[i + 1]
	}
	return ""
}

token_expires_at :: proc() -> string {
	if v := arg_value("--expires-at"); v != "" do return v
	if v := arg_value("--expires-in"); v != "" {
		seconds, ok := parse_duration_seconds(v)
		if ok do return platform.expires_at_after_seconds(seconds)
	}
	return ""
}

parse_duration_seconds :: proc(value: string) -> (int, bool) {
	if value == "" do return 0, false
	unit := value[len(value) - 1]
	number := value
	mult := 1
	if unit == 'd' || unit == 'h' || unit == 'm' || unit == 's' {
		number = value[:len(value) - 1]
		switch unit {
		case 'd': mult = 86400
		case 'h': mult = 3600
		case 'm': mult = 60
		case 's': mult = 1
		}
	}
	parsed, ok := strconv.parse_int(number)
	if !ok || parsed <= 0 do return 0, false
	return int(parsed) * mult, true
}

parse_args :: proc(config: ^app.Hub_Config) {
	if os.get_env_alloc("HEIMDALL_AUDIT_MODE", context.allocator) == "1" || os.get_env_alloc("HEIMDALL_AUDIT_MODE", context.allocator) == "true" {
		config.audit_mode = true
	}
	if os.get_env_alloc("HEIMDALL_REQUIRE_PROXY_SECRET", context.allocator) == "1" || os.get_env_alloc("HAM_REQUIRE_PROXY_SECRET", context.allocator) == "1" {
		config.require_proxy_secret = true
	}
	// VAPID config resolves as: built-in default -> environment -> flags. Applying
	// env first (below) and flags second (in the loop) keeps precedence uniform
	// across all VAPID fields, including vapid_subject which carries a default.
	apply_vapid_env(config)
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--listen" && i + 1 < len(os.args) {
			host, port, ok := split_host_port(os.args[i + 1])
			if ok {
				config.bind_host = host
				config.port = port
			}
			i += 1
		} else if arg == "--port" && i + 1 < len(os.args) {
			if parsed, ok := strconv.parse_int(os.args[i + 1]); ok do config.port = int(parsed)
			i += 1
		} else if arg == "--db" && i + 1 < len(os.args) {
			config.database_path = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--migrations-dir" && i + 1 < len(os.args) {
			config.migrations_dir = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--trusted-proxy-cidr" && i + 1 < len(os.args) {
			cidrs := make([]string, 1)
			cidrs[0] = strings.clone(os.args[i + 1])
			config.trusted_proxy_cidrs = cidrs
			i += 1
		} else if arg == "--login-url" && i + 1 < len(os.args) {
			config.login_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--logout-url" && i + 1 < len(os.args) {
			config.logout_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--device-auth-verification-uri" && i + 1 < len(os.args) {
			config.device_auth_verification_uri = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--reaper-interval-seconds" && i + 1 < len(os.args) {
			if parsed, ok := strconv.parse_int(os.args[i + 1]); ok do config.reaper_interval_seconds = int(parsed)
			i += 1
		} else if arg == "--title-nudge-cooldown-seconds" && i + 1 < len(os.args) {
			if parsed, ok := strconv.parse_int(os.args[i + 1]); ok do config.title_nudge_cooldown_seconds = int(parsed)
			i += 1
		} else if arg == "--vapid-public-key" && i + 1 < len(os.args) {
			config.vapid_public_key = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--vapid-private-key" && i + 1 < len(os.args) {
			config.vapid_private_key = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--vapid-private-key-file" && i + 1 < len(os.args) {
			config.vapid_private_key = read_key_file(os.args[i + 1]); i += 1
		} else if arg == "--vapid-subject" && i + 1 < len(os.args) {
			config.vapid_subject = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--audit-mode" {
			config.audit_mode = true
		} else if arg == "--proxy-secret" && i + 1 < len(os.args) {
			config.proxy_secret = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--proxy-secret-file" && i + 1 < len(os.args) {
			config.proxy_secret_file = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--require-proxy-secret" {
			config.require_proxy_secret = true
		} else if arg == "--cloudtop" {
			config.cloudtop = true
			config.require_proxy_secret = true
			home := os.get_env("HOME", context.allocator)
			if home == "" do home = "/tmp"
			config.database_path = fmt.tprintf("%s/.local/share/heimdall/hub.db", home)
		}
	}
}

// apply_vapid_env seeds VAPID config from the environment:
// HEIMDALL_VAPID_PUBLIC_KEY, HEIMDALL_VAPID_PRIVATE_KEY (inline) or
// HEIMDALL_VAPID_PRIVATE_KEY_FILE (path), and HEIMDALL_VAPID_SUBJECT. Command
// line flags are applied afterwards and override these. The private key is a
// secret and is never printed.
apply_vapid_env :: proc(config: ^app.Hub_Config) {
	if v := os.get_env_alloc("HEIMDALL_VAPID_PUBLIC_KEY", context.allocator); v != "" do config.vapid_public_key = v
	if v := os.get_env_alloc("HEIMDALL_VAPID_PRIVATE_KEY", context.allocator); v != "" {
		config.vapid_private_key = v
	} else if path := os.get_env_alloc("HEIMDALL_VAPID_PRIVATE_KEY_FILE", context.allocator); path != "" {
		config.vapid_private_key = read_key_file(path)
	}
	if v := os.get_env_alloc("HEIMDALL_VAPID_SUBJECT", context.allocator); v != "" do config.vapid_subject = v
}

// read_key_file loads a VAPID private key from a file, trimming trailing
// whitespace/newlines. Returns "" (push stays disabled) if the file is missing
// or unreadable, warning to stderr so a misconfigured key path is visible to
// ops (e.g. the NixOS deploy that provides the key via file). The contents are
// secret and are never logged.
read_key_file :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("ham-hub: WARNING could not read VAPID private key file:", path, "- web push send will be disabled")
		return ""
	}
	return strings.clone(strings.trim_space(string(data)))
}

split_host_port :: proc(value: string) -> (string, int, bool) {
	colon := strings.last_index_byte(value, ':')
	if colon < 0 do return "", 0, false
	port_i, ok := strconv.parse_int(value[colon + 1:])
	if !ok do return "", 0, false
	return strings.clone(value[:colon]), int(port_i), true
}
