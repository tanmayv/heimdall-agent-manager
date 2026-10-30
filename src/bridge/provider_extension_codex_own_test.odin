package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
test_codex_own_marketplace_name_is_toml_safe :: proc(t: ^testing.T) {
	testing.expect_value(t, bridge_codex_own_marketplace_name_for("heimdall-bridge-hub-brolabs-ai"), "heimdall-codex-heimdall-bridge-hub-brolabs-ai")
	testing.expect_value(t, bridge_codex_own_marketplace_name_for("Heimdall_Bridge.Two"), "heimdall-codex-heimdall-bridge-two")
	testing.expect_value(t, bridge_codex_own_marketplace_name_for("  "), "")
	testing.expect_value(t, bridge_codex_own_marketplace_name_for("\"]x"), "heimdall-codex-x")
}

@(test)
test_codex_own_launch_args_need_the_installed_plugin :: proc(t: ^testing.T) {
	home := fmt.tprintf("/tmp/heimdall-codex-own-home-%d", time.now()._nsec)
	defer _ = os.remove_all(home)
	mp := "heimdall-codex-bridge-a"
	testing.expect(t, bridge_codex_own_launch_args_for(home, mp) == nil, "no cache: no override")
	testing.expect(t, bridge_codex_own_launch_args_for(home, "") == nil, "no marketplace: no override")

	cache := fmt.tprintf("%s/plugins/cache/%s/heimdall/0.5.30", home, mp)
	testing.expect(t, os.make_directory_all(cache) == nil)
	args := bridge_codex_own_launch_args_for(home, mp)
	testing.expect_value(t, len(args), 4)
	if len(args) == 4 {
		// The shared registration off, this bridge's own on: exactly one load.
		testing.expect_value(t, args[0], "-c")
		testing.expect_value(t, args[1], "plugins.heimdall@heimdall-codex.enabled=false")
		testing.expect_value(t, args[2], "-c")
		testing.expect_value(t, args[3], "plugins.heimdall@heimdall-codex-bridge-a.enabled=true")
	}
	// Another bridge's cache does not count.
	testing.expect(t, bridge_codex_own_launch_args_for(home, "heimdall-codex-bridge-b") == nil)
}

@(test)
test_codex_config_set_plugin_disabled :: proc(t: ^testing.T) {
	id := "heimdall@heimdall-codex-a"
	Case :: struct { name, input, want: string, changed: bool }
	cases := []Case{
		{"enabled-true",
			"[marketplaces.heimdall-codex-a]\nsource = \"/x\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = true\n\n[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n",
			"[marketplaces.heimdall-codex-a]\nsource = \"/x\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n\n[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n",
			true},
		{"already-disabled",
			"[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n",
			"[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n",
			false},
		{"last-table-no-key",
			"model = \"o3\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\n",
			"model = \"o3\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n",
			true},
		{"middle-table-no-key",
			"[plugins.\"heimdall@heimdall-codex-a\"]\n[other]\nx = 1\n",
			"[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n[other]\nx = 1\n",
			true},
		{"missing-table",
			"model = \"o3\"\n",
			"model = \"o3\"\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n",
			true},
		{"empty", "", "[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n", true},
		{"other-plugin-untouched",
			"[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n",
			"[plugins.\"heimdall@heimdall-codex\"]\nenabled = true\n\n[plugins.\"heimdall@heimdall-codex-a\"]\nenabled = false\n",
			true},
	}
	for c in cases {
		got, changed := bridge_codex_config_set_plugin_disabled(c.input, id)
		testing.expectf(t, got == c.want, "%s: got %q want %q", c.name, got, c.want)
		testing.expectf(t, changed == c.changed, "%s: changed %v", c.name, changed)
	}
}

@(test)
test_codex_own_write_marketplace_names_this_bridge :: proc(t: ^testing.T) {
	data_dir := fmt.tprintf("/tmp/heimdall-codex-own-data-%d", time.now()._nsec)
	defer _ = os.remove_all(data_dir)
	_, ok, _ := bridge_codex_own_write_marketplace(data_dir, "heimdall-codex-x")
	testing.expect(t, !ok, "no extension copy: nothing registered")

	plugin := fmt.tprintf("%s/extensions/codex/.codex-plugin", data_dir)
	testing.expect(t, os.make_directory_all(plugin) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/plugin.json", plugin), transmute([]byte)string(`{"name":"heimdall","version":"0.5.30"}`)) == nil)
	root, written, msg := bridge_codex_own_write_marketplace(data_dir, "heimdall-codex-x")
	testing.expectf(t, written, "write: %s", msg)
	testing.expect_value(t, root, fmt.tprintf("%s/codex-marketplace", data_dir))
	testing.expect(t, os.exists(fmt.tprintf("%s/codex/.codex-plugin/plugin.json", root)), "plugin copied")
	raw, err := os.read_entire_file(fmt.tprintf("%s/.agents/plugins/marketplace.json", root), context.temp_allocator)
	testing.expect(t, err == nil)
	// Codex parses it like extensions/.agents/plugins/marketplace.json.
	value, jerr := json.parse(raw, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, jerr == nil, "valid JSON: %s", string(raw))
	testing.expect_value(t, string(value.(json.Object)["name"].(json.String)), "heimdall-codex-x")
	plugins, _ := value.(json.Object)["plugins"].(json.Array)
	testing.expect_value(t, len(plugins), 1)
	if len(plugins) == 1 {
		src, _ := plugins[0].(json.Object)["source"].(json.Object)
		testing.expect_value(t, string(src["path"].(json.String)), "./codex")
	}
	// The bridge's own extensions dir keeps the shared marketplace name for
	// per-account provider profiles: it is not modified.
	testing.expect(t, !os.exists(fmt.tprintf("%s/extensions/.agents/plugins/marketplace.json", data_dir)))
}

@(test)
test_codex_own_launch_args_only_for_default_codex :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/heimdall-codex-own-launch-%d", time.now()._nsec)
	defer _ = os.remove_all(root)
	home := fmt.tprintf("%s/codex-home", root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/plugins/cache/heimdall-codex-bridge-x/heimdall/0.5.30", home)) == nil)
	saved_home := os.get_env("CODEX_HOME", context.temp_allocator)
	defer {
		if saved_home != "" {
			_ = os.set_env("CODEX_HOME", saved_home)
		} else {
			os.unset_env("CODEX_HOME")
		}
	}
	_ = os.set_env("CODEX_HOME", home)
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved_data := bridge_config.data_dir
	defer bridge_config.data_dir = saved_data
	bridge_config.data_dir = fmt.tprintf("%s/bridges/bridge-x", root)

	args := bridge_pty_host_default_profile_args("codex")
	testing.expect_value(t, len(args), 4)
	if len(args) == 4 do testing.expect_value(t, args[3], "plugins.heimdall@heimdall-codex-bridge-x.enabled=true")
	// Claude launch args stay unchanged.
	testing.expect(t, bridge_pty_host_default_profile_args("claude") == nil)
	testing.expect(t, bridge_pty_host_default_profile_args("claude-code") == nil)
	testing.expect(t, bridge_pty_host_default_profile_args("antigravity") == nil)
	// Another bridge (no own plugin installed) keeps the shared release.
	bridge_config.data_dir = fmt.tprintf("%s/bridges/bridge-y", root)
	testing.expect(t, bridge_pty_host_default_profile_args("codex") == nil)
}
