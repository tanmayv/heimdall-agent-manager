package main

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:os"
import "core:sync"
import "base:runtime"
import contracts "odin_test:contracts"

ACP_CLAUDE_VERSION :: contracts.ACP_CLAUDE_DESCRIPTOR.pkg.version
ACP_CLAUDE_PACKAGE :: contracts.ACP_CLAUDE_DESCRIPTOR.pkg.name
ACP_CLAUDE_INTEGRITY :: contracts.ACP_CLAUDE_DESCRIPTOR.pkg.integrity

@(test)
c2_acp_copilot_restore_binds_policy_profile_and_minimum_version :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    instance := "inst_c2_restore"
    state := ACP_State{schema_version = 3, runtime_binding_version = 1, provider = "copilot", profile = "work", bridge = bridge_config.daemon_id,
        instance = instance, launch_epoch = "copilot_epoch", run_dir = bridge_runtime_default_run_dir(instance), pipe_generation = "saved-generation",
        adapter_version = "1.0.114", selected_mode = "ask", runtime_json = `{"phase":"initialize"}`,
        binding = acp_provider_binding(contracts.ACP_COPILOT_DESCRIPTOR, "work", "1.0.114", "AGENTS.md", 7)}
    restored, valid := acp_runtime_from_state(&state, {})
    testing.expect(t, valid && restored != nil)
    if restored != nil { testing.expect(t, restored.mode == "ask" && restored.binding.cli_version == "1.0.114"); acp_runtime_destroy(restored) }
    for field in 0..<4 {
        changed := state
        switch field {
        case 0: changed.selected_mode = "bypassPermissions"
        case 1: changed.binding.cli_version = "1.0.91"
        case 2: changed.profile = "personal"
        case 3: changed.provider = "claude"
        }
        rejected, accepted := acp_runtime_from_state(&changed, {})
        testing.expect(t, !accepted && rejected == nil)
        if rejected != nil do acp_runtime_destroy(rejected)
    }
}

@(test)
c2_acp_copilot_cli_minimum_rejects_old_host_and_untrusted_output :: proc(t: ^testing.T) {
    // The registry parses the output; the ACP minimum then decides acceptance.
    d := contracts.ACP_COPILOT_DESCRIPTOR
    copilot := bridge_provider_traits("copilot")
    version, valid := contracts.provider_parse_cli_version(copilot, "GitHub Copilot CLI 1.0.114.\nRun 'copilot version' to check for updates.\n")
    testing.expect(t, valid && version == "1.0.114" && contracts.acp_descriptor_cli_version_accepted(d, version))
    version, valid = contracts.provider_parse_cli_version(copilot, "GitHub Copilot CLI 1.2.0.\n")
    testing.expect(t, valid && contracts.acp_descriptor_cli_version_accepted(d, version), "newer CLIs meet the minimum")
    for output in ([]string{"GitHub Copilot CLI 1.0.91.", "1.0.114", "diagnostic GitHub Copilot CLI 1.0.114.", "GitHub Copilot CLI 1.0.114.secret", "GitHub Copilot CLI 1.0.114.5"}) {
        version, valid := contracts.provider_parse_cli_version(copilot, output)
        testing.expectf(t, !valid || !contracts.acp_descriptor_cli_version_accepted(d, version), "%q rejected", output)
    }
    version, valid = contracts.provider_parse_cli_version(bridge_provider_traits("claude"), "2.1.70 (Claude Code)\n")
    testing.expect(t, valid && version == "2.1.70")
}

@(test)
acp_provider_launch_argv_system_and_adapter_share_probe_semantics :: proc(t: ^testing.T) {
    d, _ := contracts.acp_provider_descriptor("claude")
    adapter, valid := acp_provider_launch_argv(d, "/managed/claude", "/profile/claude")
    testing.expect(t, valid && len(adapter) == 1 && adapter[0] == "/managed/claude/node_modules/.bin/claude-agent-acp")
    system := contracts.ACP_COPILOT_DESCRIPTOR
    argv, built := acp_provider_launch_argv(system, "/managed/copilot", "/profile/copilot")
    testing.expect(t, built && len(argv) == 3 && argv[0] == "/profile/copilot" && argv[1] == "--acp" && argv[2] == "--stdio")
    _, built = acp_provider_launch_argv(system, "/managed/copilot", "")
    testing.expect(t, !built, "missing resolved system CLI cannot fall back to another executable")
}

@(test)
acp_provider_binding_rejects_provider_version_profile_and_platform_substitution :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    d := contracts.ACP_CLAUDE_DESCRIPTOR
    expected := acp_provider_binding(d, "work", "2.1.70", "CUSTOM.md", 42)
    raw, _ := json.marshal(expected, allocator = context.temp_allocator)
    testing.expect(t, acp_provider_binding_valid(expected) && acp_provider_marker_valid(string(raw), expected))
    testing.expect(t, !acp_provider_marker_valid(ACP_CLAUDE_INTEGRITY, expected))
    for field in 0..<10 {
        changed := expected
        switch field {
        case 0: changed.provider = "copilot"
        case 1: changed.profile = "personal"
        case 2: changed.package_version = "0.108.1"
        case 3: changed.cli_version = "2.1.71"
        case 4: changed.descriptor_revision += 1
        case 5: changed.package_integrity = "sha512-wrong"
        case 6: changed.platform = "different/platform"
        case 7: changed.profile_revision += 1
        case 8: changed.bootstrap_filename = "AGENTS.md"
        case 9: changed.descriptor_id = "unregistered"
        }
        testing.expect(t, !acp_provider_marker_valid(string(raw), changed))
        changed_raw, _ := json.marshal(changed, allocator = context.temp_allocator)
        testing.expect(t, !acp_provider_marker_valid(string(changed_raw), expected))
    }
    expected.cli_version = ""
    testing.expect(t, !acp_provider_binding_valid(expected))
}

@(test)
acp_provider_restore_rejects_cross_profile_and_descriptor_journals :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    instance := "inst_acp_binding_restore"
    dir := bridge_runtime_default_run_dir(instance)
    state := ACP_State{schema_version=3,runtime_binding_version = 1, provider = "claude", profile = "work", bridge = bridge_config.daemon_id,
        instance = instance, launch_epoch = "binding_epoch", run_dir = dir, pipe_generation = "saved-generation",
        adapter_version = "0.108.0", selected_mode = "default", runtime_json = `{"phase":"initialize"}`,
        binding = acp_provider_binding(contracts.ACP_CLAUDE_DESCRIPTOR, "work", "2.1.70", "CUSTOM.md")}
    restored, valid := acp_runtime_from_state(&state, {})
    testing.expect(t, valid)
    if valid do acp_runtime_destroy(restored)
    for field in 0..<5 {
        changed := state
        switch field {
        case 0: changed.provider = "copilot"
        case 1: changed.profile = "personal"
        case 2: changed.binding.package_version = "0.108.1"
        case 3: changed.binding.descriptor_id = "native"
        case 4: changed.binding = {}
        }
        rejected, built := acp_runtime_from_state(&changed, {})
        testing.expect(t, !built && rejected == nil)
        if rejected != nil do acp_runtime_destroy(rejected)
    }
    // Keep the owned string lifetime explicit under the test allocator.
    testing.expect(t, strings.has_suffix(dir, instance))
}

@(test)
acp_provider_legacy_journal_migrates_without_new_turn_and_ambiguous_requires_restart :: proc(t: ^testing.T) {
    st := p1c_test_setup(t); defer p1c_test_teardown(st)
    context.allocator = runtime.heap_allocator()
    binary := profile_join(st.dir, "claude-version")
    p1c_put(t, binary, "#!/bin/sh\nprintf '2.1.70 (Claude Code)\\n'\n", true)
    pp := Provider_Profile{provider = "claude", profile_id = "claude", enabled = true, updated_at = 42, config = {binary_path = binary}}
    testing.expect(t, profile_store_write_locked({pp}))
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous_records }
    instance := "inst_c1_legacy_live"
    dir := bridge_runtime_default_run_dir(instance); defer delete(dir)
    bridge_make_directory_all(dir); defer os.remove_all(dir)
    p1c_put(t, profile_join(dir, "CUSTOM.md"), "legacy unique bootstrap marker")
    p1c_put(t, profile_join(dir, "heimdall-bootstrap-manifest.json"),
        `{"agent_instance_id":"inst_c1_legacy_live","managed_files":[{"kind":"AGENTS_MD","relative_path":"CUSTOM.md"}]}`)
    f: T4_Runtime_Test; t4_runtime_open(&f, instance, dir)
    r := f.r
    r.generation = strings.clone("live-generation")
    r.initialized = true; r.load_session = true; r.session = strings.clone("existing-session")
    r.d.ready = true; r.d.starter_sent = true
    acp_runtime_replace(&r.d.phase, "prompt"); acp_runtime_replace(&r.d.current_input, "existing-turn")
    id, sent := acp_rpc_request(r.client, "session/prompt", `{"sessionId":"existing-session","prompt":[{"type":"text","text":"already executed"}]}`, 0, {acp_runtime_result, r})
    testing.expect(t, sent && acp_test_wait(t, &f.f, .Writes, 1))
    sync.mutex_lock(&f.f.mu)
    delivery := strings.clone(f.f.writes[0].delivery_id)
    sync.mutex_unlock(&f.f.mu)
    acp_rpc_enqueue_frame(r.client, {kind = .Receipt, bytes = delivery})
    testing.expect(t, t4_runtime_call(&f, "resume")); delete(delivery)
    sync.mutex_lock(&f.f.mu); snapshot := strings.clone(f.f.snapshot); sync.mutex_unlock(&f.f.mu)
    defer delete(snapshot)
    state, decoded := acp_state_decode(snapshot); testing.expect(t, decoded)
    defer acp_state_delete(&state)
    rec := bridge_startup_clone_rec(r.rec)
    defer { delete(rec.token_hash); delete(rec.agent_instance_id); delete(rec.instance_token) }
    path := strings.clone(r.state_path); defer delete(path)
    r.quiescing = true; acp_runtime_destroy(r); acp_test_delete(&f.f)
    acp_provider_binding_delete(&state.binding); state.runtime_binding_version = 0; state.schema_version = 1
    testing.expect(t, acp_state_write(path, &state))
    intent := ACP_Hub_Intent{provider = "claude", profile = "claude"}
    for field in 0..<4 {
        bad := state; bad_intent := intent
        switch field {
        case 0: bad.profile = "work"
        case 1: bad.adapter_version = "0.109.0"
        case 2: bad.profile = "missing"; bad_intent.profile = "missing"
        case 3: bad.profile = ""
        }
        migrated, reason := acp_runtime_upgrade_legacy_state(&bad, bad_intent, path, rec)
        testing.expect(t, !migrated && reason == "acp_restart_required")
    }
    migrated, reason := acp_runtime_upgrade_legacy_state(&state, intent, path, rec)
    testing.expect(t, migrated && reason == "" && state.runtime_binding_version == 1)
    testing.expect(t, state.binding.profile_revision == 42 && state.binding.cli_version == "2.1.70" && state.binding.bootstrap_filename == "CUSTOM.md")
    updated, read_err := os.read_entire_file(path, context.allocator); defer delete(updated)
    testing.expect(t, read_err == nil)
    next: T4_Runtime_Test; t4_runtime_open(&next, instance, dir)
    defer { next.r.d.stopped = true; acp_runtime_destroy(next.r); acp_test_delete(&next.f) }
    acp_provider_binding_delete(&next.r.binding); next.r.binding = acp_provider_binding_copy(state.binding)
    next.r.initialized = true; next.r.load_session = true; next.r.session = strings.clone(state.sessionId)
    delete(next.r.d.phase); delete(next.r.d.starter); next.r.d = {}
    testing.expect(t, json.unmarshal_string(state.runtime_json, &next.r.d) == nil)
    testing.expect(t, acp_rpc_restore(next.r.client, string(updated)))
    testing.expect(t, t4_runtime_call(&next, "resume"))
    sync.mutex_lock(&next.f.mu); testing.expect_value(t, len(next.f.writes), 0); sync.mutex_unlock(&next.f.mu)
    next.r.client.io.feed(next.r.client, acp_test_response(id, `{"stopReason":"end_turn"}`), 1)
    acp_test_wait(t, &next.f, .Acks, 1); delete(string(id))
    sync.mutex_lock(&next.f.mu); testing.expect_value(t, len(next.f.writes), 0); sync.mutex_unlock(&next.f.mu)
}

@(test)
acp_kiro_version_argv_and_binding_use_minimum :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    d := contracts.ACP_KIRO_DESCRIPTOR
    kiro := bridge_provider_traits("kiro")
    for pair in ([][2]string{{"kiro-cli 3.5.0\n", "3.5.0"}, {"kiro-cli 3.10.2 (stable)\n", "3.10.2"}, {"kiro-cli 3.4.0", "3.4.0"}}) {
        version, valid := contracts.provider_parse_cli_version(kiro, pair[0])
        testing.expectf(t, valid && version == pair[1], "%q parses as %s", pair[0], pair[1])
    }
    for output in ([]string{"3.5.0", "Kiro CLI 3.5.0", "kiro-cli v3.5.0", "kiro-cli 3.5", "warning\nkiro-cli 3.5.0", "kiro-cli 3.5.0-beta.1", ""}) {
        version, valid := contracts.provider_parse_cli_version(kiro, output)
        testing.expectf(t, !valid, "%q rejected (got %s)", output, version)
    }
    argv, built := acp_provider_launch_argv(d, "/unused/root", "/opt/kiro/bin/kiro-cli")
    testing.expect(t, built && len(argv) == 4 && argv[0] == "/opt/kiro/bin/kiro-cli" && argv[1] == "acp" && argv[2] == "--agent-engine" && argv[3] == "v3")
    _, built = acp_provider_launch_argv(d, "/unused/root", "")
    testing.expect(t, !built, "an undetected system CLI never falls back to a managed root")
    binding := acp_provider_binding(d, "work", "3.6.1", "AGENTS.md", 3)
    testing.expect(t, acp_provider_binding_valid(binding))
    binding.cli_version = "3.4.9"
    testing.expect(t, !acp_provider_binding_valid(binding))
    testing.expect_value(t, acp_adapter_runtime_kind(d), "system")
    when ODIN_OS == .Linux || ODIN_OS == .Darwin do testing.expect(t, acp_adapter_platform_supported(d))
}

@(test)
acp_kiro_profile_config_dir_moves_settings_and_credentials :: proc(t: ^testing.T) {
    p := Provider_Profile{provider = "kiro", config = {config_dir = "/p/kiro"},
        environment = {{name = "KIRO_HOME", value = "/env/kiro"}, {name = "XDG_DATA_HOME", value = "/env/data"}}}
    joined := strings.join(profile_apply_env_plan([]string{"HOME=/bridge", "XDG_DATA_HOME=/bridge/.local/share", "PATH=/bin"}, profile_env_plan(&p)), "\n", context.temp_allocator)
    testing.expect(t, strings.contains(joined, "KIRO_HOME=/p/kiro") && strings.contains(joined, "XDG_DATA_HOME=/p/kiro/data"))
    testing.expect(t, !strings.contains(joined, "/env/") && !strings.contains(joined, "/bridge/.local/share") && strings.contains(joined, "HOME=/bridge"))
    // Without a config directory the user's own Kiro login is inherited.
    p.config.config_dir = ""; p.environment = nil
    inherited := strings.join(profile_apply_env_plan([]string{"HOME=/bridge"}, profile_env_plan(&p)), "\n", context.temp_allocator)
    testing.expect(t, !strings.contains(inherited, "KIRO_HOME") && !strings.contains(inherited, "XDG_DATA_HOME"))
    // A Copilot profile's config directory is exported as COPILOT_HOME.
    copilot := Provider_Profile{provider = "copilot", config = {config_dir = "/p/copilot"}, environment = {{name = "COPILOT_HOME", value = "/env/copilot"}}}
    plan := profile_env_plan(&copilot)
    testing.expect_value(t, len(plan.set), 1)
    if len(plan.set) == 1 do testing.expect(t, plan.set[0] == [2]string{"COPILOT_HOME", "/p/copilot"})
}

@(test)
acp_codex_version_binding_and_registered_driver :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    d := contracts.ACP_CODEX_DESCRIPTOR
    codex := bridge_provider_traits("codex")
    for output in ([]string{"codex-cli 0.162.0\n", "codex-cli 0.166.0\n"}) {
        version, valid := contracts.provider_parse_cli_version(codex, output)
        testing.expect(t, valid && contracts.acp_descriptor_cli_version_accepted(d, version))
    }
    for output in ([]string{"codex 0.162.0", "0.162.0", "codex-cli v0.162.0", "codex-cli 0.162.0-beta"}) {
        _, valid := contracts.provider_parse_cli_version(codex, output)
        testing.expect(t, !valid)
    }
    binding := acp_provider_binding(d, "work", "0.162.0", "AGENTS.md", 7)
    testing.expect(t, acp_provider_binding_valid(binding))
    binding.cli_version = "0.161.9"
    testing.expect(t, !acp_provider_binding_valid(binding))
    r := acp_runtime_new("inst_codex_descriptor", "epoch", "/unused", "codex", "work", "etag", "gpt-6.1-sol", "ask", {})
    defer acp_runtime_destroy(r)
    testing.expect(t, r.driver == &acp_protocol_codex_driver && r.descriptor.protocol == .Codex_App_Server && r.mode == "ask")
    testing.expect_value(t, acp_adapter_runtime_kind(d), "system")
}

@(test)
acp_opencode_detects_plain_version_and_preserves_argv_boundaries :: proc(t: ^testing.T) {
    d := contracts.ACP_OPENCODE_DESCRIPTOR
    opencode := bridge_provider_traits("opencode")
    version, parsed := contracts.provider_parse_cli_version(opencode, "1.19.6\r\n")
    testing.expect(t, parsed && version == "1.19.6")
    for output in ([]string{"opencode 1.19.6", "warning\n1.19.6", "1.19.6-beta", "1.19.6 2.0.0"}) {
        _, accepted := contracts.provider_parse_cli_version(opencode, output)
        testing.expect(t, !accepted)
    }
    for binary in ([]string{"/opt/Program Files/opencode", "C:\\Program Files\\OpenCode\\opencode.exe"}) {
        argv, built := acp_provider_launch_argv(d, "/unused", binary)
        testing.expect(t, built && len(argv) == 2 && argv[0] == binary && argv[1] == "acp")
    }
}
