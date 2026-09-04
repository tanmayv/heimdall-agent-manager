package main

import "core:os"
import "core:strings"
import "core:testing"

// Regression for the "no agent can launch" production bug: the bridge default
// data_dir is "~/.local/share/heimdall", but bridge_config_from_args never
// expanded the leading ~. A launchd-started bridge (cwd=/) then resolved the
// bootstrap blob cache to a LITERAL "~/.local/share/heimdall" path, so every
// cache lookup missed and every cache_put file-write failed — surfacing as
// "blob hash verify/cache failed" and blocking all agent launches. We now expand
// ~ in bridge_config_from_args. These tests assert data_dir no longer contains a
// leading ~ and resolves under $HOME, for both the default and an explicit
// --data-dir override.
@(test)
bridge_config_expands_default_data_dir_tilde :: proc(t: ^testing.T) {
	home := os.get_env_alloc("HOME", context.allocator)
	if strings.trim_space(home) == "" do return // no HOME in this env; nothing to assert

	cfg := bridge_config_from_args([]string{"ham-bridge"})
	testing.expect(t, !strings.has_prefix(cfg.data_dir, "~"), "default data_dir must not keep a literal ~")
	testing.expect(t, strings.has_prefix(cfg.data_dir, home), "default data_dir should resolve under $HOME")
	testing.expect(t, strings.has_suffix(cfg.data_dir, "/.local/share/heimdall"), "default data_dir keeps the heimdall suffix")
}

@(test)
bridge_config_expands_data_dir_override_tilde :: proc(t: ^testing.T) {
	home := os.get_env_alloc("HOME", context.allocator)
	if strings.trim_space(home) == "" do return

	cfg := bridge_config_from_args([]string{"ham-bridge", "--data-dir", "~/custom-heimdall-dir"})
	testing.expect(t, !strings.has_prefix(cfg.data_dir, "~"), "override data_dir must not keep a literal ~")
	testing.expect_value(t, cfg.data_dir, strings.concatenate({home, "/custom-heimdall-dir"}))
}

@(test)
bridge_config_leaves_absolute_data_dir_untouched :: proc(t: ^testing.T) {
	cfg := bridge_config_from_args([]string{"ham-bridge", "--data-dir", "/var/lib/heimdall"})
	testing.expect_value(t, cfg.data_dir, "/var/lib/heimdall")
}
