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
	login_url: string,
	logout_url: string,
	// Device-authorization flow (ELDA-1). The verification_uri is the browser/
	// outpost URL the device opens; the API endpoint is /api/v1/device/authorize.
	device_auth_verification_uri: string,
	device_auth_expires_in: int,
	device_auth_interval: int,
	device_auth_rate_limit: int,
	device_auth_rate_window: int,
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
		login_url = "",
		logout_url = "https://auth.example.com/application/o/heimdall/end-session/",
		device_auth_verification_uri = "https://auth.example.com/application/o/heimdall/device/",
		device_auth_expires_in = 600,
		device_auth_interval = 5,
		device_auth_rate_limit = 10,
		device_auth_rate_window = 60,
	}
}
