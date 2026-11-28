#+build !windows
package main

import contracts "odin_test:contracts"

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Copilot is a user-installed system CLI: supported wherever it ships, with
// no platform package pins (G2).
@(test)
c2_acp_copilot_platforms_follow_system_os :: proc(t: ^testing.T) {
    d, known := contracts.acp_provider_descriptor("copilot")
    testing.expect(t, known && d.launch == .System)
    when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .Windows { testing.expect(t, acp_adapter_platform_supported(d)) }
    d.system_os = {"plan9"}
    testing.expect(t, !acp_adapter_platform_supported(d))
    testing.expect(t, acp_adapter_platform_supported(contracts.ACP_CLAUDE_DESCRIPTOR))
}

// REQ-ACP-L1: each staged-layout predicate reports its own fixed identifier.
@(test)
l1_acp_claude_files_check_names_failed_predicate :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    root := profile_join(st.dir, "claude-stage")
    pkg := profile_join(root, "node_modules/" + ACP_CLAUDE_PACKAGE)
    manifest_path := profile_join(pkg, "package.json")
    lock_path := profile_join(root, "package-lock.json")
    script := profile_join(pkg, "dist/cli.js")
    bin := acp_adapter_bin(root, "claude")
    MANIFEST :: `{"name":"@agentclientprotocol/claude-agent-acp","version":"0.108.0","bin":{"claude-agent-acp":"dist/cli.js"}}`
    lock := strings.concatenate({`{"packages":{"node_modules/@agentclientprotocol/claude-agent-acp":{"version":"0.108.0","integrity":"`, ACP_CLAUDE_INTEGRITY, `"}}}`})
    testing.expect_value(t, acp_adapter_files_check(root, "claude"), ACP_Adapter_Files_Check.Manifest_Read)
    p1c_put(t, manifest_path, MANIFEST)
    testing.expect_value(t, acp_adapter_files_check(root, "claude"), ACP_Adapter_Files_Check.Lockfile_Read)
    p1c_put(t, lock_path, lock)
    p1c_put(t, script, "#!/bin/sh\nexit 0\n", true)
    bridge_make_directory_all(filepath.dir(bin))
    testing.expect(t, os.symlink("../@agentclientprotocol/claude-agent-acp/dist/cli.js", bin) == nil)
    testing.expect_value(t, acp_adapter_files_check(root, "claude"), ACP_Adapter_Files_Check.None)
    testing.expect(t, acp_adapter_files_valid(root, "claude"))
    Case :: struct { path, body: string, want: ACP_Adapter_Files_Check }
    cases := []Case{
        {manifest_path, `{"name":`, .Manifest_Parse},
        {manifest_path, `[]`, .Manifest_Parse},
        {lock_path, `{"packages":`, .Lockfile_Parse},
        {lock_path, `[]`, .Lockfile_Parse},
        {manifest_path, `{"name":"wrong","version":"0.108.0","bin":{"claude-agent-acp":"dist/cli.js"}}`, .Manifest_Identity},
        {manifest_path, `{"name":"@agentclientprotocol/claude-agent-acp","version":"0.109.0","bin":{"claude-agent-acp":"dist/cli.js"}}`, .Manifest_Version},
        {lock_path, `{"packages":{"node_modules/@agentclientprotocol/claude-agent-acp":{"version":"0.109.0"}}}`, .Lock_Entry_Version},
        {lock_path, `{"packages":{"node_modules/@agentclientprotocol/claude-agent-acp":{"version":"0.108.0","integrity":"sha512-wrong"}}}`, .Lock_Entry_Integrity},
        {lock_path, `{"packages":{}}`, .Lock_Entry_Version},
        {manifest_path, `{"name":"@agentclientprotocol/claude-agent-acp","version":"0.108.0"}`, .Bin_Entry},
        {manifest_path, `{"name":"@agentclientprotocol/claude-agent-acp","version":"0.108.0","bin":{"claude-agent-acp":"../cli.js"}}`, .Bin_Path},
        {manifest_path, `{"name":"@agentclientprotocol/claude-agent-acp","version":"0.108.0","bin":{"claude-agent-acp":"/usr/bin/true"}}`, .Bin_Path},
        {manifest_path, `{"name":"@agentclientprotocol/claude-agent-acp","version":"0.108.0","bin":{"claude-agent-acp":"dist/other.js"}}`, .Bin_Target},
    }
    for c in cases {
        original, _ := os.read_entire_file(c.path, context.temp_allocator)
        p1c_put(t, c.path, c.body)
        got := acp_adapter_files_check(root, "claude")
        testing.expectf(t, got == c.want, "%s: got %v want %v", c.body, got, c.want)
        testing.expect(t, !acp_adapter_files_valid(root, "claude"))
        id := ACP_ADAPTER_FILES_CHECK_IDS[got]
        testing.expect(t, id != "" && !strings.contains(id, "/") && !strings.contains(id, "sha512"), "identifiers never carry paths or file contents")
        p1c_put(t, c.path, string(original))
    }
    testing.expect_value(t, acp_adapter_files_check(root, "claude"), ACP_Adapter_Files_Check.None)
    os.remove(bin)
    testing.expect_value(t, acp_adapter_files_check(root, "claude"), ACP_Adapter_Files_Check.Bin_Target)
    testing.expect(t, os.symlink("../@agentclientprotocol/claude-agent-acp/dist/cli.js", bin) == nil)
    testing.expect(t, os.chmod(script, {.Read_User, .Write_User}) == nil)
    testing.expect_value(t, acp_adapter_files_check(root, "claude"), ACP_Adapter_Files_Check.Bin_Executable)
    testing.expect(t, os.chmod(script, {.Read_User, .Write_User, .Execute_User}) == nil)
    testing.expect_value(t, acp_adapter_files_check(root, "claude"), ACP_Adapter_Files_Check.None)
    testing.expect_value(t, acp_adapter_files_check(root, "unknown-provider"), ACP_Adapter_Files_Check.Unknown_Provider)
    for check in ACP_Adapter_Files_Check do testing.expect(t, (check == .None) == (ACP_ADAPTER_FILES_CHECK_IDS[check] == ""), "every failed check has an identifier")
}

@(test)
c2_acp_copilot_profile_env_and_system_argv :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    binary := profile_join(st.dir, "profile-copilot")
    p1c_put(t, binary, "#!/bin/sh\n[ \"$COPILOT_AUTO_UPDATE\" = false ] && [ \"$COPILOT_GITHUB_TOKEN\" = synthetic-token ] && [ -n \"$COPILOT_HOME\" ] && [ -z \"$HEIMDALL_AGENT_TOKEN\" ] || exit 42\nprintf 'GitHub Copilot CLI 1.0.114.\\n'\n", true)
    pp := Provider_Profile{provider = "copilot", profile_id = "work", enabled = true, config = {binary_path = binary},
        environment = {{name = "COPILOT_HOME", value = profile_join(st.dir, "work-home")}, {name = "COPILOT_GITHUB_TOKEN", value = "synthetic-token", sensitive = true},
            {name = "COPILOT_AUTO_UPDATE", value = "true"}, {name = "HEIMDALL_AGENT_TOKEN", value = "must-not-leak"}}}
    version, reason, diagnostic := acp_provider_cli_version(&pp)
    testing.expect(t, version == "1.0.114" && reason == "" && diagnostic == "")
    r := acp_runtime_new("inst_c2_profile", "epoch", st.dir, "copilot", "work", "etag", "", "ask", {})
    defer acp_runtime_destroy(r)
    spawn, built := acp_runtime_build_spawn(r, "endpoint", "synthetic-agent-token", &pp)
    testing.expect(t, built && len(spawn.argv) == 3 && spawn.argv[0] == binary && spawn.argv[1] == "--acp" && spawn.argv[2] == "--stdio")
    for pair in spawn.env {
        if pair[0] == "COPILOT_AUTO_UPDATE" do testing.expect_value(t, pair[1], "false")
        if pair[0] == "COPILOT_HOME" do testing.expect_value(t, pair[1], profile_join(st.dir, "work-home"))
        if pair[0] == "HEIMDALL_AGENT_TOKEN" do testing.expect_value(t, pair[1], "synthetic-agent-token")
    }
}

@(private = "file") t4_adapter_bad_integrity: bool
@(private = "file") t10_adapter_probe_fails: bool
@(private = "file") t4_adapter_probe_ran: bool
@(private = "file") t4_adapter_install_argv_ok: bool
@(private = "file") t4_profile_probe_calls: int
@(private = "file") t4_adapter_lock_version: string
@(private = "file") t4_adapter_install_prefix: string

// Fake runners match bare tool names: resolve each tool to its own name.
t4_tool_resolve :: proc(name: string) -> string { return name }

t4_adapter_fake_runner :: proc(argv: []string, timeout: time.Duration) -> (string, string, int, bool, bool) {
    if len(argv) == 2 && argv[0] == "node" && argv[1] == "--version" do return strings.clone("v22.0.0"), "", 0, true, false
    if len(argv) == 2 && argv[0] == "npm" && argv[1] == "--version" do return strings.clone("10.8.2"), "", 0, true, false
    t4_adapter_install_argv_ok = len(argv) == 9 && argv[0] == "npm" && argv[1] == "install" && argv[2] == "--prefix" &&
        argv[4] == "--save-exact" && argv[5] == "--ignore-scripts" && argv[6] == "--no-audit" && argv[7] == "--no-fund" && argv[8] == ACP_CLAUDE_PACKAGE+"@"+ACP_CLAUDE_VERSION && timeout <= 120*time.Second
    if !t4_adapter_install_argv_ok do return "", "", 1, false, false
    root := argv[3]
    t4_adapter_install_prefix = strings.clone(root, context.temp_allocator)
    pkg := strings.concatenate({root, "/node_modules/", ACP_CLAUDE_PACKAGE}, context.temp_allocator)
    bridge_make_directory_all(strings.concatenate({pkg, "/dist"}, context.temp_allocator))
    bridge_make_directory_all(strings.concatenate({root, "/node_modules/.bin"}, context.temp_allocator))
    _ = os.write_entire_file(strings.concatenate({pkg, "/package.json"}, context.temp_allocator), string(`{"name":"@agentclientprotocol/claude-agent-acp","version":"0.108.0","bin":{"claude-agent-acp":"dist/cli.js"}}`))
    script := strings.concatenate({pkg, "/dist/cli.js"}, context.temp_allocator)
    _ = os.write_entire_file(script, string("#!/bin/sh\nexit 0\n")); bridge_os_make_owner_executable(script)
    os.symlink("../@agentclientprotocol/claude-agent-acp/dist/cli.js", acp_adapter_bin(root, "claude"))
    integrity := ACP_CLAUDE_INTEGRITY if !t4_adapter_bad_integrity else "sha512-wrong"
    lock_version := t4_adapter_lock_version if t4_adapter_lock_version != "" else ACP_CLAUDE_VERSION
    // Like npm 11, key the entry relative to the prefix as given while the
    // package lives at its real path: a symlinked prefix yields "../" keys.
    entry_key := strings.concatenate({"node_modules/", ACP_CLAUDE_PACKAGE}, context.temp_allocator)
    if real_root := bridge_fs_canonicalize_existing(root); real_root != root {
        entry_key, _ = filepath.rel(root, strings.concatenate({real_root, "/", entry_key}, context.temp_allocator), context.temp_allocator)
    }
    lock := strings.concatenate({`{"packages":{"`, entry_key, `":{"version":"`, lock_version, `","integrity":"`, integrity, `"}}}`}, context.temp_allocator)
    _ = os.write_entire_file(strings.concatenate({root, "/package-lock.json"}, context.temp_allocator), lock)
    // Synthetic npm output must never reach the status record.
    if t4_adapter_bad_integrity do return strings.clone("npm-stdout credential=secret"), strings.clone("npm-stderr HOME=/secret-home"), 0, true, false
    return "", "", 0, true, false
}

t4_adapter_fake_binding :: proc(provider, profile: string) -> (ACP_Runtime_Binding, bool) {
    d, known := contracts.acp_provider_descriptor(provider)
    return acp_provider_binding(d, profile, "2.1.70", d.bootstrap_filename), known
}

t4_adapter_fake_profile_probe :: proc(pp: ^Provider_Profile, root, scratch: string) -> (bool, string) {
    t4_profile_probe_calls += 1
    return pp.provider == "claude" && pp.profile_id == "work" && root != scratch && acp_adapter_files_valid(root, pp.provider), ""
}

t11_adapter_legacy_profile_probe :: proc(pp: ^Provider_Profile, root, scratch: string) -> (bool, string) {
    t4_profile_probe_calls += 1
    return pp.provider == "claude" && pp.profile_id == "claude" && root != scratch && acp_adapter_files_valid(root, pp.provider), ""
}

t4_adapter_fake_claude_probe :: proc(_: string) -> (string, string) { return "", "" }

t4_adapter_fake_probe :: proc(provider, root, scratch: string) -> (bool, string) {
    if t10_adapter_probe_fails do return false, "node_module_missing"
    final := acp_adapter_root("claude"); defer delete(final)
    t4_adapter_probe_ran = !os.is_dir(final) && strings.has_prefix(scratch, root) && root != final && acp_adapter_status("claude").state == "installing" && acp_adapter_files_valid(root, "claude")
    return t4_adapter_probe_ran, ""
}

// REQ-ACP-LOCK-2: a data directory reached through a symlink (Riverwood:
// /home -> var/home) must still install. npm keys lock entries relative to the
// --prefix it is given, so the installer must pass the resolved stage path,
// while genuine lock version and integrity mismatches stay rejected.
@(test)
lock2_acp_adapter_symlinked_data_dir_installs_with_canonical_prefix :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = context.temp_allocator
    previous_config := bridge_config
    previous_snapshot := bridge_provider_catalog_snapshot
    previous_loaded := bridge_provider_catalog_loaded
    previous_runner := acp_adapter_runner; previous_probe := acp_adapter_probe_hook
    previous_claude_probe := acp_adapter_cli_probe_hook
    previous_binding := acp_adapter_binding_hook
    defer {
        bridge_config = previous_config; bridge_provider_catalog_snapshot = previous_snapshot; bridge_provider_catalog_loaded = previous_loaded
        acp_adapter_runner = previous_runner; acp_adapter_probe_hook = previous_probe; acp_adapter_cli_probe_hook = previous_claude_probe; acp_adapter_binding_hook = previous_binding
        t4_adapter_lock_version = ""; t4_adapter_bad_integrity = false; t4_adapter_install_prefix = ""
    }
    base := fmt.tprintf("%s/.cache/heimdall-tests/lock2-symlink-%d", os.get_env("HOME", context.temp_allocator), time.tick_now()._nsec)
    real_dir := strings.concatenate({base, "/real"}); link := strings.concatenate({base, "/link"})
    testing.expect(t, bridge_make_directory_all(real_dir) == nil); defer os.remove_all(base)
    testing.expect(t, os.symlink(real_dir, link) == nil)
    real_canonical := bridge_fs_canonicalize_existing(real_dir)
    bridge_config.data_dir = link; bridge_config.daemon_id = "brg_test_lock2_symlink"
    env := make(map[string]string); env["CLAUDE_AGENT_ACP_PROTOCOL"] = "v1"
    snapshot := Bridge_Provider_Catalog_Snapshot{etag = "sha256:lock2", providers = {Bridge_Catalog_Provider{provider = "claude", state = "active", acp_recipe = {command = "claude-agent-acp", protocol_version = 1, adapter_package = ACP_CLAUDE_PACKAGE, adapter_version = ACP_CLAUDE_VERSION, env = env}}}}
    bridge_provider_catalog_snapshot = &snapshot; bridge_provider_catalog_loaded = true
    acp_adapter_binding_hook = t4_adapter_fake_binding
    acp_adapter_runner = t4_adapter_fake_runner; acp_host_tool_resolve_hook = t4_tool_resolve; defer acp_host_tool_resolve_hook = acp_host_tool_resolve; acp_adapter_probe_hook = t4_adapter_fake_probe; acp_adapter_cli_probe_hook = t4_adapter_fake_claude_probe
    final := acp_adapter_root("claude")
    testing.expect(t, strings.has_prefix(final, link), "root keeps the configured (symlinked) data dir")
    read_diagnostic :: proc(final: string) -> string {
        raw, err := os.read_entire_file(strings.concatenate({final, ".status.json"}, context.temp_allocator), context.temp_allocator)
        record: struct{diagnostic: string}
        if err != nil || json.unmarshal(raw, &record, allocator = context.temp_allocator) != nil do return "<unreadable>"
        return record.diagnostic
    }
    // A genuine lock entry version mismatch is still rejected.
    t4_adapter_lock_version = "0.107.0"
    installed, reason := acp_adapter_install("claude", "sha256:lock2", ACP_CLAUDE_VERSION)
    testing.expect(t, !installed && reason == "acp_adapter_integrity_failed", reason)
    testing.expect_value(t, read_diagnostic(final), "lock_entry_version")
    testing.expect(t, !os.is_dir(final))
    // A genuine integrity mismatch is still rejected.
    t4_adapter_lock_version = ""; t4_adapter_bad_integrity = true
    installed, reason = acp_adapter_install("claude", "sha256:lock2", ACP_CLAUDE_VERSION)
    testing.expect(t, !installed && reason == "acp_adapter_integrity_failed", reason)
    testing.expect_value(t, read_diagnostic(final), "lock_entry_integrity")
    // The pinned package installs: npm received the resolved stage path.
    t4_adapter_bad_integrity = false; t4_adapter_install_prefix = ""
    installed, reason = acp_adapter_install("claude", "sha256:lock2", ACP_CLAUDE_VERSION)
    testing.expect(t, installed, reason)
    testing.expect(t, strings.has_prefix(t4_adapter_install_prefix, real_canonical), "npm --prefix is the canonical stage")
    testing.expect_value(t, acp_adapter_files_check(final, "claude"), ACP_Adapter_Files_Check.None)
    status := acp_adapter_status("claude")
    testing.expect(t, status.installed && status.state == "ready" && status.version == ACP_CLAUDE_VERSION)
    // The executable check still applies to the promoted tree.
    bin_target := strings.concatenate({final, "/node_modules/", ACP_CLAUDE_PACKAGE, "/dist/cli.js"})
    testing.expect(t, os.chmod(bin_target, {.Read_User, .Write_User}) == nil)
    testing.expect_value(t, acp_adapter_files_check(final, "claude"), ACP_Adapter_Files_Check.Bin_Executable)
}

@(test)
t4_acp_adapter_pinned_integrity_probe_and_atomic_promotion :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = context.temp_allocator
    previous_config := bridge_config
    previous_snapshot := bridge_provider_catalog_snapshot
    previous_loaded := bridge_provider_catalog_loaded
    previous_runner := acp_adapter_runner; previous_probe := acp_adapter_probe_hook
    previous_claude_probe := acp_adapter_cli_probe_hook
    previous_binding := acp_adapter_binding_hook
    previous_profile_probe := acp_adapter_profile_probe_hook
    defer {
        bridge_config = previous_config; bridge_provider_catalog_snapshot = previous_snapshot; bridge_provider_catalog_loaded = previous_loaded
        acp_adapter_runner = previous_runner; acp_adapter_probe_hook = previous_probe; acp_adapter_cli_probe_hook = previous_claude_probe; acp_adapter_binding_hook = previous_binding
        acp_adapter_profile_probe_hook = previous_profile_probe
    }
    root := fmt.tprintf("%s/.cache/heimdall-tests/t4-install-%d", os.get_env("HOME", context.temp_allocator), time.tick_now()._nsec)
    bridge_config.data_dir = root; bridge_config.daemon_id = "brg_test_t4_adapter"
    bridge_make_directory_all(root); defer os.remove_all(root)
    env := make(map[string]string); env["CLAUDE_AGENT_ACP_PROTOCOL"] = "v1"
    snapshot := Bridge_Provider_Catalog_Snapshot{etag = "sha256:t4", providers = {Bridge_Catalog_Provider{provider = "claude", state = "active", acp_recipe = {command = "claude-agent-acp", protocol_version = 1, adapter_package = ACP_CLAUDE_PACKAGE, adapter_version = ACP_CLAUDE_VERSION, env = env}}}}
    bridge_provider_catalog_snapshot = &snapshot; bridge_provider_catalog_loaded = true
    acp_adapter_binding_hook = t4_adapter_fake_binding
    acp_adapter_runner = t4_adapter_fake_runner; acp_host_tool_resolve_hook = t4_tool_resolve; defer acp_host_tool_resolve_hook = acp_host_tool_resolve; acp_adapter_probe_hook = t4_adapter_fake_probe; acp_adapter_cli_probe_hook = t4_adapter_fake_claude_probe
    final := acp_adapter_root("claude")
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
    // REQ-ACP-L1: the failed predicate is persisted as a fixed identifier; the
    // public code and the reported status error stay unchanged.
    testing.expect_value(t, acp_adapter_status("claude").error, "acp_adapter_integrity_failed")
    record_raw, record_err := os.read_entire_file(strings.concatenate({final, ".status.json"}), context.temp_allocator)
    record: struct{state, error, diagnostic: string}
    testing.expect(t, record_err == nil && json.unmarshal(record_raw, &record) == nil)
    testing.expect(t, record.state == "error" && record.error == "acp_adapter_integrity_failed" && record.diagnostic == "lock_entry_integrity")
    testing.expect(t, !strings.contains(string(record_raw), "secret") && !strings.contains(string(record_raw), "npm-std") && !strings.contains(string(record_raw), "sha512"))
    testing.expect(t, !strings.contains(acp_adapter_status_json("claude"), "lock_entry_integrity"), "diagnostic stays local")
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
    // An installed canonical profile does not certify a second account/config.
    work := Provider_Profile{provider = "claude", profile_id = "work"}
    work_binding, _ := t4_adapter_fake_binding("claude", "work")
    testing.expect(t, !acp_adapter_marker_matches(final, work_binding))
    testing.expect_value(t, acp_adapter_status("claude", "work").state, "error")
    acp_adapter_profile_probe_hook = t4_adapter_fake_profile_probe; t4_profile_probe_calls = 0
    held, acquired = acp_adapter_lock_acquire(lock_path)
    testing.expect_value(t, acquired, ACP_Adapter_Lock_State.Acquired)
    testing.expect(t, !acp_adapter_ensure_profile(&work, work_binding) && t4_profile_probe_calls == 0)
    acp_adapter_lock_release(held)
    testing.expect(t, acp_adapter_ensure_profile(&work, work_binding) && t4_profile_probe_calls == 1)
    testing.expect_value(t, acp_adapter_status("claude", "work").state, "ready")
    testing.expect_value(t, acp_adapter_status("claude").state, "ready")
    testing.expect(t, acp_adapter_ensure_profile(&work, work_binding) && t4_profile_probe_calls == 1, "matching receipt avoids another probe")
    changed := work_binding; changed.profile_revision = 1
    testing.expect(t, !acp_adapter_ensure_profile(&work, changed), "profile changed during probe cannot be certified")
    testing.expect(t, acp_adapter_marker_matches(final, work_binding))
    // Replacing package metadata after install invalidates readiness.
    _ = os.write_entire_file(strings.concatenate({final, "/node_modules/", ACP_CLAUDE_PACKAGE, "/package.json"}), string(`{"name":"wrong","version":"0.108.0"}`))
    testing.expect(t, !acp_adapter_files_valid(final, "claude"))
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
    message := acp_adapter_probe_message(code, "claude")
    testing.expect_value(t, code, "node_module_missing")
    testing.expect(t, len(message) <= 1024 && !strings.contains(message, "credential"))
    testing.expect_value(t, acp_adapter_probe_message(secret, "claude"), "")
    testing.expect_value(t, acp_adapter_probe_message("claude_missing", "claude"), "No Claude executable resolves in the canonical provider profile")
    // Messages derive from the named provider's descriptor; there is no default provider.
    testing.expect_value(t, acp_adapter_probe_message("codex_missing", "codex"), "No Codex executable resolves in the canonical provider profile")
    testing.expect_value(t, acp_adapter_probe_message("claude_missing", "codex"), "")
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

@(test)
t11_acp_claude_version_profile_env_failures_and_deadline :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    binary := profile_join(st.dir, "profile-claude")
    pp := Provider_Profile{provider = "claude", profile_id = "claude", enabled = true,
        config = {binary_path = "profile-claude", config_dir = profile_join(st.dir, "claude-config")},
        environment = {{name = "PATH", value = st.dir}, {name = "PROFILE_MARKER", value = "canonical"},
                       {name = "HEIMDALL_AGENT_TOKEN", value = "must-not-reach-child"}}}
    _, reason, diagnostic := acp_provider_cli_version(&pp)
    testing.expect_value(t, reason, "acp_claude_not_found")
    testing.expect_value(t, diagnostic, "claude_missing")
    p1c_put(t, binary, "#!/bin/sh\n[ \"$1\" = --version ] && [ \"$PROFILE_MARKER\" = canonical ] && [ \"$CLAUDE_CONFIG_DIR\" != '' ] && [ \"$CLAUDE_CODE_EXECUTABLE\" = \"$0\" ] && [ -z \"$HEIMDALL_AGENT_TOKEN\" ] && [ -z \"$HEIMDALL_BRIDGE_ENDPOINT\" ] || exit 42\nprintf '2.1.70 (Claude Code)\\n'\n", true)
    version: string
    version, reason, diagnostic = acp_provider_cli_version(&pp)
    testing.expect_value(t, version, "2.1.70")
    testing.expect(t, reason == "" && diagnostic == "")
    p1c_put(t, binary, "#!/bin/sh\nprintf 'Could not start dynamically linked executable credential=secret\\033[31m' >&2\nexit 127\n", true)
    _, reason, diagnostic = acp_provider_cli_version(&pp)
    testing.expect_value(t, reason, "acp_claude_not_runnable")
    testing.expect_value(t, diagnostic, "unsupported_dynamic_executable")
    message := acp_adapter_probe_message(diagnostic, "claude")
    testing.expect(t, strings.contains(message, "Could not start dynamically linked executable") && len(message) <= 1024)
    testing.expect(t, !strings.contains(message, "credential") && !strings.contains(message, "\x1b"))
    p1c_put(t, binary, "#!/no/such/interpreter\n", true)
    _, reason, diagnostic = acp_provider_cli_version(&pp)
    testing.expect_value(t, reason, "acp_claude_not_runnable")
    testing.expect_value(t, diagnostic, "claude_version_spawn_failed")
    p1c_put(t, binary, "#!/bin/sh\nwhile :; do :; done\n", true)
    started := time.now()
    _, reason, diagnostic = acp_provider_cli_version(&pp, 40*time.Millisecond)
    testing.expect_value(t, reason, "acp_claude_not_runnable")
    testing.expect_value(t, diagnostic, "claude_version_timeout")
    testing.expect(t, time.since(started) < 2*time.Second, "deadline must kill and reap promptly")
}

@(test)
t11_acp_install_claude_prerequisite_and_status :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    old_runner, old_probe := acp_adapter_runner, acp_adapter_probe_hook
    old_profile_probe := acp_adapter_profile_probe_hook
    defer { acp_adapter_runner = old_runner; acp_adapter_probe_hook = old_probe; acp_adapter_profile_probe_hook = old_profile_probe }
    acp_adapter_runner = t4_adapter_fake_runner; acp_host_tool_resolve_hook = t4_tool_resolve; defer acp_host_tool_resolve_hook = acp_host_tool_resolve; acp_adapter_probe_hook = t4_adapter_fake_probe
    t4_adapter_bad_integrity = false; t10_adapter_probe_fails = false
    t4_adapter_install_argv_ok = false; t4_adapter_probe_ran = false
    snapshot := bridge_provider_catalog_snapshot
    snapshot.etag = "sha256:t11"
    snapshot.providers[0].acp_recipe = {command = "claude-agent-acp", protocol_version = 1,
        adapter_package = ACP_CLAUDE_PACKAGE, adapter_version = ACP_CLAUDE_VERSION,
        env = make(map[string]string)}
    snapshot.providers[0].acp_recipe.env["CLAUDE_AGENT_ACP_PROTOCOL"] = "v1"
    defer delete(snapshot.providers[0].acp_recipe.env)
    binary := profile_join(st.dir, "claude")
    pp := Provider_Profile{profile_id = "claude", provider = "claude", enabled = true,
        config = {binary_path = binary}, environment = {{name = "PROFILE_MARKER", value = "canonical"}}}
    // Persist exactly the canonical profile read by install, including a missing binary.
    raw, _ := json.marshal(Provider_Profile_Store_Wire{version = PROFILE_STORE_VERSION, profiles = {pp}})
    p1c_put(t, g_profile_test_store_path, string(raw))
    installed, reason := acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, !installed && reason == "acp_claude_not_found")
    testing.expect(t, !t4_adapter_install_argv_ok && !t4_adapter_probe_ran)
    testing.expect_value(t, acp_adapter_status("claude").error, "acp_claude_not_found: No Claude executable resolves in the canonical provider profile")
    p1c_put(t, binary, "#!/bin/sh\nprintf 'Could not start dynamically linked executable credential=secret' >&2\nexit 127\n", true)
    installed, reason = acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, !installed && reason == "acp_claude_not_runnable")
    testing.expect(t, !t4_adapter_install_argv_ok && !t4_adapter_probe_ran)
    status_json := acp_adapter_status_json("claude")
    testing.expect(t, strings.contains(status_json, "acp_claude_not_runnable") && strings.contains(status_json, "dynamically linked executable"))
    testing.expect(t, !strings.contains(status_json, "credential") && !strings.contains(status_json, "secret"))
    root := acp_adapter_root("claude")
    record, _ := os.read_entire_file(strings.concatenate({root, ".status.json"}), context.temp_allocator)
    testing.expect(t, !strings.contains(string(record), "credential"))
    p1c_put(t, binary, "#!/bin/sh\n[ \"$PROFILE_MARKER\" = canonical ] || exit 42\nprintf '2.1.70 (Claude Code)\\n'\n", true)
    started := time.now()
    installed, reason = acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, installed && reason == "" && t4_adapter_probe_ran)
    testing.expect(t, time.since(started) < 5*time.Second)
    testing.expect_value(t, acp_adapter_status("claude").state, "ready")
    // A valid old marker must not hide a newly broken Claude binary.
    p1c_put(t, binary, "#!/bin/sh\nprintf 'credential=secret' >&2\nexit 1\n", true)
    installed, reason = acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, !installed && reason == "acp_claude_not_runnable")
    status := acp_adapter_status("claude")
    testing.expect(t, status.installed && status.state == "error")
    testing.expect_value(t, status.error, "acp_claude_not_runnable: Claude --version exited with a non-zero status")
    // Persisted arbitrary diagnostics cannot escape via the status report.
    p1c_put(t, strings.concatenate({root, ".status.json"}), `{"state":"error","error":"acp_claude_not_runnable","diagnostic":"credential=secret"}`)
    testing.expect_value(t, acp_adapter_status("claude").error, "acp_claude_not_runnable")
    p1c_put(t, binary, "#!/bin/sh\nprintf '2.1.70 (Claude Code)\\n'\n", true)
    installed, reason = acp_adapter_install("claude", snapshot.etag, ACP_CLAUDE_VERSION)
    testing.expect(t, installed && reason == "")
    testing.expect_value(t, acp_adapter_status("claude").state, "ready")
    // A deployed legacy package/lock stays in place beneath any live child.
    // Its integrity-only receipt is upgraded by an automatic isolated probe.
    base := bridge_shell_data_dir()
    legacy := strings.concatenate({base, "/bridge/acp-adapters/claude/0.108.0"}, context.temp_allocator)
    bridge_make_directory_all(filepath.dir(legacy))
    testing.expect(t, os.rename(root, legacy) == nil)
    testing.expect_value(t, acp_adapter_root("claude"), legacy)
    os.remove(acp_adapter_marker_path(legacy, "claude"))
    p1c_put(t, strings.concatenate({legacy, "/heimdall-probe-v1.json"}), ACP_CLAUDE_INTEGRITY)
    acp_adapter_profile_probe_hook = t11_adapter_legacy_profile_probe; t4_profile_probe_calls = 0
    testing.expect_value(t, acp_adapter_status("claude").state, "ready")
    testing.expect_value(t, t4_profile_probe_calls, 1)
    binding, bound := acp_adapter_profile_binding("claude", "claude")
    testing.expect(t, bound && acp_adapter_marker_matches(legacy, binding))
    testing.expect_value(t, acp_adapter_status("claude").state, "ready")
    testing.expect_value(t, t4_profile_probe_calls, 1)
}

@(test)
c3_acp_copilot_npm_layout_resolves_versions_and_launches_without_patching :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    bin_dir := profile_join(st.dir, "mac-prefix/node_modules/.bin")
    native_dir := profile_join(st.dir, "mac-prefix/node_modules/@github/copilot-darwin-arm64")
    launcher_dir := profile_join(st.dir, "mac-prefix/node_modules/@github/copilot")
    bridge_make_directory_all(bin_dir); bridge_make_directory_all(native_dir); bridge_make_directory_all(launcher_dir)
    binary := profile_join(native_dir, "copilot")
    p1c_put(t, binary, "#!/bin/sh\nprintf 'GitHub Copilot CLI 1.0.114.\\n'\n", true)
    p1c_put(t, profile_join(launcher_dir, "npm-loader.js"), "#!/bin/sh\nexec \"${0%/*}/../copilot-darwin-arm64/copilot\" \"$@\"\n", true)
    launcher := profile_join(bin_dir, "copilot")
    os.symlink("../@github/copilot/npm-loader.js", launcher)
    pp := Provider_Profile{provider = "copilot", profile_id = "mac", enabled = true,
        environment = {{name = "PATH", value = strings.concatenate({bin_dir, ":/usr/bin:/bin"})}}}
    version, reason, diagnostic := acp_provider_cli_version(&pp)
    testing.expect_value(t, reason, "")
    testing.expect_value(t, diagnostic, "")
    testing.expect_value(t, version, "1.0.114")
    r := acp_runtime_new("inst_c3_mac_layout", "epoch", st.dir, "copilot", "mac", "etag", "", "ask", {})
    defer acp_runtime_destroy(r)
    spawn, built := acp_runtime_build_spawn(r, "endpoint", "synthetic-agent-token", &pp)
    testing.expect(t, built && len(spawn.argv) == 3 && spawn.argv[0] == profile_join(launcher_dir, "npm-loader.js") && spawn.argv[1] == "--acp" && spawn.argv[2] == "--stdio")
    // An explicit native executable uses the same version/probe/spawn path.
    pp.config.binary_path = binary
    version, reason, diagnostic = acp_provider_cli_version(&pp)
    testing.expect(t, version == "1.0.114" && reason == "" && diagnostic == "")
    spawn, built = acp_runtime_build_spawn(r, "endpoint", "synthetic-agent-token", &pp)
    testing.expect(t, built && len(spawn.argv) == 3 && spawn.argv[0] == binary && spawn.argv[1] == "--acp" && spawn.argv[2] == "--stdio")
    // Below the minimum is outdated (reported with its version), not a pin mismatch.
    p1c_put(t, binary, "#!/bin/sh\nprintf 'GitHub Copilot CLI 1.0.91.\\n'\n", true)
    version, reason, diagnostic = acp_provider_cli_version(&pp)
    testing.expect(t, version == "1.0.91" && reason == "acp_copilot_outdated" && diagnostic == "cli_version_outdated")
    // A newer user-installed CLI is accepted.
    p1c_put(t, binary, "#!/bin/sh\nprintf 'GitHub Copilot CLI 1.0.130.\\n'\n", true)
    version, reason, diagnostic = acp_provider_cli_version(&pp)
    testing.expect(t, version == "1.0.130" && reason == "" && diagnostic == "")
}

@(private = "file") kiro_npm_called: bool
@(private = "file") kiro_probe_calls: int

kiro_fake_runner :: proc(argv: []string, timeout: time.Duration) -> (string, string, int, bool, bool) {
    kiro_npm_called = true
    return "", "", 1, false, false
}

kiro_fake_profile_probe :: proc(pp: ^Provider_Profile, root, scratch: string) -> (bool, string) {
    kiro_probe_calls += 1
    return pp.provider == "kiro" && root != scratch, ""
}

@(private = "file") codex_catalog_probe_calls: int
@(private = "file") codex_catalog_probe_ok: bool
codex_catalog_profile_probe :: proc(pp: ^Provider_Profile, root, scratch: string) -> (bool, string) {
    codex_catalog_probe_calls += 1
    d, known := contracts.acp_provider_descriptor(pp.provider)
    return codex_catalog_probe_ok && known && d.protocol == .Codex_App_Server &&
        acp_protocol_driver(d.protocol) == &acp_protocol_codex_driver && root != scratch, "initialize_failed"
}

@(test)
acp_codex_detect_only_recheck_requires_successful_probe :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    old_runner, old_probe := acp_adapter_runner, acp_adapter_profile_probe_hook
    defer { acp_adapter_runner = old_runner; acp_adapter_profile_probe_hook = old_probe }
    acp_adapter_runner = kiro_fake_runner; acp_adapter_profile_probe_hook = codex_catalog_profile_probe
    kiro_npm_called = false; codex_catalog_probe_calls = 0; codex_catalog_probe_ok = false
    snapshot := bridge_provider_catalog_snapshot
    snapshot.etag = "sha256:codex"
    snapshot.providers[1] = {provider = "codex", binary = "codex", state = "active", transports = {"pty", "acp"}, default_transport = "pty",
        acp_recipe = {command = "codex", args = {"app-server"}, protocol_version = 1,
            adapter_package = "codex", adapter_version = "0.162.0", env = make(map[string]string)}}
    defer delete(snapshot.providers[1].acp_recipe.env)
    testing.expect(t, bridge_catalog_transport_valid(snapshot.providers[1]))
    binary := profile_join(st.dir, "codex")
    home := profile_join(st.dir, "codex-home")
    pp := Provider_Profile{profile_id = "codex", provider = "codex", enabled = true, config = {binary_path = binary, home_path = home}}
    raw, _ := json.marshal(Provider_Profile_Store_Wire{version = PROFILE_STORE_VERSION, profiles = {pp}})
    p1c_put(t, g_profile_test_store_path, string(raw))
    testing.expect_value(t, acp_adapter_status("codex").state, "missing")
    p1c_put(t, binary, "#!/bin/sh\nprintf 'codex-cli 0.161.9\\n'\n", true)
    status := acp_adapter_status("codex")
    testing.expect(t, status.state == "outdated" && status.version == "0.161.9")
    ok, reason := acp_adapter_install("codex", snapshot.etag, "0.162.0")
    testing.expect(t, !ok && reason == "acp_codex_outdated" && codex_catalog_probe_calls == 0)
    // The version check receives the same selected CODEX_HOME as app-server.
    p1c_put(t, binary, fmt.tprintf("#!/bin/sh\n[ \"$CODEX_HOME\" = %q ] || exit 42\nprintf 'codex-cli 0.162.0\\n'\n", home), true)
    status = acp_adapter_status("codex")
    testing.expect(t, status.installed && status.state == "error" && status.version == "0.162.0")
    ok, reason = acp_adapter_install("codex", snapshot.etag, "0.162.0")
    testing.expect(t, !ok && reason == "acp_adapter_probe_failed" && codex_catalog_probe_calls == 1)
    testing.expect_value(t, acp_adapter_status("codex").state, "error")
    codex_catalog_probe_ok = true
    ok, reason = acp_adapter_install("codex", snapshot.etag, "0.162.0")
    testing.expect(t, ok && reason == "" && codex_catalog_probe_calls == 2 && !kiro_npm_called)
    testing.expect_value(t, acp_adapter_status("codex").state, "ready")
    status_json := acp_adapter_status_json("codex")
    testing.expect(t, strings.contains(status_json, `"runtime_kind":"system"`) && strings.contains(status_json, `"node_version":null`) && strings.contains(status_json, `"protocol":"codex_app_server"`))
    p1c_put(t, binary, "#!/bin/sh\nprintf 'codex-cli 0.166.0\\n'\n", true)
    status = acp_adapter_status("codex")
    testing.expect(t, status.state == "error" && status.version == "0.166.0", "a changed executable version invalidates its probe receipt")
}

@(test)
acp_kiro_system_status_recheck_and_launch :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    old_runner, old_profile_probe := acp_adapter_runner, acp_adapter_profile_probe_hook
    defer { acp_adapter_runner = old_runner; acp_adapter_profile_probe_hook = old_profile_probe }
    acp_adapter_runner = kiro_fake_runner; acp_adapter_profile_probe_hook = kiro_fake_profile_probe
    kiro_npm_called = false; kiro_probe_calls = 0
    names := make([]string, 3); copy(names, []string{"claude", "codex", "kiro"})
    g_profile_test_catalog = names
    snapshot := bridge_provider_catalog_snapshot
    snapshot.etag = "sha256:kiro"
    snapshot.providers[1] = {provider = "kiro", binary = "kiro-cli", state = "active", transports = {"acp"}, default_transport = "acp",
        acp_recipe = {command = "kiro-cli", args = {"acp", "--agent-engine", "v3"}, protocol_version = 1,
            adapter_package = "kiro-cli", adapter_version = "3.5.0", env = make(map[string]string)}}
    defer delete(snapshot.providers[1].acp_recipe.env)
    binary := profile_join(st.dir, "kiro-cli")
    home := profile_join(st.dir, "kiro-home")
    pp := Provider_Profile{profile_id = "kiro", provider = "kiro", enabled = true, config = {binary_path = binary, config_dir = home}}
    raw, _ := json.marshal(Provider_Profile_Store_Wire{version = PROFILE_STORE_VERSION, profiles = {pp}})
    p1c_put(t, g_profile_test_store_path, string(raw))

    // Not installed: detect-only status says missing; Re-check never installs.
    status := acp_adapter_status("kiro")
    testing.expect_value(t, status.state, "missing")
    testing.expect(t, strings.has_prefix(status.error, "acp_kiro_not_found"))
    ok, reason := acp_adapter_install("kiro", snapshot.etag, "3.5.0")
    testing.expect(t, !ok && reason == "acp_kiro_not_found")

    // Older than the minimum: outdated, with the detected version.
    p1c_put(t, binary, "#!/bin/sh\nprintf 'kiro-cli 3.4.0\\n'\n", true)
    status = acp_adapter_status("kiro")
    testing.expect(t, status.state == "outdated" && status.version == "3.4.0")
    testing.expect_value(t, status.error, "acp_kiro_outdated: The selected Kiro executable is older than the minimum supported version 3.5.0; upgrade it on the bridge host")
    ok, reason = acp_adapter_install("kiro", snapshot.etag, "3.5.0")
    testing.expect(t, !ok && reason == "acp_kiro_outdated")

    // Not runnable (e.g. a glibc build on NixOS) is an error, not missing.
    p1c_put(t, binary, "#!/bin/sh\nprintf 'Could not start dynamically linked executable token=secret' >&2\nexit 127\n", true)
    status = acp_adapter_status("kiro")
    testing.expect(t, status.state == "error" && strings.has_prefix(status.error, "acp_kiro_not_runnable") && !strings.contains(status.error, "secret"))

    // A supported CLI is detected under the profile's isolated dirs, then
    // certified by Re-check without npm or Node.
    p1c_put(t, binary, fmt.tprintf("#!/bin/sh\n[ \"$KIRO_HOME\" = %q ] && [ \"$XDG_DATA_HOME\" = %q ] || exit 42\nprintf 'kiro-cli 3.5.0\\n'\n", home, profile_join(home, "data")), true)
    status = acp_adapter_status("kiro")
    testing.expect(t, status.installed && status.version == "3.5.0" && status.state == "error" && status.node_version == "")
    ok, reason = acp_adapter_install("kiro", snapshot.etag, "3.5.0")
    testing.expect(t, ok && reason == "")
    testing.expect(t, !kiro_npm_called && kiro_probe_calls == 1)
    testing.expect_value(t, acp_adapter_status("kiro").state, "ready")
    status_json := acp_adapter_status_json("kiro")
    testing.expect(t, strings.contains(status_json, `"runtime_kind":"system"`) && strings.contains(status_json, `"node_version":null`) && strings.contains(status_json, `"version":"3.5.0"`))
    // Re-check of an already certified profile does not probe again.
    ok, reason = acp_adapter_install("kiro", snapshot.etag, "3.5.0")
    testing.expect(t, ok && kiro_probe_calls == 1)

    // An upgraded CLI invalidates the certification until the next Re-check.
    p1c_put(t, binary, "#!/bin/sh\nprintf 'kiro-cli 3.6.0\\n'\n", true)
    status = acp_adapter_status("kiro")
    testing.expect(t, status.state == "error" && status.version == "3.6.0")

    // Managed launches use the detected CLI, fixed v3 flags and profile dirs.
    r := acp_runtime_new("inst_kiro_launch", "epoch", st.dir, "kiro", "kiro", "etag", "", "ask", {})
    defer acp_runtime_destroy(r)
    spawn, built := acp_runtime_build_spawn(r, "endpoint", "synthetic-agent-token", &pp)
    testing.expect(t, built && len(spawn.argv) == 4 && spawn.argv[0] == binary && spawn.argv[1] == "acp" && spawn.argv[2] == "--agent-engine" && spawn.argv[3] == "v3")
    seen := 0
    for pair in spawn.env {
        if pair[0] == "KIRO_HOME" { testing.expect_value(t, pair[1], home); seen += 1 }
        if pair[0] == "XDG_DATA_HOME" { testing.expect_value(t, pair[1], profile_join(home, "data")); seen += 1 }
    }
    testing.expect_value(t, seen, 2)
}

// Model discovery over ACP no longer requires a system CLI: an adapter-launched
// descriptor that opts in probes through its installed package bin, with the
// provider CLI passed through executable_env like a managed launch.
@(test)
acp_model_discovery_accepts_adapter_launched_descriptor :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    d := contracts.ACP_CLAUDE_DESCRIPTOR; d.discover_models_via_acp = true
    testing.expect(t, d.launch == .Adapter && contracts.acp_descriptor_shape_valid(d))
    testing.expect(t, bridge_models_acp_eligible(.ACP, d))
    testing.expect(t, !bridge_models_acp_eligible(.Claude_Control, d))
    codex := contracts.ACP_CODEX_DESCRIPTOR; codex.discover_models_via_acp = true
    testing.expect(t, !bridge_models_acp_eligible(.ACP, codex), "the app-server keeps its own model/list probe")
    root := profile_join(st.dir, "claude-stage")
    _, built := bridge_models_acp_argv(d, "/profile/claude", root)
    testing.expect(t, !built, "no probe until the adapter is installed")
    _, built = bridge_models_acp_argv(d, "/profile/claude", "")
    testing.expect(t, !built)
    pkg := profile_join(root, "node_modules/" + ACP_CLAUDE_PACKAGE)
    bin := acp_adapter_bin(root, "claude")
    p1c_put(t, profile_join(pkg, "package.json"), `{"name":"@agentclientprotocol/claude-agent-acp","version":"0.108.0","bin":{"claude-agent-acp":"dist/cli.js"}}`)
    p1c_put(t, profile_join(root, "package-lock.json"), strings.concatenate({`{"packages":{"node_modules/@agentclientprotocol/claude-agent-acp":{"version":"0.108.0","integrity":"`, ACP_CLAUDE_INTEGRITY, `"}}}`}))
    p1c_put(t, profile_join(pkg, "dist/cli.js"), "#!/bin/sh\nexit 0\n", true)
    bridge_make_directory_all(filepath.dir(bin))
    testing.expect(t, os.symlink("../@agentclientprotocol/claude-agent-acp/dist/cli.js", bin) == nil)
    argv, ok := bridge_models_acp_argv(d, "/profile/claude", root)
    testing.expect(t, ok && len(argv) == 1 && argv[0] == bin)
    plan := bridge_models_acp_env_plan(d, "/profile/claude")
    testing.expect(t, len(plan.set) == 2 && plan.set[0] == [2]string{"CLAUDE_AGENT_ACP_PROTOCOL", "v1"} && plan.set[1] == [2]string{"CLAUDE_CODE_EXECUTABLE", "/profile/claude"})
    // System CLIs keep their plain argv and environment.
    kiro := contracts.ACP_KIRO_DESCRIPTOR
    argv, ok = bridge_models_acp_argv(kiro, "/opt/kiro-cli", "")
    testing.expect(t, ok && len(argv) == 4 && argv[0] == "/opt/kiro-cli")
    testing.expect_value(t, len(bridge_models_acp_env_plan(kiro, "/opt/kiro-cli").set), 0)
    // The registered Claude runtime keeps its bespoke control-protocol probe.
    _, acp := bridge_models_acp_descriptor("claude")
    testing.expect(t, !acp)
    testing.expect_value(t, bridge_models_source("claude"), "claude_control")
}
