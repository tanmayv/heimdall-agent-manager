package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import agent_runtime "odin_test:lib/agent_runtime"
import contracts "odin_test:contracts"

ACP_Runtime_Durable :: struct {
    phase, config_json, plan_json, starter, current_input, error: string,
    starter_sent, ready, stopped, auth_required, replay_only, embedded_context: bool,
    token_reissued: bool,
    exit_pending: bool,
    cancelling: bool,
    stream_retries: int,
    steering_supported, steering_pending: bool,
    steering_input: Bridge_Inbox_Input,
    // Inputs the outgoing prompt or steer carries. They left the inbox in
    // memory; this journal write commits that, and restore drops them from an
    // inbox file written before it (the inbox is saved after the journal).
    dispatched: [dynamic]string,
    // Owned by the protocol driver and opaque here; see the driver state procs.
    driver_state: rawptr `json:"-"`,
    // Delivery evidence sequence for this launch epoch (strictly increasing).
    report_seq: i64,
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
    descriptor: contracts.ACP_Provider_Descriptor,
    driver: ^ACP_Protocol_Driver,
    binding: ACP_Runtime_Binding,
    client: ^ACP_RPC_Client,
    chat: ^ACP_Chat,
    tools:ACP_Tool_Cache,
    permissions: [dynamic]^ACP_Permission_Worker,
    instance, epoch, generation, run_dir, state_path, provider, profile, etag, model, mode, session: string,
    initialized, load_session, recovering: bool,
    quiescing, reconnect_queued: bool,
    next_rpc_id, next_delivery_id: u64,
    saved_tools, saved_outbox: string,
    rec: Bridge_Local_Agent_Token_Record,
    d: ACP_Runtime_Durable,
    // The instance's durable inbox (bridge_inbox.odin), claimed for the life
    // of this runtime; only the dispatcher touches it.
    inbox: ^Bridge_Inbox,
    inbox_unreadable: bool,
    notice_interval_ms: i64,
    inbox_started: bool, // dispatcher enables ticks only after begin/restore
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
    return !exists || snap.stopped_intent_unix_ms == 0
}

acp_runtime_replace :: proc(target: ^string, value: string) {
    context.allocator = runtime.heap_allocator()
    if target^ == value do return
    delete(target^); target^ = strings.clone(value)
}

acp_runtime_checkpoint :: proc(data: rawptr, state: ^ACP_State) -> bool {
    r := cast(^ACP_Runtime)data
    if !acp_tools_checkpoint(r,state) do return false
    acp_runtime_replace(&state.bridge, bridge_config.daemon_id)
    acp_runtime_replace(&state.provider, r.provider); acp_runtime_replace(&state.profile, r.profile)
    acp_runtime_replace(&state.run_dir, r.run_dir); acp_runtime_replace(&state.catalog_etag, r.etag)
    state.schema_version = 3
    state.runtime_binding_version = 1
    acp_provider_binding_delete(&state.binding)
    state.binding = acp_provider_binding_copy(r.binding)
    acp_runtime_replace(&state.adapter_version, r.descriptor.pkg.version); acp_runtime_replace(&state.pipe_generation, r.generation)
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
    raw, ok := acp_runtime_durable_json(r)
    if !ok do return false
    delete(state.runtime_json); state.runtime_json = raw
    return true
}

// The journal holds the outgoing prompt; only now may the inbox file drop
// the inputs it carries. A crash between the two writes leaves them in the
// file, and restore removes them again (acp_runtime_inbox_restore).
acp_runtime_committed :: proc(data: rawptr) -> bool {
    r := cast(^ACP_Runtime)data
    if r.inbox_unreadable do return true
    r.inbox.sealed = r.inbox.sealed || r.chat != nil
    if !bridge_inbox_save(r.inbox) do return false
    acp_inbox_dispatched_clear(r)
    return true
}

// Shared durable fields plus the driver's opaque state under its key.
acp_runtime_durable_json :: proc(r: ^ACP_Runtime) -> (string, bool) {
    raw, err := json.marshal(r.d, allocator = context.temp_allocator)
    if err != nil do return "", false
    out := string(raw)
    driver := acp_runtime_driver(r)
    if driver != nil && driver.state_save != nil && r.d.driver_state != nil {
        state, saved := driver.state_save(r.d.driver_state)
        // A marshalled struct is a non-empty object ending in '}'.
        if !saved || len(out) < 3 || out[len(out)-1] != '}' do return "", false
        out = strings.concatenate({out[:len(out)-1], ",", acp_rpc_quote(driver.state_key), ":", state, "}"}, context.temp_allocator)
    }
    return strings.clone(out), true
}

// Inverse of acp_runtime_durable_json. On failure the caller still owns and
// deletes d (acp_runtime_durable_free_driver_state releases driver state).
// Shared fields use allocator; driver state is always heap-owned.
acp_runtime_durable_load :: proc(driver: ^ACP_Protocol_Driver, raw: string, d: ^ACP_Runtime_Durable, allocator := context.allocator) -> bool {
    if json.unmarshal_string(raw, d, allocator = allocator) != nil do return false
    d.driver_state = nil
    if driver == nil || driver.state_load == nil do return true
    state_json, present, extracted := acp_runtime_durable_driver_json(raw, driver.state_key)
    if !extracted do return false
    if !present do return true // no state saved yet; the driver allocates on first use
    state, ok := driver.state_load(state_json)
    d.driver_state = state
    return ok
}

// The JSON value (temp-allocated) a journal holds under the driver's
// state_key. present is false when the key is absent or null.
acp_runtime_durable_driver_json :: proc(raw, key: string) -> (state_json: string, present, ok: bool) {
    value, err := json.parse_string(raw, .JSON, true, context.temp_allocator)
    if err != nil do return "", false, false
    root, is_object := value.(json.Object)
    if !is_object do return "", false, false
    sub, found := root[key]
    if !found do return "", false, true
    if _, is_null := sub.(json.Null); is_null do return "", false, true
    // Keys sorted so the extracted text is deterministic.
    out, merr := json.marshal(sub, {sort_maps_by_key = true}, context.temp_allocator)
    if merr != nil do return "", false, false
    return string(out), true, true
}

acp_runtime_durable_free_driver_state :: proc(driver: ^ACP_Protocol_Driver, d: ^ACP_Runtime_Durable) {
    if d.driver_state != nil && driver != nil && driver.state_delete != nil do driver.state_delete(d.driver_state)
    d.driver_state = nil
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
    acp_delivery_runtime_failed(r, reason)
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
        bridge_runtime_set_status(r.instance, "blocked", "waiting_user", .waiting_user)
        acp_runtime_auth_blocker(r)
    } else {
        if !acp_runtime_close_child(r) {
            // A failed close is not a death receipt. Preserve launch ownership
            // for a later stop or reconciliation of the still-hosted process.
            bridge_runtime_set_status(r.instance, "blocked", "idle", .acp_close_unconfirmed)
            return
        }
        bridge_runtime_set_pty_process_alive(r.instance, false)
        bridge_runtime_set_status(r.instance, "stopped", "idle", .acp_error_child_closed)
        // The child is gone: a dead agent must not keep a launch record (it would
        // hold the auto-update quiet window forever, T16d). A relaunch records anew.
        bridge_runtime_remove_launch(r.instance)
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
        kind = "startup", summary = strings.concatenate({"ACP authentication required for profile ", r.profile, ". ", bridge_provider_traits(r.provider).auth_guidance}),
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
    driver := acp_runtime_driver(r)
    acp_runtime_usage(r, driver, method, params)
    driver.notification(r, method, params)
}

// Every driver's usage report reaches the extension token accumulator (one
// usage path for PTY and ACP runtimes). Replayed history is not current usage.
acp_runtime_usage :: proc(r: ^ACP_Runtime, driver: ^ACP_Protocol_Driver, method, params: string) {
    if driver.usage == nil || r.d.replay_only || r.session == "" do return
    usage, ok := driver.usage(r, method, params)
    if !ok do return
    ev := contracts.Ext_Event{kind = .Notification, provider = r.provider, session_id = r.session, has_usage = true, usage = usage}
    bridge_ext_usage_observe(r.instance, ev, bridge_runtime_now_ms())
}

acp_runtime_inbound :: proc(data: rawptr, id, method, params: string) -> bool {
    defer { delete(id); delete(method); delete(params) }
    r := cast(^ACP_Runtime)data
    return acp_runtime_driver(r).inbound(r, id, method, params)
}

acp_runtime_request :: proc(r: ^ACP_Runtime, method, params: string) -> bool {
    if !acp_runtime_current(r) || r.d.error != "" do return false
    id, sent := acp_rpc_request(r.client, method, params, 0, {acp_runtime_result, r})
    delete(string(id), runtime.heap_allocator())
    if !sent do acp_runtime_error(r, "acp_pipe_write_failed")
    return sent
}

acp_runtime_restore_completion :: proc(data: rawptr, role: ACP_RPC_Role, id: ACP_RPC_ID) -> ACP_RPC_Completion {
    delete(string(id))
    if role == .Steering do return {acp_inbox_steering_result, data}
    return {acp_runtime_result, data}
}

acp_runtime_work :: proc(data: rawptr, c: ^ACP_RPC_Client, argument: string) -> bool {
    r := cast(^ACP_Runtime)data
    if strings.has_prefix(argument,"chat_") do return acp_chat_work(r,argument)
    if argument == "can_steer" {
        // Steering capability of the current turn (CONTRACT-15): the session
        // must support it and the driver must not rule it out.
        if !acp_runtime_current(r) || !r.d.ready || r.d.error != "" || !r.d.steering_supported do return false
        driver := acp_runtime_driver(r)
        return driver.can_steer == nil || driver.can_steer(r) != .Never
    }
    if strings.has_prefix(argument, "send_now_batch:") {
        if !acp_runtime_current(r) || !r.d.ready || r.d.error != "" || r.d.exit_pending do return false
        req: ACP_Send_Now_Request
        if json.unmarshal_string(argument[len("send_now_batch:"):], &req, allocator = context.temp_allocator) != nil do return false
        return acp_send_now_apply(r, req)
    }
    if strings.has_prefix(argument, "inputs_read:") {
        if !acp_runtime_current(r) || r.d.error != "" do return false
        ids: []string
        if json.unmarshal_string(argument[len("inputs_read:"):], &ids, allocator = context.temp_allocator) != nil || len(ids) > 100 do return false
        if acp_delivery_inputs_read(r, ids) && !acp_rpc_checkpoint(r.client) { acp_runtime_error(r, "acp_state_write_failed"); return false }
        return true
    }
    switch argument {
    case "begin":
        r.inbox_started = true
        c.state.next_rpc_id = max(c.state.next_rpc_id, r.next_rpc_id)
        c.state.next_delivery_id = max(c.state.next_delivery_id, r.next_delivery_id)
        acp_runtime_replace(&c.state.tool_map_json, r.saved_tools)
        acp_runtime_replace(&c.state.chat_outbox_json, r.saved_outbox)
        return acp_runtime_driver(r).begin(r)
    case "resume":
        if !acp_runtime_current(r) || r.d.error != "" do return false
        r.inbox_started = true
        if r.d.ready && len(c.state.pending_outbound) == 0 {
            if !r.d.starter_sent { acp_runtime_ready(r) } else { acp_runtime_drain(r) }
        }
        return true
    case "inbox_tick":
        acp_runtime_drain(r)
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
        if acp_send_now_active(r) { acp_send_now_set_state(r, "failed"); acp_delivery_report(r, nil, "failed", "agent_stopped") }
        r.d.stopped = true
        acp_runtime_driver(r).permissions_cancel(r)
        // Cancel is a notification and the original prompt owns the response.
        acp_runtime_driver(r).cancel(r)
        return acp_rpc_checkpoint(c)
    case "interrupt":
        if acp_send_now_active(r) && !r.d.cancelling do acp_send_now_set_state(r, "cancelling")
        if !acp_runtime_current(r) || !r.d.ready || r.d.error != "" do return false
        r.d.cancelling = true
        acp_runtime_driver(r).permissions_cancel(r)
        return acp_runtime_driver(r).cancel(r)
    }
    return acp_inbox_accept(r, c, argument)
}

acp_runtime_command :: proc(instance, argument: string) -> bool {
    sync.mutex_lock(&acp_runtime_mu); defer sync.mutex_unlock(&acp_runtime_mu)
    r := acp_runtimes[instance]; if r == nil do return false
    cmd := ACP_RPC_Command{kind = .Runtime, a = argument, runtime_work = acp_runtime_work, runtime_data = r}
    acp_rpc_call(r.client, &cmd); return cmd.ok
}

acp_runtime_deliver :: proc(instance, text: string, input_id := "", lane: Bridge_Inbox_Lane = .Steer, key := "", kind := "", task := "", expected_state := "") -> bool {
    // Hub command/message identities survive retries. Local raw user input uses
    // a distinct prefix so legacy notice migration preserves its priority.
    id := input_id
    if id == "" do id = fmt.tprintf("%s_%d", "input" if lane == .Steer else "notice", time.tick_now()._nsec)
    raw, _ := json.marshal(Bridge_Inbox_Input{id = id, text = text, lane = lane, key = key, kind = kind, task = task, expected_state = expected_state}); defer delete(raw)
    return acp_runtime_command(instance, string(raw))
}

acp_runtime_destroy :: proc(r: ^ACP_Runtime) {
    context.allocator = runtime.heap_allocator()
    r.quiescing = true
    acp_chat_stop(r)
    acp_permissions_stop(r)
    // close rejects pending calls; they must not mutate the owner
    acp_rpc_close(r.client)
    acp_chat_destroy(r)
    acp_tools_destroy(r)
    acp_provider_binding_delete(&r.binding)
    delete(r.instance); delete(r.epoch); delete(r.generation); delete(r.run_dir); delete(r.state_path)
    delete(r.provider); delete(r.profile); delete(r.etag); delete(r.model); delete(r.mode); delete(r.session)
    delete(r.saved_tools); delete(r.saved_outbox)
    delete(r.rec.token_hash); delete(r.rec.agent_instance_id); delete(r.rec.instance_token)
    delete(r.d.phase); delete(r.d.config_json); delete(r.d.plan_json); delete(r.d.starter); delete(r.d.current_input); delete(r.d.error)
    bridge_inbox_input_delete(r.d.steering_input)
    for id in r.d.dispatched do delete(id); delete(r.d.dispatched)
    acp_runtime_durable_free_driver_state(acp_runtime_driver(r), &r.d)
    bridge_inbox_release(r.inbox)
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
    r.descriptor, _ = contracts.acp_provider_descriptor(provider)
    r.driver = acp_protocol_driver(r.descriptor.protocol)
    r.binding = acp_provider_binding_copy(acp_provider_binding(r.descriptor, profile, "", bridge_bootstrap_agents_md_name(provider)))
    r.notice_interval_ms = acp_inbox_interval()
    r.instance = strings.clone(instance); r.epoch = strings.clone(epoch); r.run_dir = strings.clone(run_dir)
    r.provider = strings.clone(provider); r.profile = strings.clone(profile); r.etag = strings.clone(etag)
    r.model = strings.clone(model); r.mode = strings.clone(mode); r.rec = bridge_startup_clone_rec(rec)
    base := bridge_shell_data_dir(); defer delete(base)
    r.state_path, _ = acp_state_path(base, instance, epoch)
    r.inbox = bridge_inbox_claim(instance, acp_agent_runtime.transport)
    if r.inbox == nil {
        // An unreadable inbox file is kept untouched; launch and restore refuse.
        r.inbox = new(Bridge_Inbox)
        r.inbox_unreadable = true
    }
    return r
}

acp_runtime_connect :: proc(r: ^ACP_Runtime, socket: string, after_seq: u64, checkpoint: string = "") -> bool {
    if acp_runtime_driver(r) == nil do return false
    if !acp_tools_prepare(r,r.saved_tools) { acp_runtime_error(r,"acp_protocol_error");return false }
    if !acp_chat_prepare(r) do return false
    io, ok := acp_pipe_io_open(socket, r.instance, r.generation, r.epoch, r.state_path, after_seq)
    if !ok do return false
    r.client, ok = acp_rpc_open(io, {data = r, checkpoint = acp_runtime_checkpoint, committed = acp_runtime_committed, notification = acp_runtime_notification,
        inbound_request = acp_runtime_inbound, inbound_timeout = acp_runtime_inbound_timeout, fault = acp_runtime_fault, restore_completion = acp_runtime_restore_completion, can_process = acp_chat_can_process, tick = acp_inbox_tick}, acp_runtime_driver(r).rpc)
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

// Both install probes and managed launches use the provider profile's resolved
// provider executable. An adapter's bundled SDK binary cannot run on every host.
acp_profile_child_env :: proc(pp: ^Provider_Profile) -> ([]string, bool) {
    context.allocator = context.temp_allocator
    env, ok := profile_child_env(pp); if !ok do return nil, false
    d, known := contracts.acp_provider_descriptor(pp.provider)
    if !known do return nil, false
    resolved, found := bridge_provider_resolve_binary(bridge_provider_descriptor(d.provider), pp, env)
    if !found do return nil, false
    defer delete(resolved)
    return acp_descriptor_child_env(env, d, resolved), true
}

// The one ACP child environment: a profile child env plus the descriptor's
// fixed pairs and, for an adapter, the resolved provider CLI under
// executable_env. Managed launches, install probes and ACP model discovery all
// build it here (temp-allocated).
acp_descriptor_child_env :: proc(env: []string, d: contracts.ACP_Provider_Descriptor, binary: string) -> []string {
    plan := Profile_Env_Plan{set = make([dynamic][2]string, context.temp_allocator)}
    for pair in d.env do append(&plan.set, pair)
    if d.executable_env != "" && binary != "" do append(&plan.set, [2]string{d.executable_env, binary})
    return profile_apply_env_plan(env, plan)
}

acp_runtime_build_spawn :: proc(r: ^ACP_Runtime, endpoint, token: string, pp: ^Provider_Profile) -> (Pty_Host_Spawn_Request, bool) {
    context.allocator = context.temp_allocator
    env, ok := acp_profile_child_env(pp); if !ok do return {}, false
    // Use the same authoritative profile and desktop context as the TUI path.
    bootstrap := bridge_prespawn_env(r.run_dir, endpoint, token, r.instance)
    defer { for e in bootstrap do delete(e); delete(bootstrap) }
    plan := Profile_Env_Plan{}
    for entry in bootstrap {
        eq := strings.index_byte(entry, '=')
        append(&plan.set, [2]string{entry[:eq], entry[eq+1:]})
    }
    append(&plan.set, [2]string{"HEIMDALL_STARTUP_KEY", r.rec.token_hash}, [2]string{"HEIMDALL_RUNTIME_TRANSPORT", "acp"})
    full := profile_apply_env_plan(env, plan)
    pairs := bridge_pty_host_env_pairs(full)
    root := acp_adapter_root(pp.provider)
    meta, _ := json.marshal(struct{effective_transport, launch_epoch, state_path: string}{"acp", r.epoch, r.state_path})
    d, known := contracts.acp_provider_descriptor(pp.provider)
    if !known do return {}, false
    resolved := ""
    if d.launch == .System {
        resolved, _ = bridge_provider_resolve_binary(bridge_provider_descriptor(d.provider), pp, full)
    }
    argv, built := acp_provider_launch_argv(d, root, resolved)
    if !built do return {}, false
    return {mode = .Pipe, instance = r.instance, argv = argv, env = pairs, cwd = r.run_dir, has_cwd = true,
        meta_json = string(meta), has_meta = true}, true
}

// acp_runtime_inbox_relaunch: the inbox outlives launches. A Send now batch
// of the replaced launch is over: its members go back to ordinary queued
// inputs.
acp_runtime_inbox_relaunch :: proc(r: ^ACP_Runtime) {
    if !acp_send_now_active(r) do return
    bridge_inbox_send_now_set_state(r.inbox, "failed")
    for &input in r.inbox.queue do if input.kind == BRIDGE_INBOX_SEND_NOW_KIND do acp_runtime_replace(&input.kind, "")
}

acp_runtime_launch :: proc(command, instance, epoch, etag, run_dir, endpoint, provider, model, token, permission_mode, profile: string) -> (bool, string, Bridge_Error) {
    context.allocator = runtime.heap_allocator()
    if !acp_state_component_ok(epoch) do return false, "invalid_launch_epoch", bridge_error(.agent_launch_failed, .unsupported)
    catalog, supported := acp_adapter_recipe(provider)
    current := bridge_provider_catalog_current_etag(); defer delete(current)
    if !supported || current != etag do return false, "provider_catalog_stale", bridge_error(.agent_launch_failed, .unsupported)
    d, _ := contracts.acp_provider_descriptor(provider)
    mode, mode_ok := contracts.acp_descriptor_permission_mode(d, permission_mode)
    pp, perr := profile_lookup(provider, profile)
    if !mode_ok || perr != .None || (model != "" && !profile_has_model(&pp, provider, model)) do return false, "invalid_acp_configuration", bridge_error(.agent_launch_failed, .unsupported)
    status := acp_adapter_status(provider, pp.profile_id)
    if !status.installed || status.state == "installing" || status.state == "missing_node" do return false, "acp_adapter_unavailable", bridge_error(.agent_launch_failed, .unsupported)
    binding, bound := acp_provider_profile_binding(&pp)
    if !bound || !acp_adapter_ensure_profile(&pp, binding) do return false, "acp_adapter_unavailable", bridge_error(.agent_launch_failed, .unsupported)
    rec, valid := bridge_agent_token_verify(token)
    if !valid do return false, "invalid_agent_token", bridge_error(.agent_launch_failed, .denied)
    socket, daemon := bridge_pty_host_ensure_daemon()
    if !daemon || !pty_host_supports_pipes(socket) do return false, "unsupported_runtime_transport", bridge_error(.agent_launch_failed, .unsupported)
    acp_runtime_detach(instance)
    r := acp_runtime_new(instance, epoch, run_dir, provider, pp.profile_id, etag, model, mode, rec)
    acp_provider_binding_delete(&r.binding); r.binding = acp_provider_binding_copy(binding)
    r.d.phase = strings.clone("initialize"); r.d.starter = strings.clone(catalog.starter_prompt)
    if r.state_path == "" || r.inbox_unreadable { acp_runtime_destroy(r); return false, "acp_state_write_failed", bridge_error(.agent_launch_failed) }
    acp_runtime_inbox_relaunch(r)
    initial := ACP_State{schema_version = 1, instance = strings.clone(instance), launch_epoch = strings.clone(epoch), effective_transport = strings.clone("acp"), next_rpc_id = 1, next_delivery_id = 1}
    acp_runtime_checkpoint(r, &initial)
    written := acp_state_write(r.state_path, &initial); acp_state_delete(&initial)
    if !written { acp_runtime_destroy(r); return false, "acp_state_write_failed", bridge_error(.agent_launch_failed) }
    req, built := acp_runtime_build_spawn(r, endpoint, token, &pp)
    if !built { acp_runtime_destroy(r); return false, "provider_missing", bridge_error(.provider_missing) }
    // This is a genuine new launch; common launch identity handling has already
    // refused unrelated live children before bootstrap/token replacement.
    bridge_startup_begin(token)
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
        effective_transport = "acp", launch_epoch = strings.clone(epoch), pipe_generation = strings.clone(r.generation), adapter_version = r.descriptor.pkg.version,
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

// Shared by every driver once its session accepts input: persist, publish
// readiness, then send the one-time starter prompt or drain queued input.
acp_runtime_session_ready :: proc(r: ^ACP_Runtime, starter_links_bootstrap: bool) {
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
        acp_runtime_prompt(r, {id = "starter", text = agent_runtime.render_acp_starter_prompt(r.d.starter, starter_links_bootstrap)}, bootstrap = true)
    } else {
        acp_runtime_drain(r)
    }
}

// Result/steering callbacks transfer their heap-owned result to the driver.
acp_runtime_result :: proc(data: rawptr, result: ACP_RPC_Result) {
    acp_runtime_driver(cast(^ACP_Runtime)data).result(data, result)
}
acp_runtime_prompt :: proc(r: ^ACP_Runtime, input: Bridge_Inbox_Input, bootstrap := false) {
    acp_runtime_driver(r).prompt(r, input, bootstrap)
}
acp_runtime_ready :: proc(r: ^ACP_Runtime) {
    acp_runtime_driver(r).ready(r)
}
acp_runtime_inbound_timeout :: proc(data: rawptr, id: string) {
    acp_runtime_driver(cast(^ACP_Runtime)data).inbound_timeout(data, id)
}
