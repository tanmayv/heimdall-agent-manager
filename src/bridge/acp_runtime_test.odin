package main

import contracts "odin_test:contracts"

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

T4_CONFIG :: `{"configOptions":[{"id":"actual-model","category":"model","type":"select","currentValue":"sonnet","options":[{"group":"Claude","options":[{"value":"sonnet","name":"Sonnet"}]}]},{"id":"actual-mode","category":"mode","type":"select","currentValue":"default","options":[{"value":"default","name":"Ask"},{"value":"bypassPermissions","name":"Bypass"}]}]}`

@(test)
c2_acp_copilot_auth_required_uses_trusted_profile_guidance :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous }
    instance := "inst_c2_auth_guidance"
    f: T4_Runtime_Test; t4_runtime_open(&f, instance, "/unused", "copilot")
    acp_runtime_replace(&f.r.profile, "work")
    defer { f.r.d.stopped = true; acp_runtime_destroy(f.r); acp_test_delete(&f.f); bridge_permission_test_reset(instance); bridge_runtime_set_status(instance,"stopped","idle") }
    testing.expect(t, acp_runtime_request(f.r,"session/new","{}"))
    if !acp_test_wait(t,&f.f,.Writes,1) do return
    testing.expect(t,f.r.client.io.feed(f.r.client,`{"jsonrpc":"2.0","id":"ham:t4_epoch:1","error":{"code":-32000,"message":"untrusted-login-command synthetic-secret"}}`+"\n",1))
    acp_test_wait(t,&f.f,.Acks,1)
    blockers:=bridge_blockers_list(instance)
    testing.expect(t,len(blockers)==1)
    if len(blockers)==1 {
        testing.expect(t,blockers[0].kind=="startup" && strings.contains(blockers[0].summary,"profile work"))
        testing.expect(t,strings.contains(blockers[0].summary,"copilot login") && strings.contains(blockers[0].summary,"COPILOT_HOME"))
        testing.expect(t,!strings.contains(blockers[0].summary,"untrusted-login-command") && !strings.contains(blockers[0].summary,"synthetic-secret"))
    }
    testing.expect(t,f.r.d.auth_required && !f.r.d.ready)
}

@(test)
c2_acp_once_only_configures_exact_model_without_permission_mode_rpc :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous }
    f: T4_Runtime_Test; t9_fixture_open(&f, "inst_c2_config"); defer t9_fixture_close(&f)
    f.r.descriptor.permission_policy = .Once_Only
    f.r.descriptor.permission_category = ""
    acp_runtime_replace(&f.r.mode, "ask")
    acp_runtime_replace(&f.r.d.phase, "new")
    f.r.d.ready = false
    testing.expect(t, acp_runtime_request(f.r, "session/new", "{}"))
    config :: `{"configOptions":[{"id":"advertised-model","category":"model","type":"select","currentValue":"sonnet","options":[{"value":"sonnet"}]}]}`
    t4_runtime_reply(t, &f, 0, strings.concatenate({`{"sessionId":"s",`, config[1:]}, context.temp_allocator), 1)
    t4_runtime_reply(t, &f, 1, config, 2)
    testing.expect(t, t4_runtime_call(&f, "resume"))
    testing.expect(t, f.r.d.ready && f.r.d.error == "")
    sync.mutex_lock(&f.f.mu)
    testing.expect_value(t, len(f.f.writes), 2)
    testing.expect(t, strings.contains(f.f.writes[1].bytes, `"configId":"advertised-model"`))
    sync.mutex_unlock(&f.f.mu)
}

@(test)
t4_acp_durable_driver_rejects_unbounded_and_unknown_state :: proc(t: ^testing.T) {
    d := ACP_Runtime_Durable{phase = "ready"}
    testing.expect(t, acp_runtime_durable_valid(&d))
    d.phase = "invented"; testing.expect(t, !acp_runtime_durable_valid(&d)); d.phase = "ready"
    d.error = "untrusted diagnostic"; testing.expect(t, !acp_runtime_durable_valid(&d)); d.error = ""
    d.stream_retries = -1; testing.expect(t, !acp_runtime_durable_valid(&d)); d.stream_retries = 0
    d.queue = make([dynamic]ACP_Runtime_Input, 129, allocator = context.temp_allocator)
    for &input in d.queue do input = {id = "id", text = "text"}
    testing.expect(t, !acp_runtime_durable_valid(&d))
    resize(&d.queue, 128); testing.expect(t, acp_runtime_durable_valid(&d))
    d.queue[0].id = ""; testing.expect(t, !acp_runtime_durable_valid(&d)); d.queue[0].id = "id"
    d.queue[0].text = string(make([]byte, 256*1024+1, context.temp_allocator)); testing.expect(t, !acp_runtime_durable_valid(&d))
    d.queue[0].text = "text"
    d.completed_inputs = make([dynamic]string, 257, allocator = context.temp_allocator)
    testing.expect(t, !acp_runtime_durable_valid(&d))
    testing.expect(t, !acp_adapter_node_compatible("v22.0.secret") && !acp_adapter_node_compatible("v22.0.0\nsecret"))
}

@(test)
t4_acp_config_exact_grouped_selection_and_modes :: proc(t: ^testing.T) {
    id, ok := acp_config_selection(T4_CONFIG, "model", "sonnet", true); defer delete(id)
    testing.expect(t, ok && id == "actual-model")
    absent, found := acp_config_selection(T4_CONFIG, "model", "opus"); delete(absent); testing.expect(t, !found)
    mode, valid := contracts.acp_descriptor_permission_mode(contracts.ACP_CLAUDE_DESCRIPTOR, "ask"); testing.expect(t, valid && mode == "default")
    mode, valid = contracts.acp_descriptor_permission_mode(contracts.ACP_CLAUDE_DESCRIPTOR, "yolo"); testing.expect(t, valid && mode == "bypassPermissions")
    _, valid = contracts.acp_descriptor_permission_mode(contracts.ACP_CLAUDE_DESCRIPTOR, "auto"); testing.expect(t, !valid)
    unavailable, _ := strings.replace_all(T4_CONFIG, "bypassPermissions", "policy-disabled"); defer delete(unavailable)
    missing, offered := acp_config_selection(unavailable, "mode", "bypassPermissions"); delete(missing); testing.expect(t, !offered)
    duplicate := `{"configOptions":[{"id":"a","category":"model","type":"select","options":[{"value":"sonnet"}]},{"id":"b","category":"model","type":"select","options":[{"value":"sonnet"}]}]}`
    ambiguous, accepted := acp_config_selection(duplicate, "model", "sonnet"); delete(ambiguous); testing.expect(t, !accepted)
    wrong, returned := acp_config_selection(T4_CONFIG, "mode", "bypassPermissions", true); delete(wrong); testing.expect(t, !returned)
}

@(test)
t4_acp_bootstrap_replaces_chat_send_preserves_tasks :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    input := strings.concatenate({"TASK.md\nMEMORY.md\n", acp_bootstrap_communication_marker, " ...\nALWAYS reply with `chat send`.\n\nNext section\n"}); defer delete(input)
    output := bridge_bootstrap_acp_instructions(input); defer delete(output)
    testing.expect(t, strings.contains(output, "session prompts") && strings.contains(output, "natural assistant text"))
    testing.expect(t, !strings.contains(output, "ALWAYS reply with"))
    testing.expect(t, strings.contains(output, "TASK.md") && strings.contains(output, "MEMORY.md") && strings.contains(output, "heimdall-acp-bootstrap-v1") && strings.contains(output, "Next section"))
    d := bridge_bootstrap_descriptor_from_launch(`{"payload":{"agent_instance_id":"inst_t4","effective_transport":"acp"}}`)
    testing.expect_value(t, d.effective_transport, "acp")
}

// Guard: render the REAL bootstrap frame, not the replace constant. T4 reworded
// the paragraph in bootstrap_agents.md and the exact-string replace silently
// stopped matching; this fails if the frame and the replace ever drift again.
@(test)
t7_acp_bootstrap_real_frame_drops_pty_reply_rule :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    frame := string(#load("../prompts/bootstrap_agents.md", string))
    testing.expect(t, strings.contains(frame, "ALWAYS reply with"), "frame no longer holds the PTY rule; update this test")
    output := bridge_bootstrap_acp_instructions(frame)
    testing.expect(t, !strings.contains(output, "ALWAYS reply with"), "PTY reply rule survived ACP rewrite")
    testing.expect(t, !strings.contains(output, "chat send --to user --body \"<your reply>\""))
    testing.expect(t, strings.contains(output, "Your natural assistant text reaches user chat automatically"))
    testing.expect(t, strings.contains(output, "Do not echo ordinary answers with chat send"))
    // Rewrite stops at the paragraph: following sections stay intact.
    testing.expect(t, strings.contains(output, "### Response format: ALWAYS use Markdown (REQUIRED)"))
    testing.expect(t, strings.contains(output, "## Communicating with the user (REQUIRED)"))
    testing.expect_value(t, strings.count(output, "Your natural assistant text reaches user chat automatically"), 2) // inline + v1 trailer
}

// A template without the chat-send paragraph (e.g. a bot) must not free the
// caller's body, which the caller frees afterwards (double free on launch).
@(test)
t4_acp_bootstrap_without_chat_send_keeps_caller_body :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    input := strings.clone("# Bot bootstrap\nNo chat-send guidance here.\n")
    output := bridge_bootstrap_acp_instructions(input)
    delete(input)
    testing.expect(t, strings.has_prefix(output, "# Bot bootstrap\nNo chat-send guidance here.\n"))
    testing.expect(t, strings.contains(output, "heimdall-acp-bootstrap-v1"))
    delete(output)
    testing.expect_value(t, len(track.bad_free_array), 0)
}

T4_Runtime_Test :: struct { r: ^ACP_Runtime, f: ACP_Test }
t4_runtime_checkpoint :: proc(data: rawptr, state: ^ACP_State) -> bool {
    fixture := cast(^T4_Runtime_Test)data
    return acp_runtime_checkpoint(fixture.r, state) && acp_test_checkpoint(&fixture.f, state)
}

t4_runtime_open :: proc(f: ^T4_Runtime_Test, instance, cwd: string, provider: string = "claude") {
    context.allocator = runtime.heap_allocator()
    rec := Bridge_Local_Agent_Token_Record{agent_instance_id = instance, token_hash = "t4-token", instance_token = "t4-assertion", role = .Agent}
    sync.mutex_lock(&bridge_local_token_mutex)
    append(&bridge_local_token_records, rec)
    sync.mutex_unlock(&bridge_local_token_mutex)
    sync.mutex_lock(&bridge_runtime_mutex)
    bridge_startup_begin_locked(rec, bridge_runtime_now_ms())
    sync.mutex_unlock(&bridge_runtime_mutex)
    d, _ := contracts.acp_provider_descriptor(provider)
    mode, _ := contracts.acp_descriptor_permission_mode(d, "ask")
    f.r = acp_runtime_new(instance, "t4_epoch", cwd, provider, provider, "sha256:test", "sonnet", mode, rec)
    acp_runtime_replace(&f.r.binding.cli_version, d.cli_version if d.cli_version != "" else "2.1.70")
    f.r.d.phase = strings.clone("initialize"); f.r.d.starter = strings.clone("EXACT starter text")
    f.r.client, _ = acp_rpc_open({data = &f.f, instance = instance, launch_epoch = "t4_epoch", write = acp_test_write, ack = acp_test_ack, close = acp_test_close},
        {data = f, checkpoint = t4_runtime_checkpoint, restore_completion = t4_runtime_restore_completion})
}

t4_runtime_restore_completion :: proc(data: rawptr, role: ACP_RPC_Role, id: ACP_RPC_ID) -> ACP_RPC_Completion {
    f := cast(^T4_Runtime_Test)data
    return acp_runtime_restore_completion(f.r, role, id)
}

t4_runtime_call :: proc(f: ^T4_Runtime_Test, argument: string) -> bool {
    cmd := ACP_RPC_Command{kind = .Runtime, a = argument, runtime_work = acp_runtime_work, runtime_data = f.r}
    acp_rpc_call(f.r.client, &cmd); return cmd.ok
}

@(test)
t4_acp_reconcile_stop_fences_owner_without_daemon_child :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous_records }
    f: T4_Runtime_Test; t4_runtime_open(&f, "inst_t4_stopped_absent", "/unused/bootstrap")
    defer acp_test_delete(&f.f)
    sync.mutex_lock(&acp_runtime_mu)
    previous_runtimes := acp_runtimes
    acp_runtimes = make(map[string]^ACP_Runtime, allocator = runtime.heap_allocator())
    acp_runtimes[f.r.instance] = f.r
    sync.mutex_unlock(&acp_runtime_mu)
    defer {
        sync.mutex_lock(&acp_runtime_mu); delete(acp_runtimes); acp_runtimes = previous_runtimes; sync.mutex_unlock(&acp_runtime_mu)
    }
    intents := make(map[string]ACP_Hub_Intent, allocator = context.temp_allocator)
    intents["inst_t4_stopped_absent"] = {status = "stopped", epoch = "t4_epoch", transport = "acp"}
    handled := acp_runtime_reconcile("", nil, intents, lifecycle_held = true)
    testing.expect(t, handled["inst_t4_stopped_absent"] && !acp_runtime_owned("inst_t4_stopped_absent"))
    snap, present := bridge_runtime_instance_snapshot("inst_t4_stopped_absent")
    testing.expect(t, present && snap.stopped_intent_unix_ms != 0 && snap.runtime_status == "stopped" && !snap.pty_process_alive)
}

t4_runtime_reply :: proc(t: ^testing.T, f: ^T4_Runtime_Test, index: int, result: string, seq: u64) {
    if !acp_test_wait(t, &f.f, .Writes, index+1) do return
    sync.mutex_lock(&f.f.mu)
    line := strings.clone(f.f.writes[index].bytes)
    sync.mutex_unlock(&f.f.mu)
    defer delete(line)
    id := bridge_provider_json_extract_string(line, "id", ""); defer delete(id)
    response := acp_test_response(ACP_RPC_ID(id), result)
    f.r.client.io.feed(f.r.client, response, seq)
    acp_test_wait(t, &f.f, .Acks, int(seq))
}

@(test)
t4_acp_runtime_setup_first_prompt_queue_cancel_and_stop_fence :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous_records }
    cwd := fmt.tprintf("%s/.cache/heimdall-tests/t4-bootstrap-%d", os.get_env("HOME", context.temp_allocator), sync.current_thread_id())
    bridge_make_directory_all(cwd); defer os.remove_all(cwd)
    testing.expect(t, os.write_entire_file(strings.concatenate({cwd, "/CUSTOM.md"}, context.temp_allocator), string("unique marker")) == nil)
    f: T4_Runtime_Test; t4_runtime_open(&f, "inst_t4_runtime", cwd)
    acp_runtime_replace(&f.r.binding.bootstrap_filename, "CUSTOM.md")
    defer { f.r.d.stopped = true; acp_runtime_destroy(f.r); acp_test_delete(&f.f) }
    testing.expect(t, acp_runtime_request(f.r, "initialize", ACP_INITIALIZE_PARAMS))
    t4_runtime_reply(t, &f, 0, `{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"embeddedContext":true}}}`, 1)
    t4_runtime_reply(t, &f, 1, strings.concatenate({`{"sessionId":"session-t4",`, T4_CONFIG[1:]}, context.temp_allocator), 2)
    t4_runtime_reply(t, &f, 2, T4_CONFIG, 3)
    t4_runtime_reply(t, &f, 3, T4_CONFIG, 4)
    if !acp_test_wait(t, &f.f, .Writes, 5) do return
    sync.mutex_lock(&f.f.mu)
    testing.expect(t, strings.contains(f.f.writes[1].bytes, acp_rpc_quote(cwd)))
    testing.expect(t, strings.contains(f.f.writes[1].bytes, `"mcpServers":[]`))
    testing.expect(t, strings.contains(f.f.writes[2].bytes, `"configId":"actual-model"`))
    testing.expect(t, strings.contains(f.f.writes[3].bytes, `"configId":"actual-mode"`))
    testing.expect(t, strings.contains(f.f.writes[4].bytes, "EXACT starter text") && strings.contains(f.f.writes[4].bytes, "unique marker") && strings.contains(f.f.writes[4].bytes, "/CUSTOM.md"))
    sync.mutex_unlock(&f.f.mu)
    snapshot, ready := bridge_runtime_instance_snapshot("inst_t4_runtime")
    testing.expect(t, ready && snapshot.start_success_seen && snapshot.runtime_status == "running")
    testing.expect(t, t4_runtime_call(&f, `{"id":"input-one","text":"queued next"}`))
    testing.expect(t, t4_runtime_call(&f, `{"id":"input-one","text":"duplicate"}`))
    t4_runtime_reply(t, &f, 4, `{"stopReason":"end_turn"}`, 5)
    if !acp_test_wait(t, &f.f, .Writes, 6) do return
    testing.expect(t, t4_runtime_call(&f, "interrupt"))
    if !acp_test_wait(t, &f.f, .Writes, 7) do return
    sync.mutex_lock(&f.f.mu)
    cancel := f.f.writes[6].bytes
    testing.expect(t, strings.contains(cancel, `"method":"session/cancel"`) && !strings.contains(cancel, `"id":`))
    sync.mutex_unlock(&f.f.mu)
    t4_runtime_reply(t, &f, 5, `{"stopReason":"cancelled"}`, 6)
    testing.expect(t, t4_runtime_call(&f, `{"id":"input-one","text":"duplicate completed"}`))
    testing.expect(t, t4_runtime_call(&f, "stop"))
    testing.expect(t, !t4_runtime_call(&f, `{"id":"late","text":"must not run"}`))
    sync.mutex_lock(&f.f.mu); testing.expect_value(t, f.f.order_errors, 0); sync.mutex_unlock(&f.f.mu)
}

@(test)
t4_acp_token_reissue_fences_old_same_launch :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    context.allocator = runtime.heap_allocator()
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
    defer {
        for rec in bridge_local_token_records { delete(rec.token_hash); delete(rec.agent_instance_id); delete(rec.instance_token) }
        delete(bridge_local_token_records); bridge_local_token_records = previous_records
    }
    previous := bridge_config
    defer { bridge_config = previous }
    dir := fmt.tprintf("%s/.cache/heimdall-tests/t4-token-%d", os.get_env("HOME", context.temp_allocator), sync.current_thread_id())
    bridge_make_directory_all(dir); defer os.remove_all(dir)
    bridge_config.data_dir = dir; bridge_config.daemon_id = "brg_test_t4_tokens"
    old := bridge_agent_token_issue("inst_t4_reissue", "assertion~same_epoch", .Agent, 9)
    rec, valid := bridge_agent_token_verify(old.plaintext_token); testing.expect(t, valid)
    next := acp_runtime_reissue_token(rec)
    _, old_valid := bridge_agent_token_verify(old.plaintext_token)
    current, new_valid := bridge_agent_token_verify(next.plaintext_token)
    testing.expect(t, !old_valid && new_valid && current.run_count == 9 && current.instance_token == "assertion~same_epoch")
    bridge_agent_token_invalidate_instance("inst_t4_reissue")
}

@(test)
t4_acp_node_versions_and_intent_epochs :: proc(t: ^testing.T) {
    for v in ([]string{"v22.0.0", "v24.1.2\n"}) do testing.expect(t, acp_adapter_node_compatible(v))
    for v in ([]string{"v20.19.0", "", "not-node", "v22"}) do testing.expect(t, !acp_adapter_node_compatible(v))
    intents := bridge_agent_reconcile_acp_intents(`[{"agent_instance_id":"inst_a","launch_epoch":"epoch_a","runtime_transport":"acp","runtime_status":"stopped","run_count":7}]`)
    testing.expect(t, intents["inst_a"].epoch == "epoch_a" && intents["inst_a"].run_count == 7 && intents["inst_a"].status == "stopped")
    testing.expect(t, !bridge_startup_fallback_due({runtime_transport = "acp"}, 10000))
    testing.expect_value(t, bridge_runtime_activity_source_rank("acp"), 80)
}

@(test)
t4_acp_live_restore_keeps_session_without_initialize_or_new_prompt :: proc(t: ^testing.T) {
    c2_test_live_restore(t, "claude")
}

@(test)
c2_acp_copilot_live_pipe_restore_does_not_reprompt_or_reinitialize :: proc(t: ^testing.T) {
    c2_test_live_restore(t, "copilot")
}

c2_test_live_restore :: proc(t: ^testing.T, provider: string) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous_records }
    f: T4_Runtime_Test; t4_runtime_open(&f, "inst_t4_restore", "/unused/bootstrap", provider)
    r := f.r
    r.initialized = true; r.load_session = true; r.session = strings.clone("existing-session", runtime.heap_allocator())
    r.d.ready = true; r.d.starter_sent = true
    acp_runtime_replace(&r.d.phase, "prompt")
    acp_runtime_replace(&r.d.current_input, "existing-turn")
    id, sent := acp_rpc_request(r.client, "session/prompt", `{"sessionId":"existing-session","prompt":[{"type":"text","text":"already executed"}]}`, 0, {acp_runtime_result, r})
    testing.expect(t, sent)
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    sync.mutex_lock(&f.f.mu); delivery := strings.clone(f.f.writes[0].delivery_id, runtime.heap_allocator()); sync.mutex_unlock(&f.f.mu)
    acp_rpc_enqueue_frame(r.client, {kind = .Receipt, bytes = delivery})
    testing.expect(t, t4_runtime_call(&f, "resume")) // serial barrier after receipt
    delete(delivery, runtime.heap_allocator())
    sync.mutex_lock(&f.f.mu); checkpoint := strings.clone(f.f.snapshot, runtime.heap_allocator()); sync.mutex_unlock(&f.f.mu)
    defer delete(checkpoint, runtime.heap_allocator())
    state, valid := acp_state_decode(checkpoint); testing.expect(t, valid)
    defer acp_state_delete(&state)
    testing.expect(t, state.initialized && state.sessionId == "existing-session" && len(state.pending_writes) == 0)
    r.quiescing = true; acp_runtime_destroy(r); acp_test_delete(&f.f)
    next: T4_Runtime_Test; t4_runtime_open(&next, "inst_t4_restore", "/unused/bootstrap", provider)
    defer { next.r.d.stopped = true; acp_runtime_destroy(next.r); acp_test_delete(&next.f) }
    next.r.initialized = true; next.r.load_session = true; next.r.session = strings.clone("existing-session", runtime.heap_allocator())
    // Restore runtime fields before restoring semantic RPC completions.
    delete(next.r.d.phase, runtime.heap_allocator()); delete(next.r.d.starter, runtime.heap_allocator())
    next.r.d = {}
    testing.expect(t, json.unmarshal_string(state.runtime_json, &next.r.d, allocator = runtime.heap_allocator()) == nil)
    testing.expect(t, acp_rpc_restore(next.r.client, checkpoint))
    sync.mutex_lock(&next.f.mu); testing.expect_value(t, len(next.f.writes), 0); sync.mutex_unlock(&next.f.mu)
    testing.expect(t, t4_runtime_call(&next, "resume"))
    // A completion for the original ID finishes the existing turn; no new
    // initialize, new, load or starter prompt was generated during reattachment.
    next.r.client.io.feed(next.r.client, acp_test_response(id, `{"stopReason":"end_turn"}`), 1)
    acp_test_wait(t, &next.f, .Acks, 1)
    delete(string(id), runtime.heap_allocator())
    testing.expect(t, next.r.session == "existing-session" && next.r.d.phase == "ready")
    sync.mutex_lock(&next.f.mu); testing.expect_value(t, len(next.f.writes), 0); sync.mutex_unlock(&next.f.mu)
}

@(test)
t4_acp_child_loss_load_is_replay_only_and_preserves_rpc_counter :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous_records }
    f: T4_Runtime_Test; t4_runtime_open(&f, "inst_t4_load", "/saved/bootstrap")
    defer { f.r.d.stopped = true; acp_runtime_destroy(f.r); acp_test_delete(&f.f) }
    f.r.recovering = true; f.r.load_session = true; f.r.d.starter_sent = true
    f.r.session = strings.clone("saved-session", runtime.heap_allocator()); f.r.next_rpc_id = 40
    testing.expect(t, t4_runtime_call(&f, "begin"))
    t4_runtime_reply(t, &f, 0, `{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}`, 1)
    testing.expect(t, f.r.d.replay_only)
    if !acp_test_wait(t, &f.f, .Writes, 2) do return
    sync.mutex_lock(&f.f.mu)
    testing.expect(t, strings.contains(f.f.writes[0].bytes, `"id":"ham:t4_epoch:40"`))
    testing.expect(t, strings.contains(f.f.writes[1].bytes, `"method":"session/load"`) && strings.contains(f.f.writes[1].bytes, `"sessionId":"saved-session"`) && strings.contains(f.f.writes[1].bytes, `"mcpServers":[]`))
    sync.mutex_unlock(&f.f.mu)
    t4_runtime_reply(t, &f, 1, T4_CONFIG, 2)
    testing.expect(t, !f.r.d.replay_only)
    t4_runtime_reply(t, &f, 2, T4_CONFIG, 3); t4_runtime_reply(t, &f, 3, T4_CONFIG, 4)
    sync.mutex_lock(&f.f.mu); testing.expect_value(t, len(f.f.writes), 4); sync.mutex_unlock(&f.f.mu)
    testing.expect(t, f.r.d.ready && f.r.d.starter_sent && f.r.session == "saved-session")
}

@(test)
t4_acp_auth_blocks_and_missing_bootstrap_capability_never_readies :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous_records }
    f: T4_Runtime_Test; t4_runtime_open(&f, "inst_t4_auth", "/unused")
    defer { f.r.d.stopped = true; acp_runtime_destroy(f.r); acp_test_delete(&f.f); bridge_runtime_set_status("inst_t4_auth", "stopped", "idle") }
    testing.expect(t, acp_runtime_request(f.r, "initialize", ACP_INITIALIZE_PARAMS))
    if !acp_test_wait(t, &f.f, .Writes, 1) do return
    f.r.client.io.feed(f.r.client, "{\"jsonrpc\":\"2.0\",\"id\":\"ham:t4_epoch:1\",\"error\":{\"code\":-32000,\"message\":\"Authentication required\"}}\n", 1)
    acp_test_wait(t, &f.f, .Acks, 1)
    snap, _ := bridge_runtime_instance_snapshot("inst_t4_auth")
    testing.expect(t, snap.runtime_status == "blocked" && !snap.start_success_seen && snap.acp_error_code == "acp_auth_required")
    blockers := bridge_blockers_list("inst_t4_auth")
    testing.expect(t, len(blockers) == 1 && blockers[0].kind == "startup")
    next: T4_Runtime_Test; t4_runtime_open(&next, "inst_t4_bootstrap_missing", "/unused")
    defer { next.r.d.stopped = true; acp_runtime_destroy(next.r); acp_test_delete(&next.f) }
    testing.expect(t, acp_runtime_request(next.r, "initialize", ACP_INITIALIZE_PARAMS))
    t4_runtime_reply(t, &next, 0, `{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}`, 1)
    snap, _ = bridge_runtime_instance_snapshot("inst_t4_bootstrap_missing")
    testing.expect(t, snap.runtime_status == "failed" && !snap.start_success_seen && snap.acp_error_code == "acp_bootstrap_unsupported")
    sync.mutex_lock(&next.f.mu); testing.expect_value(t, len(next.f.writes), 1); sync.mutex_unlock(&next.f.mu)
    // A terminal result must persist failure even if no later RPC is sent.
    sync.mutex_lock(&next.f.mu); saved := strings.clone(next.f.snapshot); sync.mutex_unlock(&next.f.mu)
    defer delete(saved)
    state, valid := acp_state_decode(saved); defer acp_state_delete(&state)
    testing.expect(t, valid)
    error_code := bridge_provider_json_extract_string(state.runtime_json, "error", ""); defer delete(error_code)
    testing.expect_value(t, error_code, "acp_bootstrap_unsupported")
}

@(test)
t4_acp_recovered_first_starter_requires_bootstrap_resource :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous_records }
    for embedded in ([]bool{true, false}) {
        cwd := fmt.tprintf("%s/.cache/heimdall-tests/t4-first-starter-%d", os.get_env("HOME", context.temp_allocator), time.tick_now()._nsec)
        bridge_make_directory_all(cwd); defer os.remove_all(cwd)
        _ = os.write_entire_file(strings.concatenate({cwd, "/CLAUDE.md"}, context.temp_allocator), string("unique bootstrap marker"))
        f: T4_Runtime_Test; t4_runtime_open(&f, "inst_t4_first_embedded" if embedded else "inst_t4_first_unsupported", cwd)
        f.r.recovering = true; f.r.session = strings.clone("loaded-before-starter", runtime.heap_allocator())
        testing.expect(t, t4_runtime_call(&f, "begin"))
        init := `{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"embeddedContext":true}}}` if embedded else `{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}`
        t4_runtime_reply(t, &f, 0, init, 1)
        t4_runtime_reply(t, &f, 1, T4_CONFIG, 2)
        t4_runtime_reply(t, &f, 2, T4_CONFIG, 3)
        t4_runtime_reply(t, &f, 3, T4_CONFIG, 4)
        if embedded {
            acp_test_wait(t, &f.f, .Writes, 5)
            sync.mutex_lock(&f.f.mu)
            testing.expect(t, len(f.f.writes) == 5)
            if len(f.f.writes) == 5 do testing.expect(t, strings.contains(f.f.writes[4].bytes, `"type":"resource"`) && strings.contains(f.f.writes[4].bytes, "unique bootstrap marker") && strings.contains(f.f.writes[4].bytes, "EXACT starter text"))
            sync.mutex_unlock(&f.f.mu)
        } else {
            testing.expect_value(t, f.r.d.error, "acp_bootstrap_unsupported")
            sync.mutex_lock(&f.f.mu); testing.expect_value(t, len(f.f.writes), 4); sync.mutex_unlock(&f.f.mu)
        }
        f.r.d.stopped = true; acp_runtime_destroy(f.r); acp_test_delete(&f.f)
    }
}

KIRO_TEST_SESSION :: `{"sessionId":"kiro-session","configOptions":[{"id":"model","category":"model","type":"select","currentValue":"auto","options":[{"value":"auto","name":"Auto"}]}]}`

// Kiro does not advertise embeddedContext signed out, so its descriptor opts in
// to the baseline resource_link bootstrap; its default model sends no
// set_config_option. Claude/Copilot keep failing closed (tests above).
@(test)
acp_kiro_bootstrap_resource_link_and_agent_default_model :: proc(t: ^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
    previous_records := bridge_local_token_records
    bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, allocator = runtime.heap_allocator())
    defer { delete(bridge_local_token_records); bridge_local_token_records = previous_records }
    for model in ([]string{"default", "unlisted-model"}) {
        cwd := fmt.tprintf("%s/.cache/heimdall-tests/kiro-bootstrap-%d", os.get_env("HOME", context.temp_allocator), time.tick_now()._nsec)
        bridge_make_directory_all(cwd); defer os.remove_all(cwd)
        _ = os.write_entire_file(strings.concatenate({cwd, "/AGENTS.md"}, context.temp_allocator), string("unique kiro bootstrap marker"))
        instance := "inst_kiro_default_model" if model == "default" else "inst_kiro_unlisted_model"
        f: T4_Runtime_Test; t4_runtime_open(&f, instance, cwd, "kiro")
        acp_runtime_replace(&f.r.model, model)
        acp_runtime_replace(&f.r.binding.cli_version, "3.5.0"); acp_runtime_replace(&f.r.binding.bootstrap_filename, "AGENTS.md")
        testing.expect(t, t4_runtime_call(&f, "begin"))
        t4_runtime_reply(t, &f, 0, `{"protocolVersion":1,"agentCapabilities":{"loadSession":false,"promptCapabilities":{"image":false,"audio":false,"embeddedContext":false}}}`, 1)
        t4_runtime_reply(t, &f, 1, KIRO_TEST_SESSION, 2)
        if model == "default" {
            if acp_test_wait(t, &f.f, .Writes, 3) {
                sync.mutex_lock(&f.f.mu)
                prompt := f.f.writes[2].bytes
                testing.expect(t, strings.contains(prompt, `"session/prompt"`) && strings.contains(prompt, "EXACT starter text"))
                testing.expect(t, strings.contains(prompt, `"type":"resource_link"`) && strings.contains(prompt, `"name":"AGENTS.md"`))
                testing.expect(t, strings.contains(prompt, strings.concatenate({"file://", cwd, "/AGENTS.md"}, context.temp_allocator)))
                testing.expect(t, !strings.contains(prompt, "unique kiro bootstrap marker") && !strings.contains(prompt, `"type":"resource"`))
                for write in f.f.writes do testing.expect(t, !strings.contains(write.bytes, "set_config_option"))
                sync.mutex_unlock(&f.f.mu)
            }
            testing.expect(t, f.r.d.ready && f.r.d.error == "")
        } else {
            testing.expect_value(t, f.r.d.error, "acp_model_unavailable")
        }
        f.r.d.stopped = true; acp_runtime_destroy(f.r); acp_test_delete(&f.f); bridge_runtime_set_status(instance, "stopped", "idle")
    }
}
