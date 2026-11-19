#+build !windows
package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file") t4_adapter_bad_integrity: bool
@(private = "file") t10_adapter_probe_fails: bool
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

t4_adapter_fake_probe :: proc(provider, root, scratch: string) -> (bool, string) {
    if t10_adapter_probe_fails do return false, "node_module_missing"
    final := acp_adapter_root(); defer delete(final)
    t4_adapter_probe_ran = !os.is_dir(final) && strings.has_prefix(scratch, root) && root != final && acp_adapter_status("claude").state == "installing" && acp_adapter_files_valid(root)
    return t4_adapter_probe_ran, ""
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
    t10_adapter_probe_fails = true
    installed, reason = acp_adapter_install("claude", "sha256:t4", ACP_CLAUDE_VERSION)
    testing.expect(t, !installed && reason == "acp_adapter_probe_failed")
    testing.expect_value(t, acp_adapter_status("claude").error, "acp_adapter_probe_failed: Node could not load an adapter module")
    t10_adapter_probe_fails = false
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

@(test)
t10_acp_probe_profile_env_and_missing_binary :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    binary := profile_join(st.dir, "profile-claude")
    p1c_put(t, binary, "#!/bin/sh\nexit 0\n")
    bridge_os_make_owner_executable(binary)
    pp := Provider_Profile{provider = "claude", profile_id = "claude", enabled = true,
        config = {binary_path = "profile-claude", config_dir = profile_join(st.dir, "claude-config")},
        environment = {{name = "PATH", value = st.dir}, {name = "PROFILE_MARKER", value = "canonical"},
                       {name = "CLAUDE_AGENT_ACP_PROTOCOL", value = "wrong"}}}
    pairs, ok := acp_adapter_probe_env(&pp)
    testing.expect(t, ok)
    found_binary, found_config, found_marker, found_protocol := false, false, false, false
    for pair in pairs {
        testing.expect(t, !strings.has_prefix(pair[0], "HEIMDALL_"))
        if pair[0] == "CLAUDE_CODE_EXECUTABLE" do found_binary = pair[1] == binary
        if pair[0] == "CLAUDE_CONFIG_DIR" do found_config = pair[1] == pp.config.config_dir
        if pair[0] == "PROFILE_MARKER" do found_marker = pair[1] == "canonical"
        if pair[0] == "CLAUDE_AGENT_ACP_PROTOCOL" do found_protocol = pair[1] == "v1"
    }
    testing.expect(t, found_binary && found_config && found_marker && found_protocol)
    r := ACP_Runtime{run_dir = st.dir, instance = "inst_profile", epoch = "epoch_profile"}
    req, built := acp_runtime_build_spawn(&r, "unix:/tmp/unused", "test-token", &pp)
    testing.expect(t, built)
    for pair in req.env {
        if pair[0] == "CLAUDE_CODE_EXECUTABLE" do testing.expect_value(t, pair[1], binary)
        if pair[0] == "PROFILE_MARKER" do testing.expect_value(t, pair[1], "canonical")
    }
    pp.config.binary_path = profile_join(st.dir, "missing")
    _, ok = acp_adapter_probe_env(&pp)
    testing.expect(t, !ok)
}

@(test)
t10_acp_probe_diagnostics_are_bounded_and_allowlisted :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    p: ACP_Adapter_Probe
    secret := strings.repeat("credential=must-never-appear ", 1000, context.temp_allocator)
    acp_adapter_probe_diagnostic(&p, "Error [ERR_MODULE_NOT_FOUND]: ")
    acp_adapter_probe_diagnostic(&p, secret)
    testing.expect_value(t, p.diagnostic_len, 1024)
    code := acp_adapter_probe_reason(string(p.diagnostic[:p.diagnostic_len]), "adapter_exited")
    message := acp_adapter_probe_message(code)
    testing.expect_value(t, code, "node_module_missing")
    testing.expect(t, len(message) <= 1024 && !strings.contains(message, "credential"))
    testing.expect_value(t, acp_adapter_probe_message(secret), "")
    testing.expect_value(t, acp_adapter_probe_message("claude_missing"), "No Claude executable resolves in the canonical provider profile")
}

@(test)
t10_acp_failed_install_redelivery_is_typed_and_cached :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = context.temp_allocator
    frame := acp_adapter_install_result_json("cmd_t10", false, "acp_adapter_probe_failed")
    parsed, err := json.parse(frame); testing.expect(t, err == nil)
    obj, _ := parsed.(json.Object)
    ok, _ := obj["ok"].(bool)
    error, _ := obj["error"].(json.Object)
    cause, _ := error["cause"].(json.String)
    payload, _ := obj["payload"].(json.Object)
    status, _ := payload["status"].(json.String)
    testing.expect(t, !bool(ok) && string(cause) == "acp_adapter_probe_failed" && string(status) == "failed")
    old_claims := bridge_dispatch_claims; old_outputs := bridge_dispatch_outputs
    old_bytes := bridge_dispatch_outbox_bytes; old_worker := bridge_dispatch_workers[0]
    bridge_dispatch_claims = make([dynamic]Bridge_Dispatch_Claim, runtime.default_allocator())
    bridge_dispatch_outputs = make([dynamic]Bridge_Dispatch_Output, runtime.default_allocator())
    bridge_dispatch_outbox_bytes = 0; bridge_dispatch_workers[0] = {}
    append(&bridge_dispatch_claims, Bridge_Dispatch_Claim{command_id = "cmd_t10", state = .Completed, result_json = frame})
    defer {
        for output in bridge_dispatch_outputs do delete(output.text, runtime.default_allocator())
        delete(bridge_dispatch_outputs); delete(bridge_dispatch_claims)
        delete(bridge_dispatch_workers[0].last_result, runtime.default_allocator())
        bridge_dispatch_claims = old_claims; bridge_dispatch_outputs = old_outputs
        bridge_dispatch_outbox_bytes = old_bytes; bridge_dispatch_workers[0] = old_worker
    }
    queued_before := bridge_command_dispatch_total_locked()
    for _ in 0..<2 {
        testing.expect(t, bridge_command_dispatch(&bridge_dispatch_workers[0].sink_conn,
            `{"type":"install_acp_adapter","command_id":"cmd_t10","provider":"claude"}`, 1))
    }
    testing.expect_value(t, len(bridge_dispatch_outputs), 2)
    for output in bridge_dispatch_outputs do testing.expect_value(t, output.text, frame)
    testing.expect_value(t, bridge_command_dispatch_total_locked(), queued_before)
}
