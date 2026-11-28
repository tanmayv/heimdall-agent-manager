#+build !windows
package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"

T4_Recovery_Fixture :: struct {
    rpc: T4_Runtime_Test,
    t: ^testing.T,
    instance, cwd, token, daemon_generation, provider: string,
    old_closed: bool,
    lists, closes, spawns, interrupted: int,
}
t4_recovery_fixture: ^T4_Recovery_Fixture

t4_recovery_ensure :: proc() -> (string, bool) { return "fixture-daemon", true }
t4_recovery_endpoint :: proc() -> (string, bool) { return "http://127.0.0.1:49324", true }
t4_recovery_list :: proc(_: string, frame: []byte, _: int) -> (Pty_Host_Reply, bool) {
    f := t4_recovery_fixture; f.lists += 1
    req, valid := pty_host_decode_pipe_request(frame[4:]) // request hook receives the outer length prefix
    if valid do pty_host_pipe_request_delete(req)
    testing.expect(f.t, valid && req.kind == .List)
    reply := Pty_Host_Reply{kind = .Pipe_List}
    if !f.old_closed {
        reply.pipes = make([]Pty_Host_Pipe_Info, 1)
        reply.pipes[0] = {instance = strings.clone(f.instance), generation = strings.clone(f.daemon_generation if f.daemon_generation != "" else "old-generation"), alive = false}
    }
    return reply, true
}
t4_recovery_close :: proc(_: string, instance: string) -> bool {
    f := t4_recovery_fixture
    testing.expect(f.t, instance == f.instance)
    f.closes += 1; f.old_closed = true; return true
}
t4_recovery_spawn :: proc(_: string, req: Pty_Host_Spawn_Request) -> (Pty_Host_Reply, bool) {
    f := t4_recovery_fixture; f.spawns += 1
    testing.expect(f.t, f.old_closed && f.interrupted == 1 && req.instance == f.instance && req.cwd == f.cwd && req.has_cwd)
    if f.provider == "copilot" {
        testing.expect(f.t, len(req.argv) == 3 && strings.has_suffix(req.argv[0], "/copilot") && req.argv[1] == "--acp" && req.argv[2] == "--stdio")
    }
    for pair in req.env {
        if pair[0] == "HEIMDALL_AGENT_TOKEN" do f.token = strings.clone(pair[1], runtime.heap_allocator())
    }
    testing.expect(f.t, f.token != "")
    return {kind = .Spawned, instance = strings.clone(req.instance), generation = strings.clone("new-generation"), pid = 123}, true
}
t4_recovery_finished :: proc(_: ^ACP_Runtime, input_id, _: string, error: string) {
    f := t4_recovery_fixture
    testing.expect(f.t, input_id == "interrupted-input" && error == "acp_turn_interrupted")
    f.interrupted += 1
}
t4_recovery_connect :: proc(r: ^ACP_Runtime, _: string, after_seq: u64, checkpoint: string) -> bool {
    f := t4_recovery_fixture; f.rpc.r = r
    testing.expect(f.t, after_seq == 0 && checkpoint == "" && r.generation == "new-generation")
    r.client, _ = acp_rpc_open({data = &f.rpc.f, instance = r.instance, launch_epoch = r.epoch, state_path = r.state_path,
        write = acp_test_write, ack = acp_test_ack, close = acp_test_close},
        {data = &f.rpc, checkpoint = t4_runtime_checkpoint, restore_completion = t4_runtime_restore_completion})
    return t4_runtime_call(&f.rpc, "begin")
}

// Real token store, real journal, real shim rendering and real RPC dispatcher;
// only the daemon boundary and endpoint listener are replaced.
t4_recovery_write_state :: proc(t: ^testing.T, f: ^T4_Recovery_Fixture, error := "", legacy := false) -> string {
    context.allocator = runtime.heap_allocator()
    issue := bridge_agent_token_issue(f.instance, "assertion~recovery_epoch", .Agent, 9)
    bridge_startup_begin(issue.plaintext_token)
    bridge_runtime_set_status(f.instance, "running", "idle")
    rec, valid := bridge_agent_token_verify(issue.plaintext_token); testing.expect(t, valid)
    cwd := bridge_runtime_default_run_dir(f.instance); defer delete(cwd)
    f.cwd = strings.clone(cwd, context.temp_allocator)
    bridge_make_directory_all(cwd)
    provider := f.provider if f.provider != "" else "claude"
    d, _ := contracts.acp_provider_descriptor(provider)
    mode, _ := contracts.acp_descriptor_permission_mode(d, "ask")
    _ = os.write_entire_file(strings.concatenate({cwd, "/", d.bootstrap_filename}, context.temp_allocator), string("recovery bootstrap marker"))
    r := acp_runtime_new(f.instance, "recovery_epoch", cwd, provider, provider, "sha256:test", "sonnet", mode, rec)
    defer acp_runtime_destroy(r)
    acp_runtime_replace(&r.binding.cli_version, "1.0.114" if provider == "copilot" else "2.1.70")
    r.generation = strings.clone("old-generation"); r.session = strings.clone("saved-session")
    r.initialized = true; r.load_session = true
    r.d.phase = strings.clone("prompt"); r.d.current_input = strings.clone("interrupted-input")
    r.d.starter = strings.clone("EXACT starter text"); r.d.starter_sent = true; r.d.ready = error == ""
    r.d.error = strings.clone(error)
    append(&r.inbox.queue, Bridge_Inbox_Input{id = strings.clone("fresh-input"), text = strings.clone("fresh text")})
    state := ACP_State{schema_version = 1, instance = strings.clone(f.instance), launch_epoch = strings.clone(r.epoch),
        effective_transport = strings.clone("acp"), next_rpc_id = 40, next_delivery_id = 50}
    defer acp_state_delete(&state)
    testing.expect(t, acp_runtime_checkpoint(r, &state))
    testing.expect(t, bridge_inbox_save(r.inbox)) // queued input lives in the instance's inbox file
    if legacy {
        acp_provider_binding_delete(&state.binding); state.runtime_binding_version = 0; state.schema_version = 1
        manifest, _ := json.marshal(struct { agent_instance_id: string, managed_files: []struct { relative_path, kind: string } }{
            f.instance, {{d.bootstrap_filename, "AGENTS_MD"}}}, allocator = context.temp_allocator)
        _ = os.write_entire_file(strings.concatenate({cwd, "/heimdall-bootstrap-manifest.json"}, context.temp_allocator), manifest)
    }
    testing.expect(t, acp_state_write(r.state_path, &state))
    return strings.clone(issue.plaintext_token, context.temp_allocator)
}

@(test)
t4_acp_reconcile_recovery_rotates_token_closes_old_and_never_reprompts_interrupted :: proc(t: ^testing.T) {
    c2_test_reconcile_provider_recovery(t, "claude")
}

@(test)
c2_acp_copilot_dead_child_load_preserves_profile_policy_and_inbox :: proc(t: ^testing.T) {
    c2_test_reconcile_provider_recovery(t, "copilot")
}

c2_test_reconcile_provider_recovery :: proc(t: ^testing.T, provider: string) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    sync.mutex_lock(&g_profile_test_mu); defer sync.mutex_unlock(&g_profile_test_mu)
    context.allocator = runtime.heap_allocator()
    root := fmt.tprintf("%s/.cache/heimdall-tests/t4-recovery-%d", os.get_env("HOME", context.temp_allocator), time.tick_now()._nsec)
    bridge_make_directory_all(root); defer os.remove_all(root)
    previous_config := bridge_config; previous_profile_path := g_profile_test_store_path
    previous_io := acp_runtime_io; previous_events := acp_runtime_events; previous_fixture := t4_recovery_fixture
    previous_records := bridge_local_token_records; previous_runtimes := acp_runtimes
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
    acp_runtimes = make(map[string]^ACP_Runtime)
    defer {
        for _, r in acp_runtimes do acp_runtime_destroy(r)
        delete(acp_runtimes); acp_runtimes = previous_runtimes
        for rec in bridge_local_token_records { delete(rec.token_hash); delete(rec.agent_instance_id); delete(rec.instance_token) }
        delete(bridge_local_token_records); bridge_local_token_records = previous_records
        bridge_config = previous_config; g_profile_test_store_path = previous_profile_path
        acp_runtime_io = previous_io; acp_runtime_events = previous_events; t4_recovery_fixture = previous_fixture
    }
    bridge_config.data_dir = root; bridge_config.local_endpoint_run_dir = strings.concatenate({root, "/run"}, context.temp_allocator)
    bridge_config.daemon_id = "brg_test_t4_recovery"
    g_profile_test_store_path = strings.concatenate({root, "/profiles.json"}, context.temp_allocator)
    // Keep profile/env resolution and SpawnPipe construction in the test.
    binary := strings.concatenate({root, "/", provider}, context.temp_allocator)
    version_script := "#!/bin/sh\nprintf 'GitHub Copilot CLI 1.0.114.\\n'\n" if provider == "copilot" else "#!/bin/sh\nprintf '2.1.70 (Claude Code)\\n'\n"
    _ = os.write_entire_file(binary, version_script)
    bridge_os_make_owner_executable(binary)
    profile_raw, _ := json.marshal(Provider_Profile_Store_Wire{version = PROFILE_STORE_VERSION,
        profiles = {{profile_id = provider, provider = provider, enabled = true, config = {binary_path = binary}}}}, allocator = context.temp_allocator)
    _ = os.write_entire_file(g_profile_test_store_path, profile_raw)
    acp_runtime_io = {t4_recovery_ensure, t4_recovery_list, t4_recovery_close, t4_recovery_spawn, t4_recovery_endpoint, t4_recovery_connect}
    acp_runtime_events.prompt_finished = t4_recovery_finished
    f := T4_Recovery_Fixture{t = t, instance = fmt.tprintf("inst_t4_real_recovery_%s", provider), provider = provider}; t4_recovery_fixture = &f
    old_token := t4_recovery_write_state(t, &f, legacy = provider == "claude")
    defer {
        if f.rpc.r != nil { f.rpc.r.d.stopped = true; acp_runtime_detach(f.instance) }
        bridge_runtime_set_status(f.instance, "stopped", "idle")
        bridge_runtime_set_pty_process_alive(f.instance, false)
        if launch, exists := bridge_runtime_get_launch(f.instance); exists {
            bridge_runtime_remove_launch(f.instance)
            delete(launch.agent_instance_id); delete(launch.run_dir); delete(launch.launch_epoch)
            delete(launch.acp_session_id); delete(launch.pipe_generation)
        }
        delete(f.token); acp_test_delete(&f.rpc.f)
    }
    intents := make(map[string]ACP_Hub_Intent, allocator = context.temp_allocator)
    intents[f.instance] = {status = "running", epoch = "recovery_epoch", transport = "acp", run_count = 9, provider = provider, profile = provider}
    dead_child := [1]Pty_Host_Pipe_Info{{instance=f.instance, generation="old-generation", alive=false,
        meta_json=`{"launch_epoch":"recovery_epoch"}`}}
    handled := acp_runtime_reconcile("fixture-daemon", dead_child[:], intents)
    testing.expect(t, handled[f.instance] && f.spawns == 1 && f.closes == 1 && f.interrupted == 1)
    if !testing.expect(t, f.rpc.r != nil) do return
    testing.expect(t, f.rpc.r.d.token_reissued && f.rpc.r.generation == "new-generation")
    _, old_valid := bridge_agent_token_verify(old_token)
    rec, new_valid := bridge_agent_token_verify(f.token)
    testing.expect(t, !old_valid && new_valid && rec.run_count == 9 && rec.instance_token == "assertion~recovery_epoch")
    shim, read_err := os.read_entire_file(strings.concatenate({f.cwd, "/bin/ham-ctl"}, context.temp_allocator), context.temp_allocator)
    testing.expect(t, read_err == nil && strings.contains(string(shim), f.token))
    testing.expect(t, len(f.rpc.r.inbox.completed_inputs) == 1 && f.rpc.r.inbox.completed_inputs[0] == "interrupted-input")
    t4_runtime_reply(t, &f.rpc, 0, `{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"embeddedContext":true}}}`, 1)
    testing.expect(t, f.rpc.r.d.replay_only)
    t4_runtime_reply(t, &f.rpc, 1, T4_CONFIG, 2)
    t4_runtime_reply(t, &f.rpc, 2, T4_CONFIG, 3)
    writes := 4
    if provider == "claude" { t4_runtime_reply(t, &f.rpc, 3, T4_CONFIG, 4); writes = 5 }
    acp_test_wait(t, &f.rpc.f, .Writes, writes)
    testing.expect(t, acp_runtime_deliver(f.instance, "must not replay", "interrupted-input"))
    sync.mutex_lock(&f.rpc.f.mu)
    testing.expect_value(t, len(f.rpc.f.writes), writes)
    for write in f.rpc.f.writes do testing.expect(t, !strings.contains(write.bytes, "must not replay") && !strings.contains(write.bytes, "EXACT starter text"))
    if len(f.rpc.f.writes) == writes do testing.expect(t, strings.contains(f.rpc.f.writes[writes-1].bytes, "fresh text"))
    testing.expect(t, strings.contains(f.rpc.f.writes[1].bytes, "session/load"))
    sync.mutex_unlock(&f.rpc.f.mu)
    // End the successful instance before checking terminal intents independently.
    f.rpc.r.d.stopped = true; acp_runtime_detach(f.instance); f.rpc.r = nil
    for status in ([]string{"failed", "stopped", "running", "epoch_mismatch", "newer_child", "legacy_profile_mismatch", "legacy_corrupt"}) {
        terminal := T4_Recovery_Fixture{t = t, instance = fmt.tprintf("inst_t4_terminal_%s_%s", provider, status), provider = provider}
        t4_recovery_fixture = &terminal
        _ = t4_recovery_write_state(t, &terminal, "acp_protocol_error" if status == "running" else "", legacy = strings.has_prefix(status, "legacy_"))
        if status == "legacy_corrupt" {
            path, _ := acp_state_path(root, terminal.instance, "recovery_epoch"); defer delete(path)
            _ = os.write_entire_file(path, string("{corrupt"))
        }
        hub_status := "failed" if status == "failed" else "stopped" if status == "stopped" else "running"
        epoch := "newer_epoch" if status == "epoch_mismatch" else "recovery_epoch"
        clear(&intents); intents[terminal.instance] = {status = hub_status, epoch = epoch, transport = "acp", run_count = 9, provider = provider, profile = provider}
        if status == "legacy_profile_mismatch" do intents[terminal.instance] = {status = "running", epoch = epoch, transport = "acp", run_count = 9, provider = provider, profile = "work"}
        pipes: []Pty_Host_Pipe_Info
        if status == "newer_child" {
            terminal.daemon_generation = "newer-generation"
            pipes = make([]Pty_Host_Pipe_Info, 1, context.temp_allocator)
            pipes[0] = {instance = terminal.instance, generation = terminal.daemon_generation, alive = true,
                meta_json = `{"launch_epoch":"newer_epoch"}`}
        }
        acp_runtime_reconcile("fixture-daemon", pipes, intents)
        testing.expect(t, terminal.spawns == 0 && terminal.closes == 0 && terminal.interrupted == 0 && !acp_runtime_owned(terminal.instance))
        snap, exists := bridge_runtime_instance_snapshot(terminal.instance)
        // Neither a missing identity nor a different live generation proves
        // exit. An explicit stop records intent but cannot confirm the close.
        expected := "running" if status == "stopped" else "blocked"
        testing.expect(t, exists && snap.runtime_status == expected, status)
        if strings.has_prefix(status, "legacy_") do testing.expect_value(t, snap.acp_error_code, "acp_restart_required")
        if status == "failed" || status == "stopped" || status == "running" {
            handled_retry, retry_ok := acp_runtime_retry_launch(terminal.instance, "recovery_epoch", 9)
            testing.expect(t, handled_retry && !retry_ok && terminal.spawns == 0 && terminal.closes == 0)
            after, _ := bridge_runtime_instance_snapshot(terminal.instance)
            testing.expect_value(t, after.runtime_status, expected)
        }
    }
}

T4_PTY_Route_Test :: struct { done: bool }
t4_pty_route_worker :: proc(data: rawptr) {
    context.allocator = runtime.heap_allocator()
    f := cast(^T4_PTY_Route_Test)data
    bridge_pty_host_deliver_line("/no/such/pty/socket", "inst_t4_unrelated_pty", "notice")
    sync.atomic_store(&f.done, true)
}
@(test)
t4_acp_ownership_io_lock_does_not_block_pty_delivery :: proc(t: ^testing.T) {
    context.allocator = runtime.heap_allocator()
    f: T4_PTY_Route_Test
    sync.mutex_lock(&acp_runtime_mu)
    worker := thread.create_and_start_with_data(&f, t4_pty_route_worker)
    start := time.tick_now()
    for !sync.atomic_load(&f.done) && time.tick_since(start) < time.Second do time.sleep(time.Millisecond)
    finished_while_locked := sync.atomic_load(&f.done)
    sync.mutex_unlock(&acp_runtime_mu)
    thread.join(worker); thread.destroy(worker)
    testing.expect(t, finished_while_locked)
}
