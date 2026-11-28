package contracts

import "core:strings"
import "core:testing"

@(test)
provider_descriptors_are_valid_and_unique :: proc(t: ^testing.T) {
	all := provider_descriptors()
	testing.expect_value(t, len(all), 7)
	expected := []string{"claude", "codex", "copilot", "antigravity", "pi", "kiro", "opencode"}
	for name, i in expected do testing.expect_value(t, all[i].provider, name)
	for d, i in all {
		testing.expectf(t, provider_descriptor_shape_valid(d), "%s: shape invalid", d.provider)
		for previous in all[:i] {
			testing.expect(t, previous.provider != d.provider && previous.log_sym != d.log_sym && previous.binary != d.binary)
			for name in d.program_names do for other in previous.program_names do testing.expectf(t, name != other, "program %s listed twice", name)
			for alias in d.aliases do testing.expect(t, alias != previous.provider)
		}
		got, ok := provider_descriptor(d.provider)
		testing.expect(t, ok && got.provider == d.provider)
		testing.expect_value(t, bridge_log_provider_sym(d.provider), d.log_sym)
		testing.expect_value(t, bridge_log_sym_name(d.log_sym), d.provider)
	}
	testing.expect(t, !provider_descriptor_shape_valid(Provider_Descriptor{provider = "x"}))
}

@(test)
provider_descriptor_lookup_aliases_and_generic :: proc(t: ^testing.T) {
	d, ok := provider_descriptor("claude-code")
	testing.expect(t, ok && d.provider == "claude")
	testing.expect_value(t, provider_telemetry_name("claude-code"), "claude")
	for unknown in ([]string{"", "gemini", "CLAUDE", "/usr/bin/evil", "other"}) {
		_, found := provider_descriptor(unknown)
		testing.expectf(t, !found, "%q must not resolve", unknown)
		testing.expect_value(t, provider_telemetry_name(unknown), "other")
	}
	g := provider_descriptor_or_generic("custom-cli")
	testing.expect(t, g.provider == "custom-cli" && g.log_sym == .other && g.extension == .None &&
		g.model_probe == .None && g.version_format == .Raw && g.binary == "")
	testing.expect_value(t, provider_descriptor_or_generic("kiro").binary, "kiro-cli")
}

@(test)
provider_log_syms_drop_gemini_and_name_new_providers :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_log_provider_sym("gemini"), Bridge_Log_Sym.other)
	testing.expect_value(t, bridge_log_provider_sym("pi"), Bridge_Log_Sym.pi)
	testing.expect_value(t, bridge_log_provider_sym("kiro"), Bridge_Log_Sym.kiro)
	testing.expect_value(t, bridge_log_provider_sym("opencode"), Bridge_Log_Sym.opencode)
	testing.expect_value(t, bridge_log_provider_sym("claude-code"), Bridge_Log_Sym.claude)
	for name in ([]string{"pi", "kiro", "opencode"}) {
		sym, ok := bridge_log_sym_from_name(name)
		testing.expect(t, ok && bridge_log_sym_name(sym) == name)
	}
}

@(test)
provider_for_program_maps_basenames :: proc(t: ^testing.T) {
	cases := [][2]string{
		{"/nix/store/abc/bin/claude", "claude"},
		{"claude-agent-acp", "claude"},
		{"/usr/bin/codex app-server", "codex"},
		{"/usr/local/bin/AGY", "antigravity"},
		{"kiro-cli", "kiro"},
		{"/opt/opencode", "opencode"},
		{"pi", "pi"},
		{"C:\\tools\\copilot", "copilot"},
	}
	for c in cases {
		d, ok := provider_for_program(c[0])
		testing.expectf(t, ok && d.provider == c[1], "%s -> %s, got %s", c[0], c[1], d.provider)
	}
	for program in ([]string{"", "/usr/bin/gemini", "/bin/", "bash", "kiro"}) {
		_, ok := provider_for_program(program)
		testing.expectf(t, !ok, "%q must not map to a provider", program)
	}
}

@(test)
provider_parse_cli_version_per_format :: proc(t: ^testing.T) {
	claude, _ := provider_descriptor("claude")
	codex, _ := provider_descriptor("codex")
	copilot, _ := provider_descriptor("copilot")
	kiro, _ := provider_descriptor("kiro")
	opencode, _ := provider_descriptor("opencode")
	pi, _ := provider_descriptor("pi")
	Case :: struct { d: Provider_Descriptor, output, want: string, ok: bool }
	cases := []Case{
		{claude, "2.1.3 (Claude Code)\n", "2.1.3", true},
		{claude, "Claude Code 2.1.3", "", false},
		{codex, "codex-cli 0.162.0", "0.162.0", true},
		{codex, "0.162.0", "", false},
		{copilot, "GitHub Copilot CLI 1.0.114.\nRun 'copilot update' to check for updates.", "1.0.114", true},
		{copilot, "warning: 9.9.9\nGitHub Copilot CLI 1.0.114.", "", false},
		{kiro, "kiro-cli 3.5.0 (build abc)", "3.5.0", true},
		{kiro, "kiro-cli 3.5", "", false},
		{opencode, "1.19.6\n", "1.19.6", true},
		{opencode, "opencode 1.19.6", "", false},
		{pi, "0.9.1", "", false},
	}
	for c in cases {
		got, ok := provider_parse_cli_version(c.d, c.output)
		testing.expectf(t, got == c.want && ok == c.ok, "%s %q: got (%q, %v)", c.d.provider, c.output, got, ok)
	}
}

@(test)
provider_config_dir_precedence :: proc(t: ^testing.T) {
	claude, _ := provider_descriptor("claude")
	testing.expect_value(t, provider_config_dir_resolve(claude, "/p/claude", "/env/claude", "/home/u"), "/p/claude")
	testing.expect_value(t, provider_config_dir_resolve(claude, "", "/env/claude", "/home/u"), "/env/claude")
	testing.expect_value(t, provider_config_dir_resolve(claude, "", "", "/home/u/"), "/home/u/.claude")
	testing.expect_value(t, provider_config_dir_resolve(claude, "", "", ""), "")
	codex, _ := provider_descriptor("codex")
	testing.expect(t, codex.config_field == .Home_Path && codex.config_dir_env == "CODEX_HOME")
	testing.expect_value(t, provider_config_dir_resolve(codex, "", "", "/home/u"), "/home/u/.codex")
	// Antigravity profiles have no config field: only GEMINI_CONFIG_DIR or ~/.gemini.
	agy, _ := provider_descriptor("antigravity")
	testing.expect_value(t, provider_config_dir_resolve(agy, "/ignored", "", "/home/u"), "/home/u/.gemini")
	testing.expect_value(t, provider_config_dir_resolve(agy, "", "/g", "/home/u"), "/g")
	kiro, _ := provider_descriptor("kiro")
	testing.expect(t, kiro.config_field == .Config_Dir && kiro.config_dir_env == "KIRO_HOME" &&
		len(kiro.config_dir_derived_env) == 1 && kiro.config_dir_derived_env[0] == [2]string{"XDG_DATA_HOME", "data"})
	// No env var or config field: only the home default (~/.pi/agent) applies.
	pi, _ := provider_descriptor("pi")
	testing.expect_value(t, provider_config_dir_resolve(pi, "/p", "/env", "/home/u"), "/home/u/.pi/agent")
	opencode, _ := provider_descriptor("opencode")
	testing.expect_value(t, provider_config_dir_resolve(opencode, "/p", "/env", "/home/u"), "/home/u/.config/opencode")
}

// Copilot and Kiro: profile dir, else the env var value, else the home default.
@(test)
provider_config_dir_copilot :: proc(t: ^testing.T) {
	copilot, _ := provider_descriptor("copilot")
	testing.expect_value(t, provider_config_dir_resolve(copilot, "/p", "/env", "/home/u"), "/p")
	testing.expect_value(t, provider_config_dir_resolve(copilot, "", "/env", "/home/u"), "/env")
	testing.expect_value(t, provider_config_dir_resolve(copilot, "", "", "/home/u"), "/home/u/.copilot")
}

@(test)
provider_config_dir_kiro :: proc(t: ^testing.T) {
	kiro, _ := provider_descriptor("kiro")
	testing.expect_value(t, provider_config_dir_resolve(kiro, "/p", "/env", "/home/u"), "/p")
	testing.expect_value(t, provider_config_dir_resolve(kiro, "", "/env", "/home/u"), "/env")
	testing.expect_value(t, provider_config_dir_resolve(kiro, "", "", "/home/u"), "/home/u/.kiro")
}

// OpenCode has no profile field or env var: only ~/.config/opencode applies.
@(test)
provider_config_dir_opencode :: proc(t: ^testing.T) {
	opencode, _ := provider_descriptor("opencode")
	testing.expect_value(t, provider_config_dir_resolve(opencode, "", "", "/home/u"), "/home/u/.config/opencode")
	testing.expect_value(t, provider_config_dir_resolve(opencode, "", "", ""), "")
}

@(test)
provider_extension_and_profile_traits :: proc(t: ^testing.T) {
	with_extension := 0
	for d in provider_descriptors() do if d.extension != .None do with_extension += 1
	testing.expect_value(t, with_extension, 3)
	claude, _ := provider_descriptor("claude")
	codex, _ := provider_descriptor("codex")
	testing.expect(t, claude.extension_dir == "claude-code" && claude.extension_marketplace == "heimdall")
	testing.expect(t, codex.extension_dir == "codex" && codex.extension_marketplace == "heimdall-codex")
	agy, _ := provider_descriptor("antigravity")
	testing.expect(t, !agy.profile_launch_args && !agy.profile_custom_models && len(agy.profile_auth_methods) == 4)
	secrets := 0
	for f in agy.profile_env_fields do if f.secret { secrets += 1; testing.expect_value(t, f.field, "api_key") }
	testing.expect_value(t, secrets, 1)
	for d in provider_descriptors() do if d.provider != "antigravity" {
		testing.expect(t, d.profile_launch_args && d.profile_custom_models && len(d.profile_env_fields) == 0 && len(d.profile_auth_methods) == 0)
	}
}

// The config file `ham-ctl setup` checks for a managed read-only symlink.
@(test)
provider_config_file_per_provider :: proc(t: ^testing.T) {
	want := [][2]string{{"claude", "settings.json"}, {"codex", "config.toml"}, {"antigravity", "hooks.json"}, {"pi", "extensions"}}
	for d in provider_descriptors() {
		expected := ""
		for w in want do if w[0] == d.provider do expected = w[1]
		testing.expectf(t, d.config_file == expected, "%s config_file %q", d.provider, d.config_file)
	}
	bad, _ := provider_descriptor("claude")
	bad.config_file = "../escape"
	testing.expect(t, !provider_descriptor_shape_valid(bad))
	bad.config_file = "/abs"
	testing.expect(t, !provider_descriptor_shape_valid(bad))
	no_dir, _ := provider_descriptor("opencode")
	no_dir.config_dir_default = ""
	no_dir.config_file = "x.json"
	testing.expect(t, !provider_descriptor_shape_valid(no_dir))
}

// Only Antigravity keeps the explicit bootstrap-read step.
@(test)
provider_keeps_bootstrap_read_trait :: proc(t: ^testing.T) {
	for d in provider_descriptors() {
		testing.expectf(t, d.keeps_bootstrap_read == (d.provider == "antigravity"), "%s keeps_bootstrap_read %v", d.provider, d.keeps_bootstrap_read)
	}
	testing.expect(t, !provider_descriptor_or_generic("custom").keeps_bootstrap_read)
}

// The registry's ACP model probe and the ACP recipe's opt-in never disagree:
// a provider probes models over ACP exactly when its ACP recipe is an ACP
// session (system CLI or adapter) that opts in to metadata-only discovery.
@(test)
provider_model_probe_agrees_with_acp_recipe :: proc(t: ^testing.T) {
	for d in provider_descriptors() {
		acp, found := acp_provider_descriptor(d.provider)
		recipe_discovers := found && acp.discover_models_via_acp && acp.protocol == .ACP
		testing.expectf(t, (d.model_probe == .ACP) == recipe_discovers, "%s: model_probe %v, ACP recipe discovers %v", d.provider, d.model_probe, recipe_discovers)
	}
	for acp in acp_provider_descriptors {
		if !acp.discover_models_via_acp do continue
		d, known := provider_descriptor(acp.provider)
		testing.expectf(t, known && d.model_probe == .ACP, "%s opts in to ACP discovery but its registry probe is %v", acp.provider, d.model_probe)
	}
}

// The minimum version comes from the detect-only ACP recipe; hints never
// repeat it as free text.
@(test)
provider_min_version_and_status :: proc(t: ^testing.T) {
	kiro, _ := provider_descriptor("kiro")
	opencode, _ := provider_descriptor("opencode")
	codex, _ := provider_descriptor("codex")
	copilot, _ := provider_descriptor("copilot")
	pi, _ := provider_descriptor("pi")
	testing.expect_value(t, provider_min_version(kiro), "3.5.0")
	testing.expect_value(t, provider_min_version(opencode), "1.19.6")
	testing.expect_value(t, provider_min_version(codex), "0.162.0")
	testing.expect_value(t, provider_min_version(copilot), "1.0.114") // user-installed minimum
	testing.expect_value(t, provider_min_version(pi), "")      // no ACP runtime
	testing.expect_value(t, provider_version_status(kiro, "3.5.0"), Provider_Version_Status.Ok)
	testing.expect_value(t, provider_version_status(kiro, "3.10.0"), Provider_Version_Status.Ok)
	testing.expect_value(t, provider_version_status(kiro, "3.4.9"), Provider_Version_Status.Outdated)
	testing.expect_value(t, provider_version_status(kiro, ""), Provider_Version_Status.Missing)
	testing.expect_value(t, provider_version_status(kiro, "v3.5.0"), Provider_Version_Status.Missing)
	testing.expect_value(t, provider_version_status(pi, "0.0.1"), Provider_Version_Status.Ok)
	for d in provider_descriptors() {
		if minimum := provider_min_version(d); minimum != "" {
			testing.expectf(t, !strings.contains(d.install_hint, minimum), "%s install_hint repeats %s", d.provider, minimum)
		}
	}
}

// Session-history directories scanned by bridge session-project discovery.
@(test)
provider_history_dir_per_provider :: proc(t: ^testing.T) {
	for d in provider_descriptors() {
		want := ""
		switch d.provider {
		case "claude": want = "projects"
		case "codex":  want = "sessions"
		}
		testing.expectf(t, d.history_dir == want, "%s history_dir %q", d.provider, d.history_dir)
	}
	bad, _ := provider_descriptor("codex")
	bad.history_dir = "../escape"
	testing.expect(t, !provider_descriptor_shape_valid(bad))
}
