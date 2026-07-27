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
		} else if arg == "--logout-url" && i + 1 < len(os.args) {
			config.logout_url = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--device-auth-verification-uri" && i + 1 < len(os.args) {
			config.device_auth_verification_uri = strings.clone(os.args[i + 1]); i += 1
		}
	}
}

split_host_port :: proc(value: string) -> (string, int, bool) {
	colon := strings.last_index_byte(value, ':')
	if colon < 0 do return "", 0, false
	port_i, ok := strconv.parse_int(value[colon + 1:])
	if !ok do return "", 0, false
	return strings.clone(value[:colon]), int(port_i), true
}
