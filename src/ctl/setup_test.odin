package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"
import "core:strings"
import "core:testing"

@(private = "file")
setup_test_env :: proc(key: string) -> string {
	if key == "CODEX_HOME" do return "/custom/codex"
	return ""
}

// `ham-ctl setup` lists every registry provider with its real binary and
// config-directory convention (env override, else home default).
@(test)
test_setup_harnesses_from_provider_registry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	harnesses := setup_known_harnesses("/home/u", setup_test_env)
	testing.expect_value(t, len(harnesses), 7)
	want := [][2]string{
		{"claude", "claude"}, {"codex", "codex"}, {"copilot", "copilot"}, {"antigravity", "agy"},
		{"pi", "pi"}, {"kiro", "kiro-cli"}, {"opencode", "opencode"},
	}
	for h in harnesses {
		bin := ""
		for w in want do if w[0] == h.name do bin = w[1]
		testing.expectf(t, bin != "", "unexpected harness %s", h.name)
		testing.expectf(t, h.bin == bin, "%s binary %s, want %s", h.name, h.bin, bin)
		testing.expectf(t, h.install_hint != "" && h.auth_hint != "", "%s has install and auth guidance", h.name)
		switch h.name {
		case "claude":
			testing.expect_value(t, h.config_dir, "/home/u/.claude")
			testing.expect_value(t, h.config_file, "/home/u/.claude/settings.json")
			testing.expect_value(t, h.config_dir_env, "CLAUDE_CONFIG_DIR")
		case "codex":
			testing.expect_value(t, h.config_dir, "/custom/codex") // CODEX_HOME wins over ~/.codex
			testing.expect_value(t, h.config_file, "/custom/codex/config.toml")
		case "antigravity":
			testing.expect_value(t, h.config_dir, "/home/u/.gemini")
			testing.expect_value(t, h.config_file, "/home/u/.gemini/hooks.json")
		case "pi":
			testing.expect_value(t, h.config_file, "/home/u/.pi/agent/extensions")
		case "kiro":
			testing.expect_value(t, h.config_dir_env, "KIRO_HOME")
			testing.expect_value(t, h.config_dir, "/home/u/.kiro")
			testing.expect_value(t, h.install_hint, "install Kiro CLI (kiro-cli) 3.5.0 or newer") // minimum from the registry
			testing.expect_value(t, h.config_file, "")
		case "copilot":
			testing.expect_value(t, h.config_dir, "/home/u/.copilot")
			testing.expect(t, !strings.contains(h.install_hint, "or newer"), h.install_hint) // pinned runtime: no minimum
		case "opencode":
			testing.expect_value(t, h.config_dir, "/home/u/.config/opencode")
			testing.expect_value(t, h.install_hint, "install OpenCode (opencode) 1.19.6 or newer")
		}
	}

	report := setup_report_json(harnesses, "")
	parsed, err := json.parse_string(report)
	testing.expect_value(t, err, json.Error.None)
	rows := parsed.(json.Object)["harnesses"].(json.Array)
	testing.expect_value(t, len(rows), 7)
	testing.expect(t, strings.contains(report, `"name":"kiro","bin":"kiro-cli"`), report)
	testing.expect(t, strings.contains(report, `"name":"opencode","bin":"opencode"`), report)
	// config_path keeps its original meaning (the config file); config_dir is the directory.
	claude := setup_report_json(harnesses, "claude")
	testing.expect(t, strings.contains(claude, `"config_path":"/home/u/.claude/settings.json","config_dir":"/home/u/.claude"`), claude)
	only := setup_report_json(harnesses, "kiro")
	testing.expect(t, strings.count(only, `"name":`) == 1 && strings.contains(only, `"KIRO_HOME"`), only)
	testing.expect(t, strings.contains(only, `"config_path":"","config_dir":"/home/u/.kiro"`), only) // no config file
}

@(private = "file")
setup_test_no_env :: proc(key: string) -> string { return "" }

// A home-manager style symlinked settings.json (inside a real config directory)
// is reported as read-only managed config that needs an overlay; a regular
// config file is not.
@(test)
test_setup_symlinked_config_file_needs_overlay :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	home := fmt.tprintf("%s/.cache/heimdall-tests/setup-overlay-%p-%d", os.get_env("HOME", context.temp_allocator), t, time.to_unix_nanoseconds(time.now()))
	testing.expect(t, os.make_directory_all(home) == nil)
	defer _ = os.remove_all(home)
	store := fmt.tprintf("%s/store-settings.json", home)
	testing.expect(t, os.write_entire_file_from_string(store, "{}") == nil)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/.claude", home)) == nil)
	testing.expect(t, os.symlink(store, fmt.tprintf("%s/.claude/settings.json", home)) == nil)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/.codex", home)) == nil)
	testing.expect(t, os.write_entire_file_from_string(fmt.tprintf("%s/.codex/config.toml", home), "") == nil)

	harnesses := setup_known_harnesses(home, setup_test_no_env)
	for h in harnesses {
		switch h.name {
		case "claude": testing.expect(t, setup_config_managed(h), "symlinked settings.json is managed")
		case "codex":  testing.expect(t, !setup_config_managed(h), "regular config.toml is not managed")
		}
	}
	report := setup_report_json(harnesses, "claude")
	testing.expect(t, strings.contains(report, `"needs_overlay":true`), report)
	testing.expect(t, strings.contains(report, fmt.tprintf(`"config_path":"%s/.claude/settings.json"`, home)), report)
	testing.expect(t, strings.contains(report, `"config_present":true`), report)
	codex := setup_report_json(harnesses, "codex")
	testing.expect(t, strings.contains(codex, `"needs_overlay":false`), codex)
}
