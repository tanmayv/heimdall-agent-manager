package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

ACP_Runtime_Input :: struct { id, text: string }
ACP_Runtime_Durable :: struct {
    phase, config_json, plan_json, starter, current_input, error: string,
    starter_sent, ready, stopped, auth_required, replay_only, embedded_context: bool,
    queue: [dynamic]ACP_Runtime_Input,
    completed_inputs: [dynamic]string,
    token_reissued: bool,
    exit_pending: bool,
    stream_retries: int,
}

// T5 attaches telemetry/chat handling here. Hooks execute only on the instance
// dispatcher and must honor replay_only. No RPC pointer escapes in a launch copy.
ACP_Runtime_Events :: struct {
    notification: proc(r: ^ACP_Runtime, method, params: string),
    prompt_started: proc(r: ^ACP_Runtime, input_id: string),
    prompt_finished: proc(r: ^ACP_Runtime, input_id, result, error: string),
}
acp_runtime_events := ACP_Runtime_Events{acp_events_notification, acp_events_prompt_started, acp_events_prompt_finished}

ACP_Runtime :: struct {
    client: ^ACP_RPC_Client,
    chat: ^ACP_Chat,
    instance, epoch, generation, run_dir, state_path, provider, profile, etag, model, mode, session: string,
    initialized, load_session, recovering: bool,
    quiescing, reconnect_queued: bool,
    next_rpc_id, next_delivery_id: u64,
    saved_tools, saved_outbox: string,
    rec: Bridge_Local_Agent_Token_Record,
    d: ACP_Runtime_Durable,
}

// The ownership mutex quiesces external producers before closing a client.
// Callbacks never take it. PTY routing reads the runtime transport flag instead
// of taking this mutex, so ACP I/O cannot stall unrelated PTY deliveries.
acp_runtime_mu: sync.Mutex
acp_runtimes: map[string]^ACP_Runtime

acp_runtime_owned :: proc(instance: string) -> bool {
    sync.mutex_lock(&acp_runtime_mu); defer sync.mutex_unlock(&acp_runtime_mu)
    return acp_runtimes[instance] != nil
}

acp_runtime_current :: proc(r: ^ACP_Runtime) -> bool {
    if r.quiescing || r.d.stopped || !bridge_startup_rec_current(r.rec) do return false
    snap, exists := bridge_runtime_instance_snapshot(r.instance)
    return !exists || (snap.stopped_intent_unix_ms == 0 && snap.runtime_status != "stopping" && snap.runtime_status != "stopped" && snap.runtime_status != "failed")
}

acp_runtime_replace :: proc(target: ^string, value: string) {
    context.allocator = runtime.heap_allocator()
    if target^ == value do return
    delete(target^); target^ = strings.clone(value)
}

acp_runtime_checkpoint :: proc(data: rawptr, state: ^ACP_State) -> bool {
    r := cast(^ACP_Runtime)data
    acp_runtime_replace(&state.bridge, bridge_config.daemon_id)
    acp_runtime_replace(&state.provider, r.provider); acp_runtime_replace(&state.profile, r.profile)
    acp_runtime_replace(&state.run_dir, r.run_dir); acp_runtime_replace(&state.catalog_etag, r.etag)
    acp_runtime_replace(&state.adapter_version, ACP_CLAUDE_VERSION); acp_runtime_replace(&state.pipe_generation, r.generation)
    acp_runtime_replace(&state.sessionId, r.session); acp_runtime_replace(&state.selected_model, r.model)
    acp_runtime_replace(&state.selected_mode, r.mode)
    state.initialized = r.initialized; state.loadSession = r.load_session
    sync.mutex_lock(&bridge_runtime_mutex)
    for &launch in bridge_runtime_launches {
        if launch.agent_instance_id == r.instance && launch.launch_epoch == r.epoch {
            acp_runtime_replace(&launch.acp_session_id, r.session)
            launch.acp_load_session = r.load_session
        }
    }
    sync.mutex_unlock(&bridge_runtime_mutex)
    if r.chat != nil {
        state.seal_journal = true
        acp_runtime_replace(&state.chat_outbox_json, acp_event_json(r.chat.d))
    }
    raw, err := json.marshal(r.d)
    if err != nil do return false
    delete(state.runtime_json); state.runtime_json = string(raw)
    return true
}

acp_runtime_close_child :: proc(r: ^ACP_Runtime) -> bool {
    if r.generation == "" do return true // no owned child before successful SpawnPipe
    socket, ok := acp_runtime_io.ensure_daemon(); if !ok do return false
    frame := pty_host_encode_pipe_request({kind = .List}); defer delete(frame)
    reply, received := acp_runtime_io.request(socket, frame, 2000)
    defer pty_host_reply_delete(reply)
    if !received || reply.kind != .Pipe_List do return false
    for pipe in reply.pipes {
        if pipe.instance != r.instance do continue
        if pipe.generation != r.generation do return false
        return acp_runtime_io.close_child(socket, r.instance)
    }
    return true
}

acp_runtime_error :: proc(r: ^ACP_Runtime, reason: string, auth := false) {
    if r.d.stopped || r.d.error != "" do return
    current := acp_runtime_current(r)
    acp_runtime_replace(&r.d.error, reason)
    r.d.auth_required = auth; r.d.ready = false
    // Persist before closing the child or publishing failure. Result callbacks
    // can return without sending another RPC, so no later checkpoint is implied.
    if r.client != nil do acp_rpc_checkpoint(r.client)
    if !current do return
    if acp_runtime_events.prompt_finished != nil && r.d.current_input != "" {
        acp_runtime_events.prompt_finished(r, r.d.current_input, "", reason)
    }
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances {
        if inst.agent_instance_id == r.instance { bridge_runtime_replace_acp_error(&inst, reason); inst.acp_session_ready = false }
    }
    sync.mutex_unlock(&bridge_runtime_mutex)
    if auth {
        bridge_runtime_set_status(r.instance, "blocked", "waiting_user")
        acp_runtime_auth_blocker(r)
    } else {
        acp_runtime_close_child(r)
        bridge_runtime_set_pty_process_alive(r.instance, false)
        bridge_runtime_set_status(r.instance, "failed", "idle")
    }
}

acp_runtime_auth_blocker :: proc(r: ^ACP_Runtime) {
    context.allocator = runtime.heap_allocator()
    hash := bridge_local_hash_token(r.epoch); defer delete(hash)
    id := strings.concatenate({"acpauth_", strings.trim_prefix(hash, "sha1:")})
    sync.mutex_lock(&bridge_permission_mutex)
    defer sync.mutex_unlock(&bridge_permission_mutex)
    for p in bridge_permission_pending { if p.agent_instance_id == r.instance && p.request_id == id { delete(id); return } }
    append(&bridge_permission_pending, Bridge_Permission_Pending{
        request_id = id, agent_instance_id = strings.clone(r.instance), provider = strings.clone(r.provider),
        kind = "startup", summary = "ACP authentication required. Run claude /login on the bridge host, then restart this instance.",
        input = `{"reason":"acp_auth_required","actions":[]}`, created_unix_ms = bridge_runtime_now_ms(), generation = 1,
    })
    bridge_blockers_touch_locked(r.instance)
}

acp_runtime_fault :: proc(data: rawptr, reason: string) {
    defer delete(reason)
    r := cast(^ACP_Runtime)data
    if r.quiescing do return
    if (reason == "acp_pipe_lost" || reason == "acp_pipe_gap") && !r.d.stopped && !r.quiescing && r.d.error == "" {
        acp_runtime_schedule_recovery(r, reason == "acp_pipe_gap")
        return
    }
    acp_runtime_error(r, reason)
    acp_rpc_checkpoint(r.client)
}

acp_runtime_notification :: proc(data: rawptr, method, params: string) {
    defer { delete(method); delete(params) }
    r := cast(^ACP_Runtime)data
    if !acp_runtime_current(r) || r.d.error != "" do return
    if acp_runtime_events.notification != nil do acp_runtime_events.notification(r, method, params)
}

acp_runtime_inbound :: proc(data: rawptr, id, method, params: string) -> bool {
    defer { delete(id); delete(method); delete(params) }
    r := cast(^ACP_Runtime)data
    if method != "session/request_permission" do return false
    obj := acp_event_object(params)
    if acp_event_string(obj, "sessionId") != r.session { acp_rpc_reply_error(r.client,id,{code=-32602,message="wrong ACP session"}); return true }
    // MVP policy: no interactive permission flow. In particular, never select
    // allow_always when an adapter unexpectedly asks despite bypass mode.
    acp_rpc_reply(r.client, id, `{"outcome":{"outcome":"cancelled"}}`)
    acp_events_permission(r, params)
    return true
}

acp_runtime_request :: proc(r: ^ACP_Runtime, method, params: string) -> bool {
    if !acp_runtime_current(r) || r.d.error != "" do return false
    id, sent := acp_rpc_request(r.client, method, params, 0, {acp_runtime_result, r})
    delete(string(id), runtime.heap_allocator())
    if !sent do acp_runtime_error(r, "acp_pipe_write_failed")
    return sent
}

acp_runtime_session_params :: proc(r: ^ACP_Runtime) -> string {
    raw, _ := json.marshal(struct{cwd: string, mcpServers: []string}{r.run_dir, {}} , allocator = context.temp_allocator)
    return string(raw)
}

acp_runtime_configure :: proc(r: ^ACP_Runtime, category, value, failure: string) {
    id, ok := acp_config_selection(r.d.config_json, category, value)
    defer delete(id)
    if !ok { acp_runtime_error(r, failure); return }
    acp_runtime_replace(&r.d.phase, category)
    raw, _ := json.marshal(struct{sessionId, configId, value: string}{r.session, id, value}, allocator = context.temp_allocator)
    acp_runtime_request(r, "session/set_config_option", string(raw))
}

acp_runtime_ready :: proc(r: ^ACP_Runtime) {
    if !r.d.starter_sent && !r.d.embedded_context { acp_runtime_error(r, "acp_bootstrap_unsupported"); return }
    r.d.ready = true
    acp_events_ready(r)
    acp_runtime_replace(&r.d.phase, "ready")
    if !acp_rpc_checkpoint(r.client) { acp_runtime_error(r, "acp_state_write_failed"); return }
    if !acp_runtime_current(r) do return
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == r.instance do inst.acp_session_ready = true
    sync.mutex_unlock(&bridge_runtime_mutex)
    bridge_startup_accept(r.rec, bridge_runtime_now_ms())
    bridge_runtime_mark_start_success(r.instance)
    if !r.d.starter_sent {
        r.d.starter_sent = true
        acp_runtime_prompt(r, {"starter", r.d.starter}, bootstrap = true)
    } else {
        acp_runtime_drain(r)
    }
}

acp_runtime_prompt :: proc(r: ^ACP_Runtime, input: ACP_Runtime_Input, bootstrap := false) {
    acp_runtime_replace(&r.d.phase, "prompt")
    acp_runtime_replace(&r.d.current_input, input.id)
    blocks := make([dynamic]json.Value, allocator = context.temp_allocator)
    text := make(json.Object, allocator = context.temp_allocator)
    text["type"] = json.String("text"); text["text"] = json.String(input.text); append(&blocks, text)
    if bootstrap {
        if !r.d.embedded_context { acp_runtime_error(r, "acp_bootstrap_unsupported"); return }
        content, err := os.read_entire_file(strings.concatenate({r.run_dir, "/CLAUDE.md"}, context.temp_allocator), context.temp_allocator)
        if err != nil { acp_runtime_error(r, "acp_bootstrap_unsupported"); return }
        resource := make(json.Object, allocator = context.temp_allocator)
        resource["uri"] = json.String(strings.concatenate({"file://", r.run_dir, "/CLAUDE.md"}, context.temp_allocator))
        resource["mimeType"] = json.String("text/markdown"); resource["text"] = json.String(string(content))
        block := make(json.Object, allocator = context.temp_allocator); block["type"] = json.String("resource"); block["resource"] = resource
        append(&blocks, block)
    }
    raw, _ := json.marshal(struct{sessionId: string, prompt: []json.Value}{r.session, blocks[:]}, allocator = context.temp_allocator)
    if acp_runtime_events.prompt_started != nil do acp_runtime_events.prompt_started(r, input.id)
    if acp_runtime_request(r, "session/prompt", string(raw)) {
        bridge_runtime_note_agent_activity(r.instance, "active", "acp")
    }
}

acp_runtime_drain :: proc(r: ^ACP_Runtime) {
    if r.chat != nil && (!acp_chat_vault_ready() || acp_chat_bytes(r.chat) > 1536*1024) do return
    if !r.d.ready || r.d.phase == "prompt" || r.d.error != "" || r.d.exit_pending || len(r.d.queue) == 0 do return
    input := r.d.queue[0]; ordered_remove(&r.d.queue, 0)
    defer { delete(input.id); delete(input.text) }
    acp_runtime_prompt(r, input)
}

acp_runtime_result :: proc(data: rawptr, result: ACP_RPC_Result) {
    defer acp_rpc_result_delete(result)
    r := cast(^ACP_Runtime)data
    if !acp_runtime_current(r) || r.d.error != "" do return
    if !result.ok {
        // A failed attachment does not prove process death. The owner replaces
        // the RPC connection from its last checkpoint after this callback exits.
        if result.error.message == "acp_pipe_lost" || result.error.message == "acp_pipe_gap" do return
        // Local RPC shutdown/timeouts use -32000 too; they are never auth.
        local := strings.has_prefix(result.error.message, "acp_")
        safe_reason := "acp_rpc_failed"
        switch result.error.message {
        case "acp_pipe_lost", "acp_pipe_write_failed", "acp_adapter_exited", "acp_rpc_timeout", "acp_protocol_error", "acp_state_write_failed": safe_reason = result.error.message
        }
        acp_runtime_error(r, "acp_auth_required" if result.error.code == -32000 && !local else safe_reason, auth = result.error.code == -32000 && !local)
        return
    }
    root, err := json.parse(result.result_json, parse_integers = true)
    if err != nil { acp_runtime_error(r, "acp_protocol_error"); return }
    defer json.destroy_value(root)
    obj, valid := root.(json.Object)
    if !valid { acp_runtime_error(r, "acp_protocol_error"); return }
    switch r.d.phase {
    case "initialize":
        version, _ := obj["protocolVersion"].(json.Integer)
        if version != 1 { acp_runtime_error(r, "acp_protocol_error"); return }
        r.initialized = true
        caps, _ := obj["agentCapabilities"].(json.Object)
        load, _ := caps["loadSession"].(json.Boolean); r.load_session = bool(load)
        prompts, _ := caps["promptCapabilities"].(json.Object)
        embedded, _ := prompts["embeddedContext"].(json.Boolean); r.d.embedded_context = bool(embedded)
        if r.recovering {
            if !r.load_session { acp_runtime_error(r, "acp_pipe_lost"); return }
            r.d.replay_only = true; acp_runtime_replace(&r.d.phase, "load")
            raw, _ := json.marshal(struct{sessionId, cwd: string, mcpServers: []string}{r.session, r.run_dir, {}}, allocator = context.temp_allocator)
            acp_runtime_request(r, "session/load", string(raw))
        } else {
            if !r.d.embedded_context { acp_runtime_error(r, "acp_bootstrap_unsupported"); return }
            acp_runtime_replace(&r.d.phase, "new")
            acp_runtime_request(r, "session/new", acp_runtime_session_params(r))
        }
    case "new", "load":
        if r.d.phase == "new" {
            session, _ := obj["sessionId"].(json.String)
            if session == "" { acp_runtime_error(r, "acp_protocol_error"); return }
            acp_runtime_replace(&r.session, string(session))
        }
        r.d.replay_only = false
        acp_runtime_replace(&r.d.config_json, result.result_json)
        if r.model != "" { acp_runtime_configure(r, "model", r.model, "acp_model_unavailable") }
        else { acp_runtime_configure(r, "mode", r.mode, "acp_permission_mode_unsupported") }
    case "model", "mode":
        category := r.d.phase
        value := r.model if category == "model" else r.mode
        id, selected := acp_config_selection(result.result_json, category, value, selected = true); delete(id)
        if !selected { acp_runtime_error(r, "acp_model_unavailable" if category == "model" else "acp_permission_mode_unsupported"); return }
        acp_runtime_replace(&r.d.config_json, result.result_json)
        if category == "model" { acp_runtime_configure(r, "mode", r.mode, "acp_permission_mode_unsupported") }
        else { acp_runtime_ready(r) }
    case "prompt":
        reason, _ := obj["stopReason"].(json.String)
        switch string(reason) {
        case "end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled":
        case: acp_runtime_error(r, "acp_protocol_error"); return
        }
        if acp_runtime_events.prompt_finished != nil do acp_runtime_events.prompt_finished(r, r.d.current_input, result.result_json, "")
        append(&r.d.completed_inputs, strings.clone(r.d.current_input))
        if len(r.d.completed_inputs) > 256 { delete(r.d.completed_inputs[0]); ordered_remove(&r.d.completed_inputs, 0) }
        acp_runtime_replace(&r.d.current_input, ""); acp_runtime_replace(&r.d.phase, "ready")
        bridge_runtime_note_agent_activity(r.instance, "idle", "acp")
        acp_runtime_drain(r)
    }
}

acp_runtime_restore_completion :: proc(data: rawptr, _: ACP_RPC_Role, id: ACP_RPC_ID) -> ACP_RPC_Completion {
    delete(string(id)); return {acp_runtime_result, data}
}

acp_runtime_work :: proc(data: rawptr, c: ^ACP_RPC_Client, argument: string) -> bool {
    r := cast(^ACP_Runtime)data
    if strings.has_prefix(argument,"chat_") do return acp_chat_work(r,argument)
    switch argument {
    case "begin":
        c.state.next_rpc_id = max(c.state.next_rpc_id, r.next_rpc_id)
        c.state.next_delivery_id = max(c.state.next_delivery_id, r.next_delivery_id)
        acp_runtime_replace(&c.state.tool_map_json, r.saved_tools)
        acp_runtime_replace(&c.state.chat_outbox_json, r.saved_outbox)
        return acp_runtime_request(r, "initialize", ACP_INITIALIZE_PARAMS)
    case "resume":
        if !acp_runtime_current(r) || r.d.error != "" do return false
        if r.d.ready && len(c.state.pending_outbound) == 0 {
            if !r.d.starter_sent { acp_runtime_ready(r) } else { acp_runtime_drain(r) }
        }
        return true
    case "exit":
        socket, ok := bridge_pty_host_ensure_daemon(); if !ok do return false
        frame := pty_host_encode_pipe_request({kind = .List}); defer delete(frame)
        reply, got := pty_host_request_deadline(socket, frame, 2000); defer pty_host_reply_delete(reply)
        if !got || reply.kind != .Pipe_List do return false
        for pipe in reply.pipes {
            if pipe.instance == r.instance && (pipe.generation != r.generation || pipe.alive) do return true
        }
        r.d.exit_pending = true
        return acp_pipe_io_child_exited(cast(^ACP_Pipe_IO)c.io.data)
    case "stop":
        if r.d.current_input!="" && acp_runtime_events.prompt_finished!=nil do acp_runtime_events.prompt_finished(r,r.d.current_input,`{"stopReason":"cancelled"}`,"")
        r.d.stopped = true
        for p in c.state.pending_inbound {
            if p.response_json == "" && p.method == "session/request_permission" do acp_rpc_reply(c, p.id_json, `{"outcome":{"outcome":"cancelled"}}`)
        }
        // Cancel is a notification and the original prompt owns the response.
        raw, _ := json.marshal(struct{sessionId: string}{r.session}, allocator = context.temp_allocator)
        acp_rpc_notify(c, "session/cancel", string(raw))
        return acp_rpc_checkpoint(c)
    case "interrupt":
        if !acp_runtime_current(r) || !r.d.ready || r.d.error != "" do return false
        raw, _ := json.marshal(struct{sessionId: string}{r.session}, allocator = context.temp_allocator)
        return acp_rpc_notify(c, "session/cancel", string(raw))
    }
    if !acp_runtime_current(r) || r.d.error != "" || r.d.exit_pending || len(r.d.queue) >= 128 || len(argument) > 256*1024 do return false
    input: ACP_Runtime_Input
    if json.unmarshal_string(argument, &input) != nil { delete(input.id); delete(input.text); return false }
    if input.id == "" || len(input.id) > 1024 { delete(input.id); delete(input.text); return false }
    duplicate := input.id == r.d.current_input
    for entry in r.d.queue do if entry.id == input.id do duplicate = true
    for id in r.d.completed_inputs do if id == input.id do duplicate = true
    for id in c.state.queued_input_message_ids do if id == input.id do duplicate = true
    if duplicate { delete(input.id); delete(input.text); return true }
    append(&r.d.queue, input)
    if r.chat!=nil && strings.has_prefix(input.id,"msg_") do append(&c.state.queued_input_message_ids,strings.clone(input.id))
    if !acp_rpc_checkpoint(c) { acp_runtime_error(r, "acp_state_write_failed"); return false }
    acp_runtime_drain(r)
    return true
}

acp_runtime_command :: proc(instance, argument: string) -> bool {
    sync.mutex_lock(&acp_runtime_mu); defer sync.mutex_unlock(&acp_runtime_mu)
    r := acp_runtimes[instance]; if r == nil do return false
    cmd := ACP_RPC_Command{kind = .Runtime, a = argument, runtime_work = acp_runtime_work, runtime_data = r}
    acp_rpc_call(r.client, &cmd); return cmd.ok
}

acp_runtime_deliver :: proc(instance, text: string, input_id := "") -> bool {
    // The delivery identity is supplied by T5 direct input; legacy notifications
    // are queued exactly as their PTY notice text, without terminal keystrokes.
    id := input_id
    if id == "" do id = fmt.tprintf("notice_%d", time.tick_now()._nsec)
    raw, _ := json.marshal(ACP_Runtime_Input{id, text}); defer delete(raw)
    return acp_runtime_command(instance, string(raw))
}

acp_runtime_destroy :: proc(r: ^ACP_Runtime) {
    context.allocator = runtime.heap_allocator()
    r.quiescing = true
    acp_chat_stop(r)
    // close rejects pending calls; they must not mutate the owner
    acp_rpc_close(r.client)
    acp_chat_destroy(r)
    delete(r.instance); delete(r.epoch); delete(r.generation); delete(r.run_dir); delete(r.state_path)
    delete(r.provider); delete(r.profile); delete(r.etag); delete(r.model); delete(r.mode); delete(r.session)
    delete(r.saved_tools); delete(r.saved_outbox)
    delete(r.rec.token_hash); delete(r.rec.agent_instance_id); delete(r.rec.instance_token)
    delete(r.d.phase); delete(r.d.config_json); delete(r.d.plan_json); delete(r.d.starter); delete(r.d.current_input); delete(r.d.error)
    for input in r.d.queue { delete(input.id); delete(input.text) }; delete(r.d.queue)
    for id in r.d.completed_inputs do delete(id); delete(r.d.completed_inputs)
    free(r)
}

acp_runtime_detach :: proc(instance: string) {
    context.allocator = runtime.heap_allocator()
    sync.mutex_lock(&acp_runtime_mu); defer sync.mutex_unlock(&acp_runtime_mu)
    r := acp_runtimes[instance]; if r == nil do return
    delete_key(&acp_runtimes, r.instance)
    acp_runtime_destroy(r)
}

acp_runtime_new :: proc(instance, epoch, run_dir, provider, profile, etag, model, mode: string, rec: Bridge_Local_Agent_Token_Record) -> ^ACP_Runtime {
    context.allocator = runtime.heap_allocator()
    r := new(ACP_Runtime)
    r.instance = strings.clone(instance); r.epoch = strings.clone(epoch); r.run_dir = strings.clone(run_dir)
    r.provider = strings.clone(provider); r.profile = strings.clone(profile); r.etag = strings.clone(etag)
    r.model = strings.clone(model); r.mode = strings.clone(mode); r.rec = bridge_startup_clone_rec(rec)
    base := bridge_shell_data_dir(); defer delete(base)
    r.state_path, _ = acp_state_path(base, instance, epoch)
    return r
}

acp_runtime_connect :: proc(r: ^ACP_Runtime, socket: string, after_seq: u64, checkpoint: string = "") -> bool {
    if !acp_chat_prepare(r) do return false
    io, ok := acp_pipe_io_open(socket, r.instance, r.generation, r.epoch, r.state_path, after_seq)
    if !ok do return false
    r.client, ok = acp_rpc_open(io, {data = r, checkpoint = acp_runtime_checkpoint, notification = acp_runtime_notification,
        inbound_request = acp_runtime_inbound, fault = acp_runtime_fault, restore_completion = acp_runtime_restore_completion, can_process = acp_chat_can_process})
    if !ok { io.close(io.data); io.destroy(io.data); return false }
    if checkpoint != "" {
        if !acp_rpc_restore(r.client, checkpoint) do return false
        acp_chat_run(r)
        return true
    }
    cmd := ACP_RPC_Command{kind = .Runtime, a = "begin", runtime_work = acp_runtime_work, runtime_data = r}
    acp_rpc_call(r.client, &cmd)
    if cmd.ok do acp_chat_run(r)
    return cmd.ok
}

acp_runtime_build_spawn :: proc(r: ^ACP_Runtime, endpoint, token: string, pp: ^Provider_Profile) -> (Pty_Host_Spawn_Request, bool) {
    context.allocator = context.temp_allocator
    env, ok := profile_child_env(pp); if !ok do return {}, false
    binary := "claude"
    if pp.config.binary_path != "" do binary = pp.config.binary_path
    resolved := profile_resolve_binary(binary, env)
    if resolved == "" do return {}, false
    bootstrap := bridge_prespawn_env(r.run_dir, endpoint, token, r.instance)
    defer { for e in bootstrap do delete(e); delete(bootstrap) }
    plan := Profile_Env_Plan{}
    for entry in bootstrap {
        eq := strings.index_byte(entry, '=')
        append(&plan.set, [2]string{entry[:eq], entry[eq+1:]})
    }
    append(&plan.set, [2]string{"CLAUDE_AGENT_ACP_PROTOCOL", "v1"}, [2]string{"CLAUDE_CODE_EXECUTABLE", resolved}, [2]string{"HEIMDALL_STARTUP_KEY", r.rec.token_hash}, [2]string{"HEIMDALL_RUNTIME_TRANSPORT", "acp"})
    full := profile_apply_env_plan(env, plan)
    pairs := bridge_pty_host_env_pairs(full)
    root := acp_adapter_root()
    meta, _ := json.marshal(struct{effective_transport, launch_epoch, state_path: string}{"acp", r.epoch, r.state_path})
    argv := make([]string, 1); argv[0] = acp_adapter_bin(root)
    return {mode = .Pipe, instance = r.instance, argv = argv, env = pairs, cwd = r.run_dir, has_cwd = true,
        meta_json = string(meta), has_meta = true}, true
}

acp_runtime_launch :: proc(command, instance, epoch, etag, run_dir, endpoint, provider, model, token, permission_mode, profile: string) -> (bool, string, Bridge_Error) {
    context.allocator = runtime.heap_allocator()
    if !acp_state_component_ok(epoch) do return false, "invalid_launch_epoch", bridge_error(.agent_launch_failed, .unsupported)
    catalog, supported := acp_adapter_recipe(provider)
    current := bridge_provider_catalog_current_etag(); defer delete(current)
    if !supported || current != etag do return false, "provider_catalog_stale", bridge_error(.agent_launch_failed, .unsupported)
    status := acp_adapter_status(provider)
    if status.state != "ready" do return false, "acp_adapter_unavailable", bridge_error(.agent_launch_failed, .unsupported)
    mode, mode_ok := acp_claude_permission_mode(permission_mode)
    pp, perr := profile_lookup(provider, profile)
    if !mode_ok || perr != .None || (model != "" && !profile_has_model(&pp, provider, model)) do return false, "invalid_acp_configuration", bridge_error(.agent_launch_failed, .unsupported)
    rec, valid := bridge_agent_token_verify(token)
    if !valid do return false, "invalid_agent_token", bridge_error(.agent_launch_failed, .denied)
    socket, daemon := bridge_pty_host_ensure_daemon()
    if !daemon || !pty_host_supports_pipes(socket) do return false, "unsupported_runtime_transport", bridge_error(.agent_launch_failed, .unsupported)
    acp_runtime_detach(instance)
    r := acp_runtime_new(instance, epoch, run_dir, provider, pp.profile_id, etag, model, mode, rec)
    r.d.phase = strings.clone("initialize"); r.d.starter = strings.clone(catalog.starter_prompt)
    if r.state_path == "" { acp_runtime_destroy(r); return false, "acp_state_write_failed", bridge_error(.agent_launch_failed) }
    initial := ACP_State{schema_version = 1, instance = strings.clone(instance), launch_epoch = strings.clone(epoch), effective_transport = strings.clone("acp"), next_rpc_id = 1, next_delivery_id = 1}
    acp_runtime_checkpoint(r, &initial)
    written := acp_state_write(r.state_path, &initial); acp_state_delete(&initial)
    if !written { acp_runtime_destroy(r); return false, "acp_state_write_failed", bridge_error(.agent_launch_failed) }
    req, built := acp_runtime_build_spawn(r, endpoint, token, &pp)
    if !built { acp_runtime_destroy(r); return false, "provider_missing", bridge_error(.provider_missing) }
    // This is a genuine new launch; common launch identity handling has already
    // refused unrelated live children before bootstrap/token replacement.
    bridge_startup_set_expectation(instance, token, false)
    bridge_startup_arm(instance, token, bridge_runtime_now_ms())
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == instance { inst.runtime_transport = "acp"; inst.acp_session_ready = false; bridge_runtime_replace_acp_error(&inst, "") }
    sync.mutex_unlock(&bridge_runtime_mutex)
    reply, spawned := pty_host_spawn_pipe(socket, req)
    defer pty_host_reply_delete(reply)
    if !spawned || reply.kind != .Spawned || reply.generation == "" { acp_runtime_destroy(r); return false, "acp_spawn_failed", bridge_error(.agent_launch_failed, .spawn) }
    r.generation = strings.clone(reply.generation)
    bridge_runtime_set_pty_process_alive(instance, true)
    bridge_startup_spawned(instance, token, reply.pid)
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == instance do inst.runtime_transport = "acp"
    sync.mutex_unlock(&bridge_runtime_mutex)
    bridge_runtime_record_launch({agent_instance_id = strings.clone(instance), command_id = strings.clone(command), run_dir = strings.clone(run_dir),
        effective_transport = "acp", launch_epoch = strings.clone(epoch), pipe_generation = strings.clone(r.generation), adapter_version = ACP_CLAUDE_VERSION,
        launched_at_ns = time.tick_now()._nsec})
    sync.mutex_lock(&acp_runtime_mu)
    if acp_runtimes == nil do acp_runtimes = make(map[string]^ACP_Runtime)
    acp_runtimes[r.instance] = r
    connected := acp_runtime_connect(r, socket, 0)
    sync.mutex_unlock(&acp_runtime_mu)
    if !connected { acp_runtime_close_child(r); acp_runtime_detach(instance); return false, "acp_pipe_lost", bridge_error(.agent_launch_failed) }
    bridge_pty_host_events_ensure()
    bridge_task_wake_note_launched(instance)
    return true, "", {}
}
