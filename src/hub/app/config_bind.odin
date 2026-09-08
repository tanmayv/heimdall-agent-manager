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
	// Background stale-instance reaper cadence (seconds). A dedicated hub thread
	// sweeps agent instances whose bridge stopped heartbeating and flips them to
	// 'unreachable', INDEPENDENT of inbound bridge traffic (self-heals a fully-dead
	// bridge, a lost WS close, or a hub restart with a persisted DB). <=0 falls back
	// to the default; it never blocks startup.
	reaper_interval_seconds: int,
	// Cooldown (seconds) between activity-gated title-nudges for the same
	// conversation (REQ-4,5,6). Default 3600 (1h). <=0 falls back to the engine
	// default DEFAULT_TITLE_NUDGE_COOLDOWN_SECONDS.
	title_nudge_cooldown_seconds: int,
	// VAPID keypair for Web Push (WP-STORE-2). Both keys are unpadded base64url;
	// the public key is the uncompressed P-256 point served to clients, the
	// private key is the 32-byte scalar used to sign VAPID JWTs. The private key
	// is a SECRET and MUST NEVER be logged. When either is empty, push sending is
	// disabled (the endpoints still work) — see vapid_is_configured.
	vapid_public_key: string,
	vapid_private_key: string,
	// VAPID JWT `sub` claim — a contact URI (mailto:/https:) per RFC 8292.
	vapid_subject: string,
	// Public origin (scheme://host[:port]) of the deployed PWA, used to build the
	// absolute `href` in Web Push payloads that the service worker opens on click
	// (WP-SEND). The Hub serves only /api/v1; the SW/manifest are same-origin here.
	public_app_origin: string,
	// CT-4: Code-level audit mode. When enabled, non-owner requests are strictly
	// forbidden from mutating state, spawning agents, or requesting PTY operations.
	audit_mode: bool,
	// CT-3 / Hardened Proxy-to-Hub Trust:
	proxy_secret: string,
	proxy_secret_file: string,
	require_proxy_secret: bool,
	cloudtop: bool,
}

// vapid_is_configured reports whether a usable VAPID keypair is present. Push
// send is gated on this; when false, subscription endpoints still function.
vapid_is_configured :: proc(config: Hub_Config) -> bool {
	return config.vapid_public_key != "" && config.vapid_private_key != ""
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
		reaper_interval_seconds = 20,
		title_nudge_cooldown_seconds = 3600,
		vapid_subject = "mailto:12tanmayvijay@gmail.com",
		public_app_origin = "https://heimdall.mundus.in",
		audit_mode = false,
	}
}
