package app

Hub_Config :: struct {
	bind_host: string,
	port: int,
	database_path: string,
	migrations_dir: string,
	username_header: string,
	display_name_header: string,
	email_header: string,
	trusted_proxy_cidrs: []string,
	auto_provision_users: bool,
	logout_url: string,
}

default_config :: proc() -> Hub_Config {
	cidrs := make([]string, 1)
	cidrs[0] = "127.0.0.1/32"
	return Hub_Config{
		bind_host = "127.0.0.1",
		port = 8081,
		database_path = "./hub.db",
		migrations_dir = "src/hub/repository/sqlite/migrations",
		username_header = "X-authentik-username",
		display_name_header = "X-authentik-name",
		email_header = "X-authentik-email",
		trusted_proxy_cidrs = cidrs,
		auto_provision_users = true,
		logout_url = "https://auth.example.com/application/o/heimdall/end-session/",
	}
}
