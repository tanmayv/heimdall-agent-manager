#+build !windows
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file") t4_adapter_bad_integrity: bool
@(private = "file") t4_adapter_probe_ran: bool
@(private = "file") t4_adapter_install_argv_ok: bool

t4_adapter_fake_runner :: proc(argv: []string, timeout: time.Duration) -> (string, string, int, bool, bool) {
    if len(argv) == 2 && argv[0] == "node" && argv[1] == "--version" do return strings.clone("v22.0.0"), "", 0, true, false
    t4_adapter_install_argv_ok = len(argv) == 8 && argv[0] == "npm" && argv[1] == "install" && argv[2] == "--prefix" &&
        argv[4] == "--save-exact" && argv[5] == "--no-audit" && argv[6] == "--no-fund" && argv[7] == ACP_CLAUDE_PACKAGE+"@"+ACP_CLAUDE_VERSION && timeout <= 120*time.Second
    if !t4_adapter_install_argv_ok do return "", "", 1, false, false
    root := argv[3]
    pkg := strings.concatenate({root, "/node_modules/", ACP_CLAUDE_PACKAGE}, context.temp_allocator)
    bridge_make_directory_all(strings.concatenate({pkg, "/dist"}, context.temp_allocator))
    bridge_make_directory_all(strings.concatenate({root, "/node_modules/.bin"}, context.temp_allocator))
    _ = os.write_entire_file(strings.concatenate({pkg, "/package.json"}, context.temp_allocator), string(`{"name":"@agentclientprotocol/claude-agent-acp","version":"0.108.0","bin":{"claude-agent-acp":"dist/cli.js"}}`))
    script := strings.concatenate({pkg, "/dist/cli.js"}, context.temp_allocator)
    _ = os.write_entire_file(script, string("#!/bin/sh\nexit 0\n")); bridge_os_make_owner_executable(script)
    os.symlink("../@agentclientprotocol/claude-agent-acp/dist/cli.js", acp_adapter_bin(root))
    integrity := ACP_CLAUDE_INTEGRITY if !t4_adapter_bad_integrity else "sha512-wrong"
    lock := strings.concatenate({`{"packages":{"node_modules/@agentclientprotocol/claude-agent-acp":{"version":"0.108.0","integrity":"`, integrity, `"}}}`}, context.temp_allocator)
    _ = os.write_entire_file(strings.concatenate({root, "/package-lock.json"}, context.temp_allocator), lock)
    return "", "", 0, true, false
}

t4_adapter_fake_probe :: proc(root, scratch: string) -> bool {
    final := acp_adapter_root(); defer delete(final)
    t4_adapter_probe_ran = !os.is_dir(final) && strings.has_prefix(scratch, root) && root != final && acp_adapter_status("claude").state == "installing" && acp_adapter_files_valid(root)
    return t4_adapter_probe_ran
}

@(test)
t4_acp_adapter_pinned_integrity_probe_and_atomic_promotion :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = context.temp_allocator
    previous_config := bridge_config
    previous_snapshot := bridge_provider_catalog_snapshot
    previous_loaded := bridge_provider_catalog_loaded
    previous_runner := acp_adapter_runner; previous_probe := acp_adapter_probe_hook
    defer {
        bridge_config = previous_config; bridge_provider_catalog_snapshot = previous_snapshot; bridge_provider_catalog_loaded = previous_loaded
        acp_adapter_runner = previous_runner; acp_adapter_probe_hook = previous_probe
    }
    root := fmt.tprintf("%s/.cache/heimdall-tests/t4-install-%d", os.get_env("HOME", context.temp_allocator), time.tick_now()._nsec)
    bridge_config.data_dir = root; bridge_config.daemon_id = "brg_test_t4_adapter"
    bridge_make_directory_all(root); defer os.remove_all(root)
    env := make(map[string]string); env["CLAUDE_AGENT_ACP_PROTOCOL"] = "v1"
    snapshot := Bridge_Provider_Catalog_Snapshot{etag = "sha256:t4", providers = {Bridge_Catalog_Provider{provider = "claude", state = "active", acp_recipe = {command = "claude-agent-acp", protocol_version = 1, adapter_package = ACP_CLAUDE_PACKAGE, adapter_version = ACP_CLAUDE_VERSION, env = env}}}}
    bridge_provider_catalog_snapshot = &snapshot; bridge_provider_catalog_loaded = true
    acp_adapter_runner = t4_adapter_fake_runner; acp_adapter_probe_hook = t4_adapter_fake_probe
    final := acp_adapter_root()
    bridge_make_directory_all(filepath.dir(final))
    lock_path := strings.concatenate({final, ".lock"})
    // A previous bridge's exclusive-create file and unfinished stage are not
    // evidence that an installer is still alive.
    _ = os.write_entire_file(lock_path, string("leftover from crashed bridge"))
    orphan := strings.concatenate({final, ".stage-orphan"}); bridge_make_directory_all(orphan)
    testing.expect_value(t, acp_adapter_status("claude").state, "missing")
    held, acquired := acp_adapter_lock_acquire(lock_path)
    testing.expect_value(t, acquired, ACP_Adapter_Lock_State.Acquired)
    testing.expect_value(t, acp_adapter_status("claude").state, "installing")
    blocked, blocked_reason := acp_adapter_install("claude", "sha256:t4", ACP_CLAUDE_VERSION)
    testing.expect(t, !blocked && blocked_reason == "acp_adapter_install_in_progress")
    acp_adapter_lock_release(held)
    t4_adapter_bad_integrity = true; t4_adapter_probe_ran = false; t4_adapter_install_argv_ok = false
    installed, reason := acp_adapter_install("claude", "sha256:t4", ACP_CLAUDE_VERSION)
    testing.expect(t, !installed && reason == "acp_adapter_integrity_failed" && !t4_adapter_probe_ran)
    testing.expect(t, !os.is_dir(final) && !os.is_dir(orphan))
    testing.expect_value(t, acp_adapter_status("claude").state, "error")
    t4_adapter_bad_integrity = false
    installed, reason = acp_adapter_install("claude", "sha256:t4", ACP_CLAUDE_VERSION)
    testing.expect(t, installed, reason)
    testing.expect(t, t4_adapter_install_argv_ok && t4_adapter_probe_ran)
    status := acp_adapter_status("claude")
    testing.expect(t, status.installed && status.state == "ready" && status.version == ACP_CLAUDE_VERSION)
    testing.expect(t, os.exists(strings.concatenate({final, "/package-lock.json"})))
    testing.expect(t, os.exists(lock_path)) // stable inode; only the kernel lock signals installing
    // Replacing package metadata after install invalidates readiness.
    _ = os.write_entire_file(strings.concatenate({final, "/node_modules/", ACP_CLAUDE_PACKAGE, "/package.json"}), string(`{"name":"wrong","version":"0.108.0"}`))
    testing.expect(t, !acp_adapter_files_valid(final))
    // Request fields cannot override the catalog pin or execute shell fragments.
    installed, reason = acp_adapter_install("claude", "sha256:t4", "latest")
    testing.expect(t, !installed && reason == "unsupported_acp_adapter")
}
