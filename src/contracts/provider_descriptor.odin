package contracts

import "core:strings"

// Provider registry: the compiled source of truth for provider IDENTITY and
// TRAITS (names, telemetry symbol, default CLI binary, version-output format,
// config-directory convention, profile fields, extension kind, model probe and
// user-facing hints). The Hub's SQLite provider_catalog stays the source of
// truth for the launch recipe and models; acp_provider.odin stays the source of
// truth for the ACP runtime recipe (linked by provider id). Every consumer
// resolves these facts here instead of comparing provider names (G7, G9).
//
// Heimdall never installs a provider CLI (G2): install_hint is guidance the user
// follows, never a command Heimdall runs. It carries no version number: the
// minimum version is provider_min_version (from the ACP recipe), appended where
// the hint is shown.

// How `<binary> --version` prints its version.
Provider_Version_Format :: enum u8 {
	Raw,             // not parsed: the output is reported verbatim, never validated
	Leading_Numeric, // "2.1.3 (Claude Code)": the leading digits-and-dots run
	Labelled,        // "<version_label><x.y.z>[.] ...": label, then the first token
	Bare,            // "1.19.6": the whole output is the version
}

// How the bridge discovers a provider's models (provider_model_discovery.odin).
Provider_Model_Probe :: enum u8 { None, Claude_Control, Codex_App_Server, Pi_Rpc, Copilot_Rpc, Agy_Models, ACP }

// Which Heimdall extension mechanism a provider supports (None: not installable).
Provider_Extension_Kind :: enum u8 { None, Claude_Plugin, Codex_Plugin, Antigravity_Plugin }

// Which provider-profile field holds the provider's config directory.
Provider_Config_Field :: enum u8 { None, Config_Dir, Home_Path }

// A provider-specific profile config field exported to the CLI as `env`.
Provider_Profile_Env_Field :: struct {
	field, env: string,
	secret:     bool,
}

Provider_Descriptor :: struct {
	provider, display_name: string,
	aliases:                []string, // accepted alternative ids, e.g. "claude-code"
	program_names:          []string, // lowercase process basenames for telemetry
	log_sym:                Bridge_Log_Sym,
	binary:                 string, // default CLI command (bare name, resolved on PATH)
	version_format:         Provider_Version_Format,
	version_label:          string, // Labelled only: text before the version
	// Config directory: the profile field that sets it, the env var the CLI
	// reads, its home-relative default, and env vars derived from it as
	// {env, subdirectory} (Kiro keeps credentials under XDG_DATA_HOME=<dir>/data).
	config_field:           Provider_Config_Field,
	config_dir_env:         string,
	config_dir_default:     string,
	config_dir_derived_env: [][2]string,
	// The provider's primary config file (or directory) relative to its config
	// directory; `ham-ctl setup` checks it for a read-only managed symlink
	// (Nix/home-manager) that needs an overlay instead of an in-place edit.
	config_file:            string,
	profile_env_fields:     []Provider_Profile_Env_Field,
	profile_auth_methods:   []string,
	profile_launch_args:    bool,
	profile_custom_models:  bool,
	// The harness is not known to load its bootstrap file (CLAUDE.md /
	// AGENTS.md) by itself, so the startup prompt keeps an explicit read step.
	keeps_bootstrap_read:   bool,
	extension:              Provider_Extension_Kind,
	extension_dir:          string, // variant directory under the extensions bundle
	extension_marketplace:  string,
	model_probe:            Provider_Model_Probe,
	install_hint:           string,
	auth_guidance:          string,
}

// Persistent backing storage (as in acp_provider.odin): descriptors returned by
// lookup keep pointing at these immutable nested arrays.
@(private)
provider_descriptor_table := [?]Provider_Descriptor{
	{
		provider = "claude", display_name = "Claude Code",
		aliases = {"claude-code"},
		program_names = {"claude", "claude-code", "claude-agent-acp"},
		log_sym = .claude, binary = "claude",
		version_format = .Leading_Numeric,
		config_field = .Config_Dir, config_dir_env = "CLAUDE_CONFIG_DIR", config_dir_default = ".claude",
		config_file = "settings.json",
		profile_launch_args = true, profile_custom_models = true,
		extension = .Claude_Plugin, extension_dir = "claude-code", extension_marketplace = "heimdall",
		model_probe = .Claude_Control,
		install_hint = "install Claude Code",
		auth_guidance = "Run claude /login on the bridge host using the selected provider profile, then restart this instance.",
	},
	{
		provider = "codex", display_name = "Codex",
		program_names = {"codex"},
		log_sym = .codex, binary = "codex",
		version_format = .Labelled, version_label = "codex-cli ",
		config_field = .Home_Path, config_dir_env = "CODEX_HOME", config_dir_default = ".codex",
		config_file = "config.toml",
		profile_launch_args = true, profile_custom_models = true,
		extension = .Codex_Plugin, extension_dir = "codex", extension_marketplace = "heimdall-codex",
		model_probe = .Codex_App_Server,
		install_hint = "install Codex CLI",
		auth_guidance = "Run codex login on the bridge host using the selected provider profile and its CODEX_HOME, then restart this instance.",
	},
	{
		provider = "copilot", display_name = "GitHub Copilot",
		program_names = {"copilot", "github-copilot", "gh"},
		log_sym = .copilot, binary = "copilot",
		version_format = .Labelled, version_label = "GitHub Copilot CLI ",
		config_field = .Config_Dir, config_dir_env = "COPILOT_HOME", config_dir_default = ".copilot",
		profile_launch_args = true, profile_custom_models = true,
		model_probe = .Copilot_Rpc,
		install_hint = "install GitHub Copilot CLI (npm package @github/copilot)",
		auth_guidance = "Run copilot login on the bridge host using the selected provider profile and its COPILOT_HOME, or configure the profile's sensitive COPILOT_GITHUB_TOKEN or COPILOT_PROVIDER_* environment rows, then restart this instance.",
	},
	{
		provider = "antigravity", display_name = "Antigravity",
		program_names = {"antigravity", "agy"},
		log_sym = .antigravity, binary = "agy",
		version_format = .Raw, // `agy --version` output format not verified
		// No profile field sets it; extension detection reads it.
		config_dir_env = "GEMINI_CONFIG_DIR", config_dir_default = ".gemini",
		config_file = "hooks.json",
		// Its loading of AGENTS.md could not be confirmed.
		keeps_bootstrap_read = true,
		profile_env_fields = {
			{field = "api_key", env = "GEMINI_API_KEY", secret = true},
			{field = "gcp_project", env = "GOOGLE_CLOUD_PROJECT"},
			{field = "gcp_location", env = "GOOGLE_CLOUD_LOCATION"},
		},
		profile_auth_methods = {"oauth-personal", "oauth-business", "gemini-api-key", "agent-platform"},
		extension = .Antigravity_Plugin, extension_dir = "antigravity",
		model_probe = .Agy_Models,
		install_hint = "install antigravity-cli (agy); extension: agy plugin install <repo>/extensions/antigravity",
		auth_guidance = "Google OAuth: token at ~/.gemini/antigravity-cli/antigravity-oauth-token",
	},
	{
		provider = "pi", display_name = "Pi",
		program_names = {"pi"},
		log_sym = .pi, binary = "pi",
		version_format = .Raw, // `pi --version` output format not verified
		// Pi's agent directory; no profile field or env var sets it.
		config_dir_default = ".pi/agent", config_file = "extensions",
		profile_launch_args = true, profile_custom_models = true,
		model_probe = .Pi_Rpc,
		install_hint = "install @earendil-works/pi-coding-agent (npm) or via nix",
		auth_guidance = "set provider key env (e.g. ANTHROPIC_API_KEY) or run pi's OAuth",
	},
	{
		provider = "kiro", display_name = "Kiro",
		program_names = {"kiro-cli"},
		log_sym = .kiro, binary = "kiro-cli",
		version_format = .Labelled, version_label = "kiro-cli ",
		// Without a profile dir the CLI's own default (~/.kiro) and login are inherited.
		config_field = .Config_Dir, config_dir_env = "KIRO_HOME", config_dir_default = ".kiro",
		config_dir_derived_env = {{"XDG_DATA_HOME", "data"}},
		profile_launch_args = true, profile_custom_models = true,
		model_probe = .ACP,
		install_hint = "install Kiro CLI (kiro-cli)",
		auth_guidance = "Run kiro-cli login --use-device-flow on the bridge host using the selected provider profile (its KIRO_HOME and XDG_DATA_HOME), or configure the profile's sensitive KIRO_API_KEY environment row, then restart this instance.",
	},
	{
		provider = "opencode", display_name = "OpenCode",
		program_names = {"opencode"},
		log_sym = .opencode, binary = "opencode",
		version_format = .Bare,
		// The global config dir is $XDG_CONFIG_HOME/opencode (default below).
		// OPENCODE_CONFIG_DIR adds an extra directory, it does not replace this one.
		config_dir_default = ".config/opencode",
		profile_launch_args = true, profile_custom_models = true,
		model_probe = .ACP,
		install_hint = "install OpenCode (opencode)",
		auth_guidance = "Run opencode auth login on the bridge host in the selected provider profile, or configure a local backend in OpenCode, then restart this instance.",
	},
}

// provider_descriptors lists every registered provider, in display order.
provider_descriptors :: proc() -> []Provider_Descriptor {
	return provider_descriptor_table[:]
}

// provider_descriptor finds a provider by id or alias (exact, case-sensitive).
provider_descriptor :: proc(name: string) -> (Provider_Descriptor, bool) {
	if name == "" do return {}, false
	for d in provider_descriptor_table {
		if d.provider == name do return d, true
		for alias in d.aliases do if alias == name do return d, true
	}
	return {}, false
}

// provider_descriptor_or_generic returns the registered descriptor, or for an
// unknown catalog slug a generic one: no extension, no model probe, telemetry
// symbol .other, raw version text and no ACP link (PTY only). Its binary is
// empty: the caller uses the catalog row's binary.
provider_descriptor_or_generic :: proc(name: string) -> Provider_Descriptor {
	if d, ok := provider_descriptor(name); ok do return d
	return Provider_Descriptor{provider = name, display_name = name, log_sym = .other}
}

// provider_for_program maps a process program (path, optionally followed by
// arguments) to its provider by lowercase basename.
provider_for_program :: proc(program: string) -> (Provider_Descriptor, bool) {
	p := program
	if i := strings.last_index_any(p, "/\\"); i >= 0 do p = p[i + 1:]
	if j := strings.index_byte(p, ' '); j >= 0 do p = p[:j]
	if p == "" do return {}, false
	for d in provider_descriptor_table {
		for name in d.program_names do if strings.equal_fold(name, p) do return d, true
	}
	return {}, false
}

// provider_telemetry_name is the bounded provider label for metrics: the
// canonical id of a registered provider (aliases included), else "other".
provider_telemetry_name :: proc(name: string) -> string {
	if d, ok := provider_descriptor(name); ok do return d.provider
	return "other"
}

// provider_parse_cli_version extracts the exact numeric version (x.y.z) from
// `<binary> --version` output per the descriptor's format. ok is false when the
// format is Raw or the output does not carry a valid version; callers still
// report the raw text unchanged.
provider_parse_cli_version :: proc(d: Provider_Descriptor, output: string) -> (string, bool) {
	text := strings.trim_space(output)
	switch d.version_format {
	case .Raw:
		return "", false
	case .Leading_Numeric:
		// The rest is a product label: "2.1.3 (Claude Code)".
		for c, i in text {
			if (c < '0' || c > '9') && c != '.' { text = text[:i]; break }
		}
	case .Labelled:
		// "codex-cli 0.162.0", "kiro-cli 3.5.0", "GitHub Copilot CLI 1.0.114."
		// followed by an optional hint. Never accept a version found elsewhere.
		if d.version_label == "" || !strings.has_prefix(text, d.version_label) do return "", false
		text = text[len(d.version_label):]
		if end := strings.index_any(text, " \t\r\n"); end >= 0 do text = text[:end]
		text = strings.trim_suffix(text, ".")
	case .Bare:
	}
	if len(text) > 64 || !exact_adapter_version(text) do return "", false
	return text, true
}

// provider_min_version is the minimum CLI version Heimdall supports, "" when it
// sets none. Single source: the ACP recipe of a detect-only (System) runtime,
// whose pkg.version is that minimum (acp_provider.odin). Pinned runtimes
// (Adapter, Native) bring their own CLI and set no minimum here.
provider_min_version :: proc(d: Provider_Descriptor) -> string {
	if acp, ok := acp_provider_descriptor(d.provider); ok && acp.launch == .System do return acp.pkg.version
	return ""
}

// How a detected CLI version compares with provider_min_version.
Provider_Version_Status :: enum u8 {
	Missing,  // no exact numeric version could be parsed
	Ok,       // at least the minimum, or no minimum applies
	Outdated, // below the minimum
}

// provider_version_status is THE minimum-version comparison; parsed is the
// output of provider_parse_cli_version ("" when unparsed).
provider_version_status :: proc(d: Provider_Descriptor, parsed: string) -> Provider_Version_Status {
	if !exact_adapter_version(parsed) do return .Missing
	minimum := provider_min_version(d)
	if minimum == "" || acp_semver_compare(parsed, minimum) >= 0 do return .Ok
	return .Outdated
}

// provider_config_dir_resolve picks the provider's config directory: the
// profile's field, else the CLI's env var value, else the home-relative
// default; "" when none applies. profile_dir is ignored for a provider whose
// profiles have no config field, env_dir for one without a config env var.
provider_config_dir_resolve :: proc(d: Provider_Descriptor, profile_dir, env_dir, home: string, allocator := context.temp_allocator) -> string {
	if d.config_field != .None && profile_dir != "" do return strings.clone(profile_dir, allocator)
	if d.config_dir_env != "" && env_dir != "" do return strings.clone(env_dir, allocator)
	if home == "" || d.config_dir_default == "" do return ""
	return strings.concatenate({strings.trim_right(home, "/\\"), "/", d.config_dir_default}, allocator)
}

// provider_descriptor_shape_valid checks one registry entry's internal
// consistency (registry membership is a separate question).
provider_descriptor_shape_valid :: proc(d: Provider_Descriptor) -> bool {
	if d.provider == "" || d.display_name == "" || d.binary == "" || strings.contains_any(d.binary, "/\\ ") ||
	   d.log_sym == .other || d.install_hint == "" || d.auth_guidance == "" { return false }
	if (d.version_format == .Labelled) != (d.version_label != "") do return false
	if d.config_field != .None && d.config_dir_env == "" do return false
	if len(d.config_dir_derived_env) > 0 && d.config_field == .None do return false
	for pair in d.config_dir_derived_env do if pair[0] == "" || pair[1] == "" do return false
	if d.config_file != "" {
		if d.config_dir_env == "" && d.config_dir_default == "" do return false
		if strings.has_prefix(d.config_file, "/") || strings.contains(d.config_file, "..") do return false
	}
	if (d.extension == .None) != (d.extension_dir == "") do return false
	if d.extension == .None && d.extension_marketplace != "" do return false
	binary_listed := false
	for name in d.program_names {
		if name == "" || name != strings.to_lower(name, context.temp_allocator) do return false
		if name == d.binary do binary_listed = true
	}
	if !binary_listed do return false
	for f in d.profile_env_fields do if f.field == "" || f.env == "" do return false
	return true
}
