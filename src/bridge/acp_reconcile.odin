package main

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import vm "core:mem/virtual"
import contracts "odin_test:contracts"

ACP_Hub_Intent :: struct { status, epoch, transport: string, run_count: int, provider, profile: string }

// Process-boundary seams keep recovery orchestration testable without a real
// Claude process. Journal, token rotation, shims and dispatcher stay real.
ACP_Runtime_IO :: struct {
    ensure_daemon: proc() -> (string, bool),
    request: proc(socket: string, frame: []byte, timeout_ms: int) -> (Pty_Host_Reply, bool),
    close_child: proc(socket, instance: string) -> bool,
    spawn: proc(socket: string, req: Pty_Host_Spawn_Request) -> (Pty_Host_Reply, bool),
    endpoint: proc() -> (string, bool),
    connect: proc(r: ^ACP_Runtime, socket: string, after_seq: u64, checkpoint: string) -> bool,
}
acp_runtime_io := ACP_Runtime_IO{bridge_pty_host_ensure_daemon, pty_host_request_deadline, bridge_pty_host_close,
    pty_host_spawn_pipe, bridge_runtime_ensure_local_endpoint, acp_runtime_connect}

acp_runtime_terminal_error :: proc(d: ^ACP_Runtime_Durable) -> bool {
    return d.error != "" && !d.auth_required
}

ACP_Runtime_Recovery_Job :: struct { instance, epoch, generation: string, force_load: bool }
acp_runtime_schedule_recovery :: proc(r: ^ACP_Runtime, force_load: bool) {
    context.allocator = runtime.heap_allocator()
    if r.reconnect_queued do return
    r.reconnect_queued = true
    job := new(ACP_Runtime_Recovery_Job)
    job^ = {strings.clone(r.instance), strings.clone(r.epoch), strings.clone(r.generation), force_load}
    thread.run_with_data(job, acp_runtime_recovery_worker)
}

acp_runtime_recovery_worker :: proc(data: rawptr) {
    context.allocator = runtime.heap_allocator()
    arena: vm.Arena; _ = vm.arena_init_growing(&arena); defer vm.arena_destroy(&arena)
    context.temp_allocator = vm.arena_allocator(&arena)
    job := cast(^ACP_Runtime_Recovery_Job)data
    defer { delete(job.instance); delete(job.epoch); delete(job.generation); free(job) }
    // No ownership/lifecycle lock is held while waiting for an unlock. Stop or
    // replacement can quiesce the owner and end this worker normally.
    for {
        sync.mutex_lock(&acp_runtime_mu)
        owner:=acp_runtimes[job.instance]
        waiting:=owner!=nil && owner.epoch==job.epoch && owner.generation==job.generation && !owner.quiescing && !owner.d.stopped
        needs_vault:=waiting && owner.chat!=nil
        sync.mutex_unlock(&acp_runtime_mu)
        if !waiting do return
        if !needs_vault || acp_chat_vault_ready() do break
        time.sleep(100*time.Millisecond)
    }
    lifecycle := bridge_agent_lifecycle_enter(job.instance); defer acp_runtime_leave_lifecycle(lifecycle)
    sync.mutex_lock(&acp_runtime_mu); defer sync.mutex_unlock(&acp_runtime_mu)
    previous := acp_runtimes[job.instance]
    if previous == nil || previous.epoch != job.epoch || previous.generation != job.generation || !acp_runtime_current(previous) || acp_runtime_terminal_error(&previous.d) do return
    saved, valid := acp_state_read(previous.state_path)
    defer acp_state_delete(&saved)
    raw, err := os.read_entire_file(previous.state_path, context.allocator); defer delete(raw)
    if err==nil && acp_state_waiting_for_vault(string(raw)) {
        previous.reconnect_queued=false
        acp_runtime_schedule_recovery(previous,job.force_load)
        return
    }
    rec := bridge_startup_clone_rec(previous.rec)
    defer { delete(rec.token_hash); delete(rec.agent_instance_id); delete(rec.instance_token) }
    previous.quiescing = true
    delete_key(&acp_runtimes, previous.instance)
    acp_runtime_destroy(previous) // joins the callback that queued this job
    r: ^ACP_Runtime; built := false
    if valid && err == nil && saved.instance == job.instance && saved.launch_epoch == job.epoch && saved.pipe_generation == job.generation do r, built = acp_runtime_from_state(&saved, rec)
    if !built {
        closed := acp_runtime_close_child(&ACP_Runtime{instance = job.instance, generation = job.generation})
        acp_runtime_lost_status(job.instance, closed); return
    }
    r.d.stream_retries += 1
    socket, daemon := acp_runtime_io.ensure_daemon()
    frame := pty_host_encode_pipe_request({kind = .List}); defer delete(frame)
    pipes, listed := acp_runtime_io.request(socket, frame, 2000); defer pty_host_reply_delete(pipes)
    if !daemon || !listed || pipes.kind != .Pipe_List {
        // Retain an inert owner for a later complete reconcile. A transport
        // failure cannot prove death or authorize closing an unseen child.
        acp_runtimes[r.instance] = r
        bridge_runtime_set_status(r.instance, "unreachable", "idle")
        return
    }
    same, alive := false, false
    for pipe in pipes.pipes { if pipe.instance == r.instance { same = pipe.generation == r.generation; alive = pipe.alive } }
    connected := false
    if daemon && listed && pipes.kind == .Pipe_List && r.d.stream_retries <= 3 {
        if same && alive && !job.force_load { connected = acp_runtime_connect(r, socket, saved.last_stdout_seq, string(raw)) }
        else if same || !alive { connected = acp_runtime_recover_lost(r, socket) }
    }
    if connected {
        acp_runtimes[r.instance] = r
        acp_runtime_publish_restored(r)
        work := ACP_RPC_Command{kind = .Runtime, a = "resume", runtime_work = acp_runtime_work, runtime_data = r}
        acp_rpc_call(r.client, &work)
        return
    }
    closed := acp_runtime_close_child(r)
    r.quiescing = true; acp_runtime_destroy(r)
    acp_runtime_lost_status(job.instance, closed)
}

acp_runtime_lost_status :: proc(instance: string, closed: bool, reason: string = "acp_pipe_lost") {
    if closed do bridge_runtime_set_pty_process_alive(instance, false)
    bridge_runtime_set_status(instance, "stopped" if closed else "failed", "idle")
    // Terminal end of the SIGTERM/crash path (acp_pipe_lost -> recovery could not
    // reattach or respawn): the agent is gone, so it must not keep a launch record
    // that holds the auto-update quiet window (T16d).
    bridge_runtime_remove_launch(instance)
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == instance do bridge_runtime_replace_acp_error(&inst, reason)
    sync.mutex_unlock(&bridge_runtime_mutex)
}

acp_runtime_retry_launch :: proc(instance, epoch: string, run_count: int, provider: string = "", profile: string = "") -> (handled, ok: bool) {
    if !acp_state_component_ok(epoch) do return true, false
    current_epoch := bridge_agent_instance_launch_epoch(instance); defer delete(current_epoch)
    snapshot, exists := bridge_runtime_instance_snapshot(instance)
    if exists && current_epoch == epoch && (snapshot.stopped_intent_unix_ms != 0 || snapshot.runtime_status == "failed" || snapshot.runtime_status == "stopped" || snapshot.runtime_status == "stopping") {
        return true, false // redelivery of the old launch is not an explicit retry
    }
    if acp_runtime_owned(instance) {
        launch, exists := bridge_runtime_get_launch(instance)
        if exists && launch.launch_epoch == epoch {
            sync.mutex_lock(&acp_runtime_mu)
            owner := acp_runtimes[instance]
            same := owner != nil && owner.provider == provider && owner.profile == profile_effective_id(provider, profile)
            sync.mutex_unlock(&acp_runtime_mu)
            if !same do return true, false
            snap, present := bridge_runtime_instance_snapshot(instance)
            return true, present && snap.stopped_intent_unix_ms == 0 && snap.runtime_status != "stopped" && snap.runtime_status != "stopping" && snap.runtime_status != "failed"
        }
    }
    base := bridge_shell_data_dir(); defer delete(base)
    path, _ := acp_state_path(base, instance, epoch); defer delete(path)
    if !os.exists(path) do return false, false
    socket, daemon := acp_runtime_io.ensure_daemon(); if !daemon do return true, false
    frame := pty_host_encode_pipe_request({kind = .List}); defer delete(frame)
    reply, listed := acp_runtime_io.request(socket, frame, 2000); defer pty_host_reply_delete(reply)
    if !listed || reply.kind != .Pipe_List do return true, false
    intents := make(map[string]ACP_Hub_Intent, allocator = context.temp_allocator)
    intents[instance] = {status = "starting", epoch = epoch, transport = "acp", run_count = run_count, provider = provider, profile = profile_effective_id(provider, profile)}
    // Launch caller already holds this instance's lifecycle gate.
    acp_runtime_reconcile(socket, reply.pipes, intents, lifecycle_held = true)
    snap, present := bridge_runtime_instance_snapshot(instance)
    return true, acp_runtime_owned(instance) && present && snap.stopped_intent_unix_ms == 0 && snap.runtime_status != "stopped" && snap.runtime_status != "stopping" && snap.runtime_status != "failed"
}

acp_runtime_current_record :: proc(instance: string) -> (Bridge_Local_Agent_Token_Record, bool) {
    sync.mutex_lock(&bridge_local_token_mutex); defer sync.mutex_unlock(&bridge_local_token_mutex)
    for i := len(bridge_local_token_records)-1; i >= 0; i -= 1 {
        rec := bridge_local_token_records[i]
        if rec.agent_instance_id == instance && rec.role == .Agent && rec.invalidated_at_unix_ms == 0 do return bridge_startup_clone_rec(rec), true
    }
    return {}, false
}

// Same-launch reissue is authorized by the coordinator (task comment,
// 2026-11-18). Keep the Hub assertion/run_count; plaintext never enters state.json.
acp_runtime_reissue_token :: proc(rec: Bridge_Local_Agent_Token_Record) -> Bridge_Local_Token_Issue_Result {
    sync.mutex_lock(&bridge_local_token_mutex)
    for &old in bridge_local_token_records {
        if old.agent_instance_id == rec.agent_instance_id && old.role == .Agent && old.invalidated_at_unix_ms == 0 do old.invalidated_at_unix_ms = bridge_runtime_now_ms()
    }
    bridge_agent_token_store_save_locked()
    sync.mutex_unlock(&bridge_local_token_mutex)
    return bridge_agent_token_issue(rec.agent_instance_id, rec.instance_token, .Agent, rec.run_count)
}

acp_runtime_rewrite_shims :: proc(run_dir, endpoint, token, instance: string) -> bool {
    sh, ok := bridge_bootstrap_render_ham_ctl_shim(endpoint, token, instance)
    if !ok do return false
    defer delete(sh)
    cmd, cmd_ok := bridge_bootstrap_render_ham_ctl_cmd_shim(endpoint, token, instance)
    if !cmd_ok do return false
    defer delete(cmd)
    path := bridge_prespawn_ctl_bin_path(run_dir); defer delete(path)
    if !bridge_retry_atomic_write(path, transmute([]byte)sh) do return false
    bridge_os_make_owner_executable(path)
    cmd_path := strings.concatenate({path, ".cmd"}); defer delete(cmd_path)
    return bridge_retry_atomic_write(cmd_path, transmute([]byte)cmd)
}

acp_runtime_durable_valid :: proc(d: ^ACP_Runtime_Durable) -> bool {
    return acp_driver_acp_durable_valid(d)
}

acp_runtime_from_state :: proc(s: ^ACP_State, rec: Bridge_Local_Agent_Token_Record) -> (^ACP_Runtime, bool) {
    context.allocator = runtime.heap_allocator()
    d, known := contracts.acp_provider_descriptor(s.provider)
    if !known || s.schema_version != 3 || s.runtime_binding_version != 1 || !acp_provider_binding_valid(s.binding) || s.binding.provider != s.provider || s.binding.profile != s.profile ||
       s.bridge != bridge_config.daemon_id || s.adapter_version != d.pkg.version || s.run_dir == "" || s.pipe_generation == "" ||
       !contracts.acp_descriptor_effective_mode_valid(d, s.selected_mode) { return nil, false }
    expected := bridge_runtime_default_run_dir(s.instance); defer delete(expected)
    if expected != s.run_dir do return nil, false
    r := acp_runtime_new(s.instance, s.launch_epoch, s.run_dir, s.provider, s.profile, s.catalog_etag, s.selected_model, s.selected_mode, rec)
    acp_provider_binding_delete(&r.binding); r.binding = acp_provider_binding_copy(s.binding)
    if json.unmarshal_string(s.runtime_json, &r.d) != nil || r.driver == nil || !r.driver.durable_valid(&r.d) ||
       (r.d.ready && (!s.initialized || s.sessionId == "")) || (s.sessionId != "" && !s.initialized) {
        acp_runtime_destroy(r); return nil, false
    }
    acp_runtime_merge_saved_queue(&r.d)
    r.initialized = s.initialized; r.load_session = s.loadSession
    r.generation = strings.clone(s.pipe_generation); r.session = strings.clone(s.sessionId)
    r.next_rpc_id = s.next_rpc_id; r.next_delivery_id = s.next_delivery_id
    r.saved_tools = strings.clone(s.tool_map_json); r.saved_outbox = strings.clone(s.chat_outbox_json)
    // Older checkpoints stored every notice in the FIFO's default lane.
    // Reclassify those legacy IDs so a restore cannot replay N model turns.
    acp_runtime_reclassify_saved_queue(r)
    if !acp_tools_prepare(r,r.saved_tools) {
        acp_runtime_replace(&r.d.error,"acp_protocol_error")
        r.d.auth_required=false;r.d.ready=false
    }
    if s.chat_outbox_json != "" && !acp_chat_prepare(r) { acp_runtime_destroy(r);return nil,false }
    return r, true
}

acp_runtime_reclassify_saved_queue :: proc(r: ^ACP_Runtime) {
    first_bot := -1
    for i := 0; i < len(r.d.queue); {
        input := &r.d.queue[i]
        // Old bot delivery used "bot" as the nudge sender, not its kind.
        // Match the exact saved wake, not other untyped legacy notices.
        if input.kind == "" && input.key == "" && strings.has_prefix(input.id, "notice_") && input.text == BOT_NOTICE {
            acp_runtime_replace(&input.kind, ACP_BOT_KIND)
        }
        if input.kind == ACP_BOT_KIND {
            if first_bot >= 0 {
                // Keep FIFO position, but prefer a stable attempt over a
                // legacy notice so the live worker can observe dispatch.
                first := &r.d.queue[first_bot]
                if !strings.has_prefix(first.id, ACP_BOT_INPUT_PREFIX) && strings.has_prefix(input.id, ACP_BOT_INPUT_PREFIX) {
                    first^, input^ = input^, first^
                }
                acp_inbox_remember(r, input.id)
                acp_inbox_input_delete(input^); ordered_remove(&r.d.queue, i)
                continue
            }
            first_bot = i
        }
        if input.kind == "" && strings.has_prefix(input.id, "notice_") do input.lane = .Batch
        i += 1
    }
    if first_bot >= 0 {
        r.d.queue[first_bot].lane = .Steer
        acp_runtime_replace(&r.d.queue[first_bot].key, ACP_BOT_KIND)
    }
}

// A saved FIFO may overlap a restored in-flight/completed input or contain a
// retried enqueue. Keep the first pending identity in FIFO order, never replay it.
acp_runtime_merge_saved_queue :: proc(d: ^ACP_Runtime_Durable) {
    i := 0
    for i < len(d.queue) {
        input := d.queue[i]
        duplicate := input.id == d.current_input
        for id in d.completed_inputs do if id == input.id do duplicate = true
        for old in d.queue[:i] do if old.id == input.id do duplicate = true
        if duplicate {
            acp_inbox_input_delete(input); ordered_remove(&d.queue, i)
        } else { i += 1 }
    }
}

acp_runtime_publish_restored :: proc(r: ^ACP_Runtime) {
    bridge_runtime_record_launch({agent_instance_id = strings.clone(r.instance), run_dir = strings.clone(r.run_dir), effective_transport = "acp",
        launch_epoch = strings.clone(r.epoch), acp_session_id = strings.clone(r.session), acp_load_session = r.load_session,
        pipe_generation = strings.clone(r.generation), adapter_version = r.descriptor.pkg.version})
    bridge_runtime_set_status(r.instance, "starting", "active")
    sync.mutex_lock(&bridge_runtime_mutex)
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == r.instance do inst.runtime_transport = "acp"
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == r.instance do inst.acp_session_ready = r.d.ready
    for &inst in bridge_runtime_instances do if inst.agent_instance_id == r.instance do bridge_runtime_replace_acp_error(&inst, "")
    sync.mutex_unlock(&bridge_runtime_mutex)
    bridge_runtime_set_pty_process_alive(r.instance, true)
    if r.d.auth_required { bridge_runtime_set_status(r.instance, "blocked", "waiting_user"); acp_runtime_auth_blocker(r); return }
    if r.d.ready {
        bridge_startup_accept(r.rec, bridge_runtime_now_ms())
        bridge_runtime_mark_start_success(r.instance)
        bridge_runtime_note_agent_activity(r.instance, "active" if r.d.phase == "prompt" else "idle", "acp")
    }
}

acp_runtime_recover_lost :: proc(r: ^ACP_Runtime, socket: string) -> bool {
    if r.session == "" || !r.load_session || r.d.stopped || acp_runtime_terminal_error(&r.d) || !acp_runtime_current(r) do return false
    pp, perr := profile_lookup(r.provider, r.profile); if perr != .None do return false
    binding, bound := acp_provider_profile_binding(&pp)
    binding.bootstrap_filename = r.binding.bootstrap_filename
    if !bound || !acp_provider_binding_equal(binding, r.binding) do return false
    if !acp_runtime_close_child(r) do return false
    acp_inbox_interrupt_pending(r)
    r.inbox_started = false
    if r.d.current_input != "" {
        if acp_runtime_events.prompt_finished != nil do acp_runtime_events.prompt_finished(r, r.d.current_input, "", "acp_turn_interrupted")
        append(&r.d.completed_inputs, strings.clone(r.d.current_input))
        if len(r.d.completed_inputs) > 256 { delete(r.d.completed_inputs[0]); ordered_remove(&r.d.completed_inputs, 0) }
        acp_runtime_replace(&r.d.current_input, "")
    }
    issue := acp_runtime_reissue_token(r.rec)
    endpoint, ok := acp_runtime_io.endpoint(); if !ok do return false
    if !acp_runtime_rewrite_shims(r.run_dir, endpoint, issue.plaintext_token, r.instance) do return false
    rec, verified := bridge_agent_token_verify(issue.plaintext_token); if !verified do return false
    delete(r.rec.token_hash); delete(r.rec.agent_instance_id); delete(r.rec.instance_token)
    r.rec = bridge_startup_clone_rec(rec)
    r.d.token_reissued = true; r.d.ready = false; r.d.auth_required = false; r.d.replay_only = true
    r.d.exit_pending = false
    acp_runtime_replace(&r.d.error, ""); acp_runtime_replace(&r.d.phase, "initialize")
    r.initialized = false; r.recovering = true
    req, built := acp_runtime_build_spawn(r, endpoint, issue.plaintext_token, &pp); if !built do return false
    bridge_startup_begin(issue.plaintext_token)
    bridge_startup_set_expectation(r.instance, issue.plaintext_token, false)
    bridge_startup_arm(r.instance, issue.plaintext_token, bridge_runtime_now_ms())
    reply, spawned := acp_runtime_io.spawn(socket, req); defer pty_host_reply_delete(reply)
    if !spawned || reply.kind != .Spawned || reply.generation == "" do return false
    acp_runtime_replace(&r.generation, reply.generation)
    bridge_startup_spawned(r.instance, issue.plaintext_token, reply.pid)
    acp_runtime_publish_restored(r)
    return acp_runtime_io.connect(r, socket, 0, "")
}

// Requires a complete Hub listing and ListPipes. Return all ACP identities so
// the legacy PTY reconcile never marks them ready or reaps them independently.
acp_runtime_reconcile :: proc(socket: string, pipes: []Pty_Host_Pipe_Info, intents: map[string]ACP_Hub_Intent, lifecycle_held := false) -> map[string]bool {
    context.allocator = runtime.heap_allocator()
    handled := make(map[string]bool, allocator = context.temp_allocator)
    for id, intent in intents do if intent.transport == "acp" do handled[strings.clone(id, context.temp_allocator)] = true
    for pipe in pipes do handled[strings.clone(pipe.instance, context.temp_allocator)] = true
    for id in handled {
        lifecycle: ^Bridge_Agent_Lifecycle
        if !lifecycle_held do lifecycle = bridge_agent_lifecycle_enter(id)
        intent, found := intents[id]
        pipe: Pty_Host_Pipe_Info
        for row in pipes do if row.instance == id do pipe = row
        // No intent is not permission to adopt or destroy an unknown child.
        if !found { acp_runtime_leave_lifecycle(lifecycle); continue }
        pipe_epoch := extract_json_string(pipe.meta_json, "launch_epoch", "")
        matching_child := pipe.instance != "" && pipe_epoch == intent.epoch
        delete(pipe_epoch)
        if intent.status == "failed" {
            // Failed is a terminal launch intent. Only a new launch epoch may
            // retry it; neither a valid session nor a missing child authorizes it.
            sync.mutex_lock(&acp_runtime_mu)
            owner := acp_runtimes[id]
            owned_epoch := owner != nil && owner.epoch == intent.epoch
            sync.mutex_unlock(&acp_runtime_mu)
            if owner != nil && !owned_epoch { acp_runtime_leave_lifecycle(lifecycle); continue }
            if owned_epoch do acp_runtime_detach(id)
            closed := pipe.instance == "" || matching_child && acp_runtime_close_child(&ACP_Runtime{instance = id, generation = pipe.generation})
            if closed do bridge_runtime_set_pty_process_alive(id, false)
            bridge_runtime_set_status(id, "failed", "idle")
            acp_runtime_leave_lifecycle(lifecycle); continue
        }
        if intent.status == "stopped" || intent.status == "cancelled" || intent.status == "stopping" {
            sync.mutex_lock(&acp_runtime_mu)
            owner := acp_runtimes[id]
            owned_epoch := owner != nil && owner.epoch == intent.epoch
            sync.mutex_unlock(&acp_runtime_mu)
            if matching_child || owned_epoch || owner == nil && pipe.instance == "" {
                // Stop intent fences recovery even when the child has already
                // disappeared from the daemon's complete inventory.
                bridge_runtime_mark_stop_intent(id)
                acp_runtime_command(id, "stop"); acp_runtime_detach(id)
                closed := pipe.instance == "" || matching_child && acp_runtime_close_child(&ACP_Runtime{instance = id, generation = pipe.generation})
                if closed {
                    bridge_agent_token_invalidate_instance(id)
                    bridge_runtime_set_pty_process_alive(id, false)
                    bridge_runtime_set_status(id, "stopped", "idle")
                }
            }
            acp_runtime_leave_lifecycle(lifecycle); continue
        }
        rec, has_rec := acp_runtime_current_record(id)
        if !has_rec {
            closed := pipe.instance == "" || matching_child && acp_runtime_close_child(&ACP_Runtime{instance = id, generation = pipe.generation})
            acp_runtime_lost_status(id, closed)
            acp_runtime_leave_lifecycle(lifecycle); continue
        }
        state_path_base := bridge_shell_data_dir()
        state_path, path_ok := acp_state_path(state_path_base, id, intent.epoch)
        delete(state_path_base)
        saved, readable := acp_state_read(state_path)
        raw, raw_err := os.read_entire_file(state_path, context.allocator)
        // A locked vault is temporary backpressure, not proof that a live
        // daemon child or its encrypted journal has been lost.
        if raw_err == nil && acp_state_waiting_for_vault(string(raw)) {
            acp_state_delete(&saved); delete(raw); delete(state_path)
            delete(rec.token_hash); delete(rec.agent_instance_id); delete(rec.instance_token)
            acp_runtime_leave_lifecycle(lifecycle); continue
        }
        separator := strings.index(rec.instance_token, "~")
        epoch_matches := separator >= 0 && rec.instance_token[separator+1:] == intent.epoch
        valid := path_ok && readable && saved.instance == id && saved.launch_epoch == intent.epoch && rec.run_count == intent.run_count && epoch_matches &&
            saved.provider == intent.provider && saved.profile == profile_effective_id(intent.provider, intent.profile)
        restart_reason := ""
        legacy := raw_err == nil && (!readable || saved.runtime_binding_version == 0)
        if legacy {
            restart_reason = "acp_restart_required"
            if valid {
                migrated, migration_reason := acp_runtime_upgrade_legacy_state(&saved, intent, state_path, rec)
                if migrated {
                    delete(raw)
                    raw, raw_err = os.read_entire_file(state_path, context.allocator)
                    valid = raw_err == nil
                    if valid do restart_reason = ""
                } else { valid = false; restart_reason = migration_reason }
            }
        }
        if !acp_runtime_owned(id) {
            r: ^ACP_Runtime; built := false
            if valid do r, built = acp_runtime_from_state(&saved, rec)
            if built && acp_runtime_terminal_error(&r.d) {
                closed := pipe.instance == "" || matching_child && acp_runtime_close_child(r)
                if closed do bridge_runtime_set_pty_process_alive(id, false)
                bridge_runtime_set_status(id, "failed", "idle")
                sync.mutex_lock(&bridge_runtime_mutex)
                for &inst in bridge_runtime_instances do if inst.agent_instance_id == id do bridge_runtime_replace_acp_error(&inst, r.d.error)
                sync.mutex_unlock(&bridge_runtime_mutex)
                acp_runtime_destroy(r)
            } else if built && !r.d.stopped {
                sync.mutex_lock(&acp_runtime_mu)
                if acp_runtimes == nil do acp_runtimes = make(map[string]^ACP_Runtime)
                acp_runtimes[r.instance] = r
                success := false
                if matching_child && pipe.alive && pipe.generation == saved.pipe_generation && raw_err == nil && (r.d.error == "" || r.d.auth_required) {
                    // Readiness follows successful framing/pending-call restore.
                    bridge_runtime_set_status(r.instance, "starting", "active")
                    sync.mutex_lock(&bridge_runtime_mutex)
                    for &inst in bridge_runtime_instances do if inst.agent_instance_id == r.instance { inst.runtime_transport = "acp"; inst.acp_session_ready = false }
                    sync.mutex_unlock(&bridge_runtime_mutex)
                    // Restore pending semantic roles/framing before enabling
                    // the reader. No initialize/new/load for this live child.
                    success = acp_runtime_connect(r, socket, saved.last_stdout_seq, string(raw))
                    if success {
                        acp_runtime_publish_restored(r)
                        work := ACP_RPC_Command{kind = .Runtime, a = "resume", runtime_work = acp_runtime_work, runtime_data = r}
                        acp_rpc_call(r.client, &work)
                    }
                } else if pipe.instance == "" || pipe.generation == saved.pipe_generation {
                    success = acp_runtime_recover_lost(r, socket)
                }
                sync.mutex_unlock(&acp_runtime_mu)
                if !success {
                    closed := acp_runtime_close_child(r)
                    acp_runtime_detach(id); acp_runtime_lost_status(id, closed)
                }
            } else {
                if r != nil do acp_runtime_destroy(r)
                closed := pipe.instance == "" || matching_child && acp_runtime_close_child(&ACP_Runtime{instance = id, generation = pipe.generation})
                acp_runtime_lost_status(id, closed, restart_reason if restart_reason != "" else "acp_pipe_lost")
            }
            snap, exists := bridge_runtime_instance_snapshot(id)
            if exists && snap.runtime_status == "stopped" {
                sync.mutex_lock(&bridge_runtime_mutex)
                for &inst in bridge_runtime_instances do if inst.agent_instance_id == id do bridge_runtime_replace_acp_error(&inst, restart_reason if restart_reason != "" else "acp_pipe_lost")
                sync.mutex_unlock(&bridge_runtime_mutex)
            }
        } else {
            sync.mutex_lock(&acp_runtime_mu)
            r := acp_runtimes[id]
            if r != nil && r.client == nil && r.d.error == "" && !r.d.stopped {
                acp_runtime_schedule_recovery(r, false)
            }
            sync.mutex_unlock(&acp_runtime_mu)
        }
        acp_state_delete(&saved); delete(raw); delete(state_path)
        delete(rec.token_hash); delete(rec.agent_instance_id); delete(rec.instance_token)
        acp_runtime_leave_lifecycle(lifecycle)
    }
    return handled
}

acp_runtime_leave_lifecycle :: proc(entry: ^Bridge_Agent_Lifecycle) {
    if entry != nil do bridge_agent_lifecycle_leave(entry)
}
