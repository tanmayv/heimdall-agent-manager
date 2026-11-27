package main

import "core:os"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"

// Bridge-side provider resolvers (G7): the ONE place that resolves a provider's
// CLI binary, its `--version` and its config directory. Everything else on the
// bridge consumes these instead of comparing provider names (G9). Provider
// traits come from the compiled registry (contracts/provider_descriptor.odin);
// the ACP runtime recipe stays contracts.acp_provider_descriptor(d.provider).

// bridge_provider_descriptor joins the static registry with the cached Hub
// catalog. A registered provider keeps its registry binary; a catalog-only slug
// gets the generic descriptor with the catalog row's binary ("" when the row is
// absent or inactive). Strings it adds live in the temp allocator.
bridge_provider_descriptor :: proc(name: string) -> contracts.Provider_Descriptor {
	d := bridge_provider_traits(name)
	if d.binary == "" {
		if binary, ok := bridge_provider_catalog_binary(name); ok do d.binary = binary
	}
	return d
}

// bridge_provider_traits is the pure registry lookup used by profile handling.
// A catalog-only provider launches over PTY with its catalog recipe, which
// accepts profile launch args and custom models.
bridge_provider_traits :: proc(name: string) -> contracts.Provider_Descriptor {
	if d, known := contracts.provider_descriptor(name); known do return d
	d := contracts.provider_descriptor_or_generic(name)
	d.profile_launch_args = true
	d.profile_custom_models = true
	return d
}

// bridge_provider_environ is env, or the bridge's own environment when nil.
@(private = "file")
bridge_provider_environ :: proc(env: []string) -> []string {
	if env != nil do return env
	base, _ := os.environ(context.temp_allocator)
	return base
}

// bridge_provider_resolve_binary resolves the CLI to run: the profile's
// binary_path, else the descriptor's binary. A path must be executable; a bare
// name is looked up on env's PATH (the profile child environment; nil means the
// bridge's own). The caller owns the returned path.
bridge_provider_resolve_binary :: proc(d: contracts.Provider_Descriptor, pp: ^Provider_Profile, env: []string) -> (string, bool) {
	command := d.binary
	if pp != nil && pp.config.binary_path != "" do command = pp.config.binary_path
	if command == "" do return "", false
	path := profile_resolve_binary(command, bridge_provider_environ(env))
	return path, path != ""
}

Bridge_Provider_CLI_Version :: struct {
	raw:       string, // first output line (stdout, else stderr), at most 256 bytes: the wire's version_text
	parsed:    string, // exact x.y.z per the descriptor's version format; "" when unparsed
	ok:        bool,   // the process ran and exited 0 before the deadline
	timed_out: bool,
	exit_code: int,    // -1 when the process could not be started
	excerpt:   string, // bounded stderr+stdout for failure diagnostics (temp allocator)
}

// bridge_provider_cli_version runs `<path> --version` under env (nil inherits
// the bridge's environment) and parses it per the descriptor. raw and parsed
// are allocated with allocator and are "" unless ok.
bridge_provider_cli_version :: proc(d: contracts.Provider_Descriptor, path: string, env: []string, timeout: time.Duration, allocator := context.allocator) -> (v: Bridge_Provider_CLI_Version) {
	v.exit_code = -1
	if path == "" do return
	stdout, stderr, exit_code, ran, timed_out := bridge_process_run_capture_status_env({path, "--version"}, timeout, env)
	defer { delete(stdout); delete(stderr) }
	v.exit_code, v.timed_out = exit_code, timed_out
	v.ok = ran && !timed_out && exit_code == 0
	if !v.ok {
		v.excerpt = strings.concatenate({stderr[:min(len(stderr), 512)], stdout[:min(len(stdout), 512)]}, context.temp_allocator)
		return
	}
	text := strings.trim_space(stdout)
	if text == "" do text = strings.trim_space(stderr)
	if newline := strings.index_byte(text, '\n'); newline >= 0 do text = strings.trim_space(text[:newline])
	if len(text) > 256 do text = text[:256]
	v.raw = strings.clone(text, allocator)
	if parsed, valid := contracts.provider_parse_cli_version(d, stdout); valid do v.parsed = strings.clone(parsed, allocator)
	return
}

// bridge_provider_cli_version_check runs bridge_provider_cli_version and
// compares its parsed version with the registry minimum
// (contracts.provider_version_status, the one comparison): Missing when the
// CLI did not run or its version is unparsed, Outdated below the minimum.
bridge_provider_cli_version_check :: proc(d: contracts.Provider_Descriptor, path: string, env: []string, timeout: time.Duration, allocator := context.allocator) -> (v: Bridge_Provider_CLI_Version, status: contracts.Provider_Version_Status) {
	v = bridge_provider_cli_version(d, path, env, timeout, allocator)
	return v, contracts.provider_version_status(d, v.parsed)
}

// bridge_provider_config_dir resolves the provider's config directory: the
// profile's config field, else the CLI's config env var in env (nil means the
// bridge's own environment; a leading "~/" expands), else the home default.
// "" when none applies. The result lives in the temp allocator.
bridge_provider_config_dir :: proc(d: contracts.Provider_Descriptor, pp: ^Provider_Profile, env: []string) -> string {
	env := bridge_provider_environ(env)
	home := profile_env_value(env, "HOME")
	when ODIN_OS == .Windows { if home == "" do home = profile_env_value(env, "USERPROFILE") }
	if home == "" {
		owned := cfg_lib.home_dir()
		home = strings.clone(owned, context.temp_allocator)
		delete(owned)
	}
	env_dir := strings.trim_space(profile_env_value(env, d.config_dir_env)) if d.config_dir_env != "" else ""
	if strings.has_prefix(env_dir, "~/") && home != "" do env_dir = strings.concatenate({home, env_dir[1:]}, context.temp_allocator)
	profile_dir := ""
	if pp != nil do profile_dir = profile_config_field_dir(d, &pp.config)
	return contracts.provider_config_dir_resolve(d, profile_dir, env_dir, home)
}

// profile_config_field_dir is the config directory a profile sets through the
// descriptor's config field ("" when it sets none). A shadow home (Codex P1c)
// replaces the home path it shadows.
profile_config_field_dir :: proc(d: contracts.Provider_Descriptor, c: ^Provider_Profile_Config) -> string {
	switch d.config_field {
	case .None:
		return ""
	case .Config_Dir:
		return c.config_dir
	case .Home_Path:
		return c.shadow_home_path if c.shadow_home_path != "" else c.home_path
	}
	return ""
}

// profile_config_env_field maps a descriptor profile_env_fields name onto the
// profile config field that stores it (redacted is nil for non-secret fields).
profile_config_env_field :: proc(c: ^Provider_Profile_Config, field: string) -> (value: ^string, redacted: ^bool) {
	switch field {
	case "api_key":      return &c.api_key, &c.api_key_redacted
	case "gcp_project":  return &c.gcp_project, nil
	case "gcp_location": return &c.gcp_location, nil
	}
	return nil, nil
}
