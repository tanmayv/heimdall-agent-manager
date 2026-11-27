package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"

@(test)
test_pty_spawn_resolves_bare_binary_path_on_profile_path :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	dir := fmt.tprintf("%s/ham-b1-binary-%d-%d", base, os.get_pid(), time.tick_now()._nsec)
	defer os.remove_all(dir)
	bin := profile_join(dir, "bin")
	binary := profile_join(bin, "ham-b1-profile-claude")
	p1c_put(t, binary, "#!/bin/sh\nexit 0\n", true)

	snap := Bridge_Provider_Catalog_Snapshot{providers = []Bridge_Catalog_Provider{
		{provider = "claude", state = "active", binary = "claude", model_flag = "--model", prompt_delivery = "arg", prompt_args = []string{"--prompt"},
		 starter_prompt = "hello", models = []Bridge_Catalog_Model{{model_id = "seed", state = "active"}}},
	}}
	old, old_loaded := provider_binary_path_with_catalog(&snap)
	defer provider_binary_path_restore_catalog(old, old_loaded)

	// A bare name is looked up on the profile's PATH, never used verbatim.
	pp := Provider_Profile{profile_id = "claude_bare", provider = "claude", enabled = true,
		config = {binary_path = "ham-b1-profile-claude"}, environment = {{name = "PATH", value = bin}}}
	req, ok := bridge_pty_host_build_spawn("b1_bare_binary", "/run/b1", "claude", "seed", "agent-token", []string{"HEIMDALL_AGENT_TOKEN=t"}, pp = &pp)
	if !testing.expect(t, ok) do return
	defer bridge_pty_host_spawn_request_delete(req)
	testing.expect(t, len(req.argv) > 0 && strings.has_suffix(req.argv[0], "/bin/ham-b1-profile-claude") && strings.has_prefix(req.argv[0], "/"), "bare binary_path resolves to an absolute path")

	// A bare name that is not on the profile's PATH fails the launch.
	pp.environment = {{name = "PATH", value = profile_join(dir, "empty")}}
	_, ok = bridge_pty_host_build_spawn("b1_bare_missing", "/run/b1", "claude", "seed", "agent-token", nil, pp = &pp)
	testing.expect(t, !ok, "an unresolvable binary_path is not spawned")
}

@(test)
test_provider_resolve_binary_uses_profile_override_then_descriptor :: proc(t: ^testing.T) {
	env := []string{"PATH=/bin:/usr/bin"}
	d := contracts.Provider_Descriptor{provider = "x", binary = "sh"}
	path, ok := bridge_provider_resolve_binary(d, nil, env)
	defer delete(path)
	testing.expect(t, ok && strings.has_prefix(path, "/"), "a bare descriptor binary resolves on PATH to an absolute path")
	pp := Provider_Profile{provider = "x", config = {binary_path = "/definitely/not/here"}}
	_, ok = bridge_provider_resolve_binary(d, &pp, env)
	testing.expect(t, !ok, "a missing override never falls back to the default binary")
	// A catalog-only slug without a catalog row has no binary to resolve.
	_, ok = bridge_provider_resolve_binary(contracts.Provider_Descriptor{provider = "nope"}, nil, env)
	testing.expect(t, !ok)
}

@(test)
test_provider_config_dir_resolver_precedence :: proc(t: ^testing.T) {
	// The default Codex home honours CODEX_HOME (with ~ expansion), else ~/.codex.
	testing.expect_value(t, bridge_codex_default_home([]string{"HOME=/h", "CODEX_HOME=/codex-env"}), "/codex-env")
	testing.expect_value(t, bridge_codex_default_home([]string{"HOME=/h", "CODEX_HOME= ~/alt "}), "/h/alt")
	testing.expect_value(t, bridge_codex_default_home([]string{"HOME=/h"}), "/h/.codex")
	// A profile's own directory wins over the env var.
	codex := bridge_provider_traits("codex")
	pp := Provider_Profile{provider = "codex", config = {home_path = "/profile/codex"}}
	testing.expect_value(t, bridge_provider_config_dir(codex, &pp, []string{"HOME=/h", "CODEX_HOME=/env"}), "/profile/codex")
	pp.config.shadow_home_path = "/profile/shadow"
	testing.expect_value(t, bridge_provider_config_dir(codex, &pp, []string{"HOME=/h"}), "/profile/shadow")
	copilot := bridge_provider_traits("copilot")
	cp := Provider_Profile{provider = "copilot", config = {config_dir = "/profile/copilot"}}
	testing.expect_value(t, bridge_provider_config_dir(copilot, &cp, []string{"HOME=/h"}), "/profile/copilot")
	testing.expect_value(t, bridge_provider_config_dir(copilot, nil, []string{"HOME=/h", "COPILOT_HOME=/env/copilot"}), "/env/copilot")
	// Antigravity plugin config lives under GEMINI_CONFIG_DIR, else ~/.gemini.
	paths := bridge_extension_gemini_paths([]string{"HOME=/h", "GEMINI_CONFIG_DIR=/g"}, "heimdall", false)
	testing.expect(t, len(paths) == 2 && paths[0] == "/g/config.json" && paths[1] == "/g/config/config.json")
	paths = bridge_extension_gemini_paths([]string{"HOME=/h"}, "heimdall", true)
	testing.expect(t, len(paths) == 2 && paths[0] == "/h/.gemini/plugins/heimdall/plugin.json")
}

@(test)
test_profile_env_fields_and_secrets_come_from_descriptor :: proc(t: ^testing.T) {
	agy := Provider_Profile{profile_id = "agy_work", provider = "antigravity",
		config = {api_key = "k", gcp_project = "proj", gcp_location = "loc", auth_method = "agent-platform"}}
	plan := profile_env_plan(&agy)
	want := [][2]string{{"GEMINI_API_KEY", "k"}, {"GOOGLE_CLOUD_PROJECT", "proj"}, {"GOOGLE_CLOUD_LOCATION", "loc"}}
	testing.expect_value(t, len(plan.set), len(want))
	for pair, i in want do if i < len(plan.set) do testing.expect(t, plan.set[i] == pair)
	secrets := profile_secret_fields(&agy)
	testing.expect_value(t, len(secrets), 1)
	if len(secrets) == 1 do testing.expect(t, secrets[0].value == &agy.config.api_key && secrets[0].redacted == &agy.config.api_key_redacted && secrets[0].sensitive)
	claude := Provider_Profile{profile_id = "claude_work", provider = "claude", config = {config_dir = "/c"}}
	testing.expect_value(t, len(profile_secret_fields(&claude)), 0)
	plan = profile_env_plan(&claude)
	testing.expect(t, len(plan.set) == 1 && plan.set[0] == [2]string{"CLAUDE_CONFIG_DIR", "/c"})
}

// A fake CLI whose `--version` runs body (a shell fragment).
@(private = "file")
provider_version_fixture :: proc(t: ^testing.T, name, body: string) -> string {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" do base = "/tmp"
	path := fmt.tprintf("%s/ham-r1-version-%s-%d-%d", base, name, os.get_pid(), time.tick_now()._nsec)
	testing.expect(t, os.write_entire_file(path, fmt.tprintf("#!/bin/sh\n%s\n", body)) == nil)
	testing.expect(t, os.chmod(path, os.Permissions{.Read_User, .Write_User, .Execute_User}) == nil)
	return path
}

// The version check returns the parsed version and its status against the
// registry minimum (Kiro: 3.5.0 from its ACP recipe).
@(test)
test_provider_cli_version_check_status :: proc(t: ^testing.T) {
	kiro := bridge_provider_traits("kiro")
	cases := []struct{ body, parsed: string, status: contracts.Provider_Version_Status }{
		{"echo 'kiro-cli 3.5.0'", "3.5.0", .Ok},
		{"echo 'kiro-cli 3.10.2'", "3.10.2", .Ok},
		{"echo 'kiro-cli 3.4.9'", "3.4.9", .Outdated},
		{"echo 'something else'", "", .Missing},
		{"exit 3", "", .Missing},
	}
	for c in cases {
		path := provider_version_fixture(t, "kiro", c.body)
		defer os.remove(path)
		v, status := bridge_provider_cli_version_check(kiro, path, nil, 2*time.Second, context.temp_allocator)
		testing.expectf(t, v.parsed == c.parsed && status == c.status, "%q: got (%q, %v)", c.body, v.parsed, status)
	}
}
