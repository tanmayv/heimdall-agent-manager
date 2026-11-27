package main

import "core:encoding/json"
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
			testing.expect_value(t, h.config_path, "/home/u/.claude")
			testing.expect_value(t, h.config_dir_env, "CLAUDE_CONFIG_DIR")
		case "codex":
			testing.expect_value(t, h.config_path, "/custom/codex") // CODEX_HOME wins over ~/.codex
		case "antigravity":
			testing.expect_value(t, h.config_path, "/home/u/.gemini")
		case "kiro":
			testing.expect_value(t, h.config_dir_env, "KIRO_HOME")
			testing.expect_value(t, h.config_path, "") // no default: the user's own login
		}
	}

	report := setup_report_json(harnesses, "")
	parsed, err := json.parse_string(report)
	testing.expect_value(t, err, json.Error.None)
	rows := parsed.(json.Object)["harnesses"].(json.Array)
	testing.expect_value(t, len(rows), 7)
	testing.expect(t, strings.contains(report, `"name":"kiro","bin":"kiro-cli"`), report)
	testing.expect(t, strings.contains(report, `"name":"opencode","bin":"opencode"`), report)
	only := setup_report_json(harnesses, "kiro")
	testing.expect(t, strings.count(only, `"name":`) == 1 && strings.contains(only, `"KIRO_HOME"`), only)
}
