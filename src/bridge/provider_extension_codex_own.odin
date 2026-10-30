package main

// Per-bridge Codex extension, loaded per launch (no separate CODEX_HOME).
//
// The OS user's normal Codex config keeps the shared `heimdall@heimdall-codex`
// registration (the newest release of any bridge, see
// provider_extension_reconcile.odin). In addition every bridge profile registers
// its own <data_dir>/extensions/codex under its own marketplace
// `heimdall-codex-<service>`, persisted with `enabled = false`, so neither the
// user's own Codex sessions nor other bridges' agents load it. This bridge's
// agents launch with
//   -c plugins.heimdall@heimdall-codex.enabled=false
//   -c plugins.heimdall@heimdall-codex-<service>.enabled=true
// and so load exactly one Heimdall plugin: their own bridge's version, with the
// shared CODEX_HOME and login. Codex (0.162.0) loads plugins from its versioned
// install cache only for marketplaces persisted in config.toml; `-c` can switch a
// persisted plugin on or off for one launch but cannot add a marketplace or
// repoint one. Codex has no CLI to disable a plugin, so the bridge edits the one
// `[plugins."heimdall@heimdall-codex-<service>"]` table itself.
//
// Everything here is best effort: when the own registration is missing the
// launch passes no override and agents keep the shared release.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import bridgesvc "odin_test:lib/bridgesvc"
import cfg_lib "odin_test:lib/config"

BRIDGE_CODEX_OWN_MARKETPLACE_PREFIX :: "heimdall-codex-"
BRIDGE_CODEX_OWN_MARKETPLACE_DIR :: "codex-marketplace"
BRIDGE_CODEX_PLUGIN_NAME :: "heimdall"

Bridge_Codex_Own_Ensure :: proc(bin_path: string, deadline: time.Time, env: []string) -> (ok: bool, msg: string)
Bridge_Codex_Own_Remove :: proc(bin_path: string, deadline: time.Time, env: []string)

// Called by bridge_extension_ensure/remove for the default Codex profile; tests
// replace these (they would touch the real ~/.codex/config.toml).
bridge_codex_own_ensure_hook: Bridge_Codex_Own_Ensure = bridge_codex_own_ensure
bridge_codex_own_remove_hook: Bridge_Codex_Own_Remove = bridge_codex_own_remove

// bridge_codex_own_marketplace_name_for maps a bridge service name to its
// marketplace name: lower-case letters, digits and '-' only (it is also a TOML
// bare key segment and a cache directory name). "" when nothing is left.
bridge_codex_own_marketplace_name_for :: proc(service: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for ch in strings.to_lower(strings.trim_space(service), context.temp_allocator) {
		switch ch {
		case 'a'..='z', '0'..='9', '-': strings.write_rune(&b, ch)
		case '_', '.', ' ':             strings.write_byte(&b, '-')
		}
	}
	s := strings.trim(strings.to_string(b), "-")
	if s == "" do return ""
	return strings.concatenate({BRIDGE_CODEX_OWN_MARKETPLACE_PREFIX, s}, allocator)
}

bridge_codex_own_data_dir :: proc() -> string {
	data_dir := strings.trim_space(bridge_config.data_dir)
	if data_dir == "" do return ""
	return codex_own_expand_home(data_dir, context.temp_allocator)
}

// This bridge's own marketplace name; "" without a data dir.
bridge_codex_own_marketplace_name :: proc() -> string {
	data_dir := bridge_codex_own_data_dir()
	if data_dir == "" do return ""
	return bridge_codex_own_marketplace_name_for(bridgesvc.pbase(strings.trim_right(data_dir, "/\\")))
}

bridge_codex_own_plugin_id :: proc(marketplace: string) -> string {
	return strings.concatenate({BRIDGE_CODEX_PLUGIN_NAME, "@", marketplace}, context.temp_allocator)
}

// The CODEX_HOME agents of the default profile use: $CODEX_HOME, else ~/.codex.
bridge_codex_default_home :: proc() -> string {
	if env := strings.trim_space(os.get_env("CODEX_HOME", context.temp_allocator)); env != "" do return codex_own_expand_home(env, context.temp_allocator)
	return codex_own_expand_home("~/.codex", context.temp_allocator)
}

// bridge_codex_own_launch_args_for is pure apart from one directory check: the
// per-launch overrides when marketplace's plugin is in codex_home's install
// cache, else nil (the launch keeps the shared release).
bridge_codex_own_launch_args_for :: proc(codex_home, marketplace: string, allocator := context.temp_allocator) -> []string {
	if codex_home == "" || marketplace == "" do return nil
	cache := bridgesvc.pjoin(bridgesvc.pjoin(bridgesvc.pjoin(codex_home, "plugins"), "cache"), bridgesvc.pjoin(marketplace, BRIDGE_CODEX_PLUGIN_NAME))
	if !os.is_dir(cache) do return nil
	args := make([]string, 4, allocator)
	args[0] = "-c"
	args[1] = strings.concatenate({"plugins.", BRIDGE_CODEX_PLUGIN_ID, ".enabled=false"}, allocator)
	args[2] = "-c"
	args[3] = strings.concatenate({"plugins.", BRIDGE_CODEX_PLUGIN_NAME, "@", marketplace, ".enabled=true"}, allocator)
	return args
}

// Overrides for a launch of the default Codex profile (no provider profile).
bridge_codex_own_launch_args :: proc(allocator := context.temp_allocator) -> []string {
	return bridge_codex_own_launch_args_for(bridge_codex_default_home(), bridge_codex_own_marketplace_name(), allocator)
}

// bridge_codex_config_set_plugin_disabled returns config (config.toml text) with
// `enabled = false` in the `[plugins."<plugin_id>"]` table, adding the key or the
// table when missing. changed is false when it already says so.
bridge_codex_config_set_plugin_disabled :: proc(config, plugin_id: string, allocator := context.temp_allocator) -> (out: string, changed: bool) {
	header := fmt.tprintf("[plugins.\"%s\"]", plugin_id)
	lines := strings.split_lines(config, context.temp_allocator)
	b := strings.builder_make(allocator)
	in_table, found, done := false, false, false
	write_line :: proc(b: ^strings.Builder, line: string, first: bool) {
		if !first do strings.write_byte(b, '\n')
		strings.write_string(b, line)
	}
	for line, i in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "[") {
			if in_table && !done {
				// The table ended without an enabled key.
				write_line(&b, "enabled = false", i == 0)
				done, changed = true, true
			}
			in_table = trimmed == header
			if in_table do found = true
		} else if in_table && !done {
			key := strings.trim_space(trimmed[:strings.index_byte(trimmed, '=')]) if strings.contains(trimmed, "=") else ""
			if key == "enabled" {
				done = true
				if strings.trim_space(trimmed[strings.index_byte(trimmed, '=') + 1:]) != "false" {
					write_line(&b, "enabled = false", i == 0)
					changed = true
					continue
				}
			}
		}
		write_line(&b, line, i == 0)
	}
	if in_table && !done {
		// The table is last in the file; keep a trailing newline at the end.
		text := strings.trim_right(strings.to_string(b), "\n")
		b2 := strings.builder_make(allocator)
		strings.write_string(&b2, text)
		strings.write_string(&b2, "\nenabled = false\n")
		return strings.to_string(b2), true
	}
	if !found {
		text := strings.to_string(b)
		sep := "" if text == "" || strings.has_suffix(text, "\n\n") else ("\n" if strings.has_suffix(text, "\n") else "\n\n")
		return strings.concatenate({text, sep, header, "\nenabled = false\n"}, allocator), true
	}
	return strings.to_string(b), changed
}

bridge_codex_config_disable_plugin :: proc(codex_home, plugin_id: string) -> (ok: bool, msg: string) {
	path := bridgesvc.pjoin(codex_home, "config.toml")
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false, fmt.tprintf("cannot read %s: %v", path, err)
	out, changed := bridge_codex_config_set_plugin_disabled(string(raw), plugin_id)
	if !changed do return true, ""
	tmp := strings.concatenate({path, ".heimdall.tmp"}, context.temp_allocator)
	if werr := os.write_entire_file(tmp, transmute([]byte)out); werr != nil do return false, fmt.tprintf("cannot write %s: %v", tmp, werr)
	if rerr := os.rename(tmp, path); rerr != nil {
		_ = os.remove(tmp)
		return false, fmt.tprintf("cannot replace %s: %v", path, rerr)
	}
	return true, ""
}

// bridge_codex_own_write_marketplace lays out <data_dir>/codex-marketplace: a
// copy of <data_dir>/extensions/codex under codex/ and a marketplace manifest
// naming marketplace. A copy, not the extensions dir itself, because a
// per-account provider profile registers that dir under the shared name.
bridge_codex_own_write_marketplace :: proc(data_dir, marketplace: string) -> (root: string, ok: bool, msg: string) {
	src := bridgesvc.pjoin(bridgesvc.pjoin(data_dir, "extensions"), "codex")
	if !os.is_dir(src) do return "", false, fmt.tprintf("no bridge extension copy at %s", src)
	root = bridgesvc.pjoin(data_dir, BRIDGE_CODEX_OWN_MARKETPLACE_DIR)
	_ = os.remove_all(root)
	if copied, copy_msg := bridge_extensions_copy_tree(src, bridgesvc.pjoin(root, "codex")); !copied do return "", false, copy_msg
	mp_dir := bridgesvc.pjoin(bridgesvc.pjoin(root, ".agents"), "plugins")
	if err := os.make_directory_all(mp_dir); err != nil && !os.is_dir(mp_dir) do return "", false, fmt.tprintf("cannot create %s: %v", mp_dir, err)
	// Not fmt: it reads '{' as an argument index.
	manifest := strings.concatenate({
		"{\n  \"name\": \"", marketplace, "\",\n",
		"  \"interface\": {\n    \"displayName\": \"Heimdall Codex (this bridge)\"\n  },\n",
		"  \"plugins\": [\n    {\n      \"name\": \"", BRIDGE_CODEX_PLUGIN_NAME, "\",\n",
		"      \"source\": {\n        \"source\": \"local\",\n        \"path\": \"./codex\"\n      },\n",
		"      \"policy\": {\n        \"installation\": \"AVAILABLE\",\n        \"authentication\": \"ON_INSTALL\"\n      },\n",
		"      \"category\": \"Productivity\"\n    }\n  ]\n}\n",
	}, context.temp_allocator)
	mp_path := bridgesvc.pjoin(mp_dir, "marketplace.json")
	if err := os.write_entire_file(mp_path, transmute([]byte)manifest); err != nil do return "", false, fmt.tprintf("cannot write %s: %v", mp_path, err)
	return root, true, ""
}

// bridge_codex_own_ensure (re)registers this bridge's own Codex plugin from its
// current <data_dir>/extensions copy and persists it disabled. Re-adding on every
// ensure picks up the copy an update just installed (the cache is versioned).
bridge_codex_own_ensure :: proc(bin_path: string, deadline: time.Time, env: []string) -> (ok: bool, msg: string) {
	data_dir := bridge_codex_own_data_dir()
	marketplace := bridge_codex_own_marketplace_name()
	if data_dir == "" || marketplace == "" do return false, "no bridge data dir"
	plugin_id := bridge_codex_own_plugin_id(marketplace)
	codex_home := bridge_codex_default_home()
	// Already installed at this version and disabled: leave it, so that agents
	// launching meanwhile (Hub reconnects ensure again) keep their override.
	version := bridge_provider_extension_read_manifest_version(bridgesvc.pjoin(bridgesvc.pjoin(data_dir, "extensions"), "codex"), "codex")
	cached := bridgesvc.pjoin(bridgesvc.pjoin(bridgesvc.pjoin(bridgesvc.pjoin(codex_home, "plugins"), "cache"), marketplace), bridgesvc.pjoin(BRIDGE_CODEX_PLUGIN_NAME, version))
	if version != "" && os.is_dir(cached) {
		if raw, err := os.read_entire_file(bridgesvc.pjoin(codex_home, "config.toml"), context.temp_allocator); err == nil {
			if _, changed := bridge_codex_config_set_plugin_disabled(string(raw), plugin_id); !changed {
				return true, fmt.tprintf("%s %s is already registered (enabled per launch)", plugin_id, version)
			}
		}
	}
	root, written, write_msg := bridge_codex_own_write_marketplace(data_dir, marketplace)
	if !written do return false, write_msg
	_, _, _ = bridge_extension_install_step({bin_path, "plugin", "remove", plugin_id}, deadline, env)
	_, _, _ = bridge_extension_install_step({bin_path, "plugin", "marketplace", "remove", marketplace}, deadline, env)
	if _, add_msg, added := bridge_extension_install_step({bin_path, "plugin", "marketplace", "add", root}, deadline, env); !added {
		return false, fmt.tprintf("codex plugin marketplace add %s: %s", root, add_msg)
	}
	if _, add_msg, added := bridge_extension_install_step({bin_path, "plugin", "add", plugin_id}, deadline, env); !added {
		return false, fmt.tprintf("codex plugin add %s: %s", plugin_id, add_msg)
	}
	if disabled, disable_msg := bridge_codex_config_disable_plugin(codex_home, plugin_id); !disabled {
		// Enabled for every Codex session would load it next to the shared one.
		_, _, _ = bridge_extension_install_step({bin_path, "plugin", "remove", plugin_id}, deadline, env)
		_, _, _ = bridge_extension_install_step({bin_path, "plugin", "marketplace", "remove", marketplace}, deadline, env)
		return false, disable_msg
	}
	return true, fmt.tprintf("registered %s from %s (enabled per launch)", plugin_id, root)
}

// bridge_codex_own_remove drops this bridge's own plugin, marketplace and copy.
// Other bridges' registrations are never touched.
bridge_codex_own_remove :: proc(bin_path: string, deadline: time.Time, env: []string) {
	marketplace := bridge_codex_own_marketplace_name()
	if marketplace == "" do return
	_, _, _ = bridge_extension_install_step({bin_path, "plugin", "remove", bridge_codex_own_plugin_id(marketplace)}, deadline, env)
	_, _, _ = bridge_extension_install_step({bin_path, "plugin", "marketplace", "remove", marketplace}, deadline, env)
	if data_dir := bridge_codex_own_data_dir(); data_dir != "" do _ = os.remove_all(bridgesvc.pjoin(data_dir, BRIDGE_CODEX_OWN_MARKETPLACE_DIR))
}

@(private = "file")
codex_own_expand_home :: proc(path: string, allocator := context.temp_allocator) -> string {
	if strings.has_prefix(path, "~/") {
		home := cfg_lib.home_dir()
		defer delete(home)
		if home != "" do return strings.concatenate({home, path[1:]}, allocator)
	}
	return strings.clone(path, allocator)
}
