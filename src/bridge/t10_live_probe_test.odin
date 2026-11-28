#+build !windows
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Opt-in integration check: installs the pinned real npm adapter, starts a private
// daemon and exercises the actual Bridge probe. Requires node/npm, claude and a
// matching HEIMDALL_HAM_PTY_HOST_BIN; ordinary unit suites remain offline.
when #config(HEIMDALL_ACP_LIVE_TEST, false) {
@(test)
t10_live_adapter_install_profile_and_failure :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = context.temp_allocator
    data := fmt.tprintf("%s/.cache/heimdall-tests/t10-live-%d", os.get_env("HOME", context.temp_allocator), time.tick_now()._nsec)
    bridge_config.data_dir = data; defer os.remove_all(data)
    old_daemon_id := bridge_config.daemon_id
    bridge_config.daemon_id = "brg_test_t10_live"
    defer { bridge_config.daemon_id = old_daemon_id }
    env := make(map[string]string); env["CLAUDE_AGENT_ACP_PROTOCOL"] = "v1"
    bridge_provider_catalog_snapshot.etag = "sha256:t10-live"
    bridge_provider_catalog_snapshot.providers[0].acp_recipe = {command = "claude-agent-acp", protocol_version = 1, adapter_package = ACP_CLAUDE_PACKAGE, adapter_version = ACP_CLAUDE_VERSION, env = env}
    child_env, _ := os.environ(context.temp_allocator)
    claude := profile_resolve_binary("claude", child_env); defer delete(claude)
    if !testing.expect(t, claude != "", "live fixture requires a host-compatible Claude executable") do return
    cfg := profile_join(data, "claude-config"); bridge_make_directory_all(cfg)
    profile := p1c_profile("claude", claude, cfg, "canonical-live")
    testing.expect(t, profile_store_write_locked({profile}))

    sock := fmt.tprintf("/tmp/ham-t10-%d.sock", time.tick_now()._nsec)
    swap := pty_host_test_install_socket(sock); defer pty_host_test_restore_socket(swap)
    prior := pty_host_daemon_process; has := pty_host_daemon_has_process; started := pty_host_daemon_started
    pty_host_daemon_has_process = false; pty_host_daemon_started = false
    defer {
        if pty_host_daemon_has_process {
            _ = os.process_kill(pty_host_daemon_process)
            _, _ = os.process_wait(pty_host_daemon_process)
        }
        pty_host_daemon_process = prior; pty_host_daemon_has_process = has; pty_host_daemon_started = started
        bridge_config.daemon_id = old_daemon_id
        os.remove(sock)
    }
    installed, reason := acp_adapter_install("claude", "sha256:t10-live", ACP_CLAUDE_VERSION)
    if !installed {
        status := acp_adapter_status("claude")
        fmt.eprintf("ACP live install: %s (%s)\n", reason, status.error)
    }
    if !testing.expect(t, installed, reason) do return
    testing.expect_value(t, acp_adapter_status("claude").state, "ready")
    installed, reason = acp_adapter_install("claude", "sha256:t10-live", ACP_CLAUDE_VERSION)
    testing.expect(t, installed, reason) // repeat request remains ready

    // A real pipe child with an untrusted diagnostic must produce a safe reason,
    // and no probe credential can be inherited from this agent's environment.
    bad := profile_join(data, "failing")
    bridge_make_directory_all(profile_join(bad, "node_modules/.bin"))
    script := acp_adapter_bin(bad, "claude")
    p1c_put(t, script, "#!/bin/sh\nif [ -n \"$HEIMDALL_AGENT_TOKEN\" ]; then echo credential-leaked >&2; exit 1; fi\nprintf 'Error [ERR_MODULE_NOT_FOUND]: credential=must-never-appear\\n' >&2\nexit 1\n")
    bridge_os_make_owner_executable(script)
    ok, diagnostic := acp_adapter_probe("claude", bad, data)
    testing.expect(t, !ok && diagnostic == "node_module_missing")
    testing.expect(t, !strings.contains(acp_adapter_probe_message(diagnostic, "claude"), "credential"))
    profile.config.binary_path = profile_join(data, "missing-claude")
    testing.expect(t, profile_store_write_locked({profile}))
    ok, diagnostic = acp_adapter_probe("claude", bad, data)
    testing.expect(t, !ok && diagnostic == "claude_missing")
}
}
